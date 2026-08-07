import Foundation

public enum WindowServerPressureLevel: String, Codable, Equatable {
    case normal
    case elevated
    case high
    case unavailable
}

public struct WindowServerProcessKey: Codable, Equatable, Hashable {
    public let pid: Int32
    public let effectiveUID: UInt32
    public let executablePath: String
    public let startSeconds: Int64
    public let startMicroseconds: Int32

    public init(
        pid: Int32,
        effectiveUID: UInt32,
        executablePath: String,
        startSeconds: Int64,
        startMicroseconds: Int32
    ) {
        self.pid = pid
        self.effectiveUID = effectiveUID
        self.executablePath = executablePath
        self.startSeconds = startSeconds
        self.startMicroseconds = startMicroseconds
    }
}

public struct WindowServerCPUReading: Codable, Equatable {
    public let capturedAt: Date
    public let processKey: WindowServerProcessKey?
    public let cumulativeCPUTimeNanoseconds: UInt64?
    public let cpuPercent: Double?
    public let availability: MetricAvailability
    public let note: String?

    public init(
        capturedAt: Date,
        processKey: WindowServerProcessKey?,
        cumulativeCPUTimeNanoseconds: UInt64?,
        cpuPercent: Double?,
        availability: MetricAvailability,
        note: String?
    ) {
        self.capturedAt = capturedAt
        self.processKey = processKey
        self.cumulativeCPUTimeNanoseconds = cumulativeCPUTimeNanoseconds
        self.cpuPercent = cpuPercent
        self.availability = availability
        self.note = note.map { String($0.prefix(256)) }
    }

    public static func available(
        processKey: WindowServerProcessKey,
        cumulativeCPUTimeNanoseconds: UInt64,
        cpuPercent: Double,
        at date: Date
    ) -> WindowServerCPUReading {
        WindowServerCPUReading(
            capturedAt: date,
            processKey: processKey,
            cumulativeCPUTimeNanoseconds: cumulativeCPUTimeNanoseconds,
            cpuPercent: cpuPercent,
            availability: .available,
            note: nil
        )
    }

    public static func unavailable(
        processKey: WindowServerProcessKey?,
        cumulativeCPUTimeNanoseconds: UInt64? = nil,
        at date: Date,
        note: String?
    ) -> WindowServerCPUReading {
        WindowServerCPUReading(
            capturedAt: date,
            processKey: processKey,
            cumulativeCPUTimeNanoseconds: cumulativeCPUTimeNanoseconds,
            cpuPercent: nil,
            availability: .unavailable,
            note: note
        )
    }

    public var validCPUPercent: Double? {
        guard availability == .available,
              let cpuPercent = cpuPercent,
              cpuPercent.isFinite,
              cpuPercent >= 0 else {
            return nil
        }
        return cpuPercent
    }
}

public struct WindowServerBaselineSummary: Codable, Equatable {
    public let averageCPU: Double?
    public let peakCPU: Double?
    public let validSampleCount: Int

    public init(averageCPU: Double?, peakCPU: Double?, validSampleCount: Int) {
        self.averageCPU = averageCPU
        self.peakCPU = peakCPU
        self.validSampleCount = validSampleCount
    }

    public init(samples: [WindowServerCPUReading]) {
        let values = samples.compactMap { $0.validCPUPercent }
        if values.isEmpty {
            self.averageCPU = nil
            self.peakCPU = nil
            self.validSampleCount = 0
        } else {
            self.averageCPU = values.reduce(0, +) / Double(values.count)
            self.peakCPU = values.max()
            self.validSampleCount = values.count
        }
    }

    public var isElevated: Bool {
        guard let averageCPU = averageCPU else { return false }
        return averageCPU >= WindowServerPressureClassifier.elevatedAbsoluteThreshold
    }
}

public struct WindowServerPressureClassifier {
    public static let elevatedAbsoluteThreshold = 15.0
    public static let highAbsoluteThreshold = 30.0
    public static let elevatedDeltaThreshold = 8.0
    public static let highDeltaMinimumCPU = 20.0
    public static let highDeltaThreshold = 12.0
    public static let requiredHighCandidateCount = 2

    public static func isHighCandidate(
        rollingCPU: Double,
        baselineCPU: Double?
    ) -> Bool {
        guard rollingCPU.isFinite, rollingCPU >= 0 else { return false }
        if rollingCPU >= highAbsoluteThreshold {
            return true
        }
        guard let baselineCPU = baselineCPU,
              baselineCPU.isFinite,
              baselineCPU >= 0 else {
            return false
        }
        return rollingCPU >= highDeltaMinimumCPU &&
            rollingCPU - baselineCPU >= highDeltaThreshold
    }

    public static func classify(
        rollingCPU: Double?,
        baselineCPU: Double?,
        consecutiveHighCandidates: Int
    ) -> WindowServerPressureLevel {
        guard let rollingCPU = rollingCPU,
              rollingCPU.isFinite,
              rollingCPU >= 0 else {
            return .unavailable
        }

        if isHighCandidate(rollingCPU: rollingCPU, baselineCPU: baselineCPU),
           consecutiveHighCandidates >= requiredHighCandidateCount {
            return .high
        }

        if rollingCPU >= elevatedAbsoluteThreshold {
            return .elevated
        }

        if let baselineCPU = baselineCPU,
           baselineCPU.isFinite,
           baselineCPU >= 0,
           rollingCPU - baselineCPU >= elevatedDeltaThreshold {
            return .elevated
        }

        return .normal
    }
}

public struct WindowServerSessionAggregate: Codable, Equatable {
    public var baselineSamples: [WindowServerCPUReading]
    public var baseline: WindowServerBaselineSummary?
    public var latestActiveCPU: Double?
    public var activeRunningSum: Double
    public var validActiveSampleCount: Int
    public var activePeakCPU: Double?
    public var rollingCPUValues: [Double]
    public var rollingAverageCPU: Double?
    public var currentPressure: WindowServerPressureLevel
    public var maximumSustainedPressure: WindowServerPressureLevel
    public var consecutiveHighCandidates: Int
    public var normalSeconds: TimeInterval
    public var elevatedSeconds: TimeInterval
    public var highSeconds: TimeInterval
    public var lastClassifiedAt: Date?
    public var finalPreRestoreCPU: Double?
    public var postRestoreCPU: Double?
    public var visualPerformanceActive: Bool?
    public var visualPerformanceRestorationSucceeded: Bool?

    public init(
        baselineSamples: [WindowServerCPUReading] = [],
        baseline: WindowServerBaselineSummary? = nil,
        latestActiveCPU: Double? = nil,
        activeRunningSum: Double = 0,
        validActiveSampleCount: Int = 0,
        activePeakCPU: Double? = nil,
        rollingCPUValues: [Double] = [],
        rollingAverageCPU: Double? = nil,
        currentPressure: WindowServerPressureLevel = .unavailable,
        maximumSustainedPressure: WindowServerPressureLevel = .unavailable,
        consecutiveHighCandidates: Int = 0,
        normalSeconds: TimeInterval = 0,
        elevatedSeconds: TimeInterval = 0,
        highSeconds: TimeInterval = 0,
        lastClassifiedAt: Date? = nil,
        finalPreRestoreCPU: Double? = nil,
        postRestoreCPU: Double? = nil,
        visualPerformanceActive: Bool? = nil,
        visualPerformanceRestorationSucceeded: Bool? = nil
    ) {
        self.baselineSamples = baselineSamples
        self.baseline = baseline
        self.latestActiveCPU = latestActiveCPU
        self.activeRunningSum = activeRunningSum
        self.validActiveSampleCount = validActiveSampleCount
        self.activePeakCPU = activePeakCPU
        self.rollingCPUValues = Array(rollingCPUValues.suffix(3))
        self.rollingAverageCPU = rollingAverageCPU
        self.currentPressure = currentPressure
        self.maximumSustainedPressure = maximumSustainedPressure
        self.consecutiveHighCandidates = consecutiveHighCandidates
        self.normalSeconds = normalSeconds
        self.elevatedSeconds = elevatedSeconds
        self.highSeconds = highSeconds
        self.lastClassifiedAt = lastClassifiedAt
        self.finalPreRestoreCPU = finalPreRestoreCPU
        self.postRestoreCPU = postRestoreCPU
        self.visualPerformanceActive = visualPerformanceActive
        self.visualPerformanceRestorationSucceeded = visualPerformanceRestorationSucceeded
    }

    public var activeAverageCPU: Double? {
        guard validActiveSampleCount > 0 else { return nil }
        return activeRunningSum / Double(validActiveSampleCount)
    }

    public var changeFromBaselinePercentagePoints: Double? {
        guard let activeAverageCPU = activeAverageCPU,
              let baselineCPU = baseline?.averageCPU else {
            return nil
        }
        return activeAverageCPU - baselineCPU
    }

    public mutating func beginBaseline() {
        baselineSamples = []
        baseline = nil
    }

    public mutating func recordBaseline(_ reading: WindowServerCPUReading) {
        guard baselineSamples.count < 3 else { return }
        baselineSamples.append(reading)
    }

    public mutating func finalizeBaseline() {
        baseline = WindowServerBaselineSummary(samples: baselineSamples)
    }

    public mutating func recordActive(_ reading: WindowServerCPUReading, at date: Date) {
        guard let value = reading.validCPUPercent else {
            currentPressure = .unavailable
            consecutiveHighCandidates = 0
            lastClassifiedAt = nil
            return
        }

        latestActiveCPU = value
        activeRunningSum += value
        validActiveSampleCount += 1
        activePeakCPU = max(activePeakCPU ?? value, value)

        rollingCPUValues.append(value)
        if rollingCPUValues.count > 3 {
            rollingCPUValues.removeFirst(rollingCPUValues.count - 3)
        }
        rollingAverageCPU = rollingCPUValues.reduce(0, +) / Double(rollingCPUValues.count)

        let baselineCPU = baseline?.averageCPU
        let highCandidate = WindowServerPressureClassifier.isHighCandidate(
            rollingCPU: rollingAverageCPU ?? value,
            baselineCPU: baselineCPU
        )
        if highCandidate {
            consecutiveHighCandidates += 1
        } else {
            consecutiveHighCandidates = 0
        }

        let nextPressure = WindowServerPressureClassifier.classify(
            rollingCPU: rollingAverageCPU,
            baselineCPU: baselineCPU,
            consecutiveHighCandidates: consecutiveHighCandidates
        )

        if let previousDate = lastClassifiedAt {
            let elapsed = date.timeIntervalSince(previousDate)
            if elapsed > 0 && elapsed.isFinite {
                addDuration(elapsed, to: nextPressure)
            }
        }
        lastClassifiedAt = date
        currentPressure = nextPressure
        if rank(nextPressure) > rank(maximumSustainedPressure) {
            maximumSustainedPressure = nextPressure
        }
    }

    public mutating func recordFinalPreRestore(_ reading: WindowServerCPUReading?) {
        finalPreRestoreCPU = reading?.validCPUPercent
    }

    public mutating func recordPostRestore(_ reading: WindowServerCPUReading?) {
        postRestoreCPU = reading?.validCPUPercent
    }

    private mutating func addDuration(_ seconds: TimeInterval, to level: WindowServerPressureLevel) {
        switch level {
        case .normal:
            normalSeconds += seconds
        case .elevated:
            elevatedSeconds += seconds
        case .high:
            highSeconds += seconds
        case .unavailable:
            break
        }
    }

    private func rank(_ level: WindowServerPressureLevel) -> Int {
        switch level {
        case .unavailable: return -1
        case .normal: return 0
        case .elevated: return 1
        case .high: return 2
        }
    }
}
