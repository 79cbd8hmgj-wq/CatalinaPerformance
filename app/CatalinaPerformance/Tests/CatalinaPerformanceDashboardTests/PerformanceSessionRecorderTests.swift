import XCTest
@testable import CatalinaPerformanceDashboardCore

final class PerformanceSessionRecorderTests: XCTestCase {
    private func date(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    func testRecordUpdatesLatestAveragePeakAndSampleCount() throws {
        let recorder = PerformanceSessionRecorder()
        recorder.begin(identifier: "session", startedAt: date(0), baseline: snapshot(cpu: 10, at: 0), selectedApplication: nil)
        recorder.markActive(at: date(1))
        recorder.record(sample: snapshot(cpu: 20, at: 2))
        recorder.record(sample: snapshot(cpu: 40, at: 4))
        let record = try XCTUnwrap(recorder.activeRecord())
        XCTAssertEqual(record.sampleCount, 2)
        XCTAssertEqual(record.aggregates.systemCPUPercent.average, 30)
        XCTAssertEqual(record.aggregates.systemCPUPercent.peak, 40)
    }

    func testFailedFinalizationReturnsToActiveAndPreservesBaseline() throws {
        let recorder = PerformanceSessionRecorder()
        recorder.begin(identifier: "session", startedAt: date(0), baseline: snapshot(cpu: 10, at: 0), selectedApplication: nil)
        recorder.markActive(at: date(1))
        recorder.markFinalizing(preRestore: snapshot(cpu: 30, at: 2), at: date(2))
        recorder.resumeAfterFailedFinalization(at: date(3), note: "restore failed")
        let record = try XCTUnwrap(recorder.activeRecord())
        XCTAssertEqual(record.phase, .active)
        XCTAssertEqual(record.baseline.systemCPUPercent.value, 10)
        XCTAssertEqual(record.metricErrors.last?.operation, "finalization")
    }

    func testCompletionPreservesDistinctFinalSnapshotsAndReason() throws {
        let recorder = PerformanceSessionRecorder()
        recorder.begin(identifier: "session", startedAt: date(0), baseline: snapshot(cpu: 10, at: 0), selectedApplication: nil)
        recorder.markActive(at: date(1))
        recorder.markFinalizing(preRestore: snapshot(cpu: 30, at: 2), at: date(2))
        let report = try XCTUnwrap(recorder.complete(postRestore: snapshot(cpu: 12, at: 3), reason: .normalOff, subsystemStatuses: [], completedAt: date(3)))
        XCTAssertEqual(report.phase, .completed)
        XCTAssertEqual(report.completionReason, .normalOff)
        XCTAssertEqual(report.finalPreRestore?.systemCPUPercent.value, 30)
        XCTAssertEqual(report.postRestore?.systemCPUPercent.value, 12)
        XCTAssertNil(recorder.activeRecord())
    }

    func testConcurrentRecordingIsSerialized() {
        let recorder = PerformanceSessionRecorder()
        recorder.begin(identifier: "session", startedAt: date(0), baseline: snapshot(cpu: 1, at: 0), selectedApplication: nil)
        recorder.markActive(at: date(1))
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            recorder.record(sample: self.snapshot(cpu: Double(index), at: Double(index + 2)))
        }
        XCTAssertEqual(recorder.activeRecord()?.sampleCount, 100)
    }

    private func snapshot(cpu: Double, at seconds: TimeInterval) -> SessionMetricSnapshot {
        let d = date(seconds)
        let unavailableDouble = MetricReading<Double>.unavailable(at: d, note: nil)
        let unavailableBytes = MetricReading<UInt64>.unavailable(at: d, note: nil)
        let unavailableCount = MetricReading<Int>.unavailable(at: d, note: nil)
        return SessionMetricSnapshot(
            capturedAt: d,
            systemCPUPercent: .available(cpu, at: d),
            memoryPressure: .available(.normal, at: d),
            physicalMemoryUsedBytes: unavailableBytes,
            swapUsedBytes: unavailableBytes,
            diskFreeBytes: unavailableBytes,
            schedulerLimitPercent: unavailableDouble,
            speedLimitPercent: unavailableDouble,
            selectedAppCPUPercent: unavailableDouble,
            selectedAppResidentBytes: unavailableBytes,
            selectedAppVerifiedProcessCount: unavailableCount,
            selectedAppPriorityConfirmedCount: unavailableCount
        )
    }
}
