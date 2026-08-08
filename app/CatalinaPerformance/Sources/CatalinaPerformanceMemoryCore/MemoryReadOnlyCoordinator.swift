import Foundation
import CatalinaPerformancePriorityCore

/// Compatibility protocol used by the session dashboard. Memory / Swap is read-only:
/// none of these calls may change process priority, I/O policy, application state, or VM state.
public protocol MemoryManagementCoordinating: AnyObject {
    func prepareSession(identifier: String, at date: Date) throws -> MemoryManagementStatusSnapshot
    @discardableResult
    func updateFrontmostApplication(_ application: AppPriorityApplication?, at date: Date) -> MemoryManagementStatusSnapshot
    @discardableResult
    func updateAppPriorityApplication(_ application: AppPriorityApplication?, at date: Date) -> MemoryManagementStatusSnapshot
    func evaluate(telemetry: MemoryTelemetrySnapshot) -> MemoryManagementStatusSnapshot
    func requestImmediateRestore(at date: Date) -> MemoryManagementStatusSnapshot
    func currentStatus(at date: Date) -> MemoryManagementStatusSnapshot
}

/// Read-only memory pressure classifier used by the Performance Session dashboard.
///
/// The historical name is retained to avoid needless churn in dashboard call sites,
/// but this type has no desired-state store, process inspector, privileged helper,
/// renice path, taskpolicy path, or restoration obligation.
public final class MemoryManagementCoordinator: MemoryManagementCoordinating {
    private let lock = NSLock()
    private var classifier = MemoryPressureClassifier()
    private var lastTelemetry: MemoryTelemetrySnapshot?
    private var lastPressureState: MemoryPressureState = .healthy
    private var sessionIdentifier: String?

    public init() {}

    public func prepareSession(identifier: String, at date: Date) throws -> MemoryManagementStatusSnapshot {
        lock.lock()
        defer { lock.unlock() }
        sessionIdentifier = identifier.isEmpty ? nil : identifier
        classifier = MemoryPressureClassifier()
        lastTelemetry = nil
        lastPressureState = .healthy
        return statusLocked(at: date, note: "Memory / Swap monitoring is read-only.")
    }

    @discardableResult
    public func updateFrontmostApplication(
        _ application: AppPriorityApplication?,
        at date: Date
    ) -> MemoryManagementStatusSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return statusLocked(at: date, note: "Memory / Swap monitoring is read-only.")
    }

    @discardableResult
    public func updateAppPriorityApplication(
        _ application: AppPriorityApplication?,
        at date: Date
    ) -> MemoryManagementStatusSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return statusLocked(at: date, note: "Memory / Swap monitoring is read-only.")
    }

    public func evaluate(telemetry: MemoryTelemetrySnapshot) -> MemoryManagementStatusSnapshot {
        lock.lock()
        defer { lock.unlock() }
        lastTelemetry = telemetry
        let evaluation = classifier.evaluate(snapshot: telemetry, interventionActive: false)
        lastPressureState = evaluation.confirmedState
        return statusLocked(at: telemetry.capturedAt, note: readOnlyNote(for: evaluation.confirmedState, telemetry: telemetry))
    }

    public func requestImmediateRestore(at date: Date) -> MemoryManagementStatusSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return statusLocked(at: date, note: "Memory / Swap is read-only; no restoration is required.")
    }

    public func currentStatus(at date: Date) -> MemoryManagementStatusSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return statusLocked(at: date, note: "Memory / Swap monitoring is read-only.")
    }

    private func statusLocked(at date: Date, note: String?) -> MemoryManagementStatusSnapshot {
        return MemoryManagementStatusSnapshot(
            capturedAt: date,
            sessionIdentifier: sessionIdentifier,
            pressureState: lastPressureState,
            managedFamilyCount: 0,
            managedFamilyNames: [],
            interventionActive: false,
            ioPolicyStatus: .unsupported,
            telemetry: lastTelemetry,
            note: note
        )
    }

    private func readOnlyNote(
        for state: MemoryPressureState,
        telemetry: MemoryTelemetrySnapshot
    ) -> String {
        if telemetry.counters == nil {
            return telemetry.note ?? "Memory / Swap telemetry is unavailable."
        }
        switch state {
        case .healthy:
            return "Memory pressure is healthy. Memory / Swap monitoring is read-only."
        case .elevated:
            return "Memory pressure is elevated. CatalinaPerformance is observing only."
        case .high:
            return "Memory pressure is high. CatalinaPerformance is observing only and will not change system or process settings."
        case .critical:
            return "Memory pressure is critical. CatalinaPerformance is observing only and will not change system or process settings."
        }
    }
}
