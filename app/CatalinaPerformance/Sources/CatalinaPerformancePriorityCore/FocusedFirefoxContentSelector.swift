import Foundation

public struct FocusedFirefoxCPUCounter: Codable, Equatable {
    public let identity: AppPriorityProcessIdentity
    public let cumulativeNanoseconds: UInt64

    public init(identity: AppPriorityProcessIdentity, cumulativeNanoseconds: UInt64) {
        self.identity = identity
        self.cumulativeNanoseconds = cumulativeNanoseconds
    }
}

public struct FocusedFirefoxContentSelectionState: Codable, Equatable {
    public let priorCounters: [FocusedFirefoxCPUCounter]
    public let currentTarget: AppPriorityProcessIdentity?
    public let candidateIdentity: AppPriorityProcessIdentity?
    public let candidateWinCount: Int

    public init(
        priorCounters: [FocusedFirefoxCPUCounter],
        currentTarget: AppPriorityProcessIdentity?,
        candidateIdentity: AppPriorityProcessIdentity?,
        candidateWinCount: Int
    ) {
        self.priorCounters = priorCounters
        self.currentTarget = currentTarget
        self.candidateIdentity = candidateIdentity
        self.candidateWinCount = candidateWinCount
    }

    public static let empty = FocusedFirefoxContentSelectionState(
        priorCounters: [],
        currentTarget: nil,
        candidateIdentity: nil,
        candidateWinCount: 0
    )
}

public enum FocusedFirefoxContentDecision: Equatable {
    case keepCurrent
    case select(pid: Int32)
    case switchTarget(from: Int32, to: Int32)
    case clearExitedTarget(pid: Int32)
}

public struct FocusedFirefoxContentEvaluation: Equatable {
    public let decision: FocusedFirefoxContentDecision
    public let state: FocusedFirefoxContentSelectionState

    public init(decision: FocusedFirefoxContentDecision, state: FocusedFirefoxContentSelectionState) {
        self.decision = decision
        self.state = state
    }
}

public struct FocusedFirefoxContentSelector {
    public init() {}

    public func evaluate(
        processes: [AppPriorityProcessIdentity],
        cumulativeCPUByPID: [Int32: UInt64],
        state: FocusedFirefoxContentSelectionState
    ) -> FocusedFirefoxContentEvaluation {
        let currentByPID = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) })
        let priorByPID = Dictionary(uniqueKeysWithValues: state.priorCounters.map { ($0.identity.pid, $0) })

        var nextCounters: [FocusedFirefoxCPUCounter] = []
        var positiveDeltas: [(identity: AppPriorityProcessIdentity, delta: UInt64)] = []
        for process in processes.sorted(by: { $0.pid < $1.pid }) {
            guard let cumulative = cumulativeCPUByPID[process.pid] else { continue }
            nextCounters.append(FocusedFirefoxCPUCounter(identity: process, cumulativeNanoseconds: cumulative))
            guard let prior = priorByPID[process.pid],
                  prior.identity.matchesForMutation(process),
                  cumulative > prior.cumulativeNanoseconds else {
                continue
            }
            positiveDeltas.append((process, cumulative - prior.cumulativeNanoseconds))
        }

        positiveDeltas.sort {
            if $0.delta == $1.delta { return $0.identity.pid < $1.identity.pid }
            return $0.delta > $1.delta
        }
        let leader = positiveDeltas.first?.identity

        var currentTarget = state.currentTarget
        var exitDecision: FocusedFirefoxContentDecision?
        if let current = currentTarget {
            guard let currentIdentity = currentByPID[current.pid], current.matchesForMutation(currentIdentity) else {
                currentTarget = nil
                exitDecision = .clearExitedTarget(pid: current.pid)
                return FocusedFirefoxContentEvaluation(
                    decision: exitDecision!,
                    state: FocusedFirefoxContentSelectionState(
                        priorCounters: nextCounters,
                        currentTarget: nil,
                        candidateIdentity: nil,
                        candidateWinCount: 0
                    )
                )
            }
        }

        guard let leaderIdentity = leader else {
            return FocusedFirefoxContentEvaluation(
                decision: .keepCurrent,
                state: FocusedFirefoxContentSelectionState(
                    priorCounters: nextCounters,
                    currentTarget: currentTarget,
                    candidateIdentity: nil,
                    candidateWinCount: 0
                )
            )
        }

        if let current = currentTarget, current.matchesForMutation(leaderIdentity) {
            return FocusedFirefoxContentEvaluation(
                decision: .keepCurrent,
                state: FocusedFirefoxContentSelectionState(
                    priorCounters: nextCounters,
                    currentTarget: current,
                    candidateIdentity: nil,
                    candidateWinCount: 0
                )
            )
        }

        let candidateWins: Int
        if let candidate = state.candidateIdentity, candidate.matchesForMutation(leaderIdentity) {
            candidateWins = state.candidateWinCount + 1
        } else {
            candidateWins = 1
        }

        guard candidateWins >= 2 else {
            return FocusedFirefoxContentEvaluation(
                decision: .keepCurrent,
                state: FocusedFirefoxContentSelectionState(
                    priorCounters: nextCounters,
                    currentTarget: currentTarget,
                    candidateIdentity: leaderIdentity,
                    candidateWinCount: candidateWins
                )
            )
        }

        let decision: FocusedFirefoxContentDecision
        if let current = currentTarget {
            decision = .switchTarget(from: current.pid, to: leaderIdentity.pid)
        } else {
            decision = .select(pid: leaderIdentity.pid)
        }
        return FocusedFirefoxContentEvaluation(
            decision: decision,
            state: FocusedFirefoxContentSelectionState(
                priorCounters: nextCounters,
                currentTarget: leaderIdentity,
                candidateIdentity: nil,
                candidateWinCount: 0
            )
        )
    }
}
