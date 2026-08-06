import Foundation
import CatalinaPerformancePriorityCore

public protocol PerformanceSessionRecording: AnyObject {
    func begin(identifier: String, startedAt: Date, baseline: SessionMetricSnapshot, selectedApplication: AppPriorityApplication?)
    func markActive(at date: Date)
    func record(sample: SessionMetricSnapshot)
    func markFinalizing(preRestore: SessionMetricSnapshot?, at date: Date)
    func resumeAfterFailedFinalization(at date: Date, note: String)
    func complete(postRestore: SessionMetricSnapshot?, reason: PerformanceSessionCompletionReason, subsystemStatuses: [PerformanceSubsystemStatus], completedAt: Date) -> CompletedPerformanceSessionReport?
    func interrupt(latest: SessionMetricSnapshot?, subsystemStatuses: [PerformanceSubsystemStatus], completedAt: Date) -> CompletedPerformanceSessionReport?
    func addMonitoringGap(startedAt: Date, endedAt: Date)
    func addOrCoalesceError(operation: String, message: String, at date: Date)
    func activeRecord() -> PerformanceSessionRecord?
    func replaceSubsystemStatuses(_ statuses: [PerformanceSubsystemStatus])
    func replaceBackgroundServiceStatuses(_ statuses: [BackgroundServiceDashboardCategoryStatus])
    func restoreActiveRecord(_ record: PerformanceSessionRecord)
    func discard()
}

public final class PerformanceSessionRecorder: PerformanceSessionRecording {
    private let queue = DispatchQueue(label: "local.CatalinaPerformance.session-recorder")
    private var recordValue: PerformanceSessionRecord?

    public init() {}

    public func begin(identifier: String, startedAt: Date, baseline: SessionMetricSnapshot, selectedApplication: AppPriorityApplication?) {
        queue.sync {
            var aggregates = SessionMetricAggregates()
            aggregates.recordBaseline(baseline)
            recordValue = PerformanceSessionRecord(
                sessionIdentifier: identifier,
                phase: .preparing,
                startedAt: startedAt,
                completedAt: nil,
                selectedApplication: selectedApplication,
                baseline: baseline,
                latest: baseline,
                finalPreRestore: nil,
                postRestore: nil,
                aggregates: aggregates,
                sampleCount: 0,
                subsystemStatuses: PerformanceSubsystem.allCases.map {
                    PerformanceSubsystemStatus(subsystem: $0, state: .pending, updatedAt: startedAt, note: nil)
                },
                backgroundServiceStatuses: nil,
                monitoringGaps: [],
                metricErrors: [],
                completionReason: nil
            )
        }
    }

    public func markActive(at date: Date) {
        queue.sync {
            guard var record = recordValue else { return }
            record.phase = .active
            record.completedAt = nil
            recordValue = record
        }
    }

    public func record(sample: SessionMetricSnapshot) {
        queue.sync {
            guard var record = recordValue, record.phase == .active || record.phase == .preparing else { return }
            record.latest = sample
            record.aggregates.recordSample(sample)
            record.sampleCount += 1
            recordValue = record
        }
    }

    public func markFinalizing(preRestore: SessionMetricSnapshot?, at date: Date) {
        queue.sync {
            guard var record = recordValue else { return }
            record.phase = .finalizing
            if let snapshot = preRestore {
                record.finalPreRestore = snapshot
                record.latest = snapshot
                record.aggregates.recordFinalPreRestore(snapshot)
            }
            recordValue = record
        }
    }

    public func resumeAfterFailedFinalization(at date: Date, note: String) {
        queue.sync {
            guard var record = recordValue else { return }
            record.phase = .active
            coalesceError(operation: "finalization", message: note, at: date, record: &record)
            recordValue = record
        }
    }

    public func complete(
        postRestore: SessionMetricSnapshot?,
        reason: PerformanceSessionCompletionReason,
        subsystemStatuses: [PerformanceSubsystemStatus],
        completedAt: Date
    ) -> CompletedPerformanceSessionReport? {
        queue.sync {
            guard var record = recordValue else { return nil }
            if let snapshot = postRestore {
                record.postRestore = snapshot
                record.aggregates.recordPostRestore(snapshot)
            }
            record.phase = .completed
            record.completedAt = completedAt
            record.completionReason = reason
            record.subsystemStatuses = mergingBackgroundSubsystemStatus(
                incoming: subsystemStatuses,
                existing: record.subsystemStatuses
            )
            let report = completedReport(from: record, phase: .completed, reason: reason, completedAt: completedAt)
            recordValue = nil
            return report
        }
    }

    public func interrupt(
        latest: SessionMetricSnapshot?,
        subsystemStatuses: [PerformanceSubsystemStatus],
        completedAt: Date
    ) -> CompletedPerformanceSessionReport? {
        queue.sync {
            guard var record = recordValue else { return nil }
            if let latest = latest {
                record.latest = latest
                record.finalPreRestore = latest
                record.aggregates.recordFinalPreRestore(latest)
            }
            record.phase = .interrupted
            record.completedAt = completedAt
            record.completionReason = .interrupted
            record.subsystemStatuses = mergingBackgroundSubsystemStatus(
                incoming: subsystemStatuses,
                existing: record.subsystemStatuses
            )
            let report = completedReport(from: record, phase: .interrupted, reason: .interrupted, completedAt: completedAt)
            recordValue = nil
            return report
        }
    }

    public func addMonitoringGap(startedAt: Date, endedAt: Date) {
        queue.sync {
            guard var record = recordValue else { return }
            record.monitoringGaps.append(MonitoringGap(startedAt: startedAt, endedAt: endedAt))
            recordValue = record
        }
    }

    public func addOrCoalesceError(operation: String, message: String, at date: Date) {
        queue.sync {
            guard var record = recordValue else { return }
            coalesceError(operation: operation, message: message, at: date, record: &record)
            recordValue = record
        }
    }

    public func activeRecord() -> PerformanceSessionRecord? {
        queue.sync { recordValue }
    }

    public func replaceSubsystemStatuses(_ statuses: [PerformanceSubsystemStatus]) {
        queue.sync {
            guard var record = recordValue else { return }
            record.subsystemStatuses = mergingBackgroundSubsystemStatus(
                incoming: statuses,
                existing: record.subsystemStatuses
            )
            recordValue = record
        }
    }

    public func replaceBackgroundServiceStatuses(_ statuses: [BackgroundServiceDashboardCategoryStatus]) {
        queue.sync {
            guard var record = recordValue else { return }
            record.backgroundServiceStatuses = statuses
            let updatedAt = statuses.map { $0.updatedAt }.max() ?? record.latest.capturedAt
            let summary = BackgroundServiceDashboardSummary.status(for: statuses, at: updatedAt)
            var subsystemStatuses = record.subsystemStatuses.filter {
                $0.subsystem != .backgroundServiceSuppression
            }
            subsystemStatuses.append(summary)
            record.subsystemStatuses = orderedSubsystemStatuses(subsystemStatuses)
            recordValue = record
        }
    }

    public func discard() {
        queue.sync { recordValue = nil }
    }

    public func restoreActiveRecord(_ record: PerformanceSessionRecord) {
        queue.sync { recordValue = record }
    }

    private func mergingBackgroundSubsystemStatus(
        incoming: [PerformanceSubsystemStatus],
        existing: [PerformanceSubsystemStatus]
    ) -> [PerformanceSubsystemStatus] {
        var merged = incoming
        if !merged.contains(where: { $0.subsystem == .backgroundServiceSuppression }),
           let preserved = existing.first(where: { $0.subsystem == .backgroundServiceSuppression }) {
            merged.append(preserved)
        }
        return orderedSubsystemStatuses(merged)
    }

    private func orderedSubsystemStatuses(_ statuses: [PerformanceSubsystemStatus]) -> [PerformanceSubsystemStatus] {
        let bySubsystem = Dictionary(uniqueKeysWithValues: statuses.map { ($0.subsystem, $0) })
        return PerformanceSubsystem.allCases.compactMap { bySubsystem[$0] }
    }

    private func coalesceError(operation: String, message: String, at date: Date, record: inout PerformanceSessionRecord) {
        if let index = record.metricErrors.firstIndex(where: { $0.operation == operation }) {
            var existing = record.metricErrors[index]
            existing.message = message
            existing.lastSeenAt = date
            existing.occurrenceCount += 1
            record.metricErrors[index] = existing
        } else {
            record.metricErrors.append(MetricErrorSummary(
                operation: operation,
                message: message,
                firstSeenAt: date,
                lastSeenAt: date,
                occurrenceCount: 1
            ))
        }
    }

    private func completedReport(
        from record: PerformanceSessionRecord,
        phase: PerformanceSessionPhase,
        reason: PerformanceSessionCompletionReason,
        completedAt: Date
    ) -> CompletedPerformanceSessionReport {
        CompletedPerformanceSessionReport(
            schemaVersion: record.schemaVersion,
            collectorVersion: record.collectorVersion,
            sessionIdentifier: record.sessionIdentifier,
            phase: phase,
            startedAt: record.startedAt,
            completedAt: completedAt,
            selectedApplication: record.selectedApplication,
            baseline: record.baseline,
            finalPreRestore: record.finalPreRestore,
            postRestore: record.postRestore,
            aggregates: record.aggregates,
            sampleCount: record.sampleCount,
            subsystemStatuses: record.subsystemStatuses,
            backgroundServiceStatuses: record.backgroundServiceStatuses,
            monitoringGaps: record.monitoringGaps,
            metricErrors: record.metricErrors,
            completionReason: reason
        )
    }
}
