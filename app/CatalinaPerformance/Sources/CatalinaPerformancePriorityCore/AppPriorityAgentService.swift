import Foundation
import CatalinaProcessSupport
#if os(Linux)
import Glibc
#else
import Darwin
#endif

public enum AppPriorityAgentExit: Int32, Equatable {
    case success = 0
    case failure = 1
    case usage = 2
    case disabled = 10
    case noRuntimeState = 11
    case alreadyRunning = 12
    case restorePending = 13
}

public enum AppPriorityAgentCommand: Equatable {
    case validate(uid: UInt32)
    case start(uid: UInt32)
    case monitor(uid: UInt32, session: String)
    case stopAndRestore(uid: UInt32)
    case restore(uid: UInt32)
    case status(uid: UInt32)

    public static func parse(_ arguments: [String]) throws -> AppPriorityAgentCommand {
        guard let command = arguments.first else { throw AppPriorityAgentExit.usage }
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
                  remainder[3].count <= 128 else { throw AppPriorityAgentExit.usage }
            return .monitor(uid: uid, session: remainder[3])
        default:
            throw AppPriorityAgentExit.usage
        }
    }

    private static func parseUIDOnly(_ values: [String]) throws -> UInt32 {
        guard values.count == 2, values[0] == "--uid", let uid = parseUID(values[1]) else {
            throw AppPriorityAgentExit.usage
        }
        return uid
    }

    private static func parseUID(_ value: String) -> UInt32? {
        guard !value.isEmpty, value.allSatisfy({ $0 >= "0" && $0 <= "9" }), let parsed = UInt64(value), parsed > 0, parsed <= UInt64(UInt32.max) else { return nil }
        return UInt32(parsed)
    }
}

extension AppPriorityAgentExit: Error {}

public enum AppPriorityAgentLockResult: Equatable {
    case acquired(Int32)
    case busy
    case failure(Int32)
}

public protocol AppPriorityAgentLocking {
    func tryAcquire(path: String) -> AppPriorityAgentLockResult
    func close(descriptor: Int32)
}

public struct DarwinAppPriorityAgentLockProvider: AppPriorityAgentLocking {
    public init() {}
    public func tryAcquire(path: String) -> AppPriorityAgentLockResult {
        let result = path.withCString { cp_open_lock($0) }
        if result >= 0 { return .acquired(result) }
        if result == -EWOULDBLOCK || result == -EAGAIN { return .busy }
        return .failure(result)
    }
    public func close(descriptor: Int32) { cp_close_fd(descriptor) }
}

public protocol AppPriorityAgentLaunching {
    func launch(agentPath: String, uid: UInt32, sessionIdentifier: String, logURL: URL) throws
}

public struct ProcessAppPriorityAgentLauncher: AppPriorityAgentLaunching {
    public init() {}
    public func launch(agentPath: String, uid: UInt32, sessionIdentifier: String, logURL: URL) throws {
        _ = FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: NSNumber(value: Int16(0o600))])
        guard let logHandle = FileHandle(forWritingAtPath: logURL.path), let nullHandle = FileHandle(forReadingAtPath: "/dev/null") else {
            throw AppPriorityProcessError.unsupported
        }
        logHandle.seekToEndOfFile()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: agentPath)
        process.arguments = ["monitor", "--uid", String(uid), "--session", sessionIdentifier]
        process.standardInput = nullHandle
        process.standardOutput = logHandle
        process.standardError = logHandle
        try process.run()
    }
}

public protocol AppPriorityAgentClock {
    func sleep(seconds: TimeInterval)
}

public struct SystemAppPriorityAgentClock: AppPriorityAgentClock {
    public init() {}
    public func sleep(seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }
}

public final class AppPriorityAgentService {
    public typealias SelectionProvider = (UInt32) throws -> ValidatedAppPrioritySelection
    public typealias StoreProvider = (UInt32) -> AppPriorityStateStore
    public typealias MonitorProvider = (ValidatedAppPrioritySelection, AppPriorityStateStore, String, AppPriorityMonitorIdentity?) throws -> AppPriorityMonitor
    public typealias DirectRestoreHandler = (UInt32) throws -> AppPriorityAgentExit

    private let selectionProvider: SelectionProvider
    private let storeProvider: StoreProvider
    private let monitorProvider: MonitorProvider
    private let directRestoreHandler: DirectRestoreHandler?
    private let lockProvider: AppPriorityAgentLocking
    private let launcher: AppPriorityAgentLaunching
    private let clock: AppPriorityAgentClock
    private let agentPath: String

    public init(
        selectionProvider: @escaping SelectionProvider,
        storeProvider: @escaping StoreProvider,
        monitorProvider: @escaping MonitorProvider,
        directRestoreHandler: DirectRestoreHandler? = nil,
        lockProvider: AppPriorityAgentLocking = DarwinAppPriorityAgentLockProvider(),
        launcher: AppPriorityAgentLaunching = ProcessAppPriorityAgentLauncher(),
        clock: AppPriorityAgentClock = SystemAppPriorityAgentClock(),
        agentPath: String
    ) {
        self.selectionProvider = selectionProvider
        self.storeProvider = storeProvider
        self.monitorProvider = monitorProvider
        self.directRestoreHandler = directRestoreHandler
        self.lockProvider = lockProvider
        self.launcher = launcher
        self.clock = clock
        self.agentPath = agentPath
    }

    public func execute(_ command: AppPriorityAgentCommand) -> AppPriorityAgentExit {
        do {
            switch command {
            case .validate(let uid): return try validate(uid: uid)
            case .start(let uid): return try start(uid: uid)
            case .monitor(let uid, let session): return try monitor(uid: uid, sessionIdentifier: session)
            case .stopAndRestore(let uid): return try stopAndRestore(uid: uid)
            case .restore(let uid): return try restore(uid: uid)
            case .status(let uid): return status(uid: uid)
            }
        } catch let exit as AppPriorityAgentExit {
            return exit
        } catch {
            return .failure
        }
    }

    public func validate(uid: UInt32) throws -> AppPriorityAgentExit {
        let selection = try selectionProvider(uid)
        return selection.enabled ? .success : .disabled
    }

    public func start(uid: UInt32) throws -> AppPriorityAgentExit {
        let selection = try selectionProvider(uid)
        guard selection.enabled else { return .disabled }
        let store = storeProvider(uid)
        try store.prepareDirectories()
        let startLock = lockProvider.tryAcquire(path: store.paths.startLockFile.path)
        guard case .acquired(let startDescriptor) = startLock else {
            if case .busy = startLock { return .alreadyRunning }
            return .failure
        }
        defer { lockProvider.close(descriptor: startDescriptor) }

        switch lockProvider.tryAcquire(path: store.paths.monitorLockFile.path) {
        case .busy: return .alreadyRunning
        case .failure: return .failure
        case .acquired(let descriptor): lockProvider.close(descriptor: descriptor)
        }
        store.clearStopRequest()
        let session = UUID().uuidString
        try store.writeStatus(AppPriorityStatus(state: .starting, boostedCount: 0, skippedCount: 0, message: "Starting App Priority monitor", sessionIdentifier: session))
        try launcher.launch(agentPath: agentPath, uid: uid, sessionIdentifier: session, logURL: store.paths.monitorLogFile)
        for _ in 0..<50 {
            if let status = store.loadStatus(), status.sessionIdentifier == session {
                switch status.state {
                case .active, .activeWithSkipped, .waitingForSelectedApp: return .success
                case .failed:
                    try? store.createStopRequest()
                    return .failure
                default: break
                }
            }
            clock.sleep(seconds: 0.2)
        }
        try? store.createStopRequest()
        return .failure
    }

    public func monitor(uid: UInt32, sessionIdentifier: String) throws -> AppPriorityAgentExit {
        let store = storeProvider(uid)
        try store.prepareDirectories()
        let lock = lockProvider.tryAcquire(path: store.paths.monitorLockFile.path)
        guard case .acquired(let descriptor) = lock else {
            if case .busy = lock { return .alreadyRunning }
            return .failure
        }
        defer { lockProvider.close(descriptor: descriptor) }
        let selection = try selectionProvider(uid)
        guard selection.enabled else { return .disabled }
        let inspector = DarwinAppPriorityProcessInspector()
        let identity = try? inspector.process(pid: Int32(getpid()))
        let monitorIdentity = identity.map { AppPriorityMonitorIdentity(pid: $0.pid, startSeconds: $0.startSeconds, startMicroseconds: $0.startMicroseconds) }
        if let monitorIdentity = monitorIdentity { try? store.writeMonitorIdentity(monitorIdentity) }
        let monitor = try monitorProvider(selection, store, sessionIdentifier, monitorIdentity)
        let outcome = try monitor.run()
        return outcome.outstandingRecords.isEmpty ? .success : .restorePending
    }

    public func stopAndRestore(uid: UInt32) throws -> AppPriorityAgentExit {
        let store = storeProvider(uid)
        guard store.runtimeStateIfPresent() != nil else { return .noRuntimeState }
        try store.createStopRequest()
        for _ in 0..<60 {
            if let status = store.loadStatus() {
                if status.state == .restored { return .success }
            }
            switch lockProvider.tryAcquire(path: store.paths.monitorLockFile.path) {
            case .acquired(let descriptor):
                lockProvider.close(descriptor: descriptor)
                return try restore(uid: uid)
            case .busy: break
            case .failure: break
            }
            clock.sleep(seconds: 0.25)
        }
        return try restore(uid: uid)
    }

    public func restore(uid: UInt32) throws -> AppPriorityAgentExit {
        if let handler = directRestoreHandler { return try handler(uid) }
        let store = storeProvider(uid)
        guard let state = store.runtimeStateIfPresent() else { return .noRuntimeState }
        switch lockProvider.tryAcquire(path: store.paths.monitorLockFile.path) {
        case .busy: return .alreadyRunning
        case .failure: return .failure
        case .acquired(let descriptor): lockProvider.close(descriptor: descriptor)
        }
        let selection = ValidatedAppPrioritySelection(enabled: true, application: state.selectedApplication, requestingUID: state.requestingUID)
        let monitor = try monitorProvider(selection, store, state.sessionIdentifier, state.monitorIdentity)
        let outcome = try monitor.restoreOutstandingRecords(state.records)
        return outcome.outstandingRecords.isEmpty ? .success : .restorePending
    }

    public func status(uid: UInt32) -> AppPriorityAgentExit {
        return storeProvider(uid).loadStatus() == nil ? .noRuntimeState : .success
    }

    public func statusValue(uid: UInt32) -> AppPriorityStatus? {
        return storeProvider(uid).loadStatus()
    }
}

public enum AppPriorityAgentProductionFactory {
    public static func make(environment: [String: String] = ProcessInfo.processInfo.environment, agentPath: String = CommandLine.arguments[0]) -> AppPriorityAgentService {
        let runtimeRoot = URL(fileURLWithPath: environment["CATALINA_PERFORMANCE_PRIORITY_RUNTIME_ROOT"] ?? "/var/run/CatalinaPerformance", isDirectory: true)
        let selectionProvider: AppPriorityAgentService.SelectionProvider = { uid in
            let home = try homeDirectory(uid: uid)
            let selectionURL: URL
            if let explicit = environment["CATALINA_PERFORMANCE_PRIORITY_SELECTION_FILE"], !explicit.isEmpty {
                selectionURL = URL(fileURLWithPath: explicit)
            } else {
                selectionURL = home.appendingPathComponent("Library/Application Support/CatalinaPerformance/app_priority/selection.json")
            }
            return try AppPrioritySelectionValidator().validate(
                selectionFileURL: selectionURL,
                requestingUID: uid,
                consoleUID: UInt32(cp_console_uid()),
                expectedHomeDirectory: home
            )
        }
        let storeProvider: AppPriorityAgentService.StoreProvider = { uid in
            AppPriorityStateStore(runtimeRoot: runtimeRoot, requestingUID: uid)
        }
        let monitorProvider: AppPriorityAgentService.MonitorProvider = { selection, store, session, identity in
            let system = DarwinAppPriorityProcessInspector()
            return try AppPriorityMonitor(selection: selection, inspector: system, mutator: system, stateStore: store, sessionIdentifier: session, monitorIdentity: identity)
        }
        return AppPriorityAgentService(selectionProvider: selectionProvider, storeProvider: storeProvider, monitorProvider: monitorProvider, agentPath: agentPath)
    }

    private static func homeDirectory(uid: UInt32) throws -> URL {
        guard let entry = getpwuid(uid_t(uid)), let directoryPointer = entry.pointee.pw_dir else {
            throw AppPriorityValidationError.unsafeSelectionPath
        }
        return URL(fileURLWithPath: String(cString: directoryPointer), isDirectory: true).standardizedFileURL
    }
}
