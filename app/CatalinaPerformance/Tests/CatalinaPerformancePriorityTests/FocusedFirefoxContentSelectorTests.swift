import XCTest
@testable import CatalinaPerformancePriorityCore

final class FocusedFirefoxContentSelectorTests: XCTestCase {
    private let selector = FocusedFirefoxContentSelector()

    private func content(pid: Int32, start: Int64? = nil) -> AppPriorityProcessIdentity {
        return AppPriorityProcessIdentity(
            pid: pid,
            parentPID: 612,
            effectiveUID: 501,
            executablePath: "/Applications/Firefox.app/Contents/MacOS/plugin-container.app/Contents/MacOS/plugin-container",
            startSeconds: start ?? Int64(pid),
            startMicroseconds: 0,
            processName: "plugin-container",
            niceValue: 0
        )
    }

    func testFirstSampleOnlyEstablishesCounters() {
        let result = selector.evaluate(
            processes: [content(pid: 844)],
            cumulativeCPUByPID: [844: 1_000],
            state: .empty
        )
        XCTAssertEqual(result.decision, .keepCurrent)
        XCTAssertNil(result.state.currentTarget)
    }

    func testZeroDeltaPreallocatedProcessNeverWins() {
        var state = selector.evaluate(
            processes: [content(pid: 844), content(pid: 20025)],
            cumulativeCPUByPID: [844: 1_000, 20025: 500],
            state: .empty
        ).state
        state = selector.evaluate(
            processes: [content(pid: 844), content(pid: 20025)],
            cumulativeCPUByPID: [844: 2_000, 20025: 500],
            state: state
        ).state
        let result = selector.evaluate(
            processes: [content(pid: 844), content(pid: 20025)],
            cumulativeCPUByPID: [844: 3_000, 20025: 500],
            state: state
        )
        XCTAssertEqual(result.decision, .select(pid: 844))
        XCTAssertEqual(result.state.currentTarget?.pid, 844)
    }

    func testOneCycleSpikeDoesNotSwitchExistingTarget() {
        var state = establishTarget(pid: 844)
        state = selector.evaluate(
            processes: [content(pid: 844), content(pid: 900)],
            cumulativeCPUByPID: [844: 4_000, 900: 1_000],
            state: state
        ).state
        let firstSpike = selector.evaluate(
            processes: [content(pid: 844), content(pid: 900)],
            cumulativeCPUByPID: [844: 4_100, 900: 3_000],
            state: state
        )
        state = firstSpike.state

        XCTAssertEqual(firstSpike.decision, .keepCurrent)
        XCTAssertEqual(state.currentTarget?.pid, 844)
        XCTAssertEqual(state.candidateIdentity?.pid, 900)
        XCTAssertEqual(state.candidateWinCount, 1)
    }

    func testStableReplacementRequiresTwoWins() {
        var state = establishTarget(pid: 844)
        state = selector.evaluate(
            processes: [content(pid: 844), content(pid: 900)],
            cumulativeCPUByPID: [844: 4_000, 900: 1_000],
            state: state
        ).state
        state = selector.evaluate(
            processes: [content(pid: 844), content(pid: 900)],
            cumulativeCPUByPID: [844: 4_100, 900: 3_000],
            state: state
        ).state
        let result = selector.evaluate(
            processes: [content(pid: 844), content(pid: 900)],
            cumulativeCPUByPID: [844: 4_200, 900: 5_000],
            state: state
        )

        XCTAssertEqual(result.decision, .switchTarget(from: 844, to: 900))
        XCTAssertEqual(result.state.currentTarget?.pid, 900)
    }

    func testCounterRollbackOnlyReestablishesBaseline() {
        var state = selector.evaluate(
            processes: [content(pid: 844)],
            cumulativeCPUByPID: [844: 5_000],
            state: .empty
        ).state
        let result = selector.evaluate(
            processes: [content(pid: 844)],
            cumulativeCPUByPID: [844: 100],
            state: state
        )
        state = result.state

        XCTAssertEqual(result.decision, .keepCurrent)
        XCTAssertNil(state.candidateIdentity)
        XCTAssertEqual(state.priorCounters.first?.cumulativeNanoseconds, 100)
    }

    func testMissingSampleCannotBecomeLeader() {
        var state = selector.evaluate(
            processes: [content(pid: 844), content(pid: 900)],
            cumulativeCPUByPID: [844: 1_000, 900: 1_000],
            state: .empty
        ).state
        let result = selector.evaluate(
            processes: [content(pid: 844), content(pid: 900)],
            cumulativeCPUByPID: [844: 2_000],
            state: state
        )
        state = result.state

        XCTAssertEqual(state.candidateIdentity?.pid, 844)
        XCTAssertFalse(state.priorCounters.contains { $0.identity.pid == 900 })
    }

    func testExactTieUsesAscendingPID() {
        let state = selector.evaluate(
            processes: [content(pid: 900), content(pid: 844)],
            cumulativeCPUByPID: [844: 1_000, 900: 1_000],
            state: .empty
        ).state
        let result = selector.evaluate(
            processes: [content(pid: 900), content(pid: 844)],
            cumulativeCPUByPID: [844: 2_000, 900: 2_000],
            state: state
        )

        XCTAssertEqual(result.state.candidateIdentity?.pid, 844)
    }

    func testExitedCurrentTargetIsClearedBeforeReplacementSelection() {
        let state = establishTarget(pid: 844)
        let result = selector.evaluate(
            processes: [content(pid: 900)],
            cumulativeCPUByPID: [900: 4_000],
            state: state
        )

        XCTAssertEqual(result.decision, .clearExitedTarget(pid: 844))
        XCTAssertNil(result.state.currentTarget)
    }

    func testPidReuseDoesNotUseOldCounterOrKeepTargetIdentity() {
        let original = content(pid: 844, start: 100)
        let reused = content(pid: 844, start: 200)
        let state = FocusedFirefoxContentSelectionState(
            priorCounters: [FocusedFirefoxCPUCounter(identity: original, cumulativeNanoseconds: 1_000)],
            currentTarget: original,
            candidateIdentity: nil,
            candidateWinCount: 0
        )
        let result = selector.evaluate(
            processes: [reused],
            cumulativeCPUByPID: [844: 2_000],
            state: state
        )

        XCTAssertEqual(result.decision, .clearExitedTarget(pid: 844))
        XCTAssertNil(result.state.currentTarget)
        XCTAssertNil(result.state.candidateIdentity)
    }

    func testCurrentTargetRemainsWhenNoReplacementReachesStability() {
        var state = establishTarget(pid: 844)
        state = selector.evaluate(
            processes: [content(pid: 844), content(pid: 900)],
            cumulativeCPUByPID: [844: 4_100, 900: 4_000],
            state: state
        ).state
        let result = selector.evaluate(
            processes: [content(pid: 844), content(pid: 900)],
            cumulativeCPUByPID: [844: 6_100, 900: 4_100],
            state: state
        )

        XCTAssertEqual(result.decision, .keepCurrent)
        XCTAssertEqual(result.state.currentTarget?.pid, 844)
    }

    private func establishTarget(pid: Int32) -> FocusedFirefoxContentSelectionState {
        let target = content(pid: pid)
        var state = selector.evaluate(
            processes: [target],
            cumulativeCPUByPID: [pid: 1_000],
            state: .empty
        ).state
        state = selector.evaluate(
            processes: [target],
            cumulativeCPUByPID: [pid: 2_000],
            state: state
        ).state
        let selected = selector.evaluate(
            processes: [target],
            cumulativeCPUByPID: [pid: 3_000],
            state: state
        )
        XCTAssertEqual(selected.decision, .select(pid: pid))
        return selected.state
    }
}
