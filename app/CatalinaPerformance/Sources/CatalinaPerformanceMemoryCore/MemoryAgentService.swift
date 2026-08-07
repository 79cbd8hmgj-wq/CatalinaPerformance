import Foundation
import CatalinaPerformancePriorityCore
import CatalinaProcessSupport
#if os(Linux)
import Glibc
#else
import Darwin
#endif

public enum MemoryAgentExit: Int32, Equatable, Error {
    case success = 0
    case failure = 1
    case usage = 2
    case noDesiredState = 10
    case alreadyRunning = 11
    case restorePending = 12
}

public enum MemoryAgentCommand: Equatable {
    case validate(uid: UInt32)
    case start(uid: UInt32)
    case monitor(uid: UInt32, session: String)
    case stopAndRestore(uid: UInt32)
    case restore(uid: UInt32)
    case status(uid: UInt32)

    public static func parse(_ arguments: [String]) throws -> MemoryAgentCommand {
        guard let command = arguments.first else { throw MemoryAgentExit.usage }
        let remainder = Array(arguments.dropFirst())
        switch command {
        case "validate": return .validate(uid: try parseUIDOnly(remainder))
        case "start": return .start(uid: try parseUIDOnly(remainder))
        case "stop-and-restore": return .stopAndRestore(uid: try parseUIDOnly(remainder))
        case "restore": return .restore(uid: try parseUIDOnly(remainder))
        case "status": return .status(uid: try parseUIDOnly(remainder))
        case "monitor":
            guard remainder.count == 4,
                  remainder[0] == "--uid",
                  let uid = parseUID(remainder[1]),
                  remainder[2] == "--session",
                  !remainder[3].isEmpty,
                  remainder[3].count <= 128 else {
                throw MemoryAgentExit.usage
            }
            return .monitor(uid: uid, session: remainder[3])
        default:
            throw MemoryAgentExit.usage
        }
    }

    private static func parseUIDOnly(_ values: [String]) throws -> UInt32 {
        guard values.count == 2,
              values[0] == "--uid",
              let uid = parseUID(values[1]) else {
            throw MemoryAgentExit.usage
        }
        return uid
    }

    private static func parseUID(_ value: String) -> UInt32? {
        guard !value.isEmpty,
              value.allSatisfy({ $0 >= "0" && $0 <= "9" }),
              let parsed = UInt64(value),
              parsed > 0,
              parsed <= UInt64(UInt32.max) else {
            return nil
        }
        return UInt32(parsed)
    }
}

public final class MemoryAgentService {
    public typealias DesiredStateProvider = (UInt32) throws -> MemoryDesiredState
    public typealias StoreProvider = (UInt32) -> MemoryAgentStateStore
    public typealias ControllerProvider = (UInt32, MemoryAgentStateStore) -> MemoryInterventionController

    private let desiredStateProvider: DesiredStateProvider
    private let storeProvider: StoreProvider
    private let controllerProvider: ControllerProvider
    private let lockProvider: AppPriorityAgentLocking
    private let launcher: AppPriorityAgentLaunching
    private let clock: AppPriorityAgentClock
    private let agentPath: String

    public init(
        desiredStateProvider: @escaping DesiredStateProvider,
        storeProvider: @escaping StoreProvider,
        controllerProvider: @escaping ControllerProvider,
        lockProvider: AppPriorityAgentLocking = DarwinAppPriorityAgentLockProvider(),
        launcher: AppPriorityAgentLaunching = ProcessAppPriorityAgentLauncher(),
        clock: AppPriorityAgentClock = SystemAppPriorityAgentClock(),
        agentPath: String
    ) {
        self.desiredStateProvider = desiredStateProvider
        self.storeProvider = storeProvider
        self.controllerProvider = controllerProvider
        self.lockProvider = lockProvider
        self.launcher = launcher
        self.clock = clock
        self.agentPath = agentPath
    }

    public func execute(_ command: MemoryAgentCommand) -> MemoryAgentExit {
        do {
            switch command {
            case .validate(let uid): return try validate(uid: uid)
            case .start(let uid): return try start(uid: uid)
            case .monitor(let uid, let session): return try monitor(uid: uid, sessionIdentifier: session)
            case .stopAndRestore(let uid): return try stopAndRestore(uid: uid)
            case .restore(let uid): return try restore(uid: uid)
            case .status(let uid): return status(uid: uid)
            }
        } catch let exit as MemoryAgentExit {
            return exit
        } catch {
            return .failure
        }
    }

    public func validate(uid: UInt32) throws -> MemoryAgentExit {
        let desired = try desiredStateProvider(uid)
        guard desired.requestingUID == uid else { return .failure }
        return .success
    }

    public func start(uid: UInt32) throws -> MemoryAgentExit {
        let desired = try desiredStateProvider(uid)
        guard desired.requestingUID == uid else { return .failure }

        let store = storeProvider(uid)
        try store.prepareDirectories()
        let startLock = lockProvider.tryAcquire(path: store.paths.startLockFile.path)
        guard case .acquired(let startDescriptor) = startLock else {
            if case .busy = startLock { return .alreadyRunning }
            return .failure
        }
        defer { lockProvider.close(descriptor: startDescriptor) }

        switch lockProvider.tryAcquire(path: store.paths.monitorLockFile.path) {
        case .busy:
            return .alreadyRunning
        case .failure:
            return .failure
        case .acquired(let descriptor):
            lockProvider.close(descriptor: descriptor)
        }

        store.clearStopRequest()
        try store.writeStatus(MemoryAgentStatus(
            state: .starting,
            sessionIdentifier: desired.sessionIdentifier,
            managedFamilyCount: 0,
            managedProcessCount: 0,
            managedFamilyNames: [],
            lastAppliedGeneration: nil,
            message: "Starting Memory Management monitor."
        ))

        try launcher.launch(
            agentPath: agentPath,
            uid: uid,
            sessionIdentifier: desired.sessionIdentifier,
            logURL: store.paths.monitorLogFile
        )

        for _ in 0..<50 {
            if let status = store.loadStatus(), status.sessionIdentifier == desired.sessionIdentifier {
                switch status.state {
                case .monitoring, .active, .restored:
                    return .success
                case .failed, .restorePending:
                    try? store.createStopRequest()
                    return status.state == .restorePending ? .restorePending : .failure
                case .ready, .starting, .restoring:
                    break
                }
            }
            clock.sleep(seconds: 0.2)
        }
        try? store.createStopRequest()
        return .failure
    }

    public func monitor(uid: UInt32, sessionIdentifier: String) throws -> MemoryAgentExit {
        let store = storeProvider(uid)
        try store.prepareDirectories()
        let lock = lockProvider.tryAcquire(path: store.paths.monitorLockFile.path)
        guard case .acquired(let descriptor) = lock else {
            if case .busy = lock { return .alreadyRunning }
            return .failure
        }
        defer { lockProvider.close(descriptor: descriptor) }

        let inspector = DarwinAppPriorityProcessInspector()
        if let identity = try? inspector.process(pid: Int32(getpid())) {
            let monitorIdentity = MemoryAgentMonitorIdentity(
                pid: identity.pid,
                startSeconds: identity.startSeconds,
                startMicroseconds: identity.startMicroseconds
            )
            try? store.writeMonitorIdentity(monitorIdentity)
        }

        let controller = controllerProvider(uid, store)
        try store.writeStatus(MemoryAgentStatus(
            state: .monitoring,
            sessionIdentifier: sessionIdentifier,
            managedFamilyCount: 0,
            managedProcessCount: 0,
            managedFamilyNames: [],
            lastAppliedGeneration: nil,
            message: "Memory Management monitor is waiting for confirmed pressure."
        ))

        while !store.stopRequested() {
            do {
                let desired = try desiredStateProvider(uid)
                guard desired.sessionIdentifier == sessionIdentifier,
                      desired.requestingUID == uid else {
                    return try restoreAfterInvalidDesiredState(
                        uid: uid,
                        sessionIdentifier: sessionIdentifier,
                        store: store,
                        controller: controller,
                        message: "Desired state changed session identity; outstanding memory policy was restored."
                    )
                }

                let lastGeneration = store.runtimeStateIfPresent()?.lastAppliedGeneration ?? 0
                if desired.generation > lastGeneration {
                    let outcome = try controller.reconcile(desired: desired)
                    let confirmed = confirmedSummary(store: store)
                    let state: MemoryAgentStatus.State
                    if outcome.outstandingRestorationCount > 0 && desired.shouldStopAndRestore {
                        state = .restorePending
                    } else if confirmed.managedFamilyCount > 0 {
                        state = .active
                    } else {
                        state = .monitoring
                    }
                    try store.writeStatus(status(
                        state: state,
                        sessionIdentifier: sessionIdentifier,
                        generation: desired.generation,
                        outcome: outcome,
                        store: store,
                        message: outcome.failures.isEmpty
                            ? "Memory Management desired state reconciled."
                            : "Memory Management reconciled with recoverable failures."
                    ))
                    if desired.shouldStopAndRestore {
                        store.clearStopRequest()
                        store.removeRuntimeFilesAfterSuccessfulRestore()
                        return outcome.outstandingRestorationCount == 0 ? .success : .restorePending
                    }
                }
            } catch {
                return try restoreAfterInvalidDesiredState(
                    uid: uid,
                    sessionIdentifier: sessionIdentifier,
                    store: store,
                    controller: controller,
                    message: "Desired state became unavailable or invalid; outstanding memory policy was restored."
                )
            }

            clock.sleep(seconds: 1.0)
        }

        let outcome = try controller.restoreAll()
        let finalState: MemoryAgentStatus.State = outcome.outstandingRestorationCount == 0 ? .restored : .restorePending
        try store.writeStatus(status(
            state: finalState,
            sessionIdentifier: sessionIdentifier,
            generation: store.runtimeStateIfPresent()?.lastAppliedGeneration,
            outcome: outcome,
            store: store,
            message: outcome.outstandingRestorationCount == 0
                ? "Memory Management restored all valid process priorities."
                : "Memory Management restoration remains pending for one or more processes."
        ))
        store.clearStopRequest()
        store.removeRuntimeFilesAfterSuccessfulRestore()
        return outcome.outstandingRestorationCount == 0 ? .success : .restorePending
    }

    public func stopAndRestore(uid: UInt32) throws -> MemoryAgentExit {
        let store = storeProvider(uid)
        guard store.runtimeStateIfPresent() != nil || store.loadStatus() != nil else {
            return .noDesiredState
        }
        try store.createStopRequest()

        for _ in 0..<60 {
            if let status = store.loadStatus() {
                if status.state == .restored { return .success }
                if status.state == .restorePending { return .restorePending }
            }
            switch lockProvider.tryAcquire(path: store.paths.monitorLockFile.path) {
            case .acquired(let descriptor):
                lockProvider.close(descriptor: descriptor)
                return try restore(uid: uid)
            case .busy:
                break
            case .failure:
                break
            }
            clock.sleep(seconds: 0.25)
        }
        return try restore(uid: uid)
    }

    public func restore(uid: UInt32) throws -> MemoryAgentExit {
        let store = storeProvider(uid)
        guard store.runtimeStateIfPresent() != nil else { return .noDesiredState }
        switch lockProvider.tryAcquire(path: store.paths.monitorLockFile.path) {
        case .busy:
            return .alreadyRunning
        case .failure:
            return .failure
        case .acquired(let descriptor):
            lockProvider.close(descriptor: descriptor)
        }

        let controller = controllerProvider(uid, store)
        let outcome = try controller.restoreAll()
        let finalState: MemoryAgentStatus.State = outcome.outstandingRestorationCount == 0 ? .restored : .restorePending
        try store.writeStatus(status(
            state: finalState,
            sessionIdentifier: store.runtimeStateIfPresent()?.sessionIdentifier,
            generation: store.runtimeStateIfPresent()?.lastAppliedGeneration,
            outcome: outcome,
            store: store,
            message: outcome.outstandingRestorationCount == 0
                ? "Memory Management restoration completed."
                : "Memory Management restoration remains pending."
        ))
        store.removeRuntimeFilesAfterSuccessfulRestore()
        return outcome.outstandingRestorationCount == 0 ? .success : .restorePending
    }

    public func status(uid: UInt32) -> MemoryAgentExit {
        return storeProvider(uid).loadStatus() == nil ? .noDesiredState : .success
    }

    public func statusValue(uid: UInt32) -> MemoryAgentStatus? {
        return storeProvider(uid).loadStatus()
    }

    private func restoreAfterInvalidDesiredState(
        uid: UInt32,
        sessionIdentifier: String,
        store: MemoryAgentStateStore,
        controller: MemoryInterventionController,
        message: String
    ) throws -> MemoryAgentExit {
        let outcome = try controller.restoreAll()
        let finalState: MemoryAgentStatus.State = outcome.outstandingRestorationCount == 0 ? .restored : .restorePending
        try store.writeStatus(status(
            state: finalState,
            sessionIdentifier: sessionIdentifier,
            generation: store.runtimeStateIfPresent()?.lastAppliedGeneration,
            outcome: outcome,
            store: store,
            message: message
        ))
        store.removeRuntimeFilesAfterSuccessfulRestore()
        return outcome.outstandingRestorationCount == 0 ? .success : .restorePending
    }

    private func confirmedSummary(store: MemoryAgentStateStore) -> MemoryAgentConfirmedManagementSummary {
        return store.runtimeStateIfPresent()?.confirmedManagementSummary ??
            MemoryAgentConfirmedManagementSummary(managedFamilyNames: [], managedProcessCount: 0)
    }

    private func status(
        state: MemoryAgentStatus.State,
        sessionIdentifier: String?,
        generation: UInt64?,
        outcome: MemoryInterventionOutcome,
        store: MemoryAgentStateStore,
        message: String
    ) -> MemoryAgentStatus {
        let confirmed = confirmedSummary(store: store)
        return MemoryAgentStatus(
            state: state,
            sessionIdentifier: sessionIdentifier,
            managedFamilyCount: confirmed.managedFamilyCount,
            managedProcessCount: confirmed.managedProcessCount,
            managedFamilyNames: confirmed.managedFamilyNames,
            lastAppliedGeneration: generation,
            message: message
        )
    }
}

public enum MemoryAgentProductionFactory {
    public static func make(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        agentPath: String = CommandLine.arguments[0]
    ) -> MemoryAgentService {
        let runtimeRoot = URL(
            fileURLWithPath: environment["CATALINA_PERFORMANCE_MEMORY_RUNTIME_ROOT"] ?? "/var/run/CatalinaPerformance",
            isDirectory: true
        )

        let desiredStateProvider: MemoryAgentService.DesiredStateProvider = { uid in
            let home = try homeDirectory(uid: uid)
            let expectedDirectory = home
                .appendingPathComponent("Library/Application Support/CatalinaPerformance/memory_management", isDirectory: true)
            let desiredURL: URL
            if let explicit = environment["CATALINA_PERFORMANCE_MEMORY_DESIRED_STATE_FILE"], !explicit.isEmpty {
                desiredURL = URL(fileURLWithPath: explicit)
            } else {
                desiredURL = expectedDirectory.appendingPathComponent("desired-state.json")
            }
            let store = MemoryDesiredStateStore(directoryURL: desiredURL.deletingLastPathComponent())
            return try store.loadValidatedForAgent(
                requestingUID: uid,
                consoleUID: UInt32(cp_console_uid()),
                expectedHomeDirectory: home
            )
        }

        let storeProvider: MemoryAgentService.StoreProvider = { uid in
            MemoryAgentStateStore(runtimeRoot: runtimeRoot, requestingUID: uid)
        }

        let controllerProvider: MemoryAgentService.ControllerProvider = { uid, store in
            let system = DarwinAppPriorityProcessInspector()
            return MemoryInterventionController(
                inspector: system,
                mutator: system,
                stateStore: store,
                requestingUID: uid
            )
        }

        return MemoryAgentService(
            desiredStateProvider: desiredStateProvider,
            storeProvider: storeProvider,
            controllerProvider: controllerProvider,
            agentPath: agentPath
        )
    }

    private static func homeDirectory(uid: UInt32) throws -> URL {
        guard let entry = getpwuid(uid_t(uid)),
              let directoryPointer = entry.pointee.pw_dir else {
            throw MemoryDesiredStateStoreError.unsafePath
        }
        return URL(fileURLWithPath: String(cString: directoryPointer), isDirectory: true)
            .standardizedFileURL
    }
}
