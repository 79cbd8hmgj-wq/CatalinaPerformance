import XCTest
@testable import CatalinaPerformanceVisualPerformanceCore

final class VisualPerformanceCoordinatorTests: XCTestCase {
    func testPreparePersistsBeforeFirstWriteAndAppliesSupportedSettings() {
        let operatorFake = FakeOperator()
        operatorFake.autoHideEnabled = false
        let store = FakeStore()
        let coordinator = makeCoordinator(operatorFake: operatorFake, store: store)
        let expectation = self.expectation(description: "prepare")

        coordinator.prepareForPerformanceOn { snapshot in
            XCTAssertTrue(store.didWriteBeforeFirstMutation)
            XCTAssertEqual(snapshot.settings.count, 9)
            XCTAssertEqual(snapshot.settings.filter { $0.outcome == .notApplicable }.count, 2)
            XCTAssertEqual(snapshot.settings.filter { $0.outcome == .applied || $0.outcome == .appliedDeferred }.count, 7)
            XCTAssertEqual(snapshot.aggregateStatus, .applied)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }

    func testOneApplyFailureRollsBackOnlyThatSettingAndContinues() {
        let operatorFake = FakeOperator()
        operatorFake.failWriteIDs = [.reduceMotion]
        let store = FakeStore()
        let coordinator = makeCoordinator(operatorFake: operatorFake, store: store)
        let expectation = self.expectation(description: "prepare")

        coordinator.prepareForPerformanceOn { snapshot in
            XCTAssertEqual(snapshot.settings.first(where: { $0.id == .reduceMotion })?.outcome, .applyFailed)
            XCTAssertTrue(snapshot.settings.contains(where: { $0.id == .reduceTransparency && ($0.outcome == .applied || $0.outcome == .appliedDeferred) }))
            XCTAssertEqual(snapshot.aggregateStatus, .appliedWithLimitations)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }

    func testRestorePreservesManualChangeAndDeletesOriginallyAbsentKeys() {
        let operatorFake = FakeOperator()
        operatorFake.initialValues[.minimizeEffect] = .present(.string("genie"))
        let store = FakeStore()
        let coordinator = makeCoordinator(operatorFake: operatorFake, store: store)
        let applied = expectation(description: "applied")

        coordinator.prepareForPerformanceOn { _ in applied.fulfill() }
        wait(for: [applied], timeout: 2)

        operatorFake.values[.minimizeEffect] = .present(.string("suck"))
        let restored = expectation(description: "restored")
        coordinator.restore(reason: .normalOff) { snapshot in
            XCTAssertEqual(snapshot.settings.first(where: { $0.id == .minimizeEffect })?.outcome, .preservedManualChange)
            XCTAssertEqual(operatorFake.values[.reduceMotion], .absent)
            XCTAssertEqual(snapshot.aggregateStatus, .successful)
            XCTAssertNil(store.active)
            XCTAssertNotNil(store.completed)
            restored.fulfill()
        }
        wait(for: [restored], timeout: 2)
    }

    func testRestoreFailureKeepsRecoveryState() {
        let operatorFake = FakeOperator()
        operatorFake.initialValues[.reduceTransparency] = .present(.boolean(false))
        let store = FakeStore()
        let coordinator = makeCoordinator(operatorFake: operatorFake, store: store)
        let applied = expectation(description: "applied")
        coordinator.prepareForPerformanceOn { _ in applied.fulfill() }
        wait(for: [applied], timeout: 2)

        operatorFake.failRestoreIDs = [.reduceTransparency]
        let restored = expectation(description: "restored")
        coordinator.restore(reason: .emergencyRestore) { snapshot in
            XCTAssertEqual(snapshot.settings.first(where: { $0.id == .reduceTransparency })?.outcome, .restoreFailed)
            XCTAssertEqual(snapshot.aggregateStatus, .partiallyRestored)
            XCTAssertNotNil(store.active)
            restored.fulfill()
        }
        wait(for: [restored], timeout: 2)
    }

    func testStaleSessionRecoversWhenPerformanceModeIsOff() {
        let operatorFake = FakeOperator()
        let store = FakeStore()
        let coordinator = makeCoordinator(operatorFake: operatorFake, store: store)
        let applied = expectation(description: "applied")
        coordinator.prepareForPerformanceOn { _ in applied.fulfill() }
        wait(for: [applied], timeout: 2)

        let recovered = expectation(description: "recovered")
        coordinator.recoverStaleSession(performanceModeIsOn: false) { snapshot in
            XCTAssertEqual(snapshot.aggregateStatus, .successful)
            XCTAssertNil(store.active)
            recovered.fulfill()
        }
        wait(for: [recovered], timeout: 2)
    }

    func testCompletionPersistenceFailureKeepsAggregateRecoveryVisible() {
        let operatorFake = FakeOperator()
        let store = FakeStore()
        store.failComplete = true
        let coordinator = makeCoordinator(operatorFake: operatorFake, store: store)
        let applied = expectation(description: "applied")
        coordinator.prepareForPerformanceOn { _ in applied.fulfill() }
        wait(for: [applied], timeout: 2)

        let restored = expectation(description: "restored")
        coordinator.restore(reason: .normalOff) { snapshot in
            XCTAssertEqual(snapshot.aggregateStatus, .recoveryRequired)
            XCTAssertTrue(snapshot.hasUnresolvedRestoration)
            XCTAssertNotNil(store.active)
            restored.fulfill()
        }
        wait(for: [restored], timeout: 2)
    }

    private func makeCoordinator(operatorFake: FakeOperator, store: FakeStore) -> VisualPerformanceCoordinator {
        store.mutationCountProvider = { operatorFake.mutationCount }
        return VisualPerformanceCoordinator(
            preferenceOperator: operatorFake,
            stateStore: store,
            requestingUID: 501,
            workQueue: DispatchQueue(label: "test.visual.work"),
            callbackQueue: DispatchQueue(label: "test.visual.callback"),
            nowProvider: { Date(timeIntervalSince1970: 100) },
            sessionIdentifierProvider: { "session-1" }
        )
    }
}

private final class FakeOperator: VisualPreferenceOperating {
    var initialValues: [VisualSettingID: VisualPreferenceObservation] = [:]
    var values: [VisualSettingID: VisualPreferenceObservation] = [:]
    var failWriteIDs: Set<VisualSettingID> = []
    var failRestoreIDs: Set<VisualSettingID> = []
    var autoHideEnabled = true
    var mutationCount = 0

    func read(_ entry: VisualSettingCatalogEntry) throws -> VisualPreferenceObservation {
        return values[entry.id] ?? initialValues[entry.id] ?? .absent
    }

    func writeAppliedValue(_ entry: VisualSettingCatalogEntry) throws {
        mutationCount += 1
        if failWriteIDs.contains(entry.id) { throw FakeError.failed }
        values[entry.id] = .present(entry.appliedValue)
    }

    func write(_ value: VisualScalarValue, for entry: VisualSettingCatalogEntry) throws {
        mutationCount += 1
        if failRestoreIDs.contains(entry.id) { throw FakeError.failed }
        values[entry.id] = .present(value)
    }

    func delete(_ entry: VisualSettingCatalogEntry) throws {
        mutationCount += 1
        if failRestoreIDs.contains(entry.id) { throw FakeError.failed }
        values[entry.id] = .absent
    }

    func isDockAutoHideEnabled() throws -> Bool { autoHideEnabled }

    enum FakeError: Error { case failed }
}

private final class FakeStore: VisualPerformanceStateStoring {
    var active: VisualPerformanceSessionRecord?
    var completed: VisualPerformanceSessionRecord?
    var mutationCountProvider: (() -> Int)?
    var didWriteBeforeFirstMutation = false
    var failComplete = false

    func loadActive() throws -> VisualPerformanceSessionRecord? { active }
    func loadLastCompleted() throws -> VisualPerformanceSessionRecord? { completed }
    func writeActive(_ record: VisualPerformanceSessionRecord) throws {
        if (mutationCountProvider?() ?? 0) == 0 { didWriteBeforeFirstMutation = true }
        active = record
    }
    func complete(_ record: VisualPerformanceSessionRecord) throws {
        if failComplete { throw FakeStoreError.failed }
        completed = record
        active = nil
    }
    func removeActive() throws { active = nil }

    enum FakeStoreError: Error { case failed }
}
