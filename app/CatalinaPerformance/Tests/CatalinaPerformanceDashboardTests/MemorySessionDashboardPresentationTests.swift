import XCTest
import CatalinaPerformanceMemoryCore
@testable import CatalinaPerformanceDashboardCore

final class MemorySessionDashboardPresentationTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_000)

    func testMemoryAggregateTracksReadOnlyPeaksAndDurations() {
        var aggregate = MemorySessionAggregate()
        aggregate.recordBaseline(snapshot: snapshot(
            at: 0,
            state: .healthy,
            compressed: 256 * 1_024 * 1_024,
            swap: 128 * 1_024 * 1_024
        ))
        aggregate.recordSample(snapshot: snapshot(
            at: 2,
            state: .high,
            compressed: 512 * 1_024 * 1_024,
            swap: 256 * 1_024 * 1_024,
            compressionRate: 64 * 1_024 * 1_024,
            swapInRate: 16 * 1_024 * 1_024,
            swapOutRate: 32 * 1_024 * 1_024
        ))
        aggregate.recordSample(snapshot: snapshot(
            at: 4,
            state: .critical,
            compressed: 768 * 1_024 * 1_024,
            swap: 384 * 1_024 * 1_024,
            compressionRate: 96 * 1_024 * 1_024,
            swapInRate: 24 * 1_024 * 1_024,
            swapOutRate: 48 * 1_024 * 1_024
        ))
        aggregate.recordSample(snapshot: snapshot(
            at: 6,
            state: .healthy,
            compressed: 700 * 1_024 * 1_024,
            swap: 320 * 1_024 * 1_024,
            compressionRate: 0,
            swapInRate: 0,
            swapOutRate: 0
        ))

        XCTAssertEqual(aggregate.baselineState, .healthy)
        XCTAssertEqual(aggregate.maximumState, .critical)
        XCTAssertEqual(aggregate.peakCompressedBytes, 768 * 1_024 * 1_024)
        XCTAssertEqual(aggregate.peakSwapUsedBytes, 384 * 1_024 * 1_024)
        XCTAssertEqual(aggregate.peakCompressionGrowthBytesPerSecond, Double(96 * 1_024 * 1_024))
        XCTAssertEqual(aggregate.peakSwapInBytesPerSecond, Double(24 * 1_024 * 1_024))
        XCTAssertEqual(aggregate.peakSwapOutBytesPerSecond, Double(48 * 1_024 * 1_024))
        XCTAssertEqual(aggregate.healthySeconds, 2, accuracy: 0.001)
        XCTAssertEqual(aggregate.highSeconds, 2, accuracy: 0.001)
        XCTAssertEqual(aggregate.criticalSeconds, 2, accuracy: 0.001)
    }

    func testActiveDashboardContainsReadOnlyMemoryRowsOnly() {
        let current = snapshot(
            at: 6,
            state: .high,
            compressed: 768 * 1_024 * 1_024,
            swap: 384 * 1_024 * 1_024,
            compressionRate: 96 * 1_024 * 1_024,
            swapInRate: nil,
            swapOutRate: 48 * 1_024 * 1_024
        )
        var aggregates = SessionMetricAggregates()
        let baseline = snapshot(at: 0, state: .healthy, compressed: 128, swap: 64)
        aggregates.recordBaseline(baseline)
        aggregates.recordSample(current)
        let record = PerformanceSessionRecord(
            sessionIdentifier: "memory-session",
            phase: .active,
            startedAt: base,
            completedAt: nil,
            selectedApplication: nil,
            baseline: baseline,
            latest: current,
            finalPreRestore: nil,
            postRestore: nil,
            aggregates: aggregates,
            sampleCount: 1,
            subsystemStatuses: [],
            monitoringGaps: [],
            metricErrors: [],
            completionReason: nil
        )
        let model = SessionDashboardPresenter(nowProvider: { self.base.addingTimeInterval(6) })
            .makeMemoryAwareViewModel(from: PerformanceSessionCoordinatorState(content: .active(record), warningMessage: nil))
        let labels = model.memoryRows.map { $0.label }

        for label in ["State", "Physical Used", "Available", "Compressed", "Compression Growth", "Swap Used", "Swap Growth", "Swap In", "Swap Out", "Page-Out Activity"] {
            XCTAssertTrue(labels.contains(label), "Missing read-only memory row: \(label)")
        }
        XCTAssertFalse(labels.contains("Managed Workloads"))
        XCTAssertFalse(labels.contains("I/O Policy"))
        XCTAssertEqual(model.memoryRows.first(where: { $0.label == "Swap In" })?.current, "Unavailable")
    }

    func testCompletedDashboardReportsReadOnlySessionEvidenceOnly() {
        var aggregates = SessionMetricAggregates()
        let baseline = snapshot(at: 0, state: .healthy, compressed: 128 * 1_024 * 1_024, swap: 64 * 1_024 * 1_024)
        let high = snapshot(at: 2, state: .high, compressed: 512 * 1_024 * 1_024, swap: 256 * 1_024 * 1_024, compressionRate: 32 * 1_024 * 1_024, swapInRate: 8 * 1_024 * 1_024, swapOutRate: 16 * 1_024 * 1_024)
        let final = snapshot(at: 4, state: .healthy, compressed: 400 * 1_024 * 1_024, swap: 192 * 1_024 * 1_024)
        aggregates.recordBaseline(baseline)
        aggregates.recordSample(high)
        aggregates.recordPostRestore(final)
        let report = CompletedPerformanceSessionReport(
            sessionIdentifier: "memory-session",
            phase: .completed,
            startedAt: base,
            completedAt: base.addingTimeInterval(4),
            selectedApplication: nil,
            baseline: baseline,
            finalPreRestore: high,
            postRestore: final,
            aggregates: aggregates,
            sampleCount: 1,
            subsystemStatuses: [],
            monitoringGaps: [],
            metricErrors: [],
            completionReason: .normalOff
        )
        let model = SessionDashboardPresenter(nowProvider: { self.base.addingTimeInterval(4) })
            .makeMemoryAwareViewModel(from: PerformanceSessionCoordinatorState(content: .completed(report), warningMessage: nil))
        let labels = model.memoryRows.map { $0.label }

        for label in ["Maximum State", "Peak Compressed", "Peak Swap", "Peak Swap Out", "Time High"] {
            XCTAssertTrue(labels.contains(label), "Missing completed memory row: \(label)")
        }
        for removed in ["Intervention Episodes", "Managed Families", "Longest Intervention", "Restoration", "I/O Policy"] {
            XCTAssertFalse(labels.contains(removed), "Intervention row should not be presented: \(removed)")
        }
    }

    private func snapshot(
        at seconds: TimeInterval,
        state: MemoryPressureState,
        compressed: UInt64,
        swap: UInt64,
        compressionRate: Double? = nil,
        swapInRate: Double? = nil,
        swapOutRate: Double? = nil
    ) -> SessionMetricSnapshot {
        let date = base.addingTimeInterval(seconds)
        let physical: UInt64 = 4 * 1_024 * 1_024 * 1_024
        let available: UInt64 = 512 * 1_024 * 1_024
        let telemetry = MemoryTelemetrySnapshot(
            capturedAt: date,
            counters: MemoryVMCounters(
                physicalBytes: physical,
                availableBytes: available,
                compressedBytes: compressed,
                swapUsedBytes: swap,
                compressions: 100,
                decompressions: 20,
                pageIns: 100,
                pageOuts: 50,
                swapIns: 20,
                swapOuts: 40,
                pageSizeBytes: 4096
            ),
            rates: MemoryTelemetryRates(
                compressionBytesPerSecond: compressionRate,
                swapGrowthBytesPerSecond: nil,
                swapInBytesPerSecond: swapInRate,
                swapOutBytesPerSecond: swapOutRate,
                pageOutsPerSecond: swapOutRate == nil ? nil : 5
            ),
            note: nil
        )
        let memory = MemoryManagementStatusSnapshot(
            capturedAt: date,
            pressureState: state,
            managedFamilyCount: 0,
            managedFamilyNames: [],
            interventionActive: false,
            ioPolicyStatus: .unsupported,
            telemetry: telemetry,
            note: "Memory / Swap monitoring is read-only."
        )
        let unavailableDouble = MetricReading<Double>.unavailable(at: date, note: nil)
        let unavailableBytes = MetricReading<UInt64>.unavailable(at: date, note: nil)
        let unavailableInt = MetricReading<Int>.unavailable(at: date, note: nil)
        return SessionMetricSnapshot(
            capturedAt: date,
            systemCPUPercent: unavailableDouble,
            memoryPressure: .available(.normal, at: date),
            physicalMemoryUsedBytes: .available(physical - available, at: date),
            swapUsedBytes: .available(swap, at: date),
            diskFreeBytes: unavailableBytes,
            schedulerLimitPercent: unavailableDouble,
            speedLimitPercent: unavailableDouble,
            selectedAppCPUPercent: unavailableDouble,
            selectedAppResidentBytes: unavailableBytes,
            selectedAppVerifiedProcessCount: unavailableInt,
            selectedAppPriorityConfirmedCount: unavailableInt,
            memoryManagement: memory
        )
    }
}
