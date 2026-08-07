import XCTest
import CatalinaPerformancePriorityCore
import CatalinaPerformanceMemoryCore
@testable import CatalinaPerformanceDashboardCore

final class MemoryPerformanceSessionLifecycleTests: XCTestCase {
    func testPrepareForOnArmsMemoryDesiredStateBeforeFirstSessionCapture() {
        let memory = LifecycleMemoryCoordinator()
        let collector = LifecycleCollector()
        collector.onCapture = {
            XCTAssertEqual(memory.events.first?.kind, .prepare)
        }
        let fixture = makeFixture(collector: collector, memory: memory)
        let ready = expectation(description: "ready")

        fixture.coordinator.prepareForOn(selectedApplication: nil) { ready.fulfill() }
        wait(for: [ready], timeout: 2)

        guard case .prepare(let identifier) = memory.events.first else {
            XCTFail("Expected memory session preparation before capture")
            return
        }
        XCTAssertEqual(fixture.store.active?.sessionIdentifier, identifier)
        XCTAssertEqual(memory.events.filter { $0.kind == .prepare }.count, 1)
    }

    func testFailedOnSequenceRequestsImmediateMemoryRestore() {
        let memory = LifecycleMemoryCoordinator()
        let fixture = makeFixture(collector: LifecycleCollector(), memory: memory)
        let ready = expectation(description: "ready")
        fixture.coordinator.prepareForOn(selectedApplication: nil) { ready.fulfill() }
        wait(for: [ready], timeout: 2)

        fixture.coordinator.onSequenceCompleted(succeeded: false)
        waitUntil { memory.events.contains(where: { $0.kind == .restore }) }

        XCTAssertEqual(memory.events.filter { $0.kind == .restore }.count, 1)
    }

    func testFinalizationRequestsImmediateMemoryRestoreBeforeProceedingToWrapper() {
        let memory = LifecycleMemoryCoordinator()
        let collector = LifecycleCollector()
        let fixture = makeFixture(collector: collector, memory: memory)
        let ready = expectation(description: "ready")
        fixture.coordinator.prepareForOn(selectedApplication: nil) { ready.fulfill() }
        wait(for: [ready], timeout: 2)
        fixture.coordinator.onSequenceCompleted(succeeded: true)
        let proceed = expectation(description: "proceed")
        var restoreWasVisibleAtProceed = false

        fixture.coordinator.prepareForFinalization(reason: .normalOff) {
            restoreWasVisibleAtProceed = memory.events.contains(where: { $0.kind == .restore })
            proceed.fulfill()
        }
        wait(for: [proceed], timeout: 2)

        XCTAssertTrue(restoreWasVisibleAtProceed)
        XCTAssertEqual(memory.events.filter { $0.kind == .restore }.count, 1)
    }

    func testMemoryPreparationFailureDoesNotFabricateArmedStateAndStillAllowsWrapperValidation() {
        let memory = LifecycleMemoryCoordinator()
        memory.failPreparation = true
        let fixture = makeFixture(collector: LifecycleCollector(), memory: memory)
        let ready = expectation(description: "ready")

        fixture.coordinator.prepareForOn(selectedApplication: nil) { ready.fulfill() }
        wait(for: [ready], timeout: 2)

        XCTAssertTrue(fixture.coordinator.currentState().warningMessage?.contains("Memory Pressure Management could not be armed") == true)
        XCTAssertEqual(memory.events.filter { $0.kind == .prepare }.count, 1)
    }

    private func makeFixture(
        collector: LifecycleCollector,
        memory: LifecycleMemoryCoordinator
    ) -> (coordinator: PerformanceSessionCoordinator, store: LifecycleStore) {
        let store = LifecycleStore()
        let coordinator = PerformanceSessionCoordinator(
            collector: collector,
            recorder: PerformanceSessionRecorder(),
            store: store,
            evidenceProvider: LifecycleEvidence(),
            scheduler: LifecycleScheduler(),
            modeStateProvider: LifecycleModeProvider(),
            clock: LifecycleClock(),
            callbackQueue: DispatchQueue(label: "memory-lifecycle-callback"),
            memoryManagementCoordinator: memory
        )
        return (coordinator, store)
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: @escaping () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { usleep(10_000) }
        XCTAssertTrue(condition())
    }
}

private struct LifecycleMemoryEvent: Equatable {
    enum Kind: Equatable {
        case prepare
        case restore
    }

    let kind: Kind
    let identifier: String?

    static func prepare(_ identifier: String) -> LifecycleMemoryEvent {
        return LifecycleMemoryEvent(kind: .prepare, identifier: identifier)
    }

    static var restore: LifecycleMemoryEvent {
        return LifecycleMemoryEvent(kind: .restore, identifier: nil)
    }
}

private final class LifecycleMemoryCoordinator: MemoryManagementCoordinating {
    var events: [LifecycleMemoryEvent] = []
    var failPreparation = false

    func prepareSession(identifier: String, at date: Date) throws -> MemoryManagementStatusSnapshot {
        events.append(.prepare(identifier))
        if failPreparation { throw MemoryDesiredStateStoreError.unsafeDesiredState }
        return status(at: date)
    }

    func updateFrontmostApplication(_ application: AppPriorityApplication?, at date: Date) -> MemoryManagementStatusSnapshot {
        return status(at: date)
    }

    func updateAppPriorityApplication(_ application: AppPriorityApplication?, at date: Date) -> MemoryManagementStatusSnapshot {
        return status(at: date)
    }

    func evaluate(telemetry: MemoryTelemetrySnapshot) -> MemoryManagementStatusSnapshot {
        return status(at: telemetry.capturedAt)
    }

    func requestImmediateRestore(at date: Date) -> MemoryManagementStatusSnapshot {
        events.append(.restore)
        return status(at: date)
    }

    func currentStatus(at date: Date) -> MemoryManagementStatusSnapshot {
        return status(at: date)
    }

    private func status(at date: Date) -> MemoryManagementStatusSnapshot {
        return MemoryManagementStatusSnapshot(
            capturedAt: date,
            pressureState: .healthy,
            managedFamilyCount: 0,
            managedFamilyNames: [],
            interventionActive: false,
            ioPolicyStatus: .unsupported,
            note: nil
        )
    }
}

private final class LifecycleCollector: SessionMetricsCollecting {
    var onCapture: (() -> Void)?
    private var count = 0

    func capture(at date: Date, refreshThermal: Bool) -> SessionMetricSnapshot {
        onCapture?()
        count += 1
        return SessionMetricSnapshot.unavailable(
            capturedAt: date.addingTimeInterval(TimeInterval(count - 1) * 2.0),
            note: "fixture"
        )
    }
}

private final class LifecycleScheduler: PerformanceSessionScheduling {
    func scheduleOnce(after interval: TimeInterval, _ action: @escaping () -> Void) { action() }
    func scheduleRepeating(every interval: TimeInterval, _ action: @escaping () -> Void) {}
    func cancel() {}
}

private final class LifecycleStore: PerformanceSessionStoring {
    var active: PerformanceSessionRecord?
    var completed: CompletedPerformanceSessionReport?

    func loadActive() -> PerformanceSessionStoreLoadResult<PerformanceSessionRecord> {
        return active.map { .loaded($0) } ?? .missing
    }

    func saveActive(_ record: PerformanceSessionRecord) throws { active = record }
    func removeActive() throws { active = nil }

    func loadCompleted() -> PerformanceSessionStoreLoadResult<CompletedPerformanceSessionReport> {
        return completed.map { .loaded($0) } ?? .missing
    }

    func saveCompleted(_ report: CompletedPerformanceSessionReport) throws { completed = report }
}

private struct LifecycleEvidence: PerformanceSubsystemEvidenceProviding {
    func activationStatuses(at date: Date) -> [PerformanceSubsystemStatus] { return [] }
    func restorationStatuses(commandEvidence: [DashboardCommandEvidence], at date: Date) -> [PerformanceSubsystemStatus] { return [] }
}

private struct LifecycleModeProvider: PerformanceModeStateProviding {
    func performanceModeIsOn() -> Bool { return false }
}

private struct LifecycleClock: PerformanceSessionClock {
    func currentDate() -> Date { return Date(timeIntervalSince1970: 1_000) }
}
