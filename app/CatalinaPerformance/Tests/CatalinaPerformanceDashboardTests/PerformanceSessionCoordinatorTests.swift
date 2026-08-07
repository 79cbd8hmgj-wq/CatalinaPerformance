import XCTest
import CatalinaPerformancePriorityCore
@testable import CatalinaPerformanceDashboardCore

final class PerformanceSessionCoordinatorTests: XCTestCase {
    private func date(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    func testPrepareOnCapturesBaselineBeforeCallingReadyCompletion() {
        let collector = BlockingFakeCollector()
        let fixture = makeCoordinator(collector: collector)
        let ready = expectation(description: "ready")
        fixture.coordinator.prepareForOn(selectedApplication: nil) { ready.fulfill() }
        XCTAssertNil(fixture.store.active)
        collector.finish(with: snapshot(cpu: 12, at: 0))
        collector.finish(with: snapshot(cpu: 12, at: 2))
        collector.finish(with: snapshot(cpu: 12, at: 4))
        wait(for: [ready], timeout: 2)
        XCTAssertEqual(fixture.store.active?.baseline.systemCPUPercent.value, 12)
        XCTAssertEqual(fixture.store.active?.windowServer?.baselineSamples.count, 3)
        if case .preparing = fixture.coordinator.currentState().content {} else { XCTFail("Expected preparing") }
    }

    func testPrepareForOnCollectsExactlyThreeGraphicsSamplesBeforeCompletion() {
        let collector = ImmediateFakeCollector(snapshots: [
            snapshot(cpu: 1, at: 0, windowServerCPU: nil),
            snapshot(cpu: 1, at: 2, windowServerCPU: 10),
            snapshot(cpu: 1, at: 4, windowServerCPU: 20)
        ])
        let fixture = makeCoordinator(collector: collector)
        fixture.scheduler.autoFireOneShots = false
        let ready = expectation(description: "graphics baseline ready")
        var progressMessages: [String] = []
        let token = fixture.coordinator.addObserver { state in
            if case .preparing(let progress) = state.content,
               progress.graphicsSampleIndex > 0 {
                progressMessages.append(progress.message)
            }
        }

        fixture.coordinator.prepareForOn(selectedApplication: nil) { ready.fulfill() }
        waitUntil { fixture.scheduler.oneShotCount == 1 }
        XCTAssertEqual(collector.captureCount, 1)
        fixture.scheduler.fireNextOneShot()
        waitUntil { collector.captureCount == 2 && fixture.scheduler.oneShotCount == 1 }
        fixture.scheduler.fireNextOneShot()
        wait(for: [ready], timeout: 2)
        fixture.coordinator.removeObserver(token)

        XCTAssertEqual(collector.captureCount, 3)
        XCTAssertEqual(fixture.store.active?.windowServer?.baselineSamples.count, 3)
        XCTAssertEqual(fixture.store.active?.windowServer?.baseline?.averageCPU ?? -1, 15, accuracy: 0.001)
        XCTAssertTrue(progressMessages.contains("Measuring graphics baseline… 1/3"))
        XCTAssertTrue(progressMessages.contains("Measuring graphics baseline… 2/3"))
        XCTAssertTrue(progressMessages.contains("Measuring graphics baseline… 3/3"))
    }

    func testUnavailableGraphicsBaselineStillAllowsPreparationCompletion() {
        let collector = ImmediateFakeCollector(snapshots: [
            SessionMetricSnapshot.unavailable(capturedAt: date(0), note: "graphics unavailable"),
            SessionMetricSnapshot.unavailable(capturedAt: date(2), note: "graphics unavailable"),
            SessionMetricSnapshot.unavailable(capturedAt: date(4), note: "graphics unavailable")
        ])
        let fixture = makeCoordinator(collector: collector)
        fixture.scheduler.autoFireOneShots = false
        let ready = expectation(description: "unavailable graphics still ready")
        fixture.coordinator.prepareForOn(selectedApplication: nil) { ready.fulfill() }
        waitUntil { fixture.scheduler.oneShotCount == 1 }
        fixture.scheduler.fireNextOneShot()
        waitUntil { fixture.scheduler.oneShotCount == 1 && collector.captureCount == 2 }
        fixture.scheduler.fireNextOneShot()
        wait(for: [ready], timeout: 2)

        XCTAssertEqual(collector.captureCount, 3)
        XCTAssertEqual(fixture.store.active?.windowServer?.baselineSamples.count, 3)
        XCTAssertEqual(fixture.store.active?.windowServer?.baseline?.validSampleCount, 0)
        XCTAssertEqual(
            fixture.coordinator.currentState().warningMessage,
            "Graphics baseline is unavailable; Performance Mode can continue."
        )
    }

    func testOnSuccessSchedulesTwoSecondsAndFailureDiscardsWithoutCompletedReport() {
        let collector = ImmediateFakeCollector(snapshots: [snapshot(cpu: 1, at: 0)])
        let fixture = makeCoordinator(collector: collector)
        let prepared = expectation(description: "prepared")
        fixture.coordinator.prepareForOn(selectedApplication: nil) { prepared.fulfill() }
        wait(for: [prepared], timeout: 2)
        fixture.coordinator.onSequenceCompleted(succeeded: true)
        waitUntil { fixture.scheduler.interval == 2.0 }
        XCTAssertEqual(fixture.scheduler.interval, 2.0)

        let second = makeCoordinator(collector: ImmediateFakeCollector(snapshots: [snapshot(cpu: 1, at: 0)]))
        let prepared2 = expectation(description: "prepared2")
        second.coordinator.prepareForOn(selectedApplication: nil) { prepared2.fulfill() }
        wait(for: [prepared2], timeout: 2)
        second.coordinator.onSequenceCompleted(succeeded: false)
        waitUntil { second.store.active == nil }
        XCTAssertNil(second.store.completed)
    }

    func testFinalizationSavesCompletedBeforeRemovingActive() {
        let collector = ImmediateFakeCollector(snapshots: [snapshot(cpu: 1, at: 0), snapshot(cpu: 2, at: 1), snapshot(cpu: 3, at: 2)])
        let fixture = makeCoordinator(collector: collector)
        let prepared = expectation(description: "prepared")
        fixture.coordinator.prepareForOn(selectedApplication: nil) { prepared.fulfill() }
        wait(for: [prepared], timeout: 2)
        fixture.coordinator.onSequenceCompleted(succeeded: true)
        let proceed = expectation(description: "proceed")
        fixture.coordinator.prepareForFinalization(reason: .normalOff) { proceed.fulfill() }
        wait(for: [proceed], timeout: 2)
        fixture.coordinator.finalizationCompleted(commandEvidence: [DashboardCommandEvidence(identifier: "performanceOff", succeeded: true, output: "")], performanceModeStillOn: false)
        waitUntil { fixture.store.completed != nil }
        XCTAssertEqual(fixture.store.events.suffix(2), ["saveCompleted", "removeActive"])
        XCTAssertEqual(fixture.store.completed?.completionReason, .normalOff)
    }

    func testRecoveryPreservesIdentifierAndAddsGapWhenModeIsOn() {
        let store = MemoryStore()
        store.active = activeRecord(identifier: "original", latestAt: 5)
        let fixture = makeCoordinator(collector: ImmediateFakeCollector(snapshots: []), store: store, modeOn: true, now: Date(timeIntervalSince1970: 10))
        fixture.coordinator.recoverAtLaunch()
        waitUntil { fixture.scheduler.interval == 2.0 }
        XCTAssertEqual(store.active?.sessionIdentifier, "original")
        XCTAssertEqual(store.active?.monitoringGaps.count, 1)
    }

    func testLaunchRecoveryCompletionWaitsForInterruptedSessionCapture() {
        let store = MemoryStore()
        store.active = activeRecord(identifier: "stale", latestAt: 5)
        let collector = BlockingFakeCollector()
        let fixture = makeCoordinator(collector: collector, store: store, modeOn: false, now: Date(timeIntervalSince1970: 10))
        let completed = expectation(description: "recovery completed")
        let lock = NSLock()
        var callbackRan = false

        fixture.coordinator.recoverAtLaunch {
            lock.lock(); callbackRan = true; lock.unlock()
            completed.fulfill()
        }
        usleep(25_000)
        lock.lock(); let ranBeforeCapture = callbackRan; lock.unlock()
        XCTAssertFalse(ranBeforeCapture)

        collector.finish(with: snapshot(cpu: 3, at: 10))
        wait(for: [completed], timeout: 2)
        XCTAssertEqual(store.completed?.phase, .interrupted)
        XCTAssertNil(store.active)
    }

    func testLaunchRecoveryCompletionRunsWhenNoActiveRecordExists() {
        let fixture = makeCoordinator(collector: ImmediateFakeCollector(snapshots: []))
        let completed = expectation(description: "recovery completed")
        fixture.coordinator.recoverAtLaunch { completed.fulfill() }
        wait(for: [completed], timeout: 2)
    }

    private func makeCoordinator(
        collector: SessionMetricsCollecting,
        store: MemoryStore = MemoryStore(),
        modeOn: Bool = false,
        now: Date = Date(timeIntervalSince1970: 20)
    ) -> (coordinator: PerformanceSessionCoordinator, store: MemoryStore, scheduler: ManualScheduler) {
        let scheduler = ManualScheduler()
        let coordinator = PerformanceSessionCoordinator(
            collector: collector,
            recorder: PerformanceSessionRecorder(),
            store: store,
            evidenceProvider: FakeEvidence(),
            scheduler: scheduler,
            modeStateProvider: FakeModeProvider(isOn: modeOn),
            clock: FixedClock(now: now),
            callbackQueue: DispatchQueue(label: "callback")
        )
        return (coordinator, store, scheduler)
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: @escaping () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { usleep(10_000) }
        XCTAssertTrue(condition())
    }

    private func snapshot(
        cpu: Double,
        at seconds: TimeInterval,
        windowServerCPU: Double? = nil
    ) -> SessionMetricSnapshot {
        let d = date(seconds)
        let uD = MetricReading<Double>.unavailable(at: d, note: nil)
        let uB = MetricReading<UInt64>.unavailable(at: d, note: nil)
        let uI = MetricReading<Int>.unavailable(at: d, note: nil)
        let windowServerReading: WindowServerCPUReading?
        if let windowServerCPU = windowServerCPU {
            windowServerReading = .available(
                processKey: WindowServerProcessKey(
                    pid: 88,
                    effectiveUID: 88,
                    executablePath: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer",
                    startSeconds: 1,
                    startMicroseconds: 0
                ),
                cumulativeCPUTimeNanoseconds: UInt64(windowServerCPU * 1_000_000),
                cpuPercent: windowServerCPU,
                at: d
            )
        } else {
            windowServerReading = nil
        }
        return SessionMetricSnapshot(
            capturedAt: d,
            systemCPUPercent: .available(cpu, at: d),
            memoryPressure: .available(.normal, at: d),
            physicalMemoryUsedBytes: uB,
            swapUsedBytes: uB,
            diskFreeBytes: uB,
            schedulerLimitPercent: uD,
            speedLimitPercent: uD,
            selectedAppCPUPercent: uD,
            selectedAppResidentBytes: uB,
            selectedAppVerifiedProcessCount: uI,
            selectedAppPriorityConfirmedCount: uI,
            windowServerCPU: windowServerReading
        )
    }

    private func activeRecord(identifier: String, latestAt: TimeInterval) -> PerformanceSessionRecord {
        let snap = snapshot(cpu: 1, at: latestAt)
        return PerformanceSessionRecord(sessionIdentifier: identifier, phase: .active, startedAt: date(0), completedAt: nil, selectedApplication: nil, baseline: snapshot(cpu: 1, at: 0), latest: snap, finalPreRestore: nil, postRestore: nil, aggregates: SessionMetricAggregates(), sampleCount: 1, subsystemStatuses: [], monitoringGaps: [], metricErrors: [], completionReason: nil)
    }
}

private final class BlockingFakeCollector: SessionMetricsCollecting {
    private var completions: [((SessionMetricSnapshot) -> Void)] = []
    private let lock = NSLock()
    func capture(at date: Date, refreshThermal: Bool) -> SessionMetricSnapshot {
        let semaphore = DispatchSemaphore(value: 0)
        var output: SessionMetricSnapshot?
        lock.lock(); completions.append { value in output = value; semaphore.signal() }; lock.unlock()
        semaphore.wait()
        return output!
    }
    func finish(with snapshot: SessionMetricSnapshot) {
        while true {
            lock.lock()
            let callback = completions.isEmpty ? nil : completions.removeFirst()
            lock.unlock()
            if let callback = callback { callback(snapshot); return }
            usleep(1_000)
        }
    }
}

private final class ImmediateFakeCollector: SessionMetricsCollecting {
    private var snapshots: [SessionMetricSnapshot]
    private(set) var captureCount = 0
    init(snapshots: [SessionMetricSnapshot]) { self.snapshots = snapshots }
    func capture(at date: Date, refreshThermal: Bool) -> SessionMetricSnapshot {
        captureCount += 1
        if snapshots.isEmpty { return SessionMetricSnapshot.unavailable(capturedAt: date, note: "empty") }
        return snapshots.removeFirst()
    }
}

private final class ManualScheduler: PerformanceSessionScheduling {
    var interval: TimeInterval?
    var action: (() -> Void)?
    var autoFireOneShots = true
    private var oneShots: [() -> Void] = []
    var oneShotCount: Int { oneShots.count }

    func scheduleOnce(after interval: TimeInterval, _ action: @escaping () -> Void) {
        if autoFireOneShots {
            action()
        } else {
            oneShots.append(action)
        }
    }

    func scheduleRepeating(every interval: TimeInterval, _ action: @escaping () -> Void) {
        self.interval = interval
        self.action = action
    }

    func cancel() {
        interval = nil
        action = nil
        oneShots.removeAll()
    }

    func fire() { action?() }

    func fireNextOneShot() {
        guard !oneShots.isEmpty else { return }
        let action = oneShots.removeFirst()
        action()
    }
}

private final class MemoryStore: PerformanceSessionStoring {
    var active: PerformanceSessionRecord?
    var completed: CompletedPerformanceSessionReport?
    var events: [String] = []
    func loadActive() -> PerformanceSessionStoreLoadResult<PerformanceSessionRecord> { active.map { .loaded($0) } ?? .missing }
    func saveActive(_ record: PerformanceSessionRecord) throws { active = record; events.append("saveActive") }
    func removeActive() throws { active = nil; events.append("removeActive") }
    func loadCompleted() -> PerformanceSessionStoreLoadResult<CompletedPerformanceSessionReport> { completed.map { .loaded($0) } ?? .missing }
    func saveCompleted(_ report: CompletedPerformanceSessionReport) throws { completed = report; events.append("saveCompleted") }
}

private struct FakeEvidence: PerformanceSubsystemEvidenceProviding {
    func activationStatuses(at date: Date) -> [PerformanceSubsystemStatus] { [] }
    func restorationStatuses(commandEvidence: [DashboardCommandEvidence], at date: Date) -> [PerformanceSubsystemStatus] { [] }
}
private struct FakeModeProvider: PerformanceModeStateProviding { let isOn: Bool; func performanceModeIsOn() -> Bool { isOn } }
private struct FixedClock: PerformanceSessionClock { let now: Date; func currentDate() -> Date { now } }
