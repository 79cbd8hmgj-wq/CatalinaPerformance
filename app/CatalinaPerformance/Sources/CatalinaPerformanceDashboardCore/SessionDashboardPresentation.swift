import Foundation

public enum SessionDashboardScreenKind: Equatable {
    case empty
    case active
    case finalizing
    case completed
    case interrupted
    case warning
}

public struct SessionDashboardMetricRow: Equatable {
    public let label: String
    public let current: String
    public let secondary: String?
    public let progressFraction: Double?
    public let accessibilityDescription: String

    public init(label: String, current: String, secondary: String?, progressFraction: Double?, accessibilityDescription: String) {
        self.label = label
        self.current = current
        self.secondary = secondary
        self.progressFraction = progressFraction
        self.accessibilityDescription = accessibilityDescription
    }
}

public struct SessionDashboardCompletedRow: Equatable {
    public let label: String
    public let baseline: String
    public let average: String
    public let peak: String
    public let final: String?

    public init(label: String, baseline: String, average: String, peak: String, final: String?) {
        self.label = label
        self.baseline = baseline
        self.average = average
        self.peak = peak
        self.final = final
    }
}

public struct SessionDashboardViewModel: Equatable {
    public let screenKind: SessionDashboardScreenKind
    public let title: String
    public let statusText: String
    public let durationText: String?
    public let completionText: String?
    public let restoreResultText: String?
    public let priorityTargetText: String?
    public let sampleCountText: String?
    public let systemRows: [SessionDashboardMetricRow]
    public let selectedAppRows: [SessionDashboardMetricRow]
    public let completedRows: [SessionDashboardCompletedRow]
    public let subsystemRows: [SessionDashboardMetricRow]
    public let warningText: String?

    public init(
        screenKind: SessionDashboardScreenKind,
        title: String,
        statusText: String,
        durationText: String?,
        completionText: String?,
        restoreResultText: String?,
        priorityTargetText: String?,
        sampleCountText: String?,
        systemRows: [SessionDashboardMetricRow],
        selectedAppRows: [SessionDashboardMetricRow],
        completedRows: [SessionDashboardCompletedRow],
        subsystemRows: [SessionDashboardMetricRow],
        warningText: String?
    ) {
        self.screenKind = screenKind
        self.title = title
        self.statusText = statusText
        self.durationText = durationText
        self.completionText = completionText
        self.restoreResultText = restoreResultText
        self.priorityTargetText = priorityTargetText
        self.sampleCountText = sampleCountText
        self.systemRows = systemRows
        self.selectedAppRows = selectedAppRows
        self.completedRows = completedRows
        self.subsystemRows = subsystemRows
        self.warningText = warningText
    }
}

public final class SessionDashboardPresenter {
    private let nowProvider: () -> Date
    private let byteFormatter: ByteCountFormatter

    public init(nowProvider: @escaping () -> Date = Date.init) {
        self.nowProvider = nowProvider
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.includesUnit = true
        formatter.includesCount = true
        formatter.isAdaptive = true
        self.byteFormatter = formatter
    }

    public func makeViewModel(from state: PerformanceSessionCoordinatorState) -> SessionDashboardViewModel {
        switch state.content {
        case .empty:
            return SessionDashboardViewModel(
                screenKind: state.warningMessage == nil ? .empty : .warning,
                title: "Session Dashboard",
                statusText: "No session report is available yet. A report appears after Performance Mode is used.",
                durationText: nil,
                completionText: nil,
                restoreResultText: nil,
                priorityTargetText: nil,
                sampleCountText: nil,
                systemRows: [],
                selectedAppRows: [],
                completedRows: [],
                subsystemRows: [],
                warningText: state.warningMessage
            )
        case .preparing:
            return SessionDashboardViewModel(
                screenKind: .active,
                title: "Session Dashboard",
                statusText: "Preparing baseline before Performance Mode starts…",
                durationText: nil,
                completionText: nil,
                restoreResultText: nil,
                priorityTargetText: nil,
                sampleCountText: nil,
                systemRows: [], selectedAppRows: [], completedRows: [], subsystemRows: [],
                warningText: state.warningMessage
            )
        case .active(let record):
            return activeViewModel(record: record, finalizing: false, warning: state.warningMessage)
        case .finalizing(let record):
            return activeViewModel(record: record, finalizing: true, warning: state.warningMessage)
        case .completed(let report):
            return completedViewModel(report: report, interrupted: false, warning: state.warningMessage)
        case .interrupted(let report):
            return completedViewModel(report: report, interrupted: true, warning: state.warningMessage)
        }
    }

    private func activeViewModel(record: PerformanceSessionRecord, finalizing: Bool, warning: String?) -> SessionDashboardViewModel {
        let snapshot = record.latest
        let target = record.selectedApplication?.displayName ?? "Not configured"
        let system = [
            metricRow(label: "CPU Usage", reading: snapshot.systemCPUPercent, format: percentOneDecimal, progress: true),
            metricRow(label: "Memory Pressure", reading: snapshot.memoryPressure, format: pressureText, progress: false),
            metricRow(label: "Memory Used", reading: snapshot.physicalMemoryUsedBytes, format: byteText, progress: false),
            metricRow(label: "Swap Used", reading: snapshot.swapUsedBytes, format: byteText, progress: false),
            metricRow(label: "Disk Free", reading: snapshot.diskFreeBytes, format: byteText, progress: false),
            limitRow(label: "CPU Scheduler Limit", reading: snapshot.schedulerLimitPercent),
            limitRow(label: "CPU Speed Limit", reading: snapshot.speedLimitPercent)
        ]
        let selected = [
            metricRow(label: "Verified Processes", reading: snapshot.selectedAppVerifiedProcessCount, format: countText, progress: false),
            metricRow(label: "Combined CPU Usage", reading: snapshot.selectedAppCPUPercent, format: percentOneDecimal, progress: false),
            metricRow(label: "Combined Memory", reading: snapshot.selectedAppResidentBytes, format: byteText, progress: false),
            priorityCountRow(snapshot.selectedAppPriorityConfirmedCount)
        ]
        return SessionDashboardViewModel(
            screenKind: finalizing ? .finalizing : .active,
            title: "Session Dashboard",
            statusText: finalizing ? "Finalizing session and restoring settings…" : "Active",
            durationText: durationText(seconds: max(0, nowProvider().timeIntervalSince(record.startedAt))),
            completionText: nil,
            restoreResultText: nil,
            priorityTargetText: target,
            sampleCountText: "\(record.sampleCount)",
            systemRows: system,
            selectedAppRows: selected,
            completedRows: [],
            subsystemRows: subsystemRows(record.subsystemStatuses),
            warningText: warning
        )
    }

    private func completedViewModel(report: CompletedPerformanceSessionReport, interrupted: Bool, warning: String?) -> SessionDashboardViewModel {
        let rows = [
            completedRow(label: "System CPU", aggregate: report.aggregates.systemCPUPercent, formatter: percentOneDecimal),
            completedRow(label: "Memory Used", aggregate: report.aggregates.physicalMemoryUsedBytes, formatter: byteDoubleText),
            completedRow(label: "Swap Used", aggregate: report.aggregates.swapUsedBytes, formatter: byteDoubleText),
            completedRow(label: "Selected-App CPU", aggregate: report.aggregates.selectedAppCPUPercent, formatter: percentOneDecimal),
            completedRow(label: "Selected-App Memory", aggregate: report.aggregates.selectedAppResidentBytes, formatter: byteDoubleText),
            completedRow(label: "Verified Processes", aggregate: report.aggregates.selectedAppVerifiedProcessCount, formatter: countDoubleText),
            completedRow(label: "Scheduler Limit", aggregate: report.aggregates.schedulerLimitPercent, formatter: percentWhole)
        ]
        return SessionDashboardViewModel(
            screenKind: interrupted ? .interrupted : .completed,
            title: interrupted ? "Interrupted Session" : "Last Completed Session",
            statusText: interrupted ? "Interrupted; restoration could not be fully observed." : "Completed",
            durationText: durationText(seconds: max(0, report.completedAt.timeIntervalSince(report.startedAt))),
            completionText: completedDateText(report.completedAt),
            restoreResultText: restoreResultText(report.subsystemStatuses, interrupted: interrupted),
            priorityTargetText: report.selectedApplication?.displayName ?? "Not configured",
            sampleCountText: "\(report.sampleCount)",
            systemRows: [],
            selectedAppRows: [],
            completedRows: rows,
            subsystemRows: subsystemRows(report.subsystemStatuses),
            warningText: warning
        )
    }

    private func metricRow<Value: Codable & Equatable>(
        label: String,
        reading: MetricReading<Value>,
        format: (Value) -> String,
        progress: Bool
    ) -> SessionDashboardMetricRow {
        let current = display(reading, format: format)
        var secondary = reading.note
        if reading.availability == .stale {
            secondary = ["Stale", secondary].compactMap { $0 }.joined(separator: " — ")
        }
        var fraction: Double?
        if progress, reading.availability == .available, let value = reading.value as? Double {
            fraction = min(1, max(0, value / 100.0))
        }
        return SessionDashboardMetricRow(
            label: label,
            current: current,
            secondary: secondary,
            progressFraction: fraction,
            accessibilityDescription: "\(label): \(current)"
        )
    }

    private func limitRow(label: String, reading: MetricReading<Double>) -> SessionDashboardMetricRow {
        let current = display(reading, format: percentWhole)
        var secondary = reading.note
        if let value = reading.value, reading.availability == .available, value < 100 {
            secondary = "Constraint detected; reported limit is below 100%."
        }
        let fraction = reading.availability == .available ? reading.value.map { min(1, max(0, $0 / 100.0)) } : nil
        return SessionDashboardMetricRow(label: label, current: current, secondary: secondary, progressFraction: fraction, accessibilityDescription: "\(label): \(current)")
    }

    private func priorityCountRow(_ reading: MetricReading<Int>) -> SessionDashboardMetricRow {
        let current: String
        if reading.availability == .unsupported {
            current = "Not configured"
        } else if let value = reading.value, reading.availability == .available || reading.availability == .stale {
            current = "\(value) at nice −5"
        } else {
            current = "Unavailable"
        }
        return SessionDashboardMetricRow(label: "Priority Status", current: current, secondary: reading.note, progressFraction: nil, accessibilityDescription: "Priority Status: \(current)")
    }

    private func display<Value: Codable & Equatable>(_ reading: MetricReading<Value>, format: (Value) -> String) -> String {
        if reading.availability == .unsupported {
            if reading.note == "App Priority is not configured." { return "Not configured" }
            return "Unavailable"
        }
        guard let value = reading.value, reading.availability == .available || reading.availability == .stale else {
            return "Unavailable"
        }
        return format(value)
    }

    private func completedRow(label: String, aggregate: NumericMetricAggregate, formatter: (Double) -> String) -> SessionDashboardCompletedRow {
        SessionDashboardCompletedRow(
            label: label,
            baseline: aggregate.baseline.map(formatter) ?? "Unavailable",
            average: aggregate.average.map(formatter) ?? "Unavailable",
            peak: aggregate.peak.map(formatter) ?? "Unavailable",
            final: (aggregate.postRestore ?? aggregate.finalPreRestore).map(formatter)
        )
    }

    private func subsystemRows(_ statuses: [PerformanceSubsystemStatus]) -> [SessionDashboardMetricRow] {
        statuses.map { status in
            let label = subsystemLabel(status.subsystem)
            let current = subsystemStateText(status.state)
            return SessionDashboardMetricRow(label: label, current: current, secondary: status.note, progressFraction: nil, accessibilityDescription: "\(label): \(current)")
        }
    }

    private func subsystemLabel(_ subsystem: PerformanceSubsystem) -> String {
        switch subsystem {
        case .spotlight: return "Spotlight"
        case .timeMachine: return "Time Machine"
        case .powerSettings: return "Power Settings"
        case .uiResponsiveness: return "UI Responsiveness"
        case .temporarilyClosedApplications: return "Temporary App Closing"
        case .appPriority: return "App Priority"
        }
    }

    private func subsystemStateText(_ state: PerformanceSubsystemState) -> String {
        switch state {
        case .notConfigured: return "Not configured"
        case .pending: return "Pending"
        case .applied: return "Applied"
        case .partiallyApplied: return "Partially applied"
        case .failed: return "Failed"
        case .restored: return "Restored"
        case .partiallyRestored: return "Partially restored"
        case .unknown: return "Unknown"
        }
    }

    private func completedDateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func restoreResultText(_ statuses: [PerformanceSubsystemStatus], interrupted: Bool) -> String {
        if interrupted { return "Interrupted — restoration not fully observed" }
        guard !statuses.isEmpty else { return "Unknown" }
        if statuses.contains(where: { $0.state == .failed }) { return "Failed" }
        let fullyResolved = statuses.allSatisfy { $0.state == .restored || $0.state == .notConfigured }
        return fullyResolved ? "Successful" : "Incomplete or unverified"
    }

    private func percentOneDecimal(_ value: Double) -> String { String(format: "%.1f%%", value) }
    private func percentWhole(_ value: Double) -> String { String(format: "%.0f%%", value) }
    private func byteText(_ value: UInt64) -> String { byteFormatter.string(fromByteCount: Int64(clamping: value)) }
    private func byteDoubleText(_ value: Double) -> String { byteFormatter.string(fromByteCount: Int64(max(0, min(Double(Int64.max), value)))) }
    private func countText(_ value: Int) -> String { "\(value)" }
    private func countDoubleText(_ value: Double) -> String { String(format: "%.0f", value) }
    private func pressureText(_ value: MemoryPressureLevel) -> String {
        switch value { case .normal: return "Normal"; case .warning: return "Warning"; case .critical: return "Critical" }
    }

    private func durationText(seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}
