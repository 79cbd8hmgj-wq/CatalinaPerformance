import XCTest
import CatalinaPerformancePriorityCore
@testable import CatalinaPerformanceDashboardCore

final class SessionDashboardPresentationTests: XCTestCase {
    private func date(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    func testUnavailableDisplaysUnavailableNotZero() {
        let record = activeRecord(cpu: .unavailable(at: date(2), note: nil))
        let model = SessionDashboardPresenter(nowProvider: { self.date(5) }).makeViewModel(from: PerformanceSessionCoordinatorState(content: .active(record), warningMessage: nil))
        XCTAssertEqual(model.systemRows.first(where: { $0.label == "CPU Usage" })?.current, "Unavailable")
        XCTAssertFalse(model.systemRows.contains { $0.current == "0%" })
    }

    func testFormattingUsesBinaryBytesDurationAndUnclampedSelectedCPU() {
        let d = date(0)
        let snapshot = SessionMetricSnapshot(
            capturedAt: d,
            systemCPUPercent: .available(50, at: d),
            memoryPressure: .available(.normal, at: d),
            physicalMemoryUsedBytes: .available(1_073_741_824, at: d),
            swapUsedBytes: .available(0, at: d),
            diskFreeBytes: .available(1_073_741_824, at: d),
            schedulerLimitPercent: .available(75, at: d),
            speedLimitPercent: .available(100, at: d),
            selectedAppCPUPercent: .available(150, at: d),
            selectedAppResidentBytes: .available(1_073_741_824, at: d),
            selectedAppVerifiedProcessCount: .available(2, at: d),
            selectedAppPriorityConfirmedCount: .available(2, at: d)
        )
        var record = activeRecord(cpu: snapshot.systemCPUPercent)
        record.latest = snapshot
        let state = PerformanceSessionCoordinatorState(content: .active(record), warningMessage: nil)
        let model = SessionDashboardPresenter(nowProvider: { self.date(3661) }).makeViewModel(from: state)
        XCTAssertEqual(model.durationText, "01:01:01")
        XCTAssertEqual(model.systemRows.first(where: { $0.label == "Memory Used" })?.current, "1 GB")
        XCTAssertEqual(model.selectedAppRows.first(where: { $0.label == "Combined CPU Usage" })?.current, "150.0%")
        XCTAssertTrue(model.systemRows.first(where: { $0.label == "CPU Scheduler Limit" })?.secondary?.contains("Constraint detected") == true)
    }

    func testDisabledSelectionDisplaysNotConfiguredAndNoCausalClaims() {
        let record = activeRecord(cpu: .available(10, at: date(1)))
        let model = SessionDashboardPresenter(nowProvider: { self.date(2) }).makeViewModel(from: PerformanceSessionCoordinatorState(content: .active(record), warningMessage: nil))
        XCTAssertEqual(model.priorityTargetText, "Not configured")
        let allText = ([model.title, model.statusText] + model.systemRows.flatMap { [$0.label, $0.current, $0.secondary ?? ""] }).joined(separator: " ").lowercased()
        for prohibited in ["score", "grade", "improved by", "faster"] { XCTAssertFalse(allText.contains(prohibited)) }
    }

    func testCompletedPresentationIncludesCompletionTimeAndRestoreResult() {
        let record = activeRecord(cpu: .available(10, at: date(1)))
        let statuses = PerformanceSubsystem.allCases.map {
            PerformanceSubsystemStatus(subsystem: $0, state: .restored, updatedAt: date(5), note: nil)
        }
        let report = CompletedPerformanceSessionReport(
            sessionIdentifier: record.sessionIdentifier,
            phase: .completed,
            startedAt: record.startedAt,
            completedAt: date(5),
            selectedApplication: record.selectedApplication,
            baseline: record.baseline,
            finalPreRestore: record.latest,
            postRestore: record.latest,
            aggregates: record.aggregates,
            sampleCount: record.sampleCount,
            subsystemStatuses: statuses,
            monitoringGaps: [],
            metricErrors: [],
            completionReason: .normalOff
        )
        let model = SessionDashboardPresenter().makeViewModel(from: PerformanceSessionCoordinatorState(content: .completed(report), warningMessage: nil))
        XCTAssertNotNil(model.completionText)
        XCTAssertEqual(model.restoreResultText, "Successful")
    }

    private func activeRecord(cpu: MetricReading<Double>) -> PerformanceSessionRecord {
        let d = cpu.capturedAt
        let snapshot = SessionMetricSnapshot(
            capturedAt: d,
            systemCPUPercent: cpu,
            memoryPressure: .available(.normal, at: d),
            physicalMemoryUsedBytes: .unavailable(at: d, note: nil),
            swapUsedBytes: .unavailable(at: d, note: nil),
            diskFreeBytes: .unavailable(at: d, note: nil),
            schedulerLimitPercent: .unavailable(at: d, note: nil),
            speedLimitPercent: .unavailable(at: d, note: nil),
            selectedAppCPUPercent: .unsupported(at: d, note: "App Priority is not configured."),
            selectedAppResidentBytes: .unsupported(at: d, note: "App Priority is not configured."),
            selectedAppVerifiedProcessCount: .unsupported(at: d, note: "App Priority is not configured."),
            selectedAppPriorityConfirmedCount: .unsupported(at: d, note: "App Priority is not configured.")
        )
        return PerformanceSessionRecord(sessionIdentifier: "s", phase: .active, startedAt: date(0), completedAt: nil, selectedApplication: nil, baseline: snapshot, latest: snapshot, finalPreRestore: nil, postRestore: nil, aggregates: SessionMetricAggregates(), sampleCount: 1, subsystemStatuses: [], monitoringGaps: [], metricErrors: [], completionReason: nil)
    }
}
