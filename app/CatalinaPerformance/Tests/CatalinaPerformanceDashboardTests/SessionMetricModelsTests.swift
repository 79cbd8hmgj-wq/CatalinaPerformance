import XCTest
@testable import CatalinaPerformanceDashboardCore

final class SessionMetricModelsTests: XCTestCase {
    private func date(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    func testUnavailableReadingDoesNotBecomeZero() {
        let reading = MetricReading<Double>.unavailable(at: date(10), note: "counter interval unavailable")
        XCTAssertNil(reading.value)
        XCTAssertEqual(reading.availability, .unavailable)
    }

    func testNumericAggregateExcludesUnavailableValues() {
        var aggregate = NumericMetricAggregate()
        aggregate.recordBaseline(.available(10, at: date(0)))
        aggregate.recordSample(.unavailable(at: date(2), note: nil))
        aggregate.recordSample(.available(30, at: date(4)))
        XCTAssertEqual(aggregate.average, 30)
        XCTAssertEqual(aggregate.peak, 30)
        XCTAssertEqual(aggregate.validSampleCount, 1)
    }


    func testUInt64MetricAggregationUsesNumericConversionInsteadOfBitPattern() {
        let capturedAt = date(10)
        let bytes: UInt64 = 4_091_813_888
        let snapshot = SessionMetricSnapshot(
            capturedAt: capturedAt,
            systemCPUPercent: .unavailable(at: capturedAt, note: nil),
            memoryPressure: .available(.normal, at: capturedAt),
            physicalMemoryUsedBytes: .available(bytes, at: capturedAt),
            swapUsedBytes: .available(0, at: capturedAt),
            diskFreeBytes: .available(bytes, at: capturedAt),
            schedulerLimitPercent: .available(100, at: capturedAt),
            speedLimitPercent: .available(100, at: capturedAt),
            selectedAppCPUPercent: .unavailable(at: capturedAt, note: nil),
            selectedAppResidentBytes: .available(bytes, at: capturedAt),
            selectedAppVerifiedProcessCount: .available(1, at: capturedAt),
            selectedAppPriorityConfirmedCount: .available(1, at: capturedAt)
        )

        var aggregates = SessionMetricAggregates()
        aggregates.recordBaseline(snapshot)
        aggregates.recordSample(snapshot)
        aggregates.recordFinalPreRestore(snapshot)
        aggregates.recordPostRestore(snapshot)

        let expected = Double(bytes)
        XCTAssertEqual(aggregates.physicalMemoryUsedBytes.baseline, expected)
        XCTAssertEqual(aggregates.physicalMemoryUsedBytes.average, expected)
        XCTAssertEqual(aggregates.physicalMemoryUsedBytes.peak, expected)
        XCTAssertEqual(aggregates.physicalMemoryUsedBytes.finalPreRestore, expected)
        XCTAssertEqual(aggregates.physicalMemoryUsedBytes.postRestore, expected)
        XCTAssertEqual(aggregates.selectedAppResidentBytes.baseline, expected)
        XCTAssertGreaterThan(aggregates.selectedAppResidentBytes.average ?? 0, 1_000_000)
    }

    func testMemoryPressurePeakUsesSeverityOrdering() {
        var aggregate = MemoryPressureMetricAggregate()
        aggregate.recordSample(.available(.normal, at: date(0)))
        aggregate.recordSample(.available(.critical, at: date(2)))
        aggregate.recordSample(.available(.warning, at: date(4)))
        XCTAssertEqual(aggregate.peak, .critical)
    }

    func testMemoryPressureMappingUsesConservativeAvailableMemoryThresholds() {
        XCTAssertEqual(MemoryPressureMapper.level(totalBytes: 100, availableBytes: 11), .normal)
        XCTAssertEqual(MemoryPressureMapper.level(totalBytes: 100, availableBytes: 10), .warning)
        XCTAssertEqual(MemoryPressureMapper.level(totalBytes: 100, availableBytes: 5), .critical)
    }

    func testActiveRecordRoundTripsWithoutRawSamplesArray() throws {
        let snapshot = SessionMetricSnapshot.unavailable(capturedAt: date(0), note: "fixture")
        let record = PerformanceSessionRecord(
            sessionIdentifier: "session",
            phase: .active,
            startedAt: date(0),
            completedAt: nil,
            selectedApplication: nil,
            baseline: snapshot,
            latest: snapshot,
            finalPreRestore: nil,
            postRestore: nil,
            aggregates: SessionMetricAggregates(),
            sampleCount: 7,
            subsystemStatuses: [],
            monitoringGaps: [],
            metricErrors: [],
            completionReason: nil
        )
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(record)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("sampleCount"))
        XCTAssertFalse(json.contains("\"samples\""))
        XCTAssertEqual(try decoder.decode(PerformanceSessionRecord.self, from: data), record)
    }
}
