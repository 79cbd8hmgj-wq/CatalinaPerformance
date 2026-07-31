import XCTest
import Foundation
@testable import CatalinaPerformancePriorityCore

final class AppPriorityAgentServiceTests: XCTestCase {
    private final class FakeLock: AppPriorityAgentLocking {
        var results: [AppPriorityAgentLockResult]
        var requestedPaths: [String] = []
        init(_ results: [AppPriorityAgentLockResult]) { self.results = results }
        func tryAcquire(path: String) -> AppPriorityAgentLockResult {
            requestedPaths.append(path)
            return results.isEmpty ? .acquired(99) : results.removeFirst()
        }
        func close(descriptor: Int32) {}
    }

    private final class FakeLauncher: AppPriorityAgentLaunching {
        var launchCount = 0
        let onLaunch: () -> Void
        init(onLaunch: @escaping () -> Void = {}) { self.onLaunch = onLaunch }
        func launch(agentPath: String, uid: UInt32, sessionIdentifier: String, logURL: URL) throws { launchCount += 1; onLaunch() }
    }

    private struct NoSleepClock: AppPriorityAgentClock { func sleep(seconds: TimeInterval) {} }

    private let app = AppPriorityApplication(displayName: "TextEdit", bundleIdentifier: "com.apple.TextEdit", bundlePath: "/Applications/TextEdit.app", executablePath: "/Applications/TextEdit.app/Contents/MacOS/TextEdit")

    func testParserAcceptsOnlyFixedCommandsAndDecimalUid() throws {
        XCTAssertEqual(try AppPriorityAgentCommand.parse(["validate", "--uid", "501"]), .validate(uid: 501))
        XCTAssertEqual(try AppPriorityAgentCommand.parse(["monitor", "--uid", "501", "--session", "abc"]), .monitor(uid: 501, session: "abc"))
        XCTAssertThrowsError(try AppPriorityAgentCommand.parse(["run-shell", "--uid", "501"]))
        XCTAssertThrowsError(try AppPriorityAgentCommand.parse(["start", "--uid", "501;rm -rf /"]))
        XCTAssertThrowsError(try AppPriorityAgentCommand.parse(["start", "--uid", "0"]))
        XCTAssertThrowsError(try AppPriorityAgentCommand.parse(["start", "--uid", "501", "extra"]))
    }

    func testValidateReportsDisabledWithoutLaunching() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let launcher = FakeLauncher()
        let service = AppPriorityAgentService(
            selectionProvider: { _ in ValidatedAppPrioritySelection(enabled: false, application: nil, requestingUID: 501) },
            storeProvider: { AppPriorityStateStore(runtimeRoot: root, requestingUID: $0) },
            monitorProvider: { _, _, _, _ in fatalError("not called") },
            launcher: launcher,
            clock: NoSleepClock(),
            agentPath: "/tmp/agent"
        )
        XCTAssertEqual(try service.validate(uid: 501), .disabled)
        XCTAssertEqual(launcher.launchCount, 0)
    }


    func testStartSerializesStartupBeforeCheckingMonitorLock() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var store: AppPriorityStateStore!
        let lock = FakeLock([.acquired(1), .acquired(2)])
        let launcher = FakeLauncher {
            if let current = store.loadStatus() {
                try? store.writeStatus(AppPriorityStatus(state: .active, boostedCount: 1, skippedCount: 0, message: "Active", sessionIdentifier: current.sessionIdentifier))
            }
        }
        let service = AppPriorityAgentService(
            selectionProvider: { _ in ValidatedAppPrioritySelection(enabled: true, application: self.app, requestingUID: 501) },
            storeProvider: { uid in store = AppPriorityStateStore(runtimeRoot: root, requestingUID: uid); return store },
            monitorProvider: { _, _, _, _ in fatalError("not called") },
            lockProvider: lock,
            launcher: launcher,
            clock: NoSleepClock(),
            agentPath: "/tmp/agent"
        )

        XCTAssertEqual(try service.start(uid: 501), .success)
        XCTAssertEqual(lock.requestedPaths.map { URL(fileURLWithPath: $0).lastPathComponent }, ["start.lock", "monitor.lock"])
    }

    func testStartRefusesSecondMonitorForSameUid() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var store: AppPriorityStateStore!
        let lock = FakeLock([.acquired(1), .acquired(2), .acquired(3), .busy])
        let launcher = FakeLauncher {
            if let current = store.loadStatus() {
                try? store.writeStatus(AppPriorityStatus(state: .active, boostedCount: 1, skippedCount: 0, message: "Active", sessionIdentifier: current.sessionIdentifier))
            }
        }
        let service = AppPriorityAgentService(
            selectionProvider: { _ in ValidatedAppPrioritySelection(enabled: true, application: self.app, requestingUID: 501) },
            storeProvider: { uid in store = AppPriorityStateStore(runtimeRoot: root, requestingUID: uid); return store },
            monitorProvider: { _, _, _, _ in fatalError("not called") },
            lockProvider: lock,
            launcher: launcher,
            clock: NoSleepClock(),
            agentPath: "/tmp/agent"
        )
        XCTAssertEqual(try service.start(uid: 501), .success)
        XCTAssertEqual(try service.start(uid: 501), .alreadyRunning)
    }


    func testStartFailureRequestsCooperativeMonitorStop() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var store: AppPriorityStateStore!
        let launcher = FakeLauncher {
            if let current = store.loadStatus() {
                try? store.writeStatus(AppPriorityStatus(state: .failed, boostedCount: 0, skippedCount: 1, message: "Failed", sessionIdentifier: current.sessionIdentifier))
            }
        }
        let service = AppPriorityAgentService(
            selectionProvider: { _ in ValidatedAppPrioritySelection(enabled: true, application: self.app, requestingUID: 501) },
            storeProvider: { uid in store = AppPriorityStateStore(runtimeRoot: root, requestingUID: uid); return store },
            monitorProvider: { _, _, _, _ in fatalError("not called") },
            lockProvider: FakeLock([.acquired(1), .acquired(2)]),
            launcher: launcher,
            clock: NoSleepClock(),
            agentPath: "/tmp/agent"
        )

        XCTAssertEqual(try service.start(uid: 501), .failure)
        XCTAssertTrue(store.stopRequested())
    }

    func testStartTimeoutRequestsCooperativeMonitorStop() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var store: AppPriorityStateStore!
        let service = AppPriorityAgentService(
            selectionProvider: { _ in ValidatedAppPrioritySelection(enabled: true, application: self.app, requestingUID: 501) },
            storeProvider: { uid in store = AppPriorityStateStore(runtimeRoot: root, requestingUID: uid); return store },
            monitorProvider: { _, _, _, _ in fatalError("not called") },
            lockProvider: FakeLock([.acquired(1), .acquired(2)]),
            launcher: FakeLauncher(),
            clock: NoSleepClock(),
            agentPath: "/tmp/agent"
        )

        XCTAssertEqual(try service.start(uid: 501), .failure)
        XCTAssertTrue(store.stopRequested())
    }

    func testStopAndRestoreFallsBackToRecoveryWhenMonitorIsGone() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppPriorityStateStore(runtimeRoot: root, requestingUID: 501)
        try store.writeRuntimeState(AppPriorityRuntimeState(sessionIdentifier: "session", selectedApplication: app, requestingUID: 501, monitorIdentity: nil, records: [], startedAt: Date()))
        var restoreWasRun = false
        let service = AppPriorityAgentService(
            selectionProvider: { _ in ValidatedAppPrioritySelection(enabled: true, application: self.app, requestingUID: 501) },
            storeProvider: { _ in store },
            monitorProvider: { _, _, _, _ in fatalError("not called") },
            directRestoreHandler: { _ in restoreWasRun = true; store.removeRuntimeFilesAfterSuccessfulRestore(); return .success },
            lockProvider: FakeLock([.acquired(1), .acquired(2)]),
            launcher: FakeLauncher(),
            clock: NoSleepClock(),
            agentPath: "/tmp/agent"
        )
        XCTAssertEqual(try service.stopAndRestore(uid: 501), .success)
        XCTAssertTrue(restoreWasRun)
    }
}
