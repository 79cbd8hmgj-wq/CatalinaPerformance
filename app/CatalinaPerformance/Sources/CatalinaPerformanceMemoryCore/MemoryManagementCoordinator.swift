import Foundation
import CatalinaPerformancePriorityCore

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

/// Read-only session classifier retained for dashboard compatibility.
///
/// This coordinator never changes process priority, writes desired state, starts a
/// helper, or alters VM/swap policy. The legacy management-shaped interface remains
/// temporarily so older dashboard/session code can consume the telemetry revision
/// without carrying any system-mutation capability.
public final class MemoryManagementCoordinator: MemoryManagementCoordinating {
    private let lock = NSLock()
    private var classifier = MemoryPressureClassifier()
    private var sessionIdentifier: String?
    private var lastTelemetry: MemoryTelemetrySnapshot?
    private var lastPressureState: MemoryPressureState = .healthy
    private var lastNote: String?

    public init() {}

    public func prepareSession(identifier: String, at date: Date) throws -> MemoryManagementStatusSnapshot {
        lock.lock()
        defer { lock.unlock() }

        sessionIdentifier = identifier
        classifier = MemoryPressureClassifier()
        lastTelemetry = nil
        lastPressureState = .healthy
        lastNote = "Memory / Swap monitoring is read-only; no intervention is active."
        return statusLocked(at: date)
    }

    @discardableResult
    public func updateFrontmostApplication(
        _ application: AppPriorityApplication?,
        at date: Date
    ) -> MemoryManagementStatusSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return statusLocked(at: date)
    }

    @discardableResult
    public func updateAppPriorityApplication(
        _ application: AppPriorityApplication?,
        at date: Date
    ) -> MemoryManagementStatusSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return statusLocked(at: date)
    }

    public func evaluate(telemetry: MemoryTelemetrySnapshot) -> MemoryManagementStatusSnapshot {
        lock.lock()
        defer { lock.unlock() }

        lastTelemetry = telemetry
        let evaluation = classifier.evaluate(snapshot: telemetry, interventionActive: false)
        lastPressureState = evaluation.confirmedState
        lastNote = note(for: evaluation.confirmedState, telemetry: telemetry)
        return statusLocked(at: telemetry.capturedAt)
    }

    public func requestImmediateRestore(at date: Date) -> MemoryManagementStatusSnapshot {
        lock.lock()
        defer { lock.unlock() }
        lastNote = "Memory / Swap is read-only; no restoration is required."
        return statusLocked(at: date)
    }

    public func currentStatus(at date: Date) -> MemoryManagementStatusSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return statusLocked(at: date)
    }

    private func statusLocked(at date: Date) -> MemoryManagementStatusSnapshot {
        return MemoryManagementStatusSnapshot(
            capturedAt: date,
            sessionIdentifier: sessionIdentifier,
            pressureState: lastPressureState,
            managedFamilyCount: 0,
            managedFamilyNames: [],
            interventionActive: false,
            ioPolicyStatus: .unsupported,
            telemetry: lastTelemetry,
            note: lastNote
        )
    }

    private func note(
        for state: MemoryPressureState,
        telemetry: MemoryTelemetrySnapshot
    ) -> String {
        if telemetry.counters == nil {
            return telemetry.note ?? "Memory / Swap telemetry is unavailable. No system changes are performed."
        }

        switch state {
        case .healthy:
            return "Healthy — current VM activity does not indicate sustained memory pressure. Monitoring is read-only."
        case .elevated:
            return "Elevated — memory pressure is increasing. Monitoring is read-only."
        case .high:
            return "High — sustained compression or paging pressure is present. Monitoring is read-only."
        case .critical:
            return "Critical — severe sustained VM contention is present. Monitoring is read-only."
        }
    }
}
