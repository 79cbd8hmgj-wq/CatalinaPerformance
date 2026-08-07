import Foundation
import CatalinaPerformancePriorityCore

public enum MetricAvailability: String, Codable {
    case available
    case unavailable
    case unsupported
    case stale
}

public enum MemoryPressureLevel: Int, Codable, Comparable {
    case normal = 0
    case warning = 1
    case critical = 2

    public static func < (lhs: MemoryPressureLevel, rhs: MemoryPressureLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum MemoryPressureMapper {
    public static func level(totalBytes: UInt64, availableBytes: UInt64) -> MemoryPressureLevel {
        guard totalBytes > 0 else { return .critical }
        let percent = Double(availableBytes) / Double(totalBytes) * 100.0
        if percent <= 5.0 { return .critical }
        if percent <= 10.0 { return .warning }
        return .normal
    }
}

public struct MetricReading<Value: Codable & Equatable>: Codable, Equatable {
    public let value: Value?
    public let availability: MetricAvailability
    public let capturedAt: Date
    public let note: String?

    public init(value: Value?, availability: MetricAvailability, capturedAt: Date, note: String?) {
        self.value = value
        self.availability = availability
        self.capturedAt = capturedAt
        self.note = note
    }

    public static func available(_ value: Value, at date: Date) -> MetricReading<Value> {
        MetricReading(value: value, availability: .available, capturedAt: date, note: nil)
    }

    public static func unavailable(at date: Date, note: String?) -> MetricReading<Value> {
        MetricReading(value: nil, availability: .unavailable, capturedAt: date, note: note)
    }

    public static func unsupported(at date: Date, note: String?) -> MetricReading<Value> {
        MetricReading(value: nil, availability: .unsupported, capturedAt: date, note: note)
    }

    public static func stale(_ value: Value, at date: Date, note: String?) -> MetricReading<Value> {
        MetricReading(value: value, availability: .stale, capturedAt: date, note: note)
    }
}

public struct FocusedFirefoxMetricDetails: Codable, Equatable {
    public let policySummary: String
    public let trackedProcessCount: Int
    public let actuallyBoostedCount: Int
    public let parentPID: Int32?
    public let gpuPID: Int32?
    public let contentPID: Int32?
    public let waitingForStableContent: Bool
    public let warning: String?

    public init(
        policySummary: String,
        trackedProcessCount: Int,
        actuallyBoostedCount: Int,
        parentPID: Int32?,
        gpuPID: Int32?,
        contentPID: Int32?,
        waitingForStableContent: Bool,
        warning: String?
    ) {
        self.policySummary = policySummary
        self.trackedProcessCount = trackedProcessCount
        self.actuallyBoostedCount = actuallyBoostedCount
        self.parentPID = parentPID
        self.gpuPID = gpuPID
        self.contentPID = contentPID
        self.waitingForStableContent = waitingForStableContent
        self.warning = warning.map { String($0.prefix(256)) }
    }
}

public struct SessionMetricSnapshot: Codable, Equatable {
    public let capturedAt: Date
    public let systemCPUPercent: MetricReading<Double>
    public let memoryPressure: MetricReading<MemoryPressureLevel>
    public let physicalMemoryUsedBytes: MetricReading<UInt64>
    public let swapUsedBytes: MetricReading<UInt64>
    public let diskFreeBytes: MetricReading<UInt64>
    public let schedulerLimitPercent: MetricReading<Double>
    public let speedLimitPercent: MetricReading<Double>
    public let selectedAppCPUPercent: MetricReading<Double>
    public let selectedAppResidentBytes: MetricReading<UInt64>
    public let selectedAppVerifiedProcessCount: MetricReading<Int>
    public let selectedAppPriorityConfirmedCount: MetricReading<Int>
    public let focusedFirefoxPriority: FocusedFirefoxMetricDetails?
    public let windowServerCPU: WindowServerCPUReading?

    public init(
        capturedAt: Date,
        systemCPUPercent: MetricReading<Double>,
        memoryPressure: MetricReading<MemoryPressureLevel>,
        physicalMemoryUsedBytes: MetricReading<UInt64>,
        swapUsedBytes: MetricReading<UInt64>,
        diskFreeBytes: MetricReading<UInt64>,
        schedulerLimitPercent: MetricReading<Double>,
        speedLimitPercent: MetricReading<Double>,
        selectedAppCPUPercent: MetricReading<Double>,
        selectedAppResidentBytes: MetricReading<UInt64>,
        selectedAppVerifiedProcessCount: MetricReading<Int>,
        selectedAppPriorityConfirmedCount: MetricReading<Int>,
        focusedFirefoxPriority: FocusedFirefoxMetricDetails? = nil,
        windowServerCPU: WindowServerCPUReading? = nil
    ) {
        self.capturedAt = capturedAt
        self.systemCPUPercent = systemCPUPercent
        self.memoryPressure = memoryPressure
        self.physicalMemoryUsedBytes = physicalMemoryUsedBytes
        self.swapUsedBytes = swapUsedBytes
        self.diskFreeBytes = diskFreeBytes
        self.schedulerLimitPercent = schedulerLimitPercent
        self.speedLimitPercent = speedLimitPercent
        self.selectedAppCPUPercent = selectedAppCPUPercent
        self.selectedAppResidentBytes = selectedAppResidentBytes
        self.selectedAppVerifiedProcessCount = selectedAppVerifiedProcessCount
        self.selectedAppPriorityConfirmedCount = selectedAppPriorityConfirmedCount
        self.focusedFirefoxPriority = focusedFirefoxPriority
        self.windowServerCPU = windowServerCPU
    }

    public static func unavailable(capturedAt: Date, note: String) -> SessionMetricSnapshot {
        SessionMetricSnapshot(
            capturedAt: capturedAt,
            systemCPUPercent: .unavailable(at: capturedAt, note: note),
            memoryPressure: .unavailable(at: capturedAt, note: note),
            physicalMemoryUsedBytes: .unavailable(at: capturedAt, note: note),
            swapUsedBytes: .unavailable(at: capturedAt, note: note),
            diskFreeBytes: .unavailable(at: capturedAt, note: note),
            schedulerLimitPercent: .unavailable(at: capturedAt, note: note),
            speedLimitPercent: .unavailable(at: capturedAt, note: note),
            selectedAppCPUPercent: .unavailable(at: capturedAt, note: note),
            selectedAppResidentBytes: .unavailable(at: capturedAt, note: note),
            selectedAppVerifiedProcessCount: .unavailable(at: capturedAt, note: note),
            selectedAppPriorityConfirmedCount: .unavailable(at: capturedAt, note: note),
            focusedFirefoxPriority: nil,
            windowServerCPU: nil
        )
    }
}

public struct NumericMetricAggregate: Codable, Equatable {
    public var baseline: Double?
    public var latest: Double?
    public var runningSum: Double
    public var validSampleCount: Int
    public var peak: Double?
    public var finalPreRestore: Double?
    public var postRestore: Double?

    public init(
        baseline: Double? = nil,
        latest: Double? = nil,
        runningSum: Double = 0,
        validSampleCount: Int = 0,
        peak: Double? = nil,
        finalPreRestore: Double? = nil,
        postRestore: Double? = nil
    ) {
        self.baseline = baseline
        self.latest = latest
        self.runningSum = runningSum
        self.validSampleCount = validSampleCount
        self.peak = peak
        self.finalPreRestore = finalPreRestore
        self.postRestore = postRestore
    }

    public var average: Double? {
        validSampleCount == 0 ? nil : runningSum / Double(validSampleCount)
    }

    public mutating func recordBaseline(_ reading: MetricReading<Double>) {
        baseline = availableValue(reading)
    }

    public mutating func recordSample(_ reading: MetricReading<Double>) {
        guard let value = availableValue(reading) else { return }
        latest = value
        runningSum += value
        validSampleCount += 1
        peak = max(peak ?? value, value)
    }

    public mutating func recordFinalPreRestore(_ reading: MetricReading<Double>) {
        finalPreRestore = reading.value
    }

    public mutating func recordPostRestore(_ reading: MetricReading<Double>) {
        postRestore = reading.value
    }

    private func availableValue(_ reading: MetricReading<Double>) -> Double? {
        guard reading.availability == .available, let value = reading.value, value.isFinite else { return nil }
        return value
    }
}

public struct MemoryPressureMetricAggregate: Codable, Equatable {
    public var baseline: MemoryPressureLevel?
    public var latest: MemoryPressureLevel?
    public var peak: MemoryPressureLevel?
    public var finalPreRestore: MemoryPressureLevel?
    public var postRestore: MemoryPressureLevel?
    public var validSampleCount: Int

    public init(
        baseline: MemoryPressureLevel? = nil,
        latest: MemoryPressureLevel? = nil,
        peak: MemoryPressureLevel? = nil,
        finalPreRestore: MemoryPressureLevel? = nil,
        postRestore: MemoryPressureLevel? = nil,
        validSampleCount: Int = 0
    ) {
        self.baseline = baseline
        self.latest = latest
        self.peak = peak
        self.finalPreRestore = finalPreRestore
        self.postRestore = postRestore
        self.validSampleCount = validSampleCount
    }

    public mutating func recordBaseline(_ reading: MetricReading<MemoryPressureLevel>) {
        baseline = reading.availability == .available ? reading.value : nil
    }

    public mutating func recordSample(_ reading: MetricReading<MemoryPressureLevel>) {
        guard reading.availability == .available, let value = reading.value else { return }
        latest = value
        peak = max(peak ?? value, value)
        validSampleCount += 1
    }

    public mutating func recordFinalPreRestore(_ reading: MetricReading<MemoryPressureLevel>) {
        finalPreRestore = reading.value
    }

    public mutating func recordPostRestore(_ reading: MetricReading<MemoryPressureLevel>) {
        postRestore = reading.value
    }
}

public struct SessionMetricAggregates: Codable, Equatable {
    public var systemCPUPercent: NumericMetricAggregate
    public var memoryPressure: MemoryPressureMetricAggregate
    public var physicalMemoryUsedBytes: NumericMetricAggregate
    public var swapUsedBytes: NumericMetricAggregate
    public var diskFreeBytes: NumericMetricAggregate
    public var schedulerLimitPercent: NumericMetricAggregate
    public var speedLimitPercent: NumericMetricAggregate
    public var selectedAppCPUPercent: NumericMetricAggregate
    public var selectedAppResidentBytes: NumericMetricAggregate
    public var selectedAppVerifiedProcessCount: NumericMetricAggregate
    public var selectedAppPriorityConfirmedCount: NumericMetricAggregate

    public init(
        systemCPUPercent: NumericMetricAggregate = NumericMetricAggregate(),
        memoryPressure: MemoryPressureMetricAggregate = MemoryPressureMetricAggregate(),
        physicalMemoryUsedBytes: NumericMetricAggregate = NumericMetricAggregate(),
        swapUsedBytes: NumericMetricAggregate = NumericMetricAggregate(),
        diskFreeBytes: NumericMetricAggregate = NumericMetricAggregate(),
        schedulerLimitPercent: NumericMetricAggregate = NumericMetricAggregate(),
        speedLimitPercent: NumericMetricAggregate = NumericMetricAggregate(),
        selectedAppCPUPercent: NumericMetricAggregate = NumericMetricAggregate(),
        selectedAppResidentBytes: NumericMetricAggregate = NumericMetricAggregate(),
        selectedAppVerifiedProcessCount: NumericMetricAggregate = NumericMetricAggregate(),
        selectedAppPriorityConfirmedCount: NumericMetricAggregate = NumericMetricAggregate()
    ) {
        self.systemCPUPercent = systemCPUPercent
        self.memoryPressure = memoryPressure
        self.physicalMemoryUsedBytes = physicalMemoryUsedBytes
        self.swapUsedBytes = swapUsedBytes
        self.diskFreeBytes = diskFreeBytes
        self.schedulerLimitPercent = schedulerLimitPercent
        self.speedLimitPercent = speedLimitPercent
        self.selectedAppCPUPercent = selectedAppCPUPercent
        self.selectedAppResidentBytes = selectedAppResidentBytes
        self.selectedAppVerifiedProcessCount = selectedAppVerifiedProcessCount
        self.selectedAppPriorityConfirmedCount = selectedAppPriorityConfirmedCount
    }

    public mutating func recordBaseline(_ snapshot: SessionMetricSnapshot) {
        systemCPUPercent.recordBaseline(snapshot.systemCPUPercent)
        memoryPressure.recordBaseline(snapshot.memoryPressure)
        physicalMemoryUsedBytes.recordBaseline(snapshot.physicalMemoryUsedBytes.asDouble)
        swapUsedBytes.recordBaseline(snapshot.swapUsedBytes.asDouble)
        diskFreeBytes.recordBaseline(snapshot.diskFreeBytes.asDouble)
        schedulerLimitPercent.recordBaseline(snapshot.schedulerLimitPercent)
        speedLimitPercent.recordBaseline(snapshot.speedLimitPercent)
        selectedAppCPUPercent.recordBaseline(snapshot.selectedAppCPUPercent)
        selectedAppResidentBytes.recordBaseline(snapshot.selectedAppResidentBytes.asDouble)
        selectedAppVerifiedProcessCount.recordBaseline(snapshot.selectedAppVerifiedProcessCount.asDouble)
        selectedAppPriorityConfirmedCount.recordBaseline(snapshot.selectedAppPriorityConfirmedCount.asDouble)
    }

    public mutating func recordSample(_ snapshot: SessionMetricSnapshot) {
        systemCPUPercent.recordSample(snapshot.systemCPUPercent)
        memoryPressure.recordSample(snapshot.memoryPressure)
        physicalMemoryUsedBytes.recordSample(snapshot.physicalMemoryUsedBytes.asDouble)
        swapUsedBytes.recordSample(snapshot.swapUsedBytes.asDouble)
        diskFreeBytes.recordSample(snapshot.diskFreeBytes.asDouble)
        schedulerLimitPercent.recordSample(snapshot.schedulerLimitPercent)
        speedLimitPercent.recordSample(snapshot.speedLimitPercent)
        selectedAppCPUPercent.recordSample(snapshot.selectedAppCPUPercent)
        selectedAppResidentBytes.recordSample(snapshot.selectedAppResidentBytes.asDouble)
        selectedAppVerifiedProcessCount.recordSample(snapshot.selectedAppVerifiedProcessCount.asDouble)
        selectedAppPriorityConfirmedCount.recordSample(snapshot.selectedAppPriorityConfirmedCount.asDouble)
    }

    public mutating func recordFinalPreRestore(_ snapshot: SessionMetricSnapshot) {
        systemCPUPercent.recordFinalPreRestore(snapshot.systemCPUPercent)
        memoryPressure.recordFinalPreRestore(snapshot.memoryPressure)
        physicalMemoryUsedBytes.recordFinalPreRestore(snapshot.physicalMemoryUsedBytes.asDouble)
        swapUsedBytes.recordFinalPreRestore(snapshot.swapUsedBytes.asDouble)
        diskFreeBytes.recordFinalPreRestore(snapshot.diskFreeBytes.asDouble)
        schedulerLimitPercent.recordFinalPreRestore(snapshot.schedulerLimitPercent)
        speedLimitPercent.recordFinalPreRestore(snapshot.speedLimitPercent)
        selectedAppCPUPercent.recordFinalPreRestore(snapshot.selectedAppCPUPercent)
        selectedAppResidentBytes.recordFinalPreRestore(snapshot.selectedAppResidentBytes.asDouble)
        selectedAppVerifiedProcessCount.recordFinalPreRestore(snapshot.selectedAppVerifiedProcessCount.asDouble)
        selectedAppPriorityConfirmedCount.recordFinalPreRestore(snapshot.selectedAppPriorityConfirmedCount.asDouble)
    }

    public mutating func recordPostRestore(_ snapshot: SessionMetricSnapshot) {
        systemCPUPercent.recordPostRestore(snapshot.systemCPUPercent)
        memoryPressure.recordPostRestore(snapshot.memoryPressure)
        physicalMemoryUsedBytes.recordPostRestore(snapshot.physicalMemoryUsedBytes.asDouble)
        swapUsedBytes.recordPostRestore(snapshot.swapUsedBytes.asDouble)
        diskFreeBytes.recordPostRestore(snapshot.diskFreeBytes.asDouble)
        schedulerLimitPercent.recordPostRestore(snapshot.schedulerLimitPercent)
        speedLimitPercent.recordPostRestore(snapshot.speedLimitPercent)
        selectedAppCPUPercent.recordPostRestore(snapshot.selectedAppCPUPercent)
        selectedAppResidentBytes.recordPostRestore(snapshot.selectedAppResidentBytes.asDouble)
        selectedAppVerifiedProcessCount.recordPostRestore(snapshot.selectedAppVerifiedProcessCount.asDouble)
        selectedAppPriorityConfirmedCount.recordPostRestore(snapshot.selectedAppPriorityConfirmedCount.asDouble)
    }
}

private extension MetricReading where Value == UInt64 {
    var asDouble: MetricReading<Double> {
        MetricReading<Double>(value: value.map { Double($0) }, availability: availability, capturedAt: capturedAt, note: note)
    }
}

private extension MetricReading where Value == Int {
    var asDouble: MetricReading<Double> {
        MetricReading<Double>(value: value.map { Double($0) }, availability: availability, capturedAt: capturedAt, note: note)
    }
}

public enum PerformanceSessionPhase: String, Codable {
    case preparing
    case active
    case finalizing
    case completed
    case interrupted
}

public enum PerformanceSessionCompletionReason: String, Codable {
    case normalOff
    case emergencyRestore
    case interrupted
}

public enum PerformanceSubsystem: String, Codable, CaseIterable {
    case spotlight
    case timeMachine
    case powerSettings
    case uiResponsiveness
    case temporarilyClosedApplications
    case appPriority
    case backgroundServiceSuppression
}

public enum PerformanceSubsystemState: String, Codable {
    case notConfigured
    case pending
    case applied
    case partiallyApplied
    case failed
    case restored
    case partiallyRestored
    case unknown
}

public struct PerformanceSubsystemStatus: Codable, Equatable {
    public let subsystem: PerformanceSubsystem
    public let state: PerformanceSubsystemState
    public let updatedAt: Date
    public let note: String?

    public init(subsystem: PerformanceSubsystem, state: PerformanceSubsystemState, updatedAt: Date, note: String?) {
        self.subsystem = subsystem
        self.state = state
        self.updatedAt = updatedAt
        self.note = note
    }
}

public struct BackgroundServiceDashboardCategoryStatus: Codable, Equatable {
    public let categoryRawValue: String
    public let stateRawValue: String
    public let note: String?
    public let updatedAt: Date

    public init(categoryRawValue: String, stateRawValue: String, note: String?, updatedAt: Date) {
        self.categoryRawValue = categoryRawValue
        self.stateRawValue = stateRawValue
        self.note = note
        self.updatedAt = updatedAt
    }
}

public enum BackgroundServiceDashboardSummary {
    public static func status(
        for categories: [BackgroundServiceDashboardCategoryStatus],
        at date: Date
    ) -> PerformanceSubsystemStatus {
        guard !categories.isEmpty else {
            return PerformanceSubsystemStatus(
                subsystem: .backgroundServiceSuppression,
                state: .unknown,
                updatedAt: date,
                note: "Per-category background-service evidence is missing."
            )
        }

        let states = categories.map { $0.stateRawValue }
        if states.allSatisfy({ $0 == "notConfigured" }) {
            return PerformanceSubsystemStatus(
                subsystem: .backgroundServiceSuppression,
                state: .notConfigured,
                updatedAt: date,
                note: nil
            )
        }

        if states.contains("restoreFailed") || states.contains("restoring") {
            return PerformanceSubsystemStatus(
                subsystem: .backgroundServiceSuppression,
                state: .partiallyRestored,
                updatedAt: date,
                note: "One or more background-service categories still require restoration."
            )
        }

        let resolvedRestoreStates: Set<String> = [
            "restored", "resumedByUser", "notConfigured", "unsupported", "skipped"
        ]
        if states.contains("restored") && states.allSatisfy({ resolvedRestoreStates.contains($0) }) {
            return PerformanceSubsystemStatus(
                subsystem: .backgroundServiceSuppression,
                state: .restored,
                updatedAt: date,
                note: nil
            )
        }

        let appliedStates: Set<String> = [
            "paused", "resumedByUser", "notConfigured", "unsupported"
        ]
        if states.allSatisfy({ appliedStates.contains($0) }) &&
            states.contains(where: { $0 == "paused" || $0 == "resumedByUser" }) {
            return PerformanceSubsystemStatus(
                subsystem: .backgroundServiceSuppression,
                state: .applied,
                updatedAt: date,
                note: nil
            )
        }

        if states.contains(where: {
            ["pending", "capturing", "suppressing", "degraded", "skipped", "paused", "resumedByUser"].contains($0)
        }) {
            return PerformanceSubsystemStatus(
                subsystem: .backgroundServiceSuppression,
                state: .partiallyApplied,
                updatedAt: date,
                note: "One or more requested background-service categories were skipped, unsupported, or degraded."
            )
        }

        return PerformanceSubsystemStatus(
            subsystem: .backgroundServiceSuppression,
            state: .unknown,
            updatedAt: date,
            note: "Background-service state could not be classified."
        )
    }
}

public struct MonitoringGap: Codable, Equatable {
    public let startedAt: Date
    public let endedAt: Date

    public init(startedAt: Date, endedAt: Date) {
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

public struct MetricErrorSummary: Codable, Equatable {
    public let operation: String
    public var message: String
    public var firstSeenAt: Date
    public var lastSeenAt: Date
    public var occurrenceCount: Int

    public init(operation: String, message: String, firstSeenAt: Date, lastSeenAt: Date, occurrenceCount: Int) {
        self.operation = operation
        self.message = message
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.occurrenceCount = occurrenceCount
    }
}

public struct PerformanceSessionRecord: Codable, Equatable {
    public let schemaVersion: Int
    public let collectorVersion: Int
    public let sessionIdentifier: String
    public var phase: PerformanceSessionPhase
    public let startedAt: Date
    public var completedAt: Date?
    public let selectedApplication: AppPriorityApplication?
    public let baseline: SessionMetricSnapshot
    public var latest: SessionMetricSnapshot
    public var finalPreRestore: SessionMetricSnapshot?
    public var postRestore: SessionMetricSnapshot?
    public var aggregates: SessionMetricAggregates
    public var sampleCount: Int
    public var subsystemStatuses: [PerformanceSubsystemStatus]
    public var backgroundServiceStatuses: [BackgroundServiceDashboardCategoryStatus]?
    public var monitoringGaps: [MonitoringGap]
    public var metricErrors: [MetricErrorSummary]
    public var completionReason: PerformanceSessionCompletionReason?
    public var windowServer: WindowServerSessionAggregate?

    public init(
        schemaVersion: Int = 1,
        collectorVersion: Int = 1,
        sessionIdentifier: String,
        phase: PerformanceSessionPhase,
        startedAt: Date,
        completedAt: Date?,
        selectedApplication: AppPriorityApplication?,
        baseline: SessionMetricSnapshot,
        latest: SessionMetricSnapshot,
        finalPreRestore: SessionMetricSnapshot?,
        postRestore: SessionMetricSnapshot?,
        aggregates: SessionMetricAggregates,
        sampleCount: Int,
        subsystemStatuses: [PerformanceSubsystemStatus],
        backgroundServiceStatuses: [BackgroundServiceDashboardCategoryStatus]? = nil,
        monitoringGaps: [MonitoringGap],
        metricErrors: [MetricErrorSummary],
        completionReason: PerformanceSessionCompletionReason?,
        windowServer: WindowServerSessionAggregate? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.collectorVersion = collectorVersion
        self.sessionIdentifier = sessionIdentifier
        self.phase = phase
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.selectedApplication = selectedApplication
        self.baseline = baseline
        self.latest = latest
        self.finalPreRestore = finalPreRestore
        self.postRestore = postRestore
        self.aggregates = aggregates
        self.sampleCount = sampleCount
        self.subsystemStatuses = subsystemStatuses
        self.backgroundServiceStatuses = backgroundServiceStatuses
        self.monitoringGaps = monitoringGaps
        self.metricErrors = metricErrors
        self.completionReason = completionReason
        self.windowServer = windowServer
    }
}

public struct CompletedPerformanceSessionReport: Codable, Equatable {
    public let schemaVersion: Int
    public let collectorVersion: Int
    public let sessionIdentifier: String
    public let phase: PerformanceSessionPhase
    public let startedAt: Date
    public let completedAt: Date
    public let selectedApplication: AppPriorityApplication?
    public let baseline: SessionMetricSnapshot
    public let finalPreRestore: SessionMetricSnapshot?
    public let postRestore: SessionMetricSnapshot?
    public let aggregates: SessionMetricAggregates
    public let sampleCount: Int
    public let subsystemStatuses: [PerformanceSubsystemStatus]
    public let backgroundServiceStatuses: [BackgroundServiceDashboardCategoryStatus]?
    public let monitoringGaps: [MonitoringGap]
    public let metricErrors: [MetricErrorSummary]
    public let completionReason: PerformanceSessionCompletionReason
    public let windowServer: WindowServerSessionAggregate?

    public init(
        schemaVersion: Int = 1,
        collectorVersion: Int = 1,
        sessionIdentifier: String,
        phase: PerformanceSessionPhase,
        startedAt: Date,
        completedAt: Date,
        selectedApplication: AppPriorityApplication?,
        baseline: SessionMetricSnapshot,
        finalPreRestore: SessionMetricSnapshot?,
        postRestore: SessionMetricSnapshot?,
        aggregates: SessionMetricAggregates,
        sampleCount: Int,
        subsystemStatuses: [PerformanceSubsystemStatus],
        backgroundServiceStatuses: [BackgroundServiceDashboardCategoryStatus]? = nil,
        monitoringGaps: [MonitoringGap],
        metricErrors: [MetricErrorSummary],
        completionReason: PerformanceSessionCompletionReason,
        windowServer: WindowServerSessionAggregate? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.collectorVersion = collectorVersion
        self.sessionIdentifier = sessionIdentifier
        self.phase = phase
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.selectedApplication = selectedApplication
        self.baseline = baseline
        self.finalPreRestore = finalPreRestore
        self.postRestore = postRestore
        self.aggregates = aggregates
        self.sampleCount = sampleCount
        self.subsystemStatuses = subsystemStatuses
        self.backgroundServiceStatuses = backgroundServiceStatuses
        self.monitoringGaps = monitoringGaps
        self.metricErrors = metricErrors
        self.completionReason = completionReason
        self.windowServer = windowServer
    }
}
