import Foundation
import CatalinaPerformancePriorityCore

public protocol PerformanceSessionScheduling: AnyObject {
    func scheduleRepeating(every interval: TimeInterval, _ action: @escaping () -> Void)
    func cancel()
}

public final class DispatchPerformanceSessionScheduler: PerformanceSessionScheduling {
    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()

    public init(queue: DispatchQueue = DispatchQueue(label: "local.CatalinaPerformance.session-scheduler", qos: .utility)) {
        self.queue = queue
    }

    public func scheduleRepeating(every interval: TimeInterval, _ action: @escaping () -> Void) {
        lock.lock()
        timer?.cancel()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + interval, repeating: interval)
        source.setEventHandler(handler: action)
        timer = source
        source.resume()
        lock.unlock()
    }

    public func cancel() {
        lock.lock()
        timer?.cancel()
        timer = nil
        lock.unlock()
    }
}

public protocol PerformanceModeStateProviding {
    func performanceModeIsOn() -> Bool
}

public protocol PerformanceSessionClock {
    func currentDate() -> Date
}

public struct SystemPerformanceSessionClock: PerformanceSessionClock {
    public init() {}
    public func currentDate() -> Date { Date() }
}

public enum PerformanceSessionCoordinatorContent: Equatable {
    case empty
    case preparing
    case active(PerformanceSessionRecord)
    case finalizing(PerformanceSessionRecord)
    case completed(CompletedPerformanceSessionReport)
    case interrupted(CompletedPerformanceSessionReport)
}

public struct PerformanceSessionCoordinatorState: Equatable {
    public let content: PerformanceSessionCoordinatorContent
    public let warningMessage: String?

    public init(content: PerformanceSessionCoordinatorContent, warningMessage: String?) {
        self.content = content
        self.warningMessage = warningMessage
    }
}

public final class PerformanceSessionCoordinator {
    public static let samplingInterval: TimeInterval = 2.0
    public static let thermalInterval: TimeInterval = 10.0
    public static let preRestoreCaptureTimeout: TimeInterval = 1.0

    private let collector: SessionMetricsCollecting
    private let recorder: PerformanceSessionRecording
    private let store: PerformanceSessionStoring
    private let evidenceProvider: PerformanceSubsystemEvidenceProviding
    private let scheduler: PerformanceSessionScheduling
    private let modeStateProvider: PerformanceModeStateProviding
    private let clock: PerformanceSessionClock
    private let callbackQueue: DispatchQueue
    private let stateQueue: DispatchQueue
    private let collectionQueue: DispatchQueue

    private var stateValue = PerformanceSessionCoordinatorState(content: .empty, warningMessage: nil)
    private var observers: [UUID: (PerformanceSessionCoordinatorState) -> Void] = [:]
    private var isSampleInFlight = false
    private var lastThermalRefreshAt: Date?
    private var pendingFinalizationReason: PerformanceSessionCompletionReason?
    private var finalizationGeneration = 0
    private var preRestoreCompletionUsed = false

    public init(
        collector: SessionMetricsCollecting,
        recorder: PerformanceSessionRecording,
        store: PerformanceSessionStoring,
        evidenceProvider: PerformanceSubsystemEvidenceProviding,
        scheduler: PerformanceSessionScheduling = DispatchPerformanceSessionScheduler(),
        modeStateProvider: PerformanceModeStateProviding,
        clock: PerformanceSessionClock = SystemPerformanceSessionClock(),
        callbackQueue: DispatchQueue = .main,
        stateQueue: DispatchQueue = DispatchQueue(label: "local.CatalinaPerformance.session-coordinator", qos: .utility),
        collectionQueue: DispatchQueue = DispatchQueue(label: "local.CatalinaPerformance.session-collector", qos: .utility)
    ) {
        self.collector = collector
        self.recorder = recorder
        self.store = store
        self.evidenceProvider = evidenceProvider
        self.scheduler = scheduler
        self.modeStateProvider = modeStateProvider
        self.clock = clock
        self.callbackQueue = callbackQueue
        self.stateQueue = stateQueue
        self.collectionQueue = collectionQueue
    }

    public func prepareForOn(selectedApplication: AppPriorityApplication?, completion: @escaping () -> Void) {
        stateQueue.async {
            self.scheduler.cancel()
            self.finalizationGeneration += 1
            self.pendingFinalizationReason = nil
            self.publish(content: .preparing, warning: nil)
            let startedAt = self.clock.currentDate()
            self.isSampleInFlight = true
            self.collectionQueue.async {
                let baseline = self.collector.capture(at: startedAt, refreshThermal: true)
                self.stateQueue.async {
                    self.isSampleInFlight = false
                    self.lastThermalRefreshAt = startedAt
                    self.recorder.begin(
                        identifier: UUID().uuidString,
                        startedAt: startedAt,
                        baseline: baseline,
                        selectedApplication: selectedApplication
                    )
                    var warning: String?
                    if let active = self.recorder.activeRecord() {
                        do { try self.store.saveActive(active) }
                        catch { warning = "Dashboard baseline could not be saved: \(error)" }
                    }
                    self.publish(content: .preparing, warning: warning)
                    self.callbackQueue.async(execute: completion)
                }
            }
        }
    }

    public func onSequenceCompleted(succeeded: Bool) {
        stateQueue.async {
            if !succeeded {
                self.scheduler.cancel()
                self.recorder.discard()
                try? self.store.removeActive()
                self.publishLoadedCompletedOrEmpty(warning: nil)
                return
            }
            let now = self.clock.currentDate()
            self.recorder.markActive(at: now)
            self.recorder.replaceSubsystemStatuses(self.evidenceProvider.activationStatuses(at: now))
            let warning = self.persistActiveRecord()
            if let record = self.recorder.activeRecord() {
                self.publish(content: .active(record), warning: warning)
                self.startScheduler()
            } else {
                self.publish(content: .empty, warning: "Dashboard active record was unavailable after Performance Mode started.")
            }
        }
    }

    public func prepareForFinalization(reason: PerformanceSessionCompletionReason, proceed: @escaping () -> Void) {
        stateQueue.async {
            self.scheduler.cancel()
            self.pendingFinalizationReason = reason
            self.finalizationGeneration += 1
            let generation = self.finalizationGeneration
            self.preRestoreCompletionUsed = false
            let now = self.clock.currentDate()
            self.recorder.markFinalizing(preRestore: nil, at: now)
            if let record = self.recorder.activeRecord() {
                self.publish(content: .finalizing(record), warning: self.persistActiveRecord())
            }

            self.stateQueue.asyncAfter(deadline: .now() + Self.preRestoreCaptureTimeout) {
                self.finishPreRestoreCapture(generation: generation, snapshot: nil, proceed: proceed)
            }

            guard !self.isSampleInFlight else { return }
            self.isSampleInFlight = true
            self.collectionQueue.async {
                let snapshot = self.collector.capture(at: now, refreshThermal: false)
                self.stateQueue.async {
                    self.isSampleInFlight = false
                    self.finishPreRestoreCapture(generation: generation, snapshot: snapshot, proceed: proceed)
                }
            }
        }
    }

    public func finalizationCompleted(commandEvidence: [DashboardCommandEvidence], performanceModeStillOn: Bool) {
        stateQueue.async {
            self.finalizationGeneration += 1
            let now = self.clock.currentDate()
            if performanceModeStillOn {
                self.recorder.resumeAfterFailedFinalization(at: now, note: "Performance Mode remains active after restoration attempt.")
                self.recorder.replaceSubsystemStatuses(self.evidenceProvider.activationStatuses(at: now))
                let persistWarning = self.persistActiveRecord()
                let warning = persistWarning ?? "Restoration did not turn Performance Mode off; dashboard monitoring resumed."
                if let record = self.recorder.activeRecord() {
                    self.publish(content: .active(record), warning: warning)
                    self.startScheduler()
                }
                return
            }

            let reason = self.pendingFinalizationReason ?? .normalOff
            let activeBeforeCompletion = self.recorder.activeRecord()
            self.collectionQueue.async {
                let postRestore = self.collector.capture(at: now, refreshThermal: false)
                self.stateQueue.async {
                    let statuses = self.evidenceProvider.restorationStatuses(commandEvidence: commandEvidence, at: now)
                    guard let report = self.recorder.complete(
                        postRestore: postRestore,
                        reason: reason,
                        subsystemStatuses: statuses,
                        completedAt: now
                    ) else {
                        self.publish(content: .empty, warning: "Dashboard finalization had no active record.")
                        return
                    }
                    do {
                        try self.store.saveCompleted(report)
                        try self.store.removeActive()
                        self.pendingFinalizationReason = nil
                        let content: PerformanceSessionCoordinatorContent = report.phase == .interrupted ? .interrupted(report) : .completed(report)
                        self.publish(content: content, warning: nil)
                    } catch {
                        if let active = activeBeforeCompletion {
                            self.recorder.restoreActiveRecord(active)
                            try? self.store.saveActive(active)
                            self.publish(content: .finalizing(active), warning: "Completed dashboard report could not be saved; active recovery state was preserved: \(error)")
                        } else {
                            self.publish(content: .completed(report), warning: "Completed dashboard report could not be saved: \(error)")
                        }
                    }
                }
            }
        }
    }

    public func replaceBackgroundServiceStatuses(_ statuses: [BackgroundServiceDashboardCategoryStatus]) {
        stateQueue.async {
            self.recorder.replaceBackgroundServiceStatuses(statuses)
            let warning = self.persistActiveRecord()
            guard let record = self.recorder.activeRecord() else { return }
            switch record.phase {
            case .preparing:
                self.publish(content: .preparing, warning: warning)
            case .active:
                self.publish(content: .active(record), warning: warning)
            case .finalizing:
                self.publish(content: .finalizing(record), warning: warning)
            case .completed, .interrupted:
                break
            }
        }
    }

    public func refreshNow() {
        stateQueue.async { self.startSampleIfPossible() }
    }

    public func recoverAtLaunch(completion: (() -> Void)? = nil) {
        stateQueue.async {
            var warning: String?
            switch self.store.loadActive() {
            case .loaded(let record):
                self.recorder.restoreActiveRecord(record)
                if self.modeStateProvider.performanceModeIsOn() {
                    let now = self.clock.currentDate()
                    if now > record.latest.capturedAt {
                        self.recorder.addMonitoringGap(startedAt: record.latest.capturedAt, endedAt: now)
                    }
                    self.recorder.markActive(at: now)
                    self.recorder.replaceSubsystemStatuses(self.evidenceProvider.activationStatuses(at: now))
                    warning = self.persistActiveRecord()
                    if let active = self.recorder.activeRecord() {
                        self.publish(content: .active(active), warning: warning)
                        self.startScheduler()
                    }
                    self.finishLaunchRecovery(completion)
                } else {
                    let now = self.clock.currentDate()
                    self.collectionQueue.async {
                        let latest = self.collector.capture(at: now, refreshThermal: true)
                        self.stateQueue.async {
                            let unknown = PerformanceSubsystem.allCases.map {
                                PerformanceSubsystemStatus(subsystem: $0, state: .unknown, updatedAt: now, note: "Restoration was not observed by the dashboard.")
                            }
                            guard let report = self.recorder.interrupt(latest: latest, subsystemStatuses: unknown, completedAt: now) else {
                                self.publish(content: .empty, warning: "Interrupted dashboard record could not be finalized.")
                                self.finishLaunchRecovery(completion)
                                return
                            }
                            do {
                                try self.store.saveCompleted(report)
                                try self.store.removeActive()
                                self.publish(content: .interrupted(report), warning: nil)
                            } catch {
                                self.recorder.restoreActiveRecord(record)
                                self.publish(content: .finalizing(record), warning: "Interrupted dashboard report could not be saved: \(error)")
                            }
                            self.finishLaunchRecovery(completion)
                        }
                    }
                }
            case .recoveredInvalid(_, let message):
                warning = "Invalid active dashboard record was backed up: \(message)"
                self.publishLoadedCompletedOrEmpty(warning: warning)
                self.finishLaunchRecovery(completion)
            case .missing:
                self.publishLoadedCompletedOrEmpty(warning: nil)
                self.finishLaunchRecovery(completion)
            }
        }
    }

    private func finishLaunchRecovery(_ completion: (() -> Void)?) {
        guard let completion = completion else { return }
        callbackQueue.async(execute: completion)
    }

    public func currentState() -> PerformanceSessionCoordinatorState {
        stateQueue.sync { stateValue }
    }

    internal func persistedActiveRecord() -> PerformanceSessionRecord? {
        stateQueue.sync { recorder.activeRecord() }
    }

    @discardableResult
    public func addObserver(_ observer: @escaping (PerformanceSessionCoordinatorState) -> Void) -> UUID {
        let token = UUID()
        let state = stateQueue.sync { () -> PerformanceSessionCoordinatorState in
            observers[token] = observer
            return stateValue
        }
        callbackQueue.async { observer(state) }
        return token
    }

    public func removeObserver(_ token: UUID) {
        stateQueue.async { self.observers.removeValue(forKey: token) }
    }

    private func finishPreRestoreCapture(generation: Int, snapshot: SessionMetricSnapshot?, proceed: @escaping () -> Void) {
        guard generation == finalizationGeneration, !preRestoreCompletionUsed else { return }
        preRestoreCompletionUsed = true
        if let snapshot = snapshot {
            recorder.markFinalizing(preRestore: snapshot, at: snapshot.capturedAt)
        }
        let warning = persistActiveRecord()
        if let record = recorder.activeRecord() {
            publish(content: .finalizing(record), warning: warning)
        }
        callbackQueue.async(execute: proceed)
    }

    private func startScheduler() {
        scheduler.scheduleRepeating(every: Self.samplingInterval) { [weak self] in
            self?.stateQueue.async { self?.startSampleIfPossible() }
        }
    }

    private func startSampleIfPossible() {
        guard !isSampleInFlight,
              let record = recorder.activeRecord(),
              record.phase == .active else { return }
        isSampleInFlight = true
        let now = clock.currentDate()
        let refreshThermal: Bool
        if let lastThermalRefreshAt = lastThermalRefreshAt {
            refreshThermal = now.timeIntervalSince(lastThermalRefreshAt) >= Self.thermalInterval
        } else {
            refreshThermal = true
        }
        if refreshThermal { lastThermalRefreshAt = now }
        collectionQueue.async {
            let snapshot = self.collector.capture(at: now, refreshThermal: refreshThermal)
            self.stateQueue.async {
                self.isSampleInFlight = false
                guard self.recorder.activeRecord()?.phase == .active else { return }
                self.recorder.record(sample: snapshot)
                let warning = self.persistActiveRecord()
                if let active = self.recorder.activeRecord() {
                    self.publish(content: .active(active), warning: warning)
                }
            }
        }
    }

    private func persistActiveRecord() -> String? {
        guard let record = recorder.activeRecord() else { return nil }
        do {
            try store.saveActive(record)
            return nil
        } catch {
            recorder.addOrCoalesceError(operation: "persistence", message: String(describing: error), at: clock.currentDate())
            return "Dashboard active session could not be saved: \(error)"
        }
    }

    private func publishLoadedCompletedOrEmpty(warning: String?) {
        switch store.loadCompleted() {
        case .loaded(let report):
            let content: PerformanceSessionCoordinatorContent = report.phase == .interrupted ? .interrupted(report) : .completed(report)
            publish(content: content, warning: warning)
        case .recoveredInvalid(_, let message):
            let combined = [warning, "Invalid completed dashboard report was backed up: \(message)"].compactMap { $0 }.joined(separator: " ")
            publish(content: .empty, warning: combined.isEmpty ? nil : combined)
        case .missing:
            publish(content: .empty, warning: warning)
        }
    }

    private func publish(content: PerformanceSessionCoordinatorContent, warning: String?) {
        let state = PerformanceSessionCoordinatorState(content: content, warningMessage: warning)
        stateValue = state
        let callbacks = Array(observers.values)
        for callback in callbacks {
            callbackQueue.async { callback(state) }
        }
    }
}
