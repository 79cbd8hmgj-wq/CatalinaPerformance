import XCTest
@testable import CatalinaPerformanceMemoryCore

final class MemoryPressureClassifierTests: XCTestCase {
    private let thresholds = MemoryPressureThresholds.catalina10157
    private let baseDate = Date(timeIntervalSince1970: 1_000)

    func testSingleHighCandidateDoesNotIntervene() {
        var classifier = MemoryPressureClassifier(thresholds: thresholds)
        let evaluation = classifier.evaluate(snapshot: highSnapshot(second: 0), interventionActive: false)

        XCTAssertEqual(evaluation.candidateState, .high)
        XCTAssertNotEqual(evaluation.confirmedState, .high)
        XCTAssertFalse(evaluation.shouldIntervene)
    }

    func testThreeHighCandidatesConfirmHigh() {
        var classifier = MemoryPressureClassifier(thresholds: thresholds)
        _ = classifier.evaluate(snapshot: highSnapshot(second: 0), interventionActive: false)
        _ = classifier.evaluate(snapshot: highSnapshot(second: 2), interventionActive: false)
        let third = classifier.evaluate(snapshot: highSnapshot(second: 4), interventionActive: false)

        XCTAssertEqual(third.confirmedState, .high)
        XCTAssertTrue(third.shouldIntervene)
    }

    func testTwoCriticalCandidatesConfirmCritical() {
        var classifier = MemoryPressureClassifier(thresholds: thresholds)
        _ = classifier.evaluate(snapshot: criticalSnapshot(second: 0), interventionActive: false)
        let second = classifier.evaluate(snapshot: criticalSnapshot(second: 2), interventionActive: false)

        XCTAssertEqual(second.confirmedState, .critical)
        XCTAssertTrue(second.shouldIntervene)
    }

    func testThreeElevatedCandidatesConfirmElevated() {
        var classifier = MemoryPressureClassifier(thresholds: thresholds)
        _ = classifier.evaluate(snapshot: elevatedSnapshot(second: 0), interventionActive: false)
        _ = classifier.evaluate(snapshot: elevatedSnapshot(second: 2), interventionActive: false)
        let third = classifier.evaluate(snapshot: elevatedSnapshot(second: 4), interventionActive: false)

        XCTAssertEqual(third.confirmedState, .elevated)
        XCTAssertFalse(third.shouldIntervene)
    }

    func testFiveHealthySamplesAfterInterventionRequestsRestore() {
        var classifier = MemoryPressureClassifier(thresholds: thresholds)
        _ = classifier.evaluate(snapshot: highSnapshot(second: 0), interventionActive: false)
        _ = classifier.evaluate(snapshot: highSnapshot(second: 2), interventionActive: false)
        _ = classifier.evaluate(snapshot: highSnapshot(second: 4), interventionActive: false)

        var result: MemoryPressureEvaluation?
        for index in 0..<5 {
            result = classifier.evaluate(
                snapshot: healthySnapshot(second: 6 + index * 2),
                interventionActive: true
            )
        }

        XCTAssertEqual(result?.healthyRecoveryCount, 5)
        XCTAssertEqual(result?.shouldRestore, true)
    }

    func testElevatedSampleResetsHealthyRecoveryCounter() {
        var classifier = MemoryPressureClassifier(thresholds: thresholds)
        _ = classifier.evaluate(snapshot: highSnapshot(second: 0), interventionActive: false)
        _ = classifier.evaluate(snapshot: highSnapshot(second: 2), interventionActive: false)
        _ = classifier.evaluate(snapshot: highSnapshot(second: 4), interventionActive: false)
        _ = classifier.evaluate(snapshot: healthySnapshot(second: 6), interventionActive: true)
        _ = classifier.evaluate(snapshot: healthySnapshot(second: 8), interventionActive: true)
        let elevated = classifier.evaluate(snapshot: elevatedSnapshot(second: 10), interventionActive: true)

        XCTAssertEqual(elevated.healthyRecoveryCount, 0)
        XCTAssertFalse(elevated.shouldRestore)
    }

    func testStableHistoricalSwapDoesNotCreatePressureEvidence() {
        var classifier = MemoryPressureClassifier(thresholds: thresholds)
        let snapshot = makeSnapshot(
            second: 0,
            availableFraction: 0.50,
            compressedFraction: 0.15,
            swapUsedBytes: 1_073_741_824,
            compressionRate: 0,
            swapGrowthRate: 0,
            swapInRate: 0,
            swapOutRate: 0,
            pageOutRate: 0
        )
        let evaluation = classifier.evaluate(snapshot: snapshot, interventionActive: false)

        XCTAssertEqual(evaluation.candidateState, .healthy)
        XCTAssertTrue(evaluation.evidence.isEmpty)
    }

    func testUnavailableMetricContributesNoEvidence() {
        var classifier = MemoryPressureClassifier(thresholds: thresholds)
        let snapshot = MemoryTelemetrySnapshot(
            capturedAt: baseDate,
            counters: nil,
            rates: .unavailable,
            note: "unavailable"
        )
        let evaluation = classifier.evaluate(snapshot: snapshot, interventionActive: false)

        XCTAssertEqual(evaluation.candidateState, .healthy)
        XCTAssertTrue(evaluation.evidence.isEmpty)
        XCTAssertFalse(evaluation.shouldIntervene)
    }

    private func healthySnapshot(second: Int) -> MemoryTelemetrySnapshot {
        return makeSnapshot(
            second: second,
            availableFraction: 0.40,
            compressedFraction: 0.10,
            swapUsedBytes: 100_000_000,
            compressionRate: 0,
            swapGrowthRate: 0,
            swapInRate: 0,
            swapOutRate: 0,
            pageOutRate: 0
        )
    }

    private func elevatedSnapshot(second: Int) -> MemoryTelemetrySnapshot {
        return makeSnapshot(
            second: second,
            availableFraction: 0.12,
            compressedFraction: 0.18,
            swapUsedBytes: 100_000_000,
            compressionRate: 0,
            swapGrowthRate: 0,
            swapInRate: 0,
            swapOutRate: 0,
            pageOutRate: 0
        )
    }

    private func highSnapshot(second: Int) -> MemoryTelemetrySnapshot {
        return makeSnapshot(
            second: second,
            availableFraction: 0.07,
            compressedFraction: 0.24,
            swapUsedBytes: 150_000_000,
            compressionRate: 4096,
            swapGrowthRate: nil,
            swapInRate: 0,
            swapOutRate: 4096,
            pageOutRate: 1
        )
    }

    private func criticalSnapshot(second: Int) -> MemoryTelemetrySnapshot {
        return makeSnapshot(
            second: second,
            availableFraction: 0.04,
            compressedFraction: 0.32,
            swapUsedBytes: 200_000_000,
            compressionRate: 8192,
            swapGrowthRate: nil,
            swapInRate: 4096,
            swapOutRate: 8192,
            pageOutRate: 2
        )
    }

    private func makeSnapshot(
        second: Int,
        availableFraction: Double,
        compressedFraction: Double,
        swapUsedBytes: UInt64,
        compressionRate: Double?,
        swapGrowthRate: Double?,
        swapInRate: Double?,
        swapOutRate: Double?,
        pageOutRate: Double?
    ) -> MemoryTelemetrySnapshot {
        let physical: UInt64 = 4_294_967_296
        let available = UInt64(Double(physical) * availableFraction)
        let compressed = UInt64(Double(physical) * compressedFraction)
        let counters = MemoryVMCounters(
            physicalBytes: physical,
            availableBytes: available,
            compressedBytes: compressed,
            swapUsedBytes: swapUsedBytes,
            compressions: 1,
            decompressions: 1,
            pageIns: 1,
            pageOuts: 1,
            swapIns: 1,
            swapOuts: 1,
            pageSizeBytes: 4096
        )
        return MemoryTelemetrySnapshot(
            capturedAt: baseDate.addingTimeInterval(TimeInterval(second)),
            counters: counters,
            rates: MemoryTelemetryRates(
                compressionBytesPerSecond: compressionRate,
                swapGrowthBytesPerSecond: swapGrowthRate,
                swapInBytesPerSecond: swapInRate,
                swapOutBytesPerSecond: swapOutRate,
                pageOutsPerSecond: pageOutRate
            ),
            note: nil
        )
    }
}
