import Foundation

public struct MemoryPressureEvidence: OptionSet, Codable, Equatable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let lowAvailable = MemoryPressureEvidence(rawValue: 1 << 0)
    public static let strongLowAvailable = MemoryPressureEvidence(rawValue: 1 << 1)
    public static let severeAvailable = MemoryPressureEvidence(rawValue: 1 << 2)
    public static let compressionHigh = MemoryPressureEvidence(rawValue: 1 << 3)
    public static let compressionSevere = MemoryPressureEvidence(rawValue: 1 << 4)
    public static let compressionGrowing = MemoryPressureEvidence(rawValue: 1 << 5)
    public static let swapGrowing = MemoryPressureEvidence(rawValue: 1 << 6)
    public static let swapOutActive = MemoryPressureEvidence(rawValue: 1 << 7)
    public static let swapChurn = MemoryPressureEvidence(rawValue: 1 << 8)
    public static let pageOutActive = MemoryPressureEvidence(rawValue: 1 << 9)
}

public struct MemoryPressureEvaluation: Equatable {
    public let candidateState: MemoryPressureState
    public let confirmedState: MemoryPressureState
    public let evidence: MemoryPressureEvidence
    public let healthyRecoveryCount: Int
    public let shouldIntervene: Bool
    public let shouldRestore: Bool

    public init(
        candidateState: MemoryPressureState,
        confirmedState: MemoryPressureState,
        evidence: MemoryPressureEvidence,
        healthyRecoveryCount: Int,
        shouldIntervene: Bool,
        shouldRestore: Bool
    ) {
        self.candidateState = candidateState
        self.confirmedState = confirmedState
        self.evidence = evidence
        self.healthyRecoveryCount = healthyRecoveryCount
        self.shouldIntervene = shouldIntervene
        self.shouldRestore = shouldRestore
    }
}

public struct MemoryPressureClassifier {
    private let thresholds: MemoryPressureThresholds
    private var confirmedStateValue: MemoryPressureState = .healthy
    private var consecutiveElevated = 0
    private var consecutiveHigh = 0
    private var consecutiveCritical = 0
    private var healthyRecoveryCountValue = 0

    public init(thresholds: MemoryPressureThresholds = .catalina10157) {
        self.thresholds = thresholds
    }

    public mutating func evaluate(
        snapshot: MemoryTelemetrySnapshot,
        interventionActive: Bool
    ) -> MemoryPressureEvaluation {
        let evidence = makeEvidence(snapshot: snapshot)
        let candidate = candidateState(snapshot: snapshot, evidence: evidence)

        updateConfirmation(candidate: candidate)
        updateRecovery(candidate: candidate, interventionActive: interventionActive)

        let shouldIntervene = confirmedStateValue == .high || confirmedStateValue == .critical
        let shouldRestore = interventionActive && healthyRecoveryCountValue >= 5

        return MemoryPressureEvaluation(
            candidateState: candidate,
            confirmedState: confirmedStateValue,
            evidence: evidence,
            healthyRecoveryCount: healthyRecoveryCountValue,
            shouldIntervene: shouldIntervene,
            shouldRestore: shouldRestore
        )
    }

    private func makeEvidence(snapshot: MemoryTelemetrySnapshot) -> MemoryPressureEvidence {
        guard let counters = snapshot.counters, counters.physicalBytes > 0 else {
            return []
        }

        var result: MemoryPressureEvidence = []
        let physical = Double(counters.physicalBytes)
        let availableFraction = Double(counters.availableBytes) / physical

        if availableFraction < thresholds.availableModerateFraction {
            result.insert(.lowAvailable)
        }
        if availableFraction < thresholds.availableStrongFraction {
            result.insert(.strongLowAvailable)
        }
        if availableFraction < thresholds.availableSevereFraction {
            result.insert(.severeAvailable)
        }

        if let compressedBytes = counters.compressedBytes {
            let compressedFraction = Double(compressedBytes) / physical
            if compressedFraction >= thresholds.compressedModerateFraction {
                result.insert(.compressionHigh)
            }
            if compressedFraction >= thresholds.compressedStrongFraction {
                result.insert(.compressionSevere)
            }
        }

        if let rate = snapshot.rates.compressionBytesPerSecond,
           rate > thresholds.compressionActivityBytesPerSecond {
            result.insert(.compressionGrowing)
        }

        if let threshold = thresholds.swapGrowthBytesPerSecond,
           let rate = snapshot.rates.swapGrowthBytesPerSecond,
           rate > threshold {
            result.insert(.swapGrowing)
        }

        if let rate = snapshot.rates.swapOutBytesPerSecond,
           rate > thresholds.swapOutActivityBytesPerSecond {
            result.insert(.swapOutActive)
        }

        if let rate = snapshot.rates.pageOutsPerSecond,
           rate > thresholds.pageOutActivityPagesPerSecond {
            result.insert(.pageOutActive)
        }

        if let threshold = thresholds.swapChurnBytesPerSecond,
           let swapIn = snapshot.rates.swapInBytesPerSecond,
           let swapOut = snapshot.rates.swapOutBytesPerSecond,
           swapIn > threshold,
           swapOut > threshold {
            result.insert(.swapChurn)
        }

        return result
    }

    private func candidateState(
        snapshot: MemoryTelemetrySnapshot,
        evidence: MemoryPressureEvidence
    ) -> MemoryPressureState {
        guard snapshot.counters != nil else { return .healthy }

        let activeVMWork = evidence.contains(.compressionGrowing) ||
            evidence.contains(.swapGrowing) ||
            evidence.contains(.swapOutActive) ||
            evidence.contains(.swapChurn) ||
            evidence.contains(.pageOutActive)

        if evidence.contains(.severeAvailable) &&
            evidence.contains(.compressionSevere) &&
            (evidence.contains(.swapOutActive) || evidence.contains(.swapChurn) || evidence.contains(.pageOutActive)) {
            return .critical
        }

        if evidence.contains(.strongLowAvailable) &&
            (evidence.contains(.compressionHigh) || activeVMWork) {
            return .high
        }

        if evidence.contains(.compressionSevere) &&
            (evidence.contains(.swapOutActive) || evidence.contains(.pageOutActive) || evidence.contains(.compressionGrowing)) {
            return .high
        }

        if evidence.contains(.severeAvailable) && evidence.contains(.compressionHigh) {
            return .high
        }

        if evidence.contains(.lowAvailable) || evidence.contains(.compressionHigh) {
            return .elevated
        }

        return .healthy
    }

    private mutating func updateConfirmation(candidate: MemoryPressureState) {
        switch candidate {
        case .healthy:
            consecutiveElevated = 0
            consecutiveHigh = 0
            consecutiveCritical = 0
            confirmedStateValue = .healthy

        case .elevated:
            consecutiveElevated += 1
            consecutiveHigh = 0
            consecutiveCritical = 0
            if consecutiveElevated >= 3 {
                confirmedStateValue = .elevated
            }

        case .high:
            consecutiveHigh += 1
            consecutiveElevated = 0
            consecutiveCritical = 0
            if consecutiveHigh >= 3 {
                confirmedStateValue = .high
            }

        case .critical:
            consecutiveCritical += 1
            consecutiveElevated = 0
            consecutiveHigh = 0
            if consecutiveCritical >= 2 {
                confirmedStateValue = .critical
            }
        }
    }

    private mutating func updateRecovery(
        candidate: MemoryPressureState,
        interventionActive: Bool
    ) {
        guard interventionActive else {
            healthyRecoveryCountValue = 0
            return
        }

        if candidate == .healthy {
            healthyRecoveryCountValue += 1
        } else {
            healthyRecoveryCountValue = 0
        }
    }
}
