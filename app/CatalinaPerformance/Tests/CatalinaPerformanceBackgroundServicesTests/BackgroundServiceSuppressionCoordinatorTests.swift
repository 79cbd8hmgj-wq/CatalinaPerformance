import XCTest
@testable import CatalinaPerformanceBackgroundServicesCore

final class BackgroundServiceSuppressionCoordinatorTests: XCTestCase {
    func testPrepareCapturesBaselineOnceAndRepeatedPrepareDoesNotOverwrite() {
        let store = InMemoryBackgroundStateStore()
        let worker = FakeBackgroundWorkerController()
        let coordinator = makeCoordinator(store: store, worker: worker)

        waitFor { coordinator.prepareForPerformanceOn(iCloudDriveEnabled: false, completion: $0) }
        waitFor { coordinator.prepareForPerformanceOn(iCloudDriveEnabled: false, completion: $0) }

        XCTAssertEqual(store.saveCalls, 1)
        XCTAssertEqual(worker.captureCalls.filter { $0 == .photos }.count, 1)
    }

    func testMonitorResuppressesRelaunchedWorkerAndSkipsOverlappingTick() {
        let store = InMemoryBackgroundStateStore()
        let worker = FakeBackgroundWorkerController()
        let scheduler = ManualBackgroundServiceScheduler()
        let coordinator = makeCoordinator(store: store, worker: worker, scheduler: scheduler)

        waitFor { coordinator.prepareForPerformanceOn(iCloudDriveEnabled: false, completion: $0) }
        waitFor { coordinator.performanceOnSucceeded(completion: $0) }
        let initial = worker.suppressCalls.count
        worker.captureResultByCategory[.photos] = [worker.fixtureWorker(pid: 200, category: .photos, wasRunning: false)]

        scheduler.fire()
        scheduler.fire()
        waitUntil { worker.suppressCalls.count > initial }

        XCTAssertEqual(worker.maximumConcurrentSuppressCalls, 1)
        XCTAssertGreaterThan(worker.suppressCalls.count, initial)
    }

    func testResumeExemptsCategoryForRemainderOfSession() {
        let store = InMemoryBackgroundStateStore()
        let worker = FakeBackgroundWorkerController()
        let scheduler = ManualBackgroundServiceScheduler()
        let coordinator = makeCoordinator(store: store, worker: worker, scheduler: scheduler)

        waitFor { coordinator.prepareForPerformanceOn(iCloudDriveEnabled: false, completion: $0) }
        waitFor { coordinator.performanceOnSucceeded(completion: $0) }
        waitForVoid { done in coordinator.resume(category: .photos, reason: "User opened Photos.", completion: done) }
        let calls = worker.suppressCalls.filter { $0 == .photos }.count
        worker.captureResultByCategory[.photos] = [worker.fixtureWorker(pid: 201, category: .photos, wasRunning: false)]
        scheduler.fire()
        Thread.sleep(forTimeInterval: 0.05)

        XCTAssertEqual(worker.suppressCalls.filter { $0 == .photos }.count, calls)
        let snapshot = waitFor { coordinator.currentSnapshot(completion: $0) }
        XCTAssertEqual(snapshot.categories.first(where: { $0.category == .photos })?.state, .resumedByUser)
    }

    func testCategoryFailureDoesNotPreventOtherCategories() {
        let store = InMemoryBackgroundStateStore()
        let worker = FakeBackgroundWorkerController()
        worker.degradedCategories = [.photos]
        let coordinator = makeCoordinator(store: store, worker: worker)

        waitFor { coordinator.prepareForPerformanceOn(iCloudDriveEnabled: false, completion: $0) }
        let snapshot = waitFor { coordinator.performanceOnSucceeded(completion: $0) }

        XCTAssertEqual(snapshot.categories.first(where: { $0.category == .photos })?.state, .degraded)
        XCTAssertEqual(snapshot.categories.first(where: { $0.category == .mail })?.state, .paused)
    }


    func testUnsupportedAutomaticCategoryDoesNotDegradeActiveSession() {
        let store = InMemoryBackgroundStateStore()
        let worker = FakeBackgroundWorkerController()
        let coordinator = makeCoordinator(store: store, worker: worker)

        waitFor { coordinator.prepareForPerformanceOn(iCloudDriveEnabled: false, completion: $0) }
        let snapshot = waitFor { coordinator.performanceOnSucceeded(completion: $0) }

        XCTAssertEqual(snapshot.categories.first(where: { $0.category == .siriSpeech })?.state, .unsupported)
        XCTAssertEqual(snapshot.state, .active)
    }

    func testPerformanceOffResolvesWorkerCategoryWithNoCapturedProcesses() {
        let store = InMemoryBackgroundStateStore()
        let worker = FakeBackgroundWorkerController()
        worker.captureResultByCategory[.photos] = []
        worker.captureResultByCategory[.mail] = []
        let coordinator = makeCoordinator(store: store, worker: worker)

        waitFor { coordinator.prepareForPerformanceOn(iCloudDriveEnabled: false, completion: $0) }
        waitFor { coordinator.performanceOnSucceeded(completion: $0) }
        _ = waitFor { coordinator.prepareForPerformanceOff(completion: $0) }
        let settings = BackgroundServiceSettingsStatus(categories: [
            BackgroundServiceSettingsCategoryStatus(category: .softwareUpdate, state: .restored, note: nil),
            BackgroundServiceSettingsCategoryStatus(category: .appStoreUpdates, state: .restored, note: nil)
        ])
        let snapshot = waitFor { coordinator.performanceOffFinished(settingsStatus: settings, completion: $0) }

        XCTAssertEqual(snapshot.state, .restored)
        XCTAssertNil(store.active)
        XCTAssertEqual(store.completed?.categories.first(where: { $0.category == .photos })?.state, .restored)
        XCTAssertEqual(store.completed?.categories.first(where: { $0.category == .mail })?.state, .restored)
        XCTAssertTrue(worker.restoreCalls.contains(.photos))
        XCTAssertTrue(worker.restoreCalls.contains(.mail))
    }

    func testStaleRecoveryResolvesPausedWorkerCategoryWithNoCapturedProcesses() {
        let store = InMemoryBackgroundStateStore()
        let worker = FakeBackgroundWorkerController()
        store.active = BackgroundServiceSessionRecord(
            sessionIdentifier: "stale-empty",
            requestingUID: 501,
            startedAt: Date(),
            completedAt: nil,
            categories: [
                BackgroundServiceCategoryRecord(
                    category: .photos,
                    requested: true,
                    state: .paused,
                    note: "No worker was running when suppression began.",
                    workers: [],
                    userResume: nil,
                    updatedAt: Date()
                )
            ]
        )
        let coordinator = makeCoordinator(store: store, worker: worker)

        let snapshot = waitFor { coordinator.recoverStaleSession(completion: $0) }

        XCTAssertEqual(snapshot.state, .restored)
        XCTAssertNil(store.active)
        XCTAssertEqual(store.completed?.categories.first?.state, .restored)
        XCTAssertEqual(worker.restoreCalls, [.photos])
    }

    func testPrepareForOffCancelsMonitorBeforeRestoration() {
        let store = InMemoryBackgroundStateStore()
        let worker = FakeBackgroundWorkerController()
        let scheduler = ManualBackgroundServiceScheduler()
        let coordinator = makeCoordinator(store: store, worker: worker, scheduler: scheduler)

        waitFor { coordinator.prepareForPerformanceOn(iCloudDriveEnabled: false, completion: $0) }
        waitFor { coordinator.performanceOnSucceeded(completion: $0) }
        _ = waitFor { coordinator.prepareForPerformanceOff(completion: $0) }
        XCTAssertTrue(scheduler.cancelled)

        let status = BackgroundServiceSettingsStatus(categories: [
            BackgroundServiceSettingsCategoryStatus(category: .softwareUpdate, state: .restored, note: nil),
            BackgroundServiceSettingsCategoryStatus(category: .appStoreUpdates, state: .restored, note: nil)
        ])
        _ = waitFor { coordinator.performanceOffFinished(settingsStatus: status, completion: $0) }
        XCTAssertFalse(worker.restoreCalls.isEmpty)
    }

    func testStaleRecoveryRetriesOnlyUnresolvedWorkerCategories() {
        let store = InMemoryBackgroundStateStore()
        let worker = FakeBackgroundWorkerController()
        let failed = BackgroundServiceCategoryRecord(
            category: .photos,
            requested: true,
            state: .restoreFailed,
            note: nil,
            workers: [worker.fixtureWorker(pid: 1, category: .photos, wasRunning: true, didConfirmStop: true)],
            userResume: nil,
            updatedAt: Date()
        )
        let restored = BackgroundServiceCategoryRecord(
            category: .mail,
            requested: true,
            state: .restored,
            note: nil,
            workers: [],
            userResume: nil,
            updatedAt: Date()
        )
        store.active = BackgroundServiceSessionRecord(
            sessionIdentifier: "stale",
            requestingUID: 501,
            startedAt: Date(),
            completedAt: nil,
            categories: [failed, restored]
        )
        let coordinator = makeCoordinator(store: store, worker: worker)

        _ = waitFor { coordinator.recoverStaleSession(completion: $0) }

        XCTAssertEqual(worker.restoreCalls, [.photos])
    }

    private func makeCoordinator(
        store: InMemoryBackgroundStateStore,
        worker: FakeBackgroundWorkerController,
        scheduler: ManualBackgroundServiceScheduler = ManualBackgroundServiceScheduler()
    ) -> BackgroundServiceSuppressionCoordinator {
        return BackgroundServiceSuppressionCoordinator(
            workerController: worker,
            stateStore: store,
            settingsStatusProvider: StaticSettingsStatusProvider.active,
            scheduler: scheduler,
            requestingUID: 501,
            catalog: .current,
            queue: DispatchQueue(label: "test.background.coordinator"),
            callbackQueue: .main,
            now: { Date(timeIntervalSince1970: 100) }
        )
    }

    private func waitFor<T>(timeout: TimeInterval = 2, _ body: (@escaping (T) -> Void) -> Void) -> T {
        let expectation = self.expectation(description: "completion")
        var result: T?
        body { value in result = value; expectation.fulfill() }
        wait(for: [expectation], timeout: timeout)
        return result!
    }

    private func waitForVoid(timeout: TimeInterval = 2, _ body: (@escaping () -> Void) -> Void) {
        let expectation = self.expectation(description: "completion")
        body { expectation.fulfill() }
        wait(for: [expectation], timeout: timeout)
    }

    private func waitUntil(timeout: TimeInterval = 2, condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTFail("Condition not reached")
    }
}

private final class InMemoryBackgroundStateStore: BackgroundServiceStateStoring {
    var active: BackgroundServiceSessionRecord?
    var completed: BackgroundServiceSessionRecord?
    var saveCalls = 0
    func loadActive() throws -> BackgroundServiceSessionRecord? { active }
    func saveActive(_ record: BackgroundServiceSessionRecord) throws { active = record; saveCalls += 1 }
    func complete(_ record: BackgroundServiceSessionRecord) throws { completed = record; active = nil }
    func removeActiveIfResolved() throws { active = nil }
}

private final class FakeBackgroundWorkerController: BackgroundServiceWorkerControlling {
    var captureCalls: [BackgroundServiceCategory] = []
    var suppressCalls: [BackgroundServiceCategory] = []
    var restoreCalls: [BackgroundServiceCategory] = []
    var captureResultByCategory: [BackgroundServiceCategory: [BackgroundServiceWorkerRecord]] = [:]
    var degradedCategories: Set<BackgroundServiceCategory> = []
    var concurrentSuppressCalls = 0
    var maximumConcurrentSuppressCalls = 0

    func capture(category: BackgroundServiceCategory, uid: UInt32) throws -> [BackgroundServiceWorkerRecord] {
        captureCalls.append(category)
        if let value = captureResultByCategory[category] { return value }
        guard [.photos, .mail, .messagesFaceTime].contains(category) else { return [] }
        return [fixtureWorker(pid: Int32(100 + captureCalls.count), category: category, wasRunning: true)]
    }

    func suppress(category: BackgroundServiceCategory, records: [BackgroundServiceWorkerRecord], uid: UInt32) -> BackgroundServiceCategoryRecord {
        concurrentSuppressCalls += 1
        maximumConcurrentSuppressCalls = max(maximumConcurrentSuppressCalls, concurrentSuppressCalls)
        suppressCalls.append(category)
        defer { concurrentSuppressCalls -= 1 }
        let state: BackgroundServiceCategoryState = degradedCategories.contains(category) ? .degraded : .paused
        return BackgroundServiceCategoryRecord(category: category, requested: true, state: state, note: nil, workers: records, userResume: nil, updatedAt: Date())
    }

    func verifySuppressed(category: BackgroundServiceCategory, records: [BackgroundServiceWorkerRecord], uid: UInt32) -> BackgroundServiceCategoryRecord {
        return BackgroundServiceCategoryRecord(category: category, requested: true, state: .paused, note: nil, workers: records, userResume: nil, updatedAt: Date())
    }

    func restore(category: BackgroundServiceCategory, records: [BackgroundServiceWorkerRecord], uid: UInt32) -> BackgroundServiceCategoryRecord {
        restoreCalls.append(category)
        return BackgroundServiceCategoryRecord(category: category, requested: true, state: .restored, note: nil, workers: records, userResume: nil, updatedAt: Date())
    }

    func fixtureWorker(pid: Int32, category: BackgroundServiceCategory, wasRunning: Bool, didConfirmStop: Bool = false) -> BackgroundServiceWorkerRecord {
        let target = CatalinaBackgroundServiceCatalog.current.workerTargets(for: category).first!
        return BackgroundServiceWorkerRecord(
            pid: pid, parentPID: 1, effectiveUID: 501,
            executablePath: target.allowedExecutablePaths[0],
            processStartSeconds: 1, processStartMicroseconds: 1,
            launchLabel: target.launchLabel,
            wasRunningBeforeSuppression: wasRunning,
            didAttemptStop: didConfirmStop, didConfirmStop: didConfirmStop,
            didAttemptRestore: false, didConfirmRestore: false, errorMessage: nil
        )
    }
}

private final class ManualBackgroundServiceScheduler: BackgroundServiceScheduling {
    private var action: (() -> Void)?
    var cancelled = false
    func scheduleRepeating(interval: TimeInterval, action: @escaping () -> Void) -> BackgroundServiceScheduledTask {
        self.action = action
        return ManualBackgroundServiceTask { [weak self] in self?.cancelled = true }
    }
    func fire() { action?() }
}

private struct ManualBackgroundServiceTask: BackgroundServiceScheduledTask {
    let cancellation: () -> Void
    func cancel() { cancellation() }
}

private struct StaticSettingsStatusProvider: BackgroundServiceSettingsStatusProviding {
    static let active = StaticSettingsStatusProvider()
    func loadStatus() -> BackgroundServiceSettingsStatus? {
        return BackgroundServiceSettingsStatus(categories: [
            BackgroundServiceSettingsCategoryStatus(category: .softwareUpdate, state: .paused, note: nil),
            BackgroundServiceSettingsCategoryStatus(category: .appStoreUpdates, state: .paused, note: nil)
        ])
    }
}
