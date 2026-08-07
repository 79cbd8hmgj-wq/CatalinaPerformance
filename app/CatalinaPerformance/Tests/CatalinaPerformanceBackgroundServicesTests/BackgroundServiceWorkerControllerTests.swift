import XCTest
import CatalinaPerformancePriorityCore
@testable import CatalinaPerformanceBackgroundServicesCore

final class BackgroundServiceWorkerControllerTests: XCTestCase {
    func testSuppressionRevalidatesIdentityImmediatelyBeforeSIGTERM() throws {
        let matching = process(pid: 100, path: photosPath)
        let reused = process(pid: 100, path: photosPath, startSeconds: 999)
        let inspector = MutableBackgroundProcessInspector([matching])
        let mutator = RecordingBackgroundSignalMutator(inspector: inspector)
        let controller = makeController(inspector: inspector, mutator: mutator)
        let captured = try controller.capture(category: .photos, uid: 501)
        inspector.replace(pid: matching.pid, with: reused)

        let result = controller.suppress(category: .photos, records: captured, uid: 501)

        XCTAssertTrue(mutator.signals.isEmpty)
        XCTAssertEqual(result.state, .degraded)
        XCTAssertEqual(result.workers.first?.didAttemptStop, false)
    }

    func testCaptureRejectsRootAndNoncatalogProcesses() throws {
        let inspector = MutableBackgroundProcessInspector([
            process(pid: 1, uid: 0, path: photosPath),
            process(pid: 2, path: "/tmp/photolibraryd")
        ])
        let controller = makeController(inspector: inspector)
        XCTAssertTrue(try controller.capture(category: .photos, uid: 501).isEmpty)
    }

    func testExactPathProcessIsTerminatedAndConfirmed() throws {
        let matching = process(pid: 100, path: photosPath)
        let inspector = MutableBackgroundProcessInspector([matching])
        let mutator = RecordingBackgroundSignalMutator(inspector: inspector)
        let controller = makeController(inspector: inspector, mutator: mutator)
        let captured = try controller.capture(category: .photos, uid: 501)

        let result = controller.suppress(category: .photos, records: captured, uid: 501)

        XCTAssertEqual(mutator.signals, [100])
        XCTAssertEqual(result.state, .paused)
        XCTAssertTrue(result.workers[0].didAttemptStop)
        XCTAssertTrue(result.workers[0].didConfirmStop)
    }

    func testAlreadyExitedProcessIsNotSignaledOrRestored() throws {
        let matching = process(pid: 100, path: photosPath)
        let inspector = MutableBackgroundProcessInspector([matching])
        let mutator = RecordingBackgroundSignalMutator(inspector: inspector)
        let restorer = RecordingLaunchctlRestorer(inspector: inspector, restoredProcess: process(pid: 101, path: photosPath))
        let controller = makeController(inspector: inspector, mutator: mutator, restorer: restorer)
        let captured = try controller.capture(category: .photos, uid: 501)
        inspector.remove(pid: 100)
        let suppressed = controller.suppress(category: .photos, records: captured, uid: 501)
        let restored = controller.restore(category: .photos, records: suppressed.workers, uid: 501)

        XCTAssertTrue(mutator.signals.isEmpty)
        XCTAssertTrue(restorer.labels.isEmpty)
        XCTAssertEqual(restored.state, .restored)
    }

    func testSignalFailureProducesDegradedState() throws {
        let matching = process(pid: 100, path: photosPath)
        let inspector = MutableBackgroundProcessInspector([matching])
        let mutator = RecordingBackgroundSignalMutator(inspector: inspector, shouldFail: true)
        let controller = makeController(inspector: inspector, mutator: mutator)
        let captured = try controller.capture(category: .photos, uid: 501)
        let result = controller.suppress(category: .photos, records: captured, uid: 501)
        XCTAssertEqual(result.state, .degraded)
        XCTAssertFalse(result.workers[0].didConfirmStop)
    }

    func testRestoreKickstartsOnlySuccessfullyStoppedWorker() throws {
        let matching = process(pid: 100, path: photosPath)
        let restoredProcess = process(pid: 200, path: photosPath, startSeconds: 200)
        let inspector = MutableBackgroundProcessInspector([matching])
        let mutator = RecordingBackgroundSignalMutator(inspector: inspector)
        let restorer = RecordingLaunchctlRestorer(inspector: inspector, restoredProcess: restoredProcess)
        let controller = makeController(inspector: inspector, mutator: mutator, restorer: restorer)
        let captured = try controller.capture(category: .photos, uid: 501)
        let suppressed = controller.suppress(category: .photos, records: captured, uid: 501)

        let result = controller.restore(category: .photos, records: suppressed.workers, uid: 501)

        XCTAssertEqual(restorer.labels, ["com.apple.photolibraryd"])
        XCTAssertEqual(result.state, .restored)
        XCTAssertTrue(result.workers[0].didConfirmRestore)
    }

    func testRestoreDoesNotKickstartWhenMatchingWorkerAlreadyRunning() throws {
        let original = process(pid: 100, path: photosPath)
        let replacement = process(pid: 200, path: photosPath, startSeconds: 200)
        let inspector = MutableBackgroundProcessInspector([original])
        let mutator = RecordingBackgroundSignalMutator(inspector: inspector)
        let restorer = RecordingLaunchctlRestorer(inspector: inspector, restoredProcess: replacement)
        let controller = makeController(inspector: inspector, mutator: mutator, restorer: restorer)
        let captured = try controller.capture(category: .photos, uid: 501)
        let suppressed = controller.suppress(category: .photos, records: captured, uid: 501)
        inspector.add(replacement)

        let result = controller.restore(category: .photos, records: suppressed.workers, uid: 501)

        XCTAssertTrue(restorer.labels.isEmpty)
        XCTAssertEqual(result.state, .restored)
        XCTAssertTrue(result.workers[0].didConfirmRestore)
    }


    func testEmptyCaptureIsRepresentedAsMonitoredIdleAndRestoresWithoutMutation() {
        let inspector = MutableBackgroundProcessInspector([])
        let mutator = RecordingBackgroundSignalMutator(inspector: inspector)
        let restorer = RecordingLaunchctlRestorer(inspector: inspector, restoredProcess: nil)
        let controller = makeController(inspector: inspector, mutator: mutator, restorer: restorer)

        let suppressed = controller.suppress(category: .photos, records: [], uid: 501)
        let restored = controller.restore(category: .photos, records: suppressed.workers, uid: 501)

        XCTAssertEqual(suppressed.state, .paused)
        XCTAssertEqual(suppressed.note, "No matching worker was running; relaunch monitoring remains active.")
        XCTAssertEqual(restored.state, .restored)
        XCTAssertEqual(restored.note, "No captured worker required restoration.")
        XCTAssertTrue(mutator.signals.isEmpty)
        XCTAssertTrue(restorer.labels.isEmpty)
    }

    func testUnsupportedCategoryCapturesNothing() throws {
        let inspector = MutableBackgroundProcessInspector([process(pid: 1, path: photosPath)])
        let controller = makeController(inspector: inspector)
        XCTAssertTrue(try controller.capture(category: .siriSpeech, uid: 501).isEmpty)
    }

    private let photosPath = "/System/Library/PrivateFrameworks/PhotoLibraryServices.framework/Versions/A/Support/photolibraryd"

    private func process(pid: Int32, uid: UInt32 = 501, path: String, startSeconds: Int64 = 100) -> AppPriorityProcessIdentity {
        return AppPriorityProcessIdentity(
            pid: pid,
            parentPID: 1,
            effectiveUID: uid,
            executablePath: path,
            startSeconds: startSeconds,
            startMicroseconds: 1,
            processName: URL(fileURLWithPath: path).lastPathComponent,
            niceValue: 0
        )
    }

    private func makeController(
        inspector: MutableBackgroundProcessInspector,
        mutator: RecordingBackgroundSignalMutator? = nil,
        restorer: RecordingLaunchctlRestorer? = nil
    ) -> BackgroundServiceWorkerController {
        return BackgroundServiceWorkerController(
            inspector: inspector,
            signalMutator: mutator ?? RecordingBackgroundSignalMutator(inspector: inspector),
            launchctlRestorer: restorer ?? RecordingLaunchctlRestorer(inspector: inspector, restoredProcess: nil),
            sleeper: ImmediateBackgroundServiceSleeper(),
            catalog: .current,
            now: { Date(timeIntervalSince1970: 100) }
        )
    }
}

private final class MutableBackgroundProcessInspector: AppPriorityProcessInspecting {
    private var values: [Int32: AppPriorityProcessIdentity]
    init(_ processes: [AppPriorityProcessIdentity]) { values = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) }) }
    func allProcesses() throws -> [AppPriorityProcessIdentity] { Array(values.values) }
    func process(pid: Int32) throws -> AppPriorityProcessIdentity {
        guard let value = values[pid] else { throw AppPriorityProcessError.readFailed(pid: pid, code: -1) }
        return value
    }
    func replace(pid: Int32, with value: AppPriorityProcessIdentity) { values[pid] = value }
    func remove(pid: Int32) { values.removeValue(forKey: pid) }
    func add(_ value: AppPriorityProcessIdentity) { values[value.pid] = value }
}

private final class RecordingBackgroundSignalMutator: BackgroundServiceSignalMutating {
    private let inspector: MutableBackgroundProcessInspector
    private let shouldFail: Bool
    private(set) var signals: [Int32] = []
    init(inspector: MutableBackgroundProcessInspector, shouldFail: Bool = false) { self.inspector = inspector; self.shouldFail = shouldFail }
    func terminate(pid: Int32) throws {
        signals.append(pid)
        if shouldFail { throw BackgroundServiceWorkerError.signalFailed(pid) }
        inspector.remove(pid: pid)
    }
}

private final class RecordingLaunchctlRestorer: BackgroundServiceLaunchctlRestoring {
    private let inspector: MutableBackgroundProcessInspector
    private let restoredProcess: AppPriorityProcessIdentity?
    private(set) var labels: [String] = []
    init(inspector: MutableBackgroundProcessInspector, restoredProcess: AppPriorityProcessIdentity?) { self.inspector = inspector; self.restoredProcess = restoredProcess }
    func kickstart(label: String, uid: UInt32) throws {
        labels.append(label)
        if let restoredProcess = restoredProcess { inspector.add(restoredProcess) }
    }
}

private struct ImmediateBackgroundServiceSleeper: BackgroundServiceSleeping {
    func sleep(seconds: TimeInterval) {}
}
