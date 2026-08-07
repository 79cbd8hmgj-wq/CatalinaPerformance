import XCTest
@testable import CatalinaPerformanceDashboardCore

final class WindowServerPerformanceSessionRecorderTests: XCTestCase {
    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    private func reading(_ cpu: Double?, at seconds: TimeInterval) -> WindowServerCPUReading {
        let capturedAt = date(seconds)
        let key = WindowServerProcessKey(
            pid: 88,
            effectiveUID: 88,
            executablePath: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer",
            startSeconds: 1,
            startMicroseconds: 0
        )
        if let cpu = cpu {
            return .available(
                processKey: key,
                cumulativeCPUTimeNanoseconds: UInt64(cpu * 1_000_000),
                cpuPercent: cpu,
                at: capturedAt
            )
        }
        return .unavailable(processKey: key, at: capturedAt, note: "counter unavailable")
    }

    private func snapshot(_ cpu: Double?, at seconds: TimeInterval) -> SessionMetricSnapshot {
        let capturedAt = date(seconds)
        var snapshot = SessionMetricSnapshot.unavailable(capturedAt: capturedAt, note: "fixture")
        if cpu == nil {
            return SessionMetricSnapshot(
                capturedAt: snapshot.capturedAt,
                systemCPUPercent: snapshot.systemCPUPercent,
                memoryPressure: snapshot.memoryPressure,
                physicalMemoryUsedBytes: snapshot.physicalMemoryUsedBytes,
                swapUsedBytes: snapshot.swapUsedBytes,
                diskFreeBytes: snapshot.diskFreeBytes,
                schedulerLimitPercent: snapshot.schedulerLimitPercent,
                speedLimitPercent: snapshot.speedLimitPercent,
                selectedAppCPUPercent: snapshot.selectedAppCPUPercent,
                selectedAppResidentBytes: snapshot.selectedAppResidentBytes,
                selectedAppVerifiedProcessCount: snapshot.selectedAppVerifiedProcessCount,
                selectedAppPriorityConfirmedCount: snapshot.selectedAppPriorityConfirmedCount,
                windowServerCPU: nil
            )
        }
        return SessionMetricSnapshot(
            capturedAt: capturedAt,
            systemCPUPercent: snapshot.systemCPUPercent,
            memoryPressure: snapshot.memoryPressure,
            physicalMemoryUsedBytes: snapshot.physicalMemoryUsedBytes,
            swapUsedBytes: snapshot.swapUsedBytes,
            diskFreeBytes: snapshot.diskFreeBytes,
            schedulerLimitPercent: snapshot.schedulerLimitPercent,
            speedLimitPercent: snapshot.speedLimitPercent,
            selectedAppCPUPercent: snapshot.selectedAppCPUPercent,
            selectedAppResidentBytes: snapshot.selectedAppResidentBytes,
            selectedAppVerifiedProcessCount: snapshot.selectedAppVerifiedProcessCount,
            selectedAppPriorityConfirmedCount: snapshot.selectedAppPriorityConfirmedCount,
            windowServerCPU: reading(cpu, at: seconds)
        )
    }

    func testGraphicsBaselineRetainsThreeSamplesAndSummarizesValidValues() {
        let recorder = PerformanceSessionRecorder()
        recorder.begin(
            identifier: "baseline",
            startedAt: date(0),
            baseline: snapshot(nil, at: 0),
            selectedApplication: nil
        )
        recorder.beginGraphicsBaseline()
        recorder.recordGraphicsBaseline(sample: reading(nil, at: 0))
        recorder.recordGraphicsBaseline(sample: reading(10, at: 2))
        recorder.recordGraphicsBaseline(sample: reading(20, at: 4))
        recorder.finalizeGraphicsBaseline()

        let graphics = recorder.activeRecord()?.windowServer
        XCTAssertEqual(graphics?.baselineSamples.count, 3)
        XCTAssertEqual(graphics?.baseline?.averageCPU ?? -1, 15, accuracy: 0.001)
        XCTAssertEqual(graphics?.baseline?.peakCPU ?? -1, 20, accuracy: 0.001)
        XCTAssertEqual(graphics?.baseline?.validSampleCount, 2)
    }

    func testActiveSamplesUpdateGraphicsAggregateWithoutCountingUnavailableAsZero() {
        let recorder = PerformanceSessionRecorder()
        recorder.begin(
            identifier: "active",
            startedAt: date(0),
            baseline: snapshot(nil, at: 0),
            selectedApplication: nil
        )
        recorder.beginGraphicsBaseline()
        recorder.recordGraphicsBaseline(sample: reading(5, at: 0))
        recorder.finalizeGraphicsBaseline()
        recorder.markActive(at: date(1))
        recorder.record(sample: snapshot(20, at: 2))
        recorder.record(sample: snapshot(nil, at: 4))
        recorder.record(sample: snapshot(30, at: 6))

        let graphics = recorder.activeRecord()?.windowServer
        XCTAssertEqual(graphics?.validActiveSampleCount, 2)
        XCTAssertEqual(graphics?.activeAverageCPU ?? -1, 25, accuracy: 0.001)
        XCTAssertEqual(graphics?.activePeakCPU ?? -1, 30, accuracy: 0.001)
    }

    func testFinalAndPostRestoreReadingsFlowIntoCompletedReport() {
        let recorder = PerformanceSessionRecorder()
        recorder.begin(
            identifier: "complete",
            startedAt: date(0),
            baseline: snapshot(nil, at: 0),
            selectedApplication: nil
        )
        recorder.beginGraphicsBaseline()
        recorder.recordGraphicsBaseline(sample: reading(6, at: 0))
        recorder.finalizeGraphicsBaseline()
        recorder.markActive(at: date(1))
        recorder.record(sample: snapshot(12, at: 2))
        recorder.markFinalizing(preRestore: snapshot(18, at: 4), at: date(4))

        let report = recorder.complete(
            postRestore: snapshot(8, at: 6),
            reason: .normalOff,
            subsystemStatuses: [],
            completedAt: date(6)
        )

        XCTAssertEqual(report?.windowServer?.finalPreRestoreCPU ?? -1, 18, accuracy: 0.001)
        XCTAssertEqual(report?.windowServer?.postRestoreCPU ?? -1, 8, accuracy: 0.001)
        XCTAssertEqual(report?.windowServer?.validActiveSampleCount, 1)
        XCTAssertNil(recorder.activeRecord())
    }

    func testInterruptedSessionRecordsLatestWindowServerAsFinalPreRestore() {
        let recorder = PerformanceSessionRecorder()
        recorder.begin(
            identifier: "interrupted",
            startedAt: date(0),
            baseline: snapshot(nil, at: 0),
            selectedApplication: nil
        )
        recorder.markActive(at: date(1))

        let report = recorder.interrupt(
            latest: snapshot(22, at: 4),
            subsystemStatuses: [],
            completedAt: date(4)
        )

        XCTAssertEqual(report?.windowServer?.finalPreRestoreCPU ?? -1, 22, accuracy: 0.001)
        XCTAssertEqual(report?.completionReason, .interrupted)
    }
}
