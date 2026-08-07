import XCTest
@testable import CatalinaPerformanceDashboardCore

final class WindowServerPressureModelsTests: XCTestCase {
    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    private func key(_ pid: Int32 = 100) -> WindowServerProcessKey {
        WindowServerProcessKey(
            pid: pid,
            effectiveUID: 88,
            executablePath: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer",
            startSeconds: 1,
            startMicroseconds: 0
        )
    }

    private func reading(_ cpu: Double?, _ seconds: TimeInterval) -> WindowServerCPUReading {
        if let cpu = cpu {
            return .available(
                processKey: key(),
                cumulativeCPUTimeNanoseconds: UInt64(cpu * 1_000_000),
                cpuPercent: cpu,
                at: date(seconds)
            )
        }
        return .unavailable(
            processKey: key(),
            at: date(seconds),
            note: "unavailable"
        )
    }

    func testNormalRequiresBothAbsoluteAndRelativeConditions() {
        XCTAssertEqual(
            WindowServerPressureClassifier.classify(
                rollingCPU: 14.9,
                baselineCPU: 7.0,
                consecutiveHighCandidates: 0
            ),
            .normal
        )
        XCTAssertEqual(
            WindowServerPressureClassifier.classify(
                rollingCPU: 14.9,
                baselineCPU: 6.8,
                consecutiveHighCandidates: 0
            ),
            .elevated
        )
    }

    func testElevatedAtFifteenPercent() {
        XCTAssertEqual(
            WindowServerPressureClassifier.classify(
                rollingCPU: 15.0,
                baselineCPU: 10.0,
                consecutiveHighCandidates: 0
            ),
            .elevated
        )
    }

    func testThirtyPercentIsHighCandidateButNeedsConfirmation() {
        XCTAssertEqual(
            WindowServerPressureClassifier.classify(
                rollingCPU: 30.0,
                baselineCPU: 10.0,
                consecutiveHighCandidates: 1
            ),
            .elevated
        )
        XCTAssertEqual(
            WindowServerPressureClassifier.classify(
                rollingCPU: 30.0,
                baselineCPU: 10.0,
                consecutiveHighCandidates: 2
            ),
            .high
        )
    }

    func testRelativeHighCandidateRequiresTwentyPercentAndTwelvePointIncrease() {
        XCTAssertEqual(
            WindowServerPressureClassifier.classify(
                rollingCPU: 20.0,
                baselineCPU: 8.0,
                consecutiveHighCandidates: 2
            ),
            .high
        )
        XCTAssertEqual(
            WindowServerPressureClassifier.classify(
                rollingCPU: 19.9,
                baselineCPU: 7.0,
                consecutiveHighCandidates: 2
            ),
            .elevated
        )
    }

    func testMissingRollingCPUIsUnavailable() {
        XCTAssertEqual(
            WindowServerPressureClassifier.classify(
                rollingCPU: nil,
                baselineCPU: 10.0,
                consecutiveHighCandidates: 0
            ),
            .unavailable
        )
    }

    func testRollingWindowKeepsLastThreeValidSamples() {
        var aggregate = WindowServerSessionAggregate()
        aggregate.baseline = WindowServerBaselineSummary(
            averageCPU: 0,
            peakCPU: 0,
            validSampleCount: 1
        )
        aggregate.recordActive(reading(10, 0), at: date(0))
        aggregate.recordActive(reading(20, 2), at: date(2))
        aggregate.recordActive(reading(30, 4), at: date(4))
        aggregate.recordActive(reading(40, 6), at: date(6))

        XCTAssertEqual(aggregate.rollingCPUValues, [20, 30, 40])
        XCTAssertEqual(aggregate.rollingAverageCPU ?? -1, 30, accuracy: 0.001)
    }

    func testUnavailableActiveReadingNeverBecomesZeroOrCountsAsSample() {
        var aggregate = WindowServerSessionAggregate()
        aggregate.recordActive(reading(nil, 2), at: date(2))

        XCTAssertNil(aggregate.activeAverageCPU)
        XCTAssertNil(aggregate.activePeakCPU)
        XCTAssertEqual(aggregate.validActiveSampleCount, 0)
        XCTAssertEqual(aggregate.currentPressure, .unavailable)
    }

    func testBaselineRetainsThreeRawSamplesAndAggregatesOnlyValidCPUValues() {
        var aggregate = WindowServerSessionAggregate()
        aggregate.beginBaseline()
        aggregate.recordBaseline(reading(nil, 0))
        aggregate.recordBaseline(reading(10, 2))
        aggregate.recordBaseline(reading(20, 4))
        aggregate.finalizeBaseline()

        XCTAssertEqual(aggregate.baselineSamples.count, 3)
        XCTAssertEqual(aggregate.baseline?.averageCPU ?? -1, 15, accuracy: 0.001)
        XCTAssertEqual(aggregate.baseline?.peakCPU ?? -1, 20, accuracy: 0.001)
        XCTAssertEqual(aggregate.baseline?.validSampleCount, 2)
    }

    func testTwoConsecutiveHighCandidatesRequiredForHigh() {
        var aggregate = WindowServerSessionAggregate()
        aggregate.baseline = WindowServerBaselineSummary(
            averageCPU: 5,
            peakCPU: 5,
            validSampleCount: 1
        )
        aggregate.recordActive(reading(30, 0), at: date(0))
        XCTAssertEqual(aggregate.currentPressure, .elevated)

        aggregate.recordActive(reading(30, 2), at: date(2))
        XCTAssertEqual(aggregate.currentPressure, .high)
        XCTAssertEqual(aggregate.maximumSustainedPressure, .high)
    }
}
