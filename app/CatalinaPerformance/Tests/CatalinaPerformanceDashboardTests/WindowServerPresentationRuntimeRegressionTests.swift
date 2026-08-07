import XCTest
@testable import CatalinaPerformanceDashboardCore

final class WindowServerPresentationRuntimeRegressionTests: XCTestCase {
    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    func testExpectedTwoMeasuredBaselineIntervalsDoNotRenderPartialEvidenceWarning() {
        var graphics = WindowServerSessionAggregate()
        graphics.baseline = WindowServerBaselineSummary(
            averageCPU: 0.2,
            peakCPU: 0.5,
            validSampleCount: 2
        )
        graphics.currentPressure = .normal

        let viewModel = presenter().makeViewModel(from: .init(
            content: .active(record(graphics: graphics)),
            warningMessage: nil
        ))

        let baseline = viewModel.graphicsRows.first(where: { $0.label == "Pre-ON Baseline" })
        XCTAssertEqual(baseline?.current, "0.2%")
        XCTAssertNil(baseline?.secondary)
    }

    func testOnlyOneMeasuredBaselineIntervalStillReportsPartialEvidence() {
        var graphics = WindowServerSessionAggregate()
        graphics.baseline = WindowServerBaselineSummary(
            averageCPU: 0.2,
            peakCPU: 0.2,
            validSampleCount: 1
        )
        graphics.currentPressure = .normal

        let viewModel = presenter().makeViewModel(from: .init(
            content: .active(record(graphics: graphics)),
            warningMessage: nil
        ))

        let baseline = viewModel.graphicsRows.first(where: { $0.label == "Pre-ON Baseline" })
        XCTAssertEqual(
            baseline?.secondary,
            "Only 1 of 2 measurable baseline CPU intervals was valid."
        )
    }

    func testGraphicsSectionDoesNotDuplicateVisualPerformanceEvidence() {
        var graphics = WindowServerSessionAggregate()
        graphics.baseline = WindowServerBaselineSummary(
            averageCPU: 0.2,
            peakCPU: 0.5,
            validSampleCount: 2
        )
        graphics.currentPressure = .normal
        graphics.finalPreRestoreCPU = 9.1
        graphics.postRestoreCPU = 5.4

        let active = presenter().makeViewModel(from: .init(
            content: .active(record(graphics: graphics)),
            warningMessage: nil
        ))
        XCTAssertFalse(active.graphicsRows.contains(where: { $0.label == "Visual Performance" }))

        let completed = presenter().makeViewModel(from: .init(
            content: .completed(report(graphics: graphics)),
            warningMessage: nil
        ))
        XCTAssertFalse(completed.graphicsRows.contains(where: { $0.label == "Visual Performance Applied" }))
        XCTAssertFalse(completed.graphicsRows.contains(where: { $0.label == "Visual Performance Restored" }))
    }

    private func presenter() -> SessionDashboardPresenter {
        SessionDashboardPresenter(nowProvider: { self.date(20) })
    }

    private func snapshot(at seconds: TimeInterval) -> SessionMetricSnapshot {
        SessionMetricSnapshot.unavailable(capturedAt: date(seconds), note: "fixture")
    }

    private func record(graphics: WindowServerSessionAggregate) -> PerformanceSessionRecord {
        let baseline = snapshot(at: 0)
        return PerformanceSessionRecord(
            sessionIdentifier: "active",
            phase: .active,
            startedAt: date(0),
            completedAt: nil,
            selectedApplication: nil,
            baseline: baseline,
            latest: baseline,
            finalPreRestore: nil,
            postRestore: nil,
            aggregates: SessionMetricAggregates(),
            sampleCount: 1,
            subsystemStatuses: [],
            monitoringGaps: [],
            metricErrors: [],
            completionReason: nil,
            windowServer: graphics
        )
    }

    private func report(graphics: WindowServerSessionAggregate) -> CompletedPerformanceSessionReport {
        let baseline = snapshot(at: 0)
        return CompletedPerformanceSessionReport(
            sessionIdentifier: "completed",
            phase: .completed,
            startedAt: date(0),
            completedAt: date(20),
            selectedApplication: nil,
            baseline: baseline,
            finalPreRestore: nil,
            postRestore: nil,
            aggregates: SessionMetricAggregates(),
            sampleCount: 1,
            subsystemStatuses: [],
            monitoringGaps: [],
            metricErrors: [],
            completionReason: .normalOff,
            windowServer: graphics
        )
    }
}
