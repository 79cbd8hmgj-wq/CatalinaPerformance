import Foundation
import CatalinaPerformanceMemoryCore

public enum MemoryManagementRestorationResult: String, Codable, Equatable {
    case notRequired
    case restoreRequested
    case restored
    case incomplete
    case unavailable
}

public struct MemorySessionAggregate: Codable, Equatable {
    public var baselineState: MemoryPressureState?
    public var latestState: MemoryPressureState?
    public var maximumState: MemoryPressureState?
    public var baselineCompressedBytes: UInt64?
    public var peakCompressedBytes: UInt64?
    public var baselineSwapUsedBytes: UInt64?
    public var latestSwapUsedBytes: UInt64?
    public var postRestoreSwapUsedBytes: UInt64?
    public var peakSwapUsedBytes: UInt64?
    public var peakCompressionGrowthBytesPerSecond: Double?
    public var peakSwapInBytesPerSecond: Double?
    public var peakSwapOutBytesPerSecond: Double?
    public var healthySeconds: TimeInterval
    public var elevatedSeconds: TimeInterval
    public var highSeconds: TimeInterval
    public var criticalSeconds: TimeInterval
    public var interventionEpisodes: Int
    public var managedFamilyNames: [String]
    public var longestInterventionDuration: TimeInterval
    public var restorationResult: MemoryManagementRestorationResult

    private var lastCapturedAt: Date?
    private var lastState: MemoryPressureState?
    private var lastInterventionActive: Bool
    private var activeInterventionStartedAt: Date?

    public init(
        baselineState: MemoryPressureState? = nil,
        latestState: MemoryPressureState? = nil,
        maximumState: MemoryPressureState? = nil,
        baselineCompressedBytes: UInt64? = nil,
        peakCompressedBytes: UInt64? = nil,
        baselineSwapUsedBytes: UInt64? = nil,
        latestSwapUsedBytes: UInt64? = nil,
        postRestoreSwapUsedBytes: UInt64? = nil,
        peakSwapUsedBytes: UInt64? = nil,
        peakCompressionGrowthBytesPerSecond: Double? = nil,
        peakSwapInBytesPerSecond: Double? = nil,
        peakSwapOutBytesPerSecond: Double? = nil,
        healthySeconds: TimeInterval = 0,
        elevatedSeconds: TimeInterval = 0,
        highSeconds: TimeInterval = 0,
        criticalSeconds: TimeInterval = 0,
        interventionEpisodes: Int = 0,
        managedFamilyNames: [String] = [],
        longestInterventionDuration: TimeInterval = 0,
        restorationResult: MemoryManagementRestorationResult = .notRequired,
        lastCapturedAt: Date? = nil,
        lastState: MemoryPressureState? = nil,
        lastInterventionActive: Bool = false,
        activeInterventionStartedAt: Date? = nil
    ) {
        self.baselineState = baselineState
        self.latestState = latestState
        self.maximumState = maximumState
        self.baselineCompressedBytes = baselineCompressedBytes
        self.peakCompressedBytes = peakCompressedBytes
        self.baselineSwapUsedBytes = baselineSwapUsedBytes
        self.latestSwapUsedBytes = latestSwapUsedBytes
        self.postRestoreSwapUsedBytes = postRestoreSwapUsedBytes
        self.peakSwapUsedBytes = peakSwapUsedBytes
        self.peakCompressionGrowthBytesPerSecond = peakCompressionGrowthBytesPerSecond
        self.peakSwapInBytesPerSecond = peakSwapInBytesPerSecond
        self.peakSwapOutBytesPerSecond = peakSwapOutBytesPerSecond
        self.healthySeconds = healthySeconds
        self.elevatedSeconds = elevatedSeconds
        self.highSeconds = highSeconds
        self.criticalSeconds = criticalSeconds
        self.interventionEpisodes = interventionEpisodes
        self.managedFamilyNames = managedFamilyNames
        self.longestInterventionDuration = longestInterventionDuration
        self.restorationResult = restorationResult
        self.lastCapturedAt = lastCapturedAt
        self.lastState = lastState
        self.lastInterventionActive = lastInterventionActive
        self.activeInterventionStartedAt = activeInterventionStartedAt
    }

    public mutating func recordBaseline(snapshot: SessionMetricSnapshot) {
        guard let status = snapshot.memoryManagement else { return }
        baselineState = status.pressureState
        latestState = status.pressureState
        maximumState = status.pressureState
        baselineCompressedBytes = status.telemetry?.counters?.compressedBytes
        peakCompressedBytes = status.telemetry?.counters?.compressedBytes
        baselineSwapUsedBytes = status.telemetry?.counters?.swapUsedBytes
        latestSwapUsedBytes = status.telemetry?.counters?.swapUsedBytes
        peakSwapUsedBytes = status.telemetry?.counters?.swapUsedBytes
        lastCapturedAt = snapshot.capturedAt
        lastState = status.pressureState
        lastInterventionActive = status.interventionActive
        if status.interventionActive {
            interventionEpisodes = 1
            activeInterventionStartedAt = snapshot.capturedAt
            restorationResult = .restoreRequested
        }
        mergeFamilyNames(status.managedFamilyNames)
        recordPeaks(status)
    }

    public mutating func recordSample(snapshot: SessionMetricSnapshot) {
        record(snapshot: snapshot, isPostRestore: false)
    }

    public mutating func recordFinalPreRestore(snapshot: SessionMetricSnapshot) {
        record(snapshot: snapshot, isPostRestore: false)
    }

    public mutating func recordPostRestore(snapshot: SessionMetricSnapshot) {
        record(snapshot: snapshot, isPostRestore: true)
    }

    private mutating func record(snapshot: SessionMetricSnapshot, isPostRestore: Bool) {
        guard let status = snapshot.memoryManagement else {
            if isPostRestore, interventionEpisodes > 0 {
                restorationResult = .unavailable
            }
            return
        }

        addElapsedTime(until: snapshot.capturedAt)
        latestState = status.pressureState
        maximumState = max(maximumState ?? status.pressureState, status.pressureState)
        latestSwapUsedBytes = status.telemetry?.counters?.swapUsedBytes
        if isPostRestore {
            postRestoreSwapUsedBytes = status.telemetry?.counters?.swapUsedBytes
        }
        mergeFamilyNames(status.managedFamilyNames)
        recordPeaks(status)
        updateIntervention(status: status, at: snapshot.capturedAt)
        lastCapturedAt = snapshot.capturedAt
        lastState = status.pressureState

        if isPostRestore {
            if interventionEpisodes == 0 {
                restorationResult = .notRequired
            } else if status.interventionActive || status.managedFamilyCount > 0 {
                restorationResult = .incomplete
            } else if status.note?.localizedCaseInsensitiveContains("restored") == true {
                restorationResult = .restored
            } else {
                restorationResult = .restoreRequested
            }
        }
    }

    private mutating func addElapsedTime(until date: Date) {
        guard let previousDate = lastCapturedAt,
              let previousState = lastState else { return }
        let elapsed = date.timeIntervalSince(previousDate)
        guard elapsed.isFinite, elapsed > 0, elapsed <= 300 else { return }
        switch previousState {
        case .healthy: healthySeconds += elapsed
        case .elevated: elevatedSeconds += elapsed
        case .high: highSeconds += elapsed
        case .critical: criticalSeconds += elapsed
        }
        if lastInterventionActive, let started = activeInterventionStartedAt {
            let duration = date.timeIntervalSince(started)
            if duration.isFinite, duration >= 0 {
                longestInterventionDuration = max(longestInterventionDuration, duration)
            }
        }
    }

    private mutating func updateIntervention(status: MemoryManagementStatusSnapshot, at date: Date) {
        if status.interventionActive && !lastInterventionActive {
            interventionEpisodes += 1
            activeInterventionStartedAt = date
            restorationResult = .restoreRequested
        } else if !status.interventionActive && lastInterventionActive {
            if let started = activeInterventionStartedAt {
                let duration = date.timeIntervalSince(started)
                if duration.isFinite, duration >= 0 {
                    longestInterventionDuration = max(longestInterventionDuration, duration)
                }
            }
            activeInterventionStartedAt = nil
        }
        lastInterventionActive = status.interventionActive
    }

    private mutating func recordPeaks(_ status: MemoryManagementStatusSnapshot) {
        if let compressed = status.telemetry?.counters?.compressedBytes {
            peakCompressedBytes = max(peakCompressedBytes ?? compressed, compressed)
        }
        if let swap = status.telemetry?.counters?.swapUsedBytes {
            peakSwapUsedBytes = max(peakSwapUsedBytes ?? swap, swap)
        }
        peakCompressionGrowthBytesPerSecond = maximumFinite(
            peakCompressionGrowthBytesPerSecond,
            status.telemetry?.rates.compressionBytesPerSecond
        )
        peakSwapInBytesPerSecond = maximumFinite(
            peakSwapInBytesPerSecond,
            status.telemetry?.rates.swapInBytesPerSecond
        )
        peakSwapOutBytesPerSecond = maximumFinite(
            peakSwapOutBytesPerSecond,
            status.telemetry?.rates.swapOutBytesPerSecond
        )
    }

    private func maximumFinite(_ current: Double?, _ candidate: Double?) -> Double? {
        guard let candidate = candidate, candidate.isFinite, candidate >= 0 else { return current }
        guard let current = current else { return candidate }
        return max(current, candidate)
    }

    private mutating func mergeFamilyNames(_ names: [String]) {
        var existing = Set(managedFamilyNames)
        for name in names where !name.isEmpty {
            existing.insert(name)
        }
        managedFamilyNames = existing.sorted()
    }
}
