import Foundation
import CatalinaPerformanceMemoryCore

private enum MemoryDashboardLabels {
    static let active: Set<String> = [
        "State", "Physical Used", "Available", "Compressed", "Compression Growth",
        "Swap Used", "Swap Growth", "Swap In", "Swap Out", "Page-Out Activity"
    ]
    static let completed: Set<String> = [
        "Baseline State", "Maximum State", "Baseline Compressed", "Peak Compressed",
        "Peak Compression Growth", "Baseline Swap", "Peak Swap", "Net Swap",
        "Peak Swap In", "Peak Swap Out", "Time Healthy", "Time Elevated", "Time High",
        "Time Critical"
    ]
    static let all = active.union(completed)
}

public extension SessionDashboardViewModel {
    var memoryRows: [SessionDashboardMetricRow] {
        return systemRows.filter { MemoryDashboardLabels.all.contains($0.label) }
    }

    var systemRowsWithoutMemory: [SessionDashboardMetricRow] {
        return systemRows.filter { !MemoryDashboardLabels.all.contains($0.label) }
    }
}

public extension SessionDashboardPresenter {
    func makeMemoryAwareViewModel(
        from state: PerformanceSessionCoordinatorState
    ) -> SessionDashboardViewModel {
        let base = makeViewModel(from: state)
        let detailedMemoryRows: [SessionDashboardMetricRow]
        switch state.content {
        case .active(let record), .finalizing(let record):
            detailedMemoryRows = MemorySessionDashboardPresentation.activeRows(record.latest.memoryManagement)
        case .completed(let report), .interrupted(let report):
            detailedMemoryRows = MemorySessionDashboardPresentation.completedRows(report.aggregates.memory)
        case .empty, .preparing:
            detailedMemoryRows = []
        }

        let genericSystemRows = base.systemRows.filter { row in
            row.label != "Memory Pressure" && row.label != "Memory Used" && row.label != "Swap Used"
        }
        let genericCompletedRows = base.completedRows.filter { row in
            row.label != "Memory Used" && row.label != "Swap Used"
        }

        return SessionDashboardViewModel(
            screenKind: base.screenKind,
            title: base.title,
            statusText: base.statusText,
            durationText: base.durationText,
            completionText: base.completionText,
            restoreResultText: base.restoreResultText,
            priorityTargetText: base.priorityTargetText,
            sampleCountText: base.sampleCountText,
            systemRows: genericSystemRows + detailedMemoryRows,
            graphicsRows: base.graphicsRows,
            graphicsAdvisoryText: base.graphicsAdvisoryText,
            selectedAppRows: base.selectedAppRows,
            priorityDetailRows: base.priorityDetailRows,
            completedRows: genericCompletedRows,
            subsystemRows: base.subsystemRows,
            warningText: base.warningText
        )
    }
}

private enum MemorySessionDashboardPresentation {
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.includesUnit = true
        formatter.includesCount = true
        formatter.isAdaptive = true
        return formatter
    }()

    static func activeRows(
        _ status: MemoryManagementStatusSnapshot?
    ) -> [SessionDashboardMetricRow] {
        guard let status = status else {
            return [row(label: "State", value: "Unavailable", secondary: "Memory / Swap telemetry is unavailable.")]
        }
        let counters = status.telemetry?.counters
        let rates = status.telemetry?.rates
        let physicalUsed: UInt64?
        if let physical = counters?.physicalBytes,
           let available = counters?.availableBytes,
           physical >= available {
            physicalUsed = physical - available
        } else {
            physicalUsed = nil
        }
        return [
            row(label: "State", value: stateText(status.pressureState), secondary: status.note),
            row(label: "Physical Used", value: bytes(physicalUsed), secondary: nil),
            row(label: "Available", value: bytes(counters?.availableBytes), secondary: nil),
            row(label: "Compressed", value: bytes(counters?.compressedBytes), secondary: nil),
            row(label: "Compression Growth", value: byteRate(rates?.compressionBytesPerSecond, signed: true), secondary: nil),
            row(label: "Swap Used", value: bytes(counters?.swapUsedBytes), secondary: "Allocated swap is not the same as active swap growth."),
            row(label: "Swap Growth", value: byteRate(rates?.swapGrowthBytesPerSecond, signed: true), secondary: nil),
            row(label: "Swap In", value: byteRate(rates?.swapInBytesPerSecond, signed: false), secondary: nil),
            row(label: "Swap Out", value: byteRate(rates?.swapOutBytesPerSecond, signed: false), secondary: nil),
            row(label: "Page-Out Activity", value: pageRate(rates?.pageOutsPerSecond), secondary: nil)
        ]
    }

    static func completedRows(
        _ aggregate: MemorySessionAggregate?
    ) -> [SessionDashboardMetricRow] {
        guard let aggregate = aggregate else {
            return [row(label: "Maximum State", value: "Unavailable", secondary: "No Memory / Swap aggregate was recorded for this session.")]
        }
        let netSwap: String
        if let baseline = aggregate.baselineSwapUsedBytes,
           let final = aggregate.postRestoreSwapUsedBytes ?? aggregate.latestSwapUsedBytes {
            netSwap = signedByteDelta(from: baseline, to: final)
        } else {
            netSwap = "Unavailable"
        }
        return [
            row(label: "Baseline State", value: optionalStateText(aggregate.baselineState), secondary: nil),
            row(label: "Maximum State", value: optionalStateText(aggregate.maximumState), secondary: nil),
            row(label: "Baseline Compressed", value: bytes(aggregate.baselineCompressedBytes), secondary: nil),
            row(label: "Peak Compressed", value: bytes(aggregate.peakCompressedBytes), secondary: nil),
            row(label: "Peak Compression Growth", value: byteRate(aggregate.peakCompressionGrowthBytesPerSecond, signed: false), secondary: nil),
            row(label: "Baseline Swap", value: bytes(aggregate.baselineSwapUsedBytes), secondary: nil),
            row(label: "Peak Swap", value: bytes(aggregate.peakSwapUsedBytes), secondary: nil),
            row(label: "Net Swap", value: netSwap, secondary: "A lower or higher endpoint alone is not proof of improved performance."),
            row(label: "Peak Swap In", value: byteRate(aggregate.peakSwapInBytesPerSecond, signed: false), secondary: nil),
            row(label: "Peak Swap Out", value: byteRate(aggregate.peakSwapOutBytesPerSecond, signed: false), secondary: nil),
            row(label: "Time Healthy", value: seconds(aggregate.healthySeconds), secondary: nil),
            row(label: "Time Elevated", value: seconds(aggregate.elevatedSeconds), secondary: nil),
            row(label: "Time High", value: seconds(aggregate.highSeconds), secondary: nil),
            row(label: "Time Critical", value: seconds(aggregate.criticalSeconds), secondary: nil)
        ]
    }

    private static func row(label: String, value: String, secondary: String?) -> SessionDashboardMetricRow {
        return SessionDashboardMetricRow(
            label: label,
            current: value,
            secondary: secondary,
            progressFraction: nil,
            accessibilityDescription: "\(label): \(value)"
        )
    }

    private static func stateText(_ value: MemoryPressureState) -> String {
        switch value {
        case .healthy: return "Healthy"
        case .elevated: return "Elevated"
        case .high: return "High"
        case .critical: return "Critical"
        }
    }

    private static func optionalStateText(_ value: MemoryPressureState?) -> String {
        guard let value = value else { return "Unavailable" }
        return stateText(value)
    }

    private static func bytes(_ value: UInt64?) -> String {
        guard let value = value else { return "Unavailable" }
        if value > UInt64(Int64.max) { return "Unavailable" }
        return byteFormatter.string(fromByteCount: Int64(value))
    }

    private static func byteRate(_ value: Double?, signed: Bool) -> String {
        guard let value = value, value.isFinite else { return "Unavailable" }
        let magnitude = abs(value)
        guard magnitude <= Double(Int64.max) else { return "Unavailable" }
        let formatted = byteFormatter.string(fromByteCount: Int64(magnitude.rounded())) + "/s"
        if signed {
            if value > 0 { return "+" + formatted }
            if value < 0 { return "-" + formatted }
        }
        return formatted
    }

    private static func pageRate(_ value: Double?) -> String {
        guard let value = value, value.isFinite, value >= 0 else { return "Unavailable" }
        return String(format: "%.1f pages/s", value)
    }

    private static func seconds(_ value: TimeInterval) -> String {
        guard value.isFinite, value >= 0 else { return "Unavailable" }
        let whole = Int(value.rounded())
        if whole < 60 { return "\(whole)s" }
        return "\(whole / 60)m \(whole % 60)s"
    }

    private static func signedByteDelta(from baseline: UInt64, to final: UInt64) -> String {
        if final >= baseline {
            return "+" + bytes(final - baseline)
        }
        return "-" + bytes(baseline - final)
    }
}
