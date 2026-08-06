import XCTest
import Foundation
@testable import CatalinaPerformancePriorityCore

final class AppPriorityMonitorTests: XCTestCase {
    private enum TestError: Error { case missingProcess }

    private final class FakeProcessSystem:
        AppPriorityProcessInspecting,
        AppPriorityProcessActivityInspecting,
        AppPriorityPriorityMutating {
        struct SetCall: Equatable { let pid: Int32; let value: Int32 }

        var listedProcesses: [AppPriorityProcessIdentity]
        var liveProcesses: [AppPriorityProcessIdentity]
        var argumentsByPID: [Int32: [String]] = [:]
        var cpuByPID: [Int32: UInt64] = [:]
        var setCalls: [SetCall] = []
        var failingSetPIDs: Set<Int32> = []
        var failingRestores: Set<Int32> = []

        init(processes: [AppPriorityProcessIdentity]) {
            self.listedProcesses = processes
            self.liveProcesses = processes
        }

        func allProcesses() throws -> [AppPriorityProcessIdentity] { listedProcesses }

        func process(pid: Int32) throws -> AppPriorityProcessIdentity {
            guard let value = liveProcesses.first(where: { $0.pid == pid }) else {
                throw AppPriorityProcessError.readFailed(pid: pid, code: -1)
            }
            return value
        }

        func arguments(pid: Int32) throws -> [String] {
            guard let value = argumentsByPID[pid] else { throw TestError.missingProcess }
            return value
        }

        func cpuTimeNanoseconds(pid: Int32) throws -> UInt64 {
            guard let value = cpuByPID[pid] else { throw TestError.missingProcess }
            return value
        }

        func priority(pid: Int32) throws -> Int32 { try process(pid: pid).niceValue }

        func setPriority(pid: Int32, value: Int32) throws {
            if failingSetPIDs.contains(pid) || (value != -1 && failingRestores.contains(pid)) {
                throw AppPriorityProcessError.priorityWriteFailed(pid: pid, code: -1)
            }
            guard let liveIndex = liveProcesses.firstIndex(where: { $0.pid == pid }) else {
                throw AppPriorityProcessError.readFailed(pid: pid, code: -1)
            }
            let old = liveProcesses[liveIndex]
            let updated = AppPriorityProcessIdentity(
                pid: old.pid,
                parentPID: old.parentPID,
                effectiveUID: old.effectiveUID,
                executablePath: old.executablePath,
                startSeconds: old.startSeconds,
                startMicroseconds: old.startMicroseconds,
                processName: old.processName,
                niceValue: value
            )
            liveProcesses[liveIndex] = updated
            if let listedIndex = listedProcesses.firstIndex(where: {
                $0.pid == pid && $0.startSeconds == old.startSeconds && $0.startMicroseconds == old.startMicroseconds
            }) {
                listedProcesses[listedIndex] = updated
            }
            setCalls.append(SetCall(pid: pid, value: value))
        }
    }

    private let genericApp = AppPriorityApplication(
        displayName: "Encoder",
        bundleIdentifier: "local.encoder",
        bundlePath: "/Applications/Encoder.app",
        executablePath: "/Applications/Encoder.app/Contents/MacOS/Encoder"
    )

    private let firefox = AppPriorityApplication(
        displayName: "Firefox",
        bundleIdentifier: "org.mozilla.firefox",
        bundlePath: "/Applications/Firefox.app",
        executablePath: "/Applications/Firefox.app/Contents/MacOS/firefox"
    )

    private var firefoxGPUPath: String {
        "/Applications/Firefox.app/Contents/MacOS/gpu-helper.app/Contents/MacOS/Firefox GPU Helper"
    }

    private var firefoxContentPath: String {
        "/Applications/Firefox.app/Contents/MacOS/plugin-container.app/Contents/MacOS/plugin-container"
    }

    private func process(
        pid: Int32,
        ppid: Int32,
        path: String,
        nice: Int32 = 0,
        start: Int64 = 100,
        uid: UInt32 = 501
    ) -> AppPriorityProcessIdentity {
        AppPriorityProcessIdentity(
            pid: pid,
            parentPID: ppid,
            effectiveUID: uid,
            executablePath: path,
            startSeconds: start,
            startMicroseconds: 0,
            processName: URL(fileURLWithPath: path).lastPathComponent,
            niceValue: nice
        )
    }

    private func firefoxProcesses(
        parentPID: Int32 = 612,
        gpuPID: Int32 = 616,
        contentPIDs: [Int32] = [844],
        start: Int64 = 100
    ) -> [AppPriorityProcessIdentity] {
        var values = [
            process(pid: parentPID, ppid: 1, path: firefox.executablePath, start: start),
            process(pid: gpuPID, ppid: parentPID, path: firefoxGPUPath, start: start)
        ]
        values.append(contentsOf: contentPIDs.map {
            process(pid: $0, ppid: parentPID, path: firefoxContentPath, start: start)
        })
        return values
    }

    private func configureFirefoxArguments(
        _ fake: FakeProcessSystem,
        parentPID: Int32 = 612,
        gpuPID: Int32 = 616,
        contentPIDs: [Int32] = [844]
    ) {
        fake.argumentsByPID[parentPID] = [firefox.executablePath, "-foreground"]
        fake.argumentsByPID[gpuPID] = [firefoxGPUPath, "gpu"]
        for pid in contentPIDs {
            fake.argumentsByPID[pid] = [firefoxContentPath, "-isForBrowser", "tab"]
        }
    }

    private func makeMonitor(
        app: AppPriorityApplication,
        fake: FakeProcessSystem,
        session: String = "session"
    ) throws -> (AppPriorityMonitor, AppPriorityStateStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = AppPriorityStateStore(runtimeRoot: root, requestingUID: 501)
        let selection = ValidatedAppPrioritySelection(enabled: true, application: app, requestingUID: 501)
        let monitor = try AppPriorityMonitor(
            selection: selection,
            inspector: fake,
            activityInspector: fake,
            mutator: fake,
            stateStore: store,
            sessionIdentifier: session
        )
        return (monitor, store, root)
    }

    func testFocusedFirstScanBoostsParentAndGPUOnlyAtMinusOne() throws {
        let fake = FakeProcessSystem(processes: firefoxProcesses())
        configureFirefoxArguments(fake)
        fake.cpuByPID[844] = 100
        let (monitor, _, root) = try makeMonitor(app: firefox, fake: fake)
        defer { try? FileManager.default.removeItem(at: root) }

        let outcome = try monitor.scanOnce()

        XCTAssertEqual(fake.setCalls, [.init(pid: 612, value: -1), .init(pid: 616, value: -1)])
        XCTAssertEqual(outcome.boostedCount, 2)
        XCTAssertEqual(outcome.focusedFirefox?.actuallyBoostedCount, 2)
        XCTAssertNil(outcome.focusedFirefox?.contentPID)
    }

    func testFocusedContentRequiresTwoPositiveDeltaWinsAfterBaseline() throws {
        let fake = FakeProcessSystem(processes: firefoxProcesses())
        configureFirefoxArguments(fake)
        fake.cpuByPID[844] = 100
        let (monitor, _, root) = try makeMonitor(app: firefox, fake: fake)
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try monitor.scanOnce()
        fake.cpuByPID[844] = 200
        _ = try monitor.scanOnce()
        XCTAssertFalse(fake.setCalls.contains(.init(pid: 844, value: -1)))

        fake.cpuByPID[844] = 300
        let outcome = try monitor.scanOnce()

        XCTAssertTrue(fake.setCalls.contains(.init(pid: 844, value: -1)))
        XCTAssertEqual(outcome.boostedCount, 3)
        XCTAssertEqual(outcome.focusedFirefox?.contentPID, 844)
    }

    func testFocusedZeroDeltaPreallocatedProcessesRemainUnchangedAndMaximumIsThree() throws {
        let fake = FakeProcessSystem(processes: firefoxProcesses(contentPIDs: [844, 20025, 20027, 20028]))
        configureFirefoxArguments(fake, contentPIDs: [844, 20025, 20027, 20028])
        fake.cpuByPID = [844: 100, 20025: 50, 20027: 50, 20028: 50]
        let (monitor, store, root) = try makeMonitor(app: firefox, fake: fake)
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try monitor.scanOnce()
        fake.cpuByPID[844] = 200
        _ = try monitor.scanOnce()
        fake.cpuByPID[844] = 300
        _ = try monitor.scanOnce()

        XCTAssertFalse(fake.setCalls.contains { [20025, 20027, 20028].contains($0.pid) })
        XCTAssertEqual(try store.loadRuntimeState().records.filter { $0.didChangePriority }.count, 3)
    }

    func testFocusedSwitchRestoresOldContentBeforeBoostingReplacement() throws {
        let fake = FakeProcessSystem(processes: firefoxProcesses(contentPIDs: [844, 900]))
        configureFirefoxArguments(fake, contentPIDs: [844, 900])
        fake.cpuByPID = [844: 100, 900: 100]
        let (monitor, _, root) = try makeMonitor(app: firefox, fake: fake)
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try monitor.scanOnce()
        fake.cpuByPID = [844: 200, 900: 100]
        _ = try monitor.scanOnce()
        fake.cpuByPID = [844: 300, 900: 100]
        _ = try monitor.scanOnce()
        fake.cpuByPID = [844: 310, 900: 200]
        _ = try monitor.scanOnce()
        fake.cpuByPID = [844: 320, 900: 400]
        _ = try monitor.scanOnce()

        XCTAssertEqual(
            fake.setCalls.suffix(2).map { "\($0.pid):\($0.value)" },
            ["844:0", "900:-1"]
        )
    }

    func testFocusedSwitchRestoreFailurePreservesOldObligationAndDoesNotBoostReplacement() throws {
        let fake = FakeProcessSystem(processes: firefoxProcesses(contentPIDs: [844, 900]))
        configureFirefoxArguments(fake, contentPIDs: [844, 900])
        fake.cpuByPID = [844: 100, 900: 100]
        let (monitor, store, root) = try makeMonitor(app: firefox, fake: fake)
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try monitor.scanOnce()
        fake.cpuByPID = [844: 200, 900: 100]
        _ = try monitor.scanOnce()
        fake.cpuByPID = [844: 300, 900: 100]
        _ = try monitor.scanOnce()
        fake.failingRestores.insert(844)
        fake.cpuByPID = [844: 310, 900: 200]
        _ = try monitor.scanOnce()
        fake.cpuByPID = [844: 320, 900: 400]
        _ = try monitor.scanOnce()

        XCTAssertFalse(fake.setCalls.contains(.init(pid: 900, value: -1)))
        let records = try store.loadRuntimeState().records
        XCTAssertTrue(records.contains { $0.role == .contentTarget && $0.identity.pid == 844 })
    }

    func testFocusedFirefoxRelaunchResetsCountersAndReacquiresParentAndGPU() throws {
        let fake = FakeProcessSystem(processes: firefoxProcesses())
        configureFirefoxArguments(fake)
        fake.cpuByPID[844] = 100
        let (monitor, _, root) = try makeMonitor(app: firefox, fake: fake)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try monitor.scanOnce()

        let relaunched = firefoxProcesses(parentPID: 700, gpuPID: 701, contentPIDs: [702], start: 200)
        fake.listedProcesses = relaunched
        fake.liveProcesses = relaunched
        fake.argumentsByPID = [:]
        configureFirefoxArguments(fake, parentPID: 700, gpuPID: 701, contentPIDs: [702])
        fake.cpuByPID = [702: 500]

        let outcome = try monitor.scanOnce()

        XCTAssertTrue(fake.setCalls.contains(.init(pid: 700, value: -1)))
        XCTAssertTrue(fake.setCalls.contains(.init(pid: 701, value: -1)))
        XCTAssertNil(outcome.focusedFirefox?.contentPID)
    }

    func testFocusedPIDReuseBlocksActivityAndContentMutation() throws {
        let listed = firefoxProcesses(contentPIDs: [844])
        let fake = FakeProcessSystem(processes: listed)
        configureFirefoxArguments(fake)
        fake.cpuByPID[844] = 1000
        fake.liveProcesses = listed.map { identity in
            guard identity.pid == 844 else { return identity }
            return process(pid: 844, ppid: 612, path: firefoxContentPath, start: 999)
        }
        let (monitor, _, root) = try makeMonitor(app: firefox, fake: fake)
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try monitor.scanOnce()
        fake.cpuByPID[844] = 2000
        _ = try monitor.scanOnce()
        fake.cpuByPID[844] = 3000
        _ = try monitor.scanOnce()

        XCTAssertFalse(fake.setCalls.contains(.init(pid: 844, value: -1)))
    }

    func testGenericNonBrowserStillBoostsVerifiedFamilyAtMinusFive() throws {
        let fake = FakeProcessSystem(processes: [
            process(pid: 10, ppid: 1, path: genericApp.executablePath),
            process(pid: 11, ppid: 10, path: "/usr/libexec/encoder-helper", nice: 3),
            process(pid: 12, ppid: 10, path: "/usr/libexec/already-prioritized", nice: -10)
        ])
        let (monitor, _, root) = try makeMonitor(app: genericApp, fake: fake)
        defer { try? FileManager.default.removeItem(at: root) }

        let outcome = try monitor.scanOnce()

        XCTAssertEqual(fake.setCalls, [.init(pid: 10, value: -5), .init(pid: 11, value: -5)])
        XCTAssertEqual(outcome.unchangedCount, 1)
    }

    func testPreexistingStopRequestPreventsLateMonitorFromBoosting() throws {
        let fake = FakeProcessSystem(processes: [process(pid: 10, ppid: 1, path: genericApp.executablePath)])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppPriorityStateStore(runtimeRoot: root, requestingUID: 501)
        try store.createStopRequest()
        let selection = ValidatedAppPrioritySelection(enabled: true, application: genericApp, requestingUID: 501)
        let monitor = try AppPriorityMonitor(
            selection: selection,
            inspector: fake,
            activityInspector: fake,
            mutator: fake,
            stateStore: store,
            sessionIdentifier: "late-session"
        )

        let outcome = try monitor.run()

        XCTAssertTrue(fake.setCalls.isEmpty)
        XCTAssertTrue(outcome.outstandingRecords.isEmpty)
    }

    func testRestoreSkipsReusedPIDAndRestoresMatchingProcess() throws {
        let matchingIdentity = process(pid: 10, ppid: 1, path: genericApp.executablePath, nice: -5, start: 100)
        let reusedOriginal = process(pid: 20, ppid: 1, path: genericApp.executablePath, nice: -5, start: 100)
        let fake = FakeProcessSystem(processes: [
            matchingIdentity,
            process(pid: 20, ppid: 1, path: genericApp.executablePath, nice: -5, start: 999)
        ])
        let (monitor, _, root) = try makeMonitor(app: genericApp, fake: fake)
        defer { try? FileManager.default.removeItem(at: root) }
        let matching = AppPriorityRestoreRecord(identity: matchingIdentity, originalNiceValue: 4, didChangePriority: true, lastObservedStatus: .changed, errorMessage: nil)
        let reused = AppPriorityRestoreRecord(identity: reusedOriginal, originalNiceValue: 2, didChangePriority: true, lastObservedStatus: .changed, errorMessage: nil)

        let result = try monitor.restoreOutstandingRecords([matching, reused])

        XCTAssertEqual(fake.setCalls, [.init(pid: 10, value: 4)])
        XCTAssertEqual(result.restoredCount, 1)
        XCTAssertEqual(result.mismatchedCount, 1)
        XCTAssertEqual(result.outstandingRecords.count, 1)
    }

    func testFocusedFinalRestoreOrdersContentGPUParent() throws {
        let identities = firefoxProcesses()
        let fake = FakeProcessSystem(processes: identities.map {
            process(pid: $0.pid, ppid: $0.parentPID, path: $0.executablePath, nice: -1, start: $0.startSeconds)
        })
        let (monitor, _, root) = try makeMonitor(app: firefox, fake: fake)
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = AppPriorityRestoreRecord(identity: identities[0], originalNiceValue: 0, didChangePriority: true, lastObservedStatus: .changed, errorMessage: nil, role: .parentUI)
        let gpu = AppPriorityRestoreRecord(identity: identities[1], originalNiceValue: 0, didChangePriority: true, lastObservedStatus: .changed, errorMessage: nil, role: .gpuHelper)
        let content = AppPriorityRestoreRecord(identity: identities[2], originalNiceValue: 0, didChangePriority: true, lastObservedStatus: .changed, errorMessage: nil, role: .contentTarget)

        _ = try monitor.restoreOutstandingRecords([parent, content, gpu])

        XCTAssertEqual(fake.setCalls.map { $0.pid }, [844, 616, 612])
    }
}
