import XCTest
import CatalinaPerformancePriorityCore
@testable import CatalinaPerformanceMemoryCore

final class MemoryAgentServiceTests: XCTestCase {
    func testCommandParserRejectsMalformedUIDAndSession() {
        XCTAssertThrowsError(try MemoryAgentCommand.parse(["validate", "--uid", "0"]))
        XCTAssertThrowsError(try MemoryAgentCommand.parse(["monitor", "--uid", "501", "--session", ""]))
        XCTAssertNoThrow(try MemoryAgentCommand.parse(["monitor", "--uid", "501", "--session", "session"] as [String]))
    }

    func testStartLaunchesMonitorAndObservesReadyStatus() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryAgentStateStore(runtimeRoot: root, requestingUID: 501)
        let launcher = ServiceLauncher()
        launcher.onLaunch = { _, _, session, _ in
            try store.writeStatus(MemoryAgentStatus(
                state: .monitoring,
                sessionIdentifier: session,
                managedFamilyCount: 0,
                managedProcessCount: 0,
                lastAppliedGeneration: nil,
                message: "ready"
            ))
        }
        let service = makeService(store: store, launcher: launcher)

        XCTAssertEqual(try service.start(uid: 501), .success)
        XCTAssertEqual(launcher.launchCount, 1)
    }

    func testMonitorStopRequestRestoresAppliedPriority() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryAgentStateStore(runtimeRoot: root, requestingUID: 501)
        let process = serviceIdentity(pid: 10)
        let inspector = ServiceInspector(values: [10: process])
        let mutator = ServiceMutator(values: [10: 0])
        let clock = ServiceClock()
        clock.onSleep = { _ in
            if mutator.values[10] == 5 {
                try? store.createStopRequest()
            }
        }
        let service = makeService(
            store: store,
            clock: clock,
            desired: desiredState(process: process),
            inspector: inspector,
            mutator: mutator
        )

        XCTAssertEqual(try service.monitor(uid: 501, sessionIdentifier: "session"), .success)
        XCTAssertEqual(mutator.values[10], 0)
    }

    func testInvalidDesiredSessionRestoresOutstandingState() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryAgentStateStore(runtimeRoot: root, requestingUID: 501)
        let process = serviceIdentity(pid: 10)
        let inspector = ServiceInspector(values: [10: process])
        let mutator = ServiceMutator(values: [10: 0])
        let controller = MemoryInterventionController(inspector: inspector, mutator: mutator, stateStore: store, requestingUID: 501)
        _ = try controller.reconcile(desired: desiredState(process: process))
        XCTAssertEqual(mutator.values[10], 5)

        let service = makeService(
            store: store,
            desired: MemoryDesiredState(
                sessionIdentifier: "different-session",
                requestingUID: 501,
                generation: 2,
                shouldStopAndRestore: false,
                families: []
            ),
            inspector: inspector,
            mutator: mutator
        )

        XCTAssertEqual(try service.monitor(uid: 501, sessionIdentifier: "session"), .success)
        XCTAssertEqual(mutator.values[10], 0)
    }

    func testStatusReturnsNoDesiredStateWhenNoStatusExists() {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryAgentStateStore(runtimeRoot: root, requestingUID: 501)
        let service = makeService(store: store)

        XCTAssertEqual(service.status(uid: 501), .noDesiredState)
    }

    private func makeService(
        store: MemoryAgentStateStore,
        launcher: ServiceLauncher = ServiceLauncher(),
        clock: ServiceClock = ServiceClock(),
        desired: MemoryDesiredState? = nil,
        inspector: ServiceInspector? = nil,
        mutator: ServiceMutator? = nil
    ) -> MemoryAgentService {
        let desiredValue = desired ?? MemoryDesiredState(
            sessionIdentifier: "session",
            requestingUID: 501,
            generation: 1,
            shouldStopAndRestore: false,
            families: []
        )
        let processInspector = inspector ?? ServiceInspector(values: [:])
        let priorityMutator = mutator ?? ServiceMutator(values: [:])
        return MemoryAgentService(
            desiredStateProvider: { uid in
                guard uid == 501 else { throw MemoryDesiredStateStoreError.requestingUserIsNotConsoleUser }
                return desiredValue
            },
            storeProvider: { _ in store },
            controllerProvider: { uid, stateStore in
                MemoryInterventionController(
                    inspector: processInspector,
                    mutator: priorityMutator,
                    stateStore: stateStore,
                    requestingUID: uid,
                    nowProvider: { Date(timeIntervalSince1970: 100) }
                )
            },
            lockProvider: ServiceLockProvider(),
            launcher: launcher,
            clock: clock,
            agentPath: "/tmp/CatalinaPerformanceMemoryAgent"
        )
    }

    private func desiredState(process: AppPriorityProcessIdentity) -> MemoryDesiredState {
        let bundle = "/Applications/App.app"
        let identifier = bundle.lowercased()
        return MemoryDesiredState(
            sessionIdentifier: "session",
            requestingUID: 501,
            generation: 1,
            shouldStopAndRestore: false,
            families: [MemoryDesiredFamily(
                identifier: identifier,
                displayName: "App",
                bundlePath: bundle,
                processes: [MemoryDesiredProcess(identity: process, familyIdentifier: identifier, requestedNiceValue: 5)]
            )]
        )
    }

    private func serviceIdentity(pid: Int32) -> AppPriorityProcessIdentity {
        return AppPriorityProcessIdentity(
            pid: pid,
            parentPID: 1,
            effectiveUID: 501,
            executablePath: "/Applications/App.app/Contents/MacOS/App",
            startSeconds: Int64(pid) * 10,
            startMicroseconds: 0,
            processName: "App",
            niceValue: 0
        )
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class ServiceInspector: AppPriorityProcessInspecting {
    var values: [Int32: AppPriorityProcessIdentity]
    init(values: [Int32: AppPriorityProcessIdentity]) { self.values = values }
    func allProcesses() throws -> [AppPriorityProcessIdentity] { return Array(values.values) }
    func process(pid: Int32) throws -> AppPriorityProcessIdentity {
        guard let value = values[pid] else { throw AppPriorityProcessError.readFailed(pid: pid, code: -3) }
        return value
    }
}

private final class ServiceMutator: AppPriorityPriorityMutating {
    var values: [Int32: Int32]
    init(values: [Int32: Int32]) { self.values = values }
    func priority(pid: Int32) throws -> Int32 { return values[pid] ?? 0 }
    func setPriority(pid: Int32, value: Int32) throws { values[pid] = value }
}

private final class ServiceLockProvider: AppPriorityAgentLocking {
    private var nextDescriptor: Int32 = 10
    func tryAcquire(path: String) -> AppPriorityAgentLockResult {
        defer { nextDescriptor += 1 }
        return .acquired(nextDescriptor)
    }
    func close(descriptor: Int32) {}
}

private final class ServiceLauncher: AppPriorityAgentLaunching {
    var launchCount = 0
    var onLaunch: ((String, UInt32, String, URL) throws -> Void)?
    func launch(agentPath: String, uid: UInt32, sessionIdentifier: String, logURL: URL) throws {
        launchCount += 1
        try onLaunch?(agentPath, uid, sessionIdentifier, logURL)
    }
}

private final class ServiceClock: AppPriorityAgentClock {
    var onSleep: ((TimeInterval) -> Void)?
    func sleep(seconds: TimeInterval) { onSleep?(seconds) }
}
