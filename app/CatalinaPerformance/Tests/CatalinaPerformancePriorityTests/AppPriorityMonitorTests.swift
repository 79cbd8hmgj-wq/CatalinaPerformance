import XCTest
import Foundation
@testable import CatalinaPerformancePriorityCore

final class AppPriorityMonitorTests: XCTestCase {
    private final class FakeProcessSystem: AppPriorityProcessInspecting, AppPriorityPriorityMutating {
        struct SetCall: Equatable { let pid: Int32; let value: Int32 }
        var processes: [AppPriorityProcessIdentity]
        var setCalls: [SetCall] = []
        var failingSetPIDs: Set<Int32> = []

        init(processes: [AppPriorityProcessIdentity]) { self.processes = processes }
        func allProcesses() throws -> [AppPriorityProcessIdentity] { processes }
        func process(pid: Int32) throws -> AppPriorityProcessIdentity {
            guard let value = processes.first(where: { $0.pid == pid }) else { throw AppPriorityProcessError.readFailed(pid: pid, code: -1) }
            return value
        }
        func priority(pid: Int32) throws -> Int32 { try process(pid: pid).niceValue }
        func setPriority(pid: Int32, value: Int32) throws {
            if failingSetPIDs.contains(pid) { throw AppPriorityProcessError.priorityWriteFailed(pid: pid, code: -1) }
            guard let index = processes.firstIndex(where: { $0.pid == pid }) else { throw AppPriorityProcessError.readFailed(pid: pid, code: -1) }
            let old = processes[index]
            processes[index] = AppPriorityProcessIdentity(pid: old.pid, parentPID: old.parentPID, effectiveUID: old.effectiveUID, executablePath: old.executablePath, startSeconds: old.startSeconds, startMicroseconds: old.startMicroseconds, processName: old.processName, niceValue: value)
            setCalls.append(SetCall(pid: pid, value: value))
        }
    }

    private let app = AppPriorityApplication(displayName: "Firefox", bundleIdentifier: "org.mozilla.firefox", bundlePath: "/Applications/Firefox.app", executablePath: "/Applications/Firefox.app/Contents/MacOS/firefox")

    private func process(pid: Int32, ppid: Int32, path: String, nice: Int32 = 0, start: Int64 = 100, uid: UInt32 = 501) -> AppPriorityProcessIdentity {
        AppPriorityProcessIdentity(pid: pid, parentPID: ppid, effectiveUID: uid, executablePath: path, startSeconds: start, startMicroseconds: 0, processName: URL(fileURLWithPath: path).lastPathComponent, niceValue: nice)
    }

    private func makeMonitor(_ fake: FakeProcessSystem) throws -> (AppPriorityMonitor, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let selection = ValidatedAppPrioritySelection(enabled: true, application: app, requestingUID: 501)
        let monitor = try AppPriorityMonitor(selection: selection, inspector: fake, mutator: fake, stateStore: AppPriorityStateStore(runtimeRoot: root, requestingUID: 501), sessionIdentifier: "session")
        return (monitor, root)
    }

    func testInitialScanBoostsMainAndChildrenAndRecordsOriginalNiceValues() throws {
        let fake = FakeProcessSystem(processes: [
            process(pid: 10, ppid: 1, path: app.executablePath, nice: 0),
            process(pid: 11, ppid: 10, path: "/usr/libexec/firefox-child", nice: 3),
            process(pid: 12, ppid: 10, path: "/usr/libexec/already-prioritized", nice: -10)
        ])
        let (monitor, root) = try makeMonitor(fake)
        defer { try? FileManager.default.removeItem(at: root) }
        let outcome = try monitor.scanOnce()
        XCTAssertEqual(fake.setCalls, [.init(pid: 10, value: -5), .init(pid: 11, value: -5)])
        XCTAssertEqual(outcome.changedRecords.map { $0.originalNiceValue }.sorted(), [0, 3])
        XCTAssertFalse(outcome.changedRecords.contains { $0.identity.pid == 12 })
        XCTAssertEqual(outcome.unchangedCount, 1)
    }

    func testSecondScanBoostsNewHelperAndDoesNotReboostRecordedProcesses() throws {
        let main = process(pid: 10, ppid: 1, path: app.executablePath)
        let fake = FakeProcessSystem(processes: [main])
        let (monitor, root) = try makeMonitor(fake)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try monitor.scanOnce()
        fake.processes.append(process(pid: 11, ppid: 10, path: "/usr/libexec/new-helper", nice: 2))
        _ = try monitor.scanOnce()
        XCTAssertEqual(fake.setCalls.filter { $0.pid == 10 }.count, 1)
        XCTAssertTrue(fake.setCalls.contains(.init(pid: 11, value: -5)))
    }

    func testRelaunchedMainIsReacquiredByPathAndNewStartTime() throws {
        let fake = FakeProcessSystem(processes: [process(pid: 10, ppid: 1, path: app.executablePath, start: 100)])
        let (monitor, root) = try makeMonitor(fake)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try monitor.scanOnce()
        fake.processes = [process(pid: 20, ppid: 1, path: app.executablePath, start: 200)]
        _ = try monitor.scanOnce()
        XCTAssertTrue(fake.setCalls.contains(.init(pid: 20, value: -5)))
    }


    func testPreexistingStopRequestPreventsLateMonitorFromBoosting() throws {
        let fake = FakeProcessSystem(processes: [process(pid: 10, ppid: 1, path: app.executablePath)])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppPriorityStateStore(runtimeRoot: root, requestingUID: 501)
        try store.createStopRequest()
        let selection = ValidatedAppPrioritySelection(enabled: true, application: app, requestingUID: 501)
        let monitor = try AppPriorityMonitor(selection: selection, inspector: fake, mutator: fake, stateStore: store, sessionIdentifier: "late-session")

        let outcome = try monitor.run()

        XCTAssertTrue(fake.setCalls.isEmpty)
        XCTAssertTrue(outcome.outstandingRecords.isEmpty)
    }

    func testRestoreSkipsReusedPidAndRestoresMatchingProcess() throws {
        let matchingIdentity = process(pid: 10, ppid: 1, path: app.executablePath, nice: -5, start: 100)
        let reusedOriginal = process(pid: 20, ppid: 1, path: app.executablePath, nice: -5, start: 100)
        let fake = FakeProcessSystem(processes: [matchingIdentity, process(pid: 20, ppid: 1, path: app.executablePath, nice: -5, start: 999)])
        let (monitor, root) = try makeMonitor(fake)
        defer { try? FileManager.default.removeItem(at: root) }
        let matching = AppPriorityRestoreRecord(identity: matchingIdentity, originalNiceValue: 4, didChangePriority: true, lastObservedStatus: .changed, errorMessage: nil)
        let reused = AppPriorityRestoreRecord(identity: reusedOriginal, originalNiceValue: 2, didChangePriority: true, lastObservedStatus: .changed, errorMessage: nil)
        let result = try monitor.restoreOutstandingRecords([matching, reused])
        XCTAssertEqual(fake.setCalls, [.init(pid: 10, value: 4)])
        XCTAssertEqual(result.restoredCount, 1)
        XCTAssertEqual(result.mismatchedCount, 1)
        XCTAssertEqual(result.outstandingRecords.count, 1)
    }

    func testRestoreTreatsExitedProcessAsCompleteAndPreservesFailures() throws {
        let live = process(pid: 10, ppid: 1, path: app.executablePath, nice: -5)
        let exited = process(pid: 11, ppid: 1, path: "/usr/libexec/exited", nice: -5)
        let fake = FakeProcessSystem(processes: [live])
        fake.failingSetPIDs = [10]
        let (monitor, root) = try makeMonitor(fake)
        defer { try? FileManager.default.removeItem(at: root) }
        let records = [
            AppPriorityRestoreRecord(identity: live, originalNiceValue: 0, didChangePriority: true, lastObservedStatus: .changed, errorMessage: nil),
            AppPriorityRestoreRecord(identity: exited, originalNiceValue: 2, didChangePriority: true, lastObservedStatus: .changed, errorMessage: nil)
        ]
        let result = try monitor.restoreOutstandingRecords(records)
        XCTAssertEqual(result.exitedCount, 1)
        XCTAssertEqual(result.failedCount, 1)
        XCTAssertEqual(result.outstandingRecords.map { $0.identity.pid }, [10])
    }
}
