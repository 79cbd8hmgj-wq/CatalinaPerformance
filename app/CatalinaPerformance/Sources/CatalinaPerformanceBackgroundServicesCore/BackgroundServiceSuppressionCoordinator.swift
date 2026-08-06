import Foundation

public protocol BackgroundServiceScheduledTask {
    func cancel()
}

public protocol BackgroundServiceScheduling {
    func scheduleRepeating(interval: TimeInterval, action: @escaping () -> Void) -> BackgroundServiceScheduledTask
}

public protocol BackgroundServiceSettingsStatusProviding {
    func loadStatus() -> BackgroundServiceSettingsStatus?
}

public protocol BackgroundServiceSuppressionCoordinating: AnyObject {
    var onStatusChange: ((BackgroundServiceStatusSnapshot) -> Void)? { get set }
    func prepareForPerformanceOn(iCloudDriveEnabled: Bool, completion: @escaping (BackgroundServiceStatusSnapshot) -> Void)
    func performanceOnSucceeded(completion: @escaping (BackgroundServiceStatusSnapshot) -> Void)
    func performanceOnFailed(completion: @escaping (BackgroundServiceStatusSnapshot) -> Void)
    func resume(category: BackgroundServiceCategory, reason: String, completion: (() -> Void)?)
    func prepareForPerformanceOff(completion: @escaping (BackgroundServiceStatusSnapshot) -> Void)
    func performanceOffFinished(settingsStatus: BackgroundServiceSettingsStatus?, completion: @escaping (BackgroundServiceStatusSnapshot) -> Void)
    func recoverStaleSession(completion: @escaping (BackgroundServiceStatusSnapshot) -> Void)
    func currentSnapshot(completion: @escaping (BackgroundServiceStatusSnapshot) -> Void)
}

public final class DispatchBackgroundServiceScheduledTask: BackgroundServiceScheduledTask {
    private let timer: DispatchSourceTimer
    init(timer: DispatchSourceTimer) { self.timer = timer }
    public func cancel() { timer.setEventHandler {}; timer.cancel() }
}

public struct DispatchBackgroundServiceScheduler: BackgroundServiceScheduling {
    private let queue: DispatchQueue
    public init(queue: DispatchQueue) { self.queue = queue }
    public func scheduleRepeating(interval: TimeInterval, action: @escaping () -> Void) -> BackgroundServiceScheduledTask {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler(handler: action)
        timer.resume()
        return DispatchBackgroundServiceScheduledTask(timer: timer)
    }
}

public struct FileBackgroundServiceSettingsStatusProvider: BackgroundServiceSettingsStatusProviding {
    public let statusURL: URL
    public init(statusURL: URL) { self.statusURL = statusURL }
    public func loadStatus() -> BackgroundServiceSettingsStatus? {
        return try? BackgroundServiceSettingsStatus.load(from: statusURL)
    }
}

public final class BackgroundServiceSuppressionCoordinator: BackgroundServiceSuppressionCoordinating {
    public var onStatusChange: ((BackgroundServiceStatusSnapshot) -> Void)?

    private let workerController: BackgroundServiceWorkerControlling
    private let stateStore: BackgroundServiceStateStoring
    private let settingsStatusProvider: BackgroundServiceSettingsStatusProviding
    private let scheduler: BackgroundServiceScheduling
    private let requestingUID: UInt32
    private let catalog: CatalinaBackgroundServiceCatalog
    private let queue: DispatchQueue
    private let callbackQueue: DispatchQueue
    private let now: () -> Date

    private var session: BackgroundServiceSessionRecord?
    private var scheduledTask: BackgroundServiceScheduledTask?
    private var scanInProgress = false
    private var overallState: BackgroundServiceOverallState = .off

    public init(
        workerController: BackgroundServiceWorkerControlling,
        stateStore: BackgroundServiceStateStoring,
        settingsStatusProvider: BackgroundServiceSettingsStatusProviding,
        scheduler: BackgroundServiceScheduling,
        requestingUID: UInt32,
        catalog: CatalinaBackgroundServiceCatalog = .current,
        queue: DispatchQueue = DispatchQueue(label: "local.catalinaperformance.background-services", qos: .utility),
        callbackQueue: DispatchQueue = .main,
        now: @escaping () -> Date = Date.init
    ) {
        self.workerController = workerController
        self.stateStore = stateStore
        self.settingsStatusProvider = settingsStatusProvider
        self.scheduler = scheduler
        self.requestingUID = requestingUID
        self.catalog = catalog
        self.queue = queue
        self.callbackQueue = callbackQueue
        self.now = now
    }

    public convenience init(
        workerController: BackgroundServiceWorkerControlling,
        stateStore: BackgroundServiceStateStoring,
        settingsStatusProvider: BackgroundServiceSettingsStatusProviding,
        requestingUID: UInt32,
        catalog: CatalinaBackgroundServiceCatalog = .current,
        queue: DispatchQueue = DispatchQueue(label: "local.catalinaperformance.background-services", qos: .utility),
        callbackQueue: DispatchQueue = .main,
        now: @escaping () -> Date = Date.init
    ) {
        self.init(
            workerController: workerController,
            stateStore: stateStore,
            settingsStatusProvider: settingsStatusProvider,
            scheduler: DispatchBackgroundServiceScheduler(queue: queue),
            requestingUID: requestingUID,
            catalog: catalog,
            queue: queue,
            callbackQueue: callbackQueue,
            now: now
        )
    }

    public func prepareForPerformanceOn(iCloudDriveEnabled: Bool, completion: @escaping (BackgroundServiceStatusSnapshot) -> Void) {
        queue.async {
            if self.session == nil {
                self.session = try? self.stateStore.loadActive()
            }
            if self.session != nil {
                self.overallState = .preparing
                self.finish(completion)
                return
            }

            self.overallState = .preparing
            let requested = BackgroundServiceCategory.automatic + (iCloudDriveEnabled ? [.iCloudDrive] : [])
            var categories: [BackgroundServiceCategoryRecord] = []
            var captureFailed = false

            for category in BackgroundServiceCategory.allCases {
                guard requested.contains(category) else {
                    categories.append(self.categoryRecord(category: category, requested: false, state: .notConfigured, note: nil, workers: []))
                    continue
                }
                if self.catalog.unsupportedCategories.contains(category) {
                    categories.append(self.categoryRecord(category: category, requested: true, state: .unsupported, note: "No exact Catalina target with a reliable resume path was verified.", workers: []))
                    continue
                }
                if self.catalog.workerTargets(for: category).isEmpty {
                    categories.append(self.categoryRecord(category: category, requested: true, state: .pending, note: "Settings baseline will be captured by the privileged wrapper.", workers: []))
                    continue
                }
                do {
                    let workers = try self.workerController.capture(category: category, uid: self.requestingUID)
                    categories.append(self.categoryRecord(category: category, requested: true, state: .pending, note: "Worker baseline captured.", workers: workers))
                } catch {
                    captureFailed = true
                    categories.append(self.categoryRecord(category: category, requested: true, state: .degraded, note: "Worker baseline capture failed: \(error)", workers: []))
                }
            }

            let record = BackgroundServiceSessionRecord(
                sessionIdentifier: UUID().uuidString,
                requestingUID: self.requestingUID,
                startedAt: self.now(),
                completedAt: nil,
                categories: categories
            )
            do {
                try self.stateStore.saveActive(record)
                self.session = record
                if captureFailed { self.overallState = .degraded }
            } catch {
                self.session = nil
                self.overallState = .recoveryRequired
            }
            self.finish(completion)
        }
    }

    public func performanceOnSucceeded(completion: @escaping (BackgroundServiceStatusSnapshot) -> Void) {
        queue.async {
            guard var current = self.session else {
                self.overallState = .degraded
                self.finish(completion)
                return
            }

            if let settings = self.settingsStatusProvider.loadStatus() {
                current = self.mergingSettings(settings, into: current)
            } else {
                current = self.markSettingsUnavailable(in: current)
            }

            for category in [BackgroundServiceCategory.photos, .mail, .messagesFaceTime, .siriSpeech, .iCloudDrive] {
                guard let record = current.categories.first(where: { $0.category == category }), record.requested else { continue }
                if record.state == .unsupported || record.state == .resumedByUser { continue }
                let result = self.workerController.suppress(category: category, records: record.workers, uid: self.requestingUID)
                current = self.replacing(category: category, with: result, in: current)
            }

            self.session = current
            do { try self.stateStore.saveActive(current) } catch { self.overallState = .recoveryRequired; self.finish(completion); return }
            self.overallState = current.categories.contains(where: {
                $0.state == .degraded || $0.state == .restoreFailed
            }) ? .degraded : .active
            self.startMonitoringIfNeeded()
            self.finish(completion)
        }
    }

    public func performanceOnFailed(completion: @escaping (BackgroundServiceStatusSnapshot) -> Void) {
        queue.async {
            self.stopMonitoring()
            guard var current = self.session else {
                self.overallState = .off
                self.finish(completion)
                return
            }
            for record in current.categories where record.requested &&
                !self.catalog.workerTargets(for: record.category).isEmpty {
                let restored = self.workerController.restore(category: record.category, records: record.workers, uid: self.requestingUID)
                current = self.replacing(category: record.category, with: restored, in: current)
            }
            if let settings = self.settingsStatusProvider.loadStatus() {
                current = self.mergingSettings(settings, into: current)
            }
            self.finalizeIfResolved(current)
            self.finish(completion)
        }
    }

    public func resume(category: BackgroundServiceCategory, reason: String, completion: (() -> Void)? = nil) {
        queue.async {
            guard let current = self.session,
                  let existing = current.categories.first(where: { $0.category == category }),
                  existing.requested,
                  existing.state != .unsupported,
                  existing.state != .resumedByUser else {
                self.callbackQueue.async { completion?() }
                return
            }
            let resumed = BackgroundServiceCategoryRecord(
                category: category,
                requested: true,
                state: .resumedByUser,
                note: reason,
                workers: existing.workers,
                userResume: BackgroundServiceUserResume(reason: reason, resumedAt: self.now()),
                updatedAt: self.now()
            )
            let updated = self.replacing(category: category, with: resumed, in: current)
            self.session = updated
            try? self.stateStore.saveActive(updated)
            self.publish(self.snapshot())
            self.callbackQueue.async { completion?() }
        }
    }

    public func prepareForPerformanceOff(completion: @escaping (BackgroundServiceStatusSnapshot) -> Void) {
        queue.async {
            self.stopMonitoring()
            self.overallState = .restoring
            self.finish(completion)
        }
    }

    public func performanceOffFinished(settingsStatus: BackgroundServiceSettingsStatus?, completion: @escaping (BackgroundServiceStatusSnapshot) -> Void) {
        queue.async {
            guard var current = self.session ?? (try? self.stateStore.loadActive()) else {
                self.overallState = .restored
                self.finish(completion)
                return
            }
            if let settingsStatus = settingsStatus {
                current = self.mergingSettings(settingsStatus, into: current)
            } else if let status = self.settingsStatusProvider.loadStatus() {
                current = self.mergingSettings(status, into: current)
            }

            for record in current.categories where record.requested &&
                !self.catalog.workerTargets(for: record.category).isEmpty {
                if record.state == .resumedByUser {
                    let resolved = self.categoryRecord(category: record.category, requested: true, state: .restored, note: "Category resumed by the user during the session.", workers: record.workers)
                    current = self.replacing(category: record.category, with: resolved, in: current)
                } else {
                    let restored = self.workerController.restore(category: record.category, records: record.workers, uid: self.requestingUID)
                    current = self.replacing(category: record.category, with: restored, in: current)
                }
            }
            self.finalizeIfResolved(current)
            self.finish(completion)
        }
    }

    public func recoverStaleSession(completion: @escaping (BackgroundServiceStatusSnapshot) -> Void) {
        queue.async {
            do { self.session = try self.stateStore.loadActive() } catch { self.overallState = .recoveryRequired; self.finish(completion); return }
            guard var current = self.session else {
                self.overallState = .off
                self.finish(completion)
                return
            }

            var rootSettingsUnresolved = false
            for record in current.categories {
                if [.softwareUpdate, .appStoreUpdates].contains(record.category) &&
                    [.pending, .paused, .degraded, .restoring, .restoreFailed].contains(record.state) {
                    rootSettingsUnresolved = true
                }
            }

            for record in current.categories where record.requested &&
                !self.catalog.workerTargets(for: record.category).isEmpty &&
                [.pending, .paused, .degraded, .restoring, .restoreFailed].contains(record.state) {
                let restored = self.workerController.restore(category: record.category, records: record.workers, uid: self.requestingUID)
                current = self.replacing(category: record.category, with: restored, in: current)
            }
            self.session = current
            try? self.stateStore.saveActive(current)
            if rootSettingsUnresolved || current.categories.contains(where: { $0.state == .restoreFailed }) {
                self.overallState = .recoveryRequired
            } else {
                self.finalizeIfResolved(current)
            }
            self.finish(completion)
        }
    }

    public func currentSnapshot(completion: @escaping (BackgroundServiceStatusSnapshot) -> Void) {
        queue.async { self.finish(completion) }
    }

    private func startMonitoringIfNeeded() {
        guard scheduledTask == nil else { return }
        scheduledTask = scheduler.scheduleRepeating(interval: 5.0) { [weak self] in
            self?.queue.async { self?.monitorTick() }
        }
    }

    private func stopMonitoring() {
        scheduledTask?.cancel()
        scheduledTask = nil
        scanInProgress = false
    }

    private func monitorTick() {
        guard !scanInProgress, var current = session else { return }
        scanInProgress = true
        defer { scanInProgress = false }

        for record in current.categories where record.requested &&
            record.state != .unsupported && record.state != .resumedByUser &&
            !catalog.workerTargets(for: record.category).isEmpty {
            guard let captured = try? workerController.capture(category: record.category, uid: requestingUID), !captured.isEmpty else { continue }
            let monitorRecords = captured.map { worker in
                return BackgroundServiceWorkerRecord(
                    pid: worker.pid,
                    parentPID: worker.parentPID,
                    effectiveUID: worker.effectiveUID,
                    executablePath: worker.executablePath,
                    processStartSeconds: worker.processStartSeconds,
                    processStartMicroseconds: worker.processStartMicroseconds,
                    launchLabel: worker.launchLabel,
                    wasRunningBeforeSuppression: false,
                    didAttemptStop: false,
                    didConfirmStop: false,
                    didAttemptRestore: false,
                    didConfirmRestore: false,
                    errorMessage: nil
                )
            }
            let result = workerController.suppress(category: record.category, records: monitorRecords, uid: requestingUID)
            let merged = BackgroundServiceCategoryRecord(
                category: record.category,
                requested: true,
                state: result.state,
                note: result.note,
                workers: record.workers + result.workers,
                userResume: record.userResume,
                updatedAt: now()
            )
            current = replacing(category: record.category, with: merged, in: current)
        }
        session = current
        try? stateStore.saveActive(current)
        publish(snapshot())
    }

    private func mergingSettings(_ status: BackgroundServiceSettingsStatus, into record: BackgroundServiceSessionRecord) -> BackgroundServiceSessionRecord {
        var result = record
        for value in status.categories {
            guard let existing = result.categories.first(where: { $0.category == value.category }) else { continue }
            let replacement = BackgroundServiceCategoryRecord(
                category: value.category,
                requested: existing.requested,
                state: value.state,
                note: value.note,
                workers: existing.workers,
                userResume: existing.userResume,
                updatedAt: now()
            )
            result = replacing(category: value.category, with: replacement, in: result)
        }
        return result
    }

    private func markSettingsUnavailable(in record: BackgroundServiceSessionRecord) -> BackgroundServiceSessionRecord {
        var result = record
        for category in [BackgroundServiceCategory.softwareUpdate, .appStoreUpdates] {
            guard let existing = result.categories.first(where: { $0.category == category }), existing.requested else { continue }
            let replacement = categoryRecord(category: category, requested: true, state: .degraded, note: "Settings status is unavailable.", workers: existing.workers)
            result = replacing(category: category, with: replacement, in: result)
        }
        return result
    }

    private func finalizeIfResolved(_ record: BackgroundServiceSessionRecord) {
        let unresolved = record.categories.contains { category in
            category.requested && [.pending, .paused, .degraded, .restoring, .restoreFailed].contains(category.state)
        }
        let completed = BackgroundServiceSessionRecord(
            schemaVersion: record.schemaVersion,
            sessionIdentifier: record.sessionIdentifier,
            requestingUID: record.requestingUID,
            startedAt: record.startedAt,
            completedAt: unresolved ? nil : now(),
            categories: record.categories
        )
        session = completed
        if unresolved {
            overallState = .recoveryRequired
            try? stateStore.saveActive(completed)
        } else {
            overallState = .restored
            do {
                try stateStore.complete(completed)
                session = nil
            } catch {
                overallState = .recoveryRequired
                try? stateStore.saveActive(completed)
            }
        }
    }

    private func replacing(category: BackgroundServiceCategory, with replacement: BackgroundServiceCategoryRecord, in record: BackgroundServiceSessionRecord) -> BackgroundServiceSessionRecord {
        let categories = record.categories.map { $0.category == category ? replacement : $0 }
        return BackgroundServiceSessionRecord(
            schemaVersion: record.schemaVersion,
            sessionIdentifier: record.sessionIdentifier,
            requestingUID: record.requestingUID,
            startedAt: record.startedAt,
            completedAt: record.completedAt,
            categories: categories
        )
    }

    private func categoryRecord(category: BackgroundServiceCategory, requested: Bool, state: BackgroundServiceCategoryState, note: String?, workers: [BackgroundServiceWorkerRecord]) -> BackgroundServiceCategoryRecord {
        return BackgroundServiceCategoryRecord(category: category, requested: requested, state: state, note: note, workers: workers, userResume: nil, updatedAt: now())
    }

    private func snapshot() -> BackgroundServiceStatusSnapshot {
        let values: [BackgroundServiceCategoryStatus]
        if let session = session {
            values = session.categories.map {
                BackgroundServiceCategoryStatus(category: $0.category, state: $0.state, note: $0.note, updatedAt: $0.updatedAt)
            }
        } else {
            values = BackgroundServiceCategory.allCases.map {
                BackgroundServiceCategoryStatus(category: $0, state: .notConfigured, note: nil, updatedAt: now())
            }
        }
        return BackgroundServiceStatusSnapshot(
            sessionIdentifier: session?.sessionIdentifier,
            state: overallState,
            categories: values,
            updatedAt: now()
        )
    }

    private func finish(_ completion: @escaping (BackgroundServiceStatusSnapshot) -> Void) {
        let value = snapshot()
        publish(value)
        callbackQueue.async { completion(value) }
    }

    private func publish(_ value: BackgroundServiceStatusSnapshot) {
        guard let callback = onStatusChange else { return }
        callbackQueue.async { callback(value) }
    }
}
