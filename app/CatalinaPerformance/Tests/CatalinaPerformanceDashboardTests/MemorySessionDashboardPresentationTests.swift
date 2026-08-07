import XCTest
import CatalinaPerformanceMemoryCore
@testable import CatalinaPerformanceDashboardCore

final class MemorySessionDashboardPresentationTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_000)

    func testMemoryAggregateTracksPeaksDurationsEpisodesAndFamilies() {
        var aggregate = MemorySessionAggregate()
        aggregate.recordBaseline(snapshot: snapshot(
            at: 0,
            state: .healthy,
            compressed: 256 * 1_024 * 1_024,
            swap: 128 * 1_024 * 1_024,
            compressionRate: nil,
            swapInRate: nil,
            swapOutRate: nil,
            active: false,
            families: []
        ))
        aggregate.recordSample(snapshot: snapshot(
            at: 2,
            state: .high,
            compressed: 512 * 1_024 * 1_024,
            swap: 256 * 1_024 * 1_024,
            compressionRate: 64 * 1_024 * 1_024,
            swapInRate: 16 * 1_024 * 1_024,
            swapOutRate: 32 * 1_024 * 1_024,
            active: true,
            families: ["Browser"]
        ))
        aggregate.recordSample(snapshot: snapshot(
            at: 4,
            state: .critical,
            compressed: 768 * 1_024 * 1_024,
            swap: 384 * 1_024 * 1_024,
            compressionRate: 96 * 1_024 * 1_024,
            swapInRate: 24 * 1_024 * 1_024,
            swapOutRate: 48 * 1_024 * 1_024,
            active: true,
            families: ["Browser", "Editor"]
        ))
        aggregate.recordSample(snapshot: snapshot(
            at: 6,
            state: .healthy,
            compressed: 700 * 1_024 * 1_024,
            swap: 320 * 1_024 * 1_024,
            compressionRate: 0,
            swapInRate: 0,
            swapOutRate: 0,
            active: false,
            families: []
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
        XCTAssertEqual(aggregate.interventionEpisodes, 1)
        XCTAssertEqual(aggregate.managedFamilyNames, ["Browser", "Editor"])
        XCTAssertEqual(aggregate.longestInterventionDuration, 4, accuracy: 0.001)
    }

    func testActiveDashboardHasDedicatedMemoryRowsWithoutFabricatingUnsupportedRates() {
        let current = snapshot(
            at: 6,
            state: .high,
            compressed: 768 * 1_024 * 1_024,
            swap: 384 * 1_024 * 1_024,
            compressionRate: 96 * 1_024 * 1_024,
            swapInRate: nil,
            swapOutRate: 48 * 1_024 * 1_024,
            active: true,
            families: ["Browser"]
        )
        var aggregates = SessionMetricAggregates()
        aggregates.recordBaseline(snapshot(at: 0, state: .healthy, compressed: 128, swap: 64, active: false, families: []))
        aggregates.recordSample(current)
        let record = PerformanceSessionRecord(
            sessionIdentifier: "memory-session",
            phase: .active,
            startedAt: base,
            completedAt: nil,
            selectedApplication: nil,
            baseline: snapshot(at: 0, state: .healthy, compressed: 128, swap: 64, active: false, families: []),
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
        let presenter = SessionDashboardPresenter(nowProvider: { self.base.addingTimeInterval(6) })
        let model = presenter.makeViewModel(from: PerformanceSessionCoordinatorState(content: .active(record), warningMessage: nil))
        let labels = model.memoryRows.map { $0.label }

        XCTAssertTrue(labels.contains("State"))
        XCTAssertTrue(labels.contains("Physical Used"))
        XCTAssertTrue(labels.contains("Available"))
        XCTAssertTrue(labels.contains("Compressed"))
        XCTAssertTrue(labels.contains("Compression Growth"))
        XCTAssertTrue(labels.contains("Swap Used"))
        XCTAssertTrue(labels.contains("Swap Growth"))
        XCTAssertTrue(labels.contains("Swap In"))
        XCTAssertTrue(labels.contains("Swap Out"))
        XCTAssertTrue(labels.contains("Page-Out Activity"))
        XCTAssertTrue(labels.contains("Managed Workloads"))
        XCTAssertTrue(labels.contains("I/O Policy"))
        XCTAssertEqual(model.memoryRows.first(where: { $0.label == "Swap In" })?.current, "Unavailable")
    }

    func testCompletedDashboardReportsMemorySessionEvidence() {
        var aggregates = SessionMetricAggregates()
        let baseline = snapshot(at: 0, state: .healthy, compressed: 128 * 1_024 * 1_024, swap: 64 * 1_024 * 1_024, active: false, families: [])
        let active = snapshot(at: 2, state: .high, compressed: 512 * 1_024 * 1_024, swap: 256 * 1_024 * 1_024, compressionRate: 32 * 1_024 * 1_024, swapInRate: 8 * 1_024 * 1_024, swapOutRate: 16 * 1_024 * 1_024, active: true, families: ["Browser"])
        let restored = snapshot(at: 4, state: .healthy, compressed: 400 * 1_024 * 1_024, swap: 192 * 1_024 * 1_024, active: false, families: [])
        aggregates.recordBaseline(baseline)
        aggregates.recordSample(active)
        aggregates.recordPostRestore(restored)
        let report = CompletedPerformanceSessionReport(
            sessionIdentifier: "memory-session",
            phase: .completed,
            startedAt: base,
            completedAt: base.addingTimeInterval(4),
            selectedApplication: nil,
            baseline: baseline,
            finalPreRestore: active,
            postRestore: restored,
            aggregates: aggregates,
            sampleCount: 1,
            subsystemStatuses: [],
            monitoringGaps: [],
            metricErrors: [],
            completionReason: .normalOff
        )
        let model = SessionDashboardPresenter(nowProvider: { self.base.addingTimeInterval(4) })
            .makeViewModel(from: PerformanceSessionCoordinatorState(content: .completed(report), warningMessage: nil))
        let labels = model.memoryRows.map { $0.label }

        XCTAssertTrue(labels.contains("Maximum State"))
        XCTAssertTrue(labels.contains("Peak Compressed"))
        XCTAssertTrue(labels.contains("Peak Swap"))
        XCTAssertTrue(labels.contains("Peak Swap Out"))
        XCTAssertTrue(labels.contains("Time High"))
        XCTAssertTrue(labels.contains("Intervention Episodes"))
        XCTAssertTrue(labels.contains("Managed Families"))
        XCTAssertTrue(labels.contains("Longest Intervention"))
        XCTAssertTrue(labels.contains("Restoration"))
    }

    private func snapshot(
        at seconds: TimeInterval,
        state: MemoryPressureState,
        compressed: UInt64,
        swap: UInt64,
        compressionRate: Double? = nil,
        swapInRate: Double? = nil,
        swapOutRate: Double? = nil,
        active: Bool,
        families: [String]
    ) -> SessionMetricSnapshot {
        let date = base.addingTimeInterval(seconds)
        let physical: UInt64 = 4 * 1_024 * 1_024 * 1_024
        let available: UInt64 = 512 * 1_024 * 1_024
        let counters = MemoryVMCounters(
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
        )
        let telemetry = MemoryTelemetrySnapshot(
            capturedAt: date,
            counters: counters,
            rates: MemoryTelemetryRates(
                compressionBytesPerSecond: compressionRate,
                swapGrowthBytesPerSecond: nil,
                swapInBytesPerSecond: swapInRate,
                swapOutBytesPerSecond: swapOutRate,
                pageOutsPerSecond: swapOutRate == nil ? nil : 5
            ),
            note: nil
        )
        let management = MemoryManagementStatusSnapshot(
            capturedAt: date,
            pressureState: state,
            managedFamilyCount: families.count,
            managedFamilyNames: families,
            interventionActive: active,
            ioPolicyStatus: .unsupported,
            telemetry: telemetry,
            note: nil
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
            memoryManagement: management
        )
    }
}
