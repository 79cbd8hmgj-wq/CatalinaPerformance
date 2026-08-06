import Foundation
import CatalinaPerformanceDashboardCore
import CatalinaPerformanceVisualPerformanceCore

final class VisualPerformanceDashboardAdapter {
    private let stateStore: VisualPerformanceStateStoring
    private let queue: DispatchQueue
    private let callbackQueue: DispatchQueue

    init(
        directoryURL: URL = AdvancedPreferences.configDirectoryURL
            .appendingPathComponent("visual_performance", isDirectory: true),
        queue: DispatchQueue = DispatchQueue(
            label: "CatalinaPerformance.VisualDashboardReader",
            qos: .utility
        ),
        callbackQueue: DispatchQueue = .main
    ) {
        self.stateStore = VisualPerformanceStateStore(directoryURL: directoryURL)
        self.queue = queue
        self.callbackQueue = callbackQueue
    }

    func loadRows(
        for screenKind: SessionDashboardScreenKind,
        completion: @escaping ([SessionDashboardMetricRow]) -> Void
    ) {
        queue.async {
            let rows: [SessionDashboardMetricRow]
            do {
                let record: VisualPerformanceSessionRecord?
                switch screenKind {
                case .active, .finalizing:
                    record = try self.stateStore.loadActive()
                case .completed, .interrupted:
                    record = try self.stateStore.loadLastCompleted()
                case .empty, .warning:
                    if let active = try self.stateStore.loadActive() {
                        record = active
                    } else {
                        record = try self.stateStore.loadLastCompleted()
                    }
                }
                rows = record.map(self.rows) ?? []
            } catch {
                rows = [
                    SessionDashboardMetricRow(
                        label: "Visual Performance",
                        current: "Recovery required",
                        secondary: "Visual state could not be read safely: \(error.localizedDescription)",
                        progressFraction: nil,
                        accessibilityDescription: "Visual Performance: Recovery required"
                    )
                ]
            }
            self.callbackQueue.async { completion(rows) }
        }
    }

    private func rows(
        for record: VisualPerformanceSessionRecord
    ) -> [SessionDashboardMetricRow] {
        let aggregate = aggregateText(record.aggregateStatus)
        var result = [
            SessionDashboardMetricRow(
                label: "Visual Performance",
                current: aggregate,
                secondary: nil,
                progressFraction: nil,
                accessibilityDescription: "Visual Performance: \(aggregate)"
            )
        ]
        result.append(contentsOf: record.settings.map { setting in
            let value = outcomeText(setting.outcome)
            return SessionDashboardMetricRow(
                label: setting.displayName,
                current: value,
                secondary: setting.note,
                progressFraction: nil,
                accessibilityDescription: "\(setting.displayName): \(value)"
            )
        })
        return result
    }

    private func aggregateText(
        _ status: VisualPerformanceAggregateStatus
    ) -> String {
        switch status {
        case .notConfigured: return "Not configured"
        case .preparing: return "Preparing"
        case .applied: return "Applied"
        case .appliedWithLimitations: return "Applied with limitations"
        case .failed: return "Failed"
        case .restoring: return "Restoring"
        case .recoveryRequired: return "Recovery required"
        case .successful: return "Successful"
        case .partiallyRestored: return "Partially restored"
        }
    }

    private func outcomeText(_ outcome: VisualSettingOutcome) -> String {
        switch outcome {
        case .pending: return "Pending"
        case .applied: return "Reduced / Enabled"
        case .appliedDeferred: return "Applied — refresh deferred"
        case .restored: return "Restored"
        case .preservedManualChange: return "Preserved manual change"
        case .notApplicable: return "Not applicable"
        case .unsupported: return "Unsupported"
        case .applyFailed: return "Apply failed"
        case .restoreFailed: return "Restore failed"
        case .recoveryRequired: return "Recovery required"
        }
    }
}
