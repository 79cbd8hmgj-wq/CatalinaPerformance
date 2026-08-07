import XCTest
@testable import CatalinaPerformanceDashboardCore

final class WindowServerSessionDashboardPresentationTests: XCTestCase {
    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    func testPreparingStateUsesGraphicsProgressMessageExactly() {
        let presenter = SessionDashboardPresenter(nowProvider: { self.date(0) })
        let progress = PerformancePreparationProgress(
            graphicsSampleIndex: 2,
            graphicsSampleCount: 3,
            message: "Measuring graphics baseline… 2/3"
        )

        let viewModel = presenter.makeViewModel(from: PerformanceSessionCoordinatorState(
            content: .preparing(progress),
            warningMessage: nil
        ))

        XCTAssertEqual(viewModel.statusText, "Measuring graphics baseline… 2/3")
        XCTAssertTrue(viewModel.graphicsRows.isEmpty)
    }

    func testActiveGraphicsRowsExposeApprovedLabelsAndOneDecimalPercentages() {
        var graphics = WindowServerSessionAggregate()
        graphics.baseline = WindowServerBaselineSummary(averageCPU: 10, peakCPU: 12, validSampleCount: 3)
        graphics.latestActiveCPU = 22.4
        graphics.activeRunningSum = 35.8
        graphics.validActiveSampleCount = 2
        graphics.activePeakCPU = 34.2
        graphics.rollingCPUValues = [14, 19, 23.1]
        graphics.rollingAverageCPU = 18.7
        graphics.currentPressure = .elevated
        graphics.maximumSustainedPressure = .elevated
        graphics.visualPerformanceActive = true

        let viewModel = presenter().makeViewModel(from: .init(
            content: .active(record(graphics: graphics)),
            warningMessage: nil
        ))
        let labels = viewModel.graphicsRows.map { $0.label }

        XCTAssertEqual(labels, [
            "Pressure",
            "Current CPU",
            "Rolling Average",
            "Session Average",
            "Session Peak",
            "Pre-ON Baseline",
            "Change from Baseline"
        ])
        XCTAssertEqual(value("Current CPU", in: viewModel), "22.4%")
        XCTAssertEqual(value("Rolling Average", in: viewModel), "18.7%")
        XCTAssertEqual(value("Session Average", in: viewModel), "17.9%")
        XCTAssertEqual(value("Change from Baseline", in: viewModel), "+7.9 percentage points")
    }

    func testUnavailableGraphicsValuesNeverRenderAsZero() {
        var graphics = WindowServerSessionAggregate()
        graphics.currentPressure = .unavailable

        let viewModel = presenter().makeViewModel(from: .init(
            content: .active(record(graphics: graphics)),
            warningMessage: nil
        ))

        XCTAssertEqual(value("Pressure", in: viewModel), "Unavailable")
        XCTAssertEqual(value("Current CPU", in: viewModel), "Unavailable")
        XCTAssertEqual(value("Rolling Average", in: viewModel), "Unavailable")
        XCTAssertFalse(viewModel.graphicsRows.contains(where: { $0.current == "0.0%" }))
    }

    func testElevatedAdvisoryUsesApprovedCausalNeutralCopy() {
        var graphics = WindowServerSessionAggregate()
        graphics.baseline = WindowServerBaselineSummary(averageCPU: 10, peakCPU: 12, validSampleCount: 3)
        graphics.currentPressure = .elevated
        graphics.maximumSustainedPressure = .elevated

        let viewModel = presenter().makeViewModel(from: .init(
            content: .active(record(graphics: graphics)),
            warningMessage: nil
        ))

        XCTAssertEqual(
            viewModel.graphicsAdvisoryText,
            "WindowServer load was elevated during this session. No additional graphics changes were made automatically."
        )
        XCTAssertFalse(viewModel.graphicsAdvisoryText?.contains("Visual Performance reduced") ?? false)
    }

    func testElevatedBaselineTakesAdvisoryPrecedence() {
        var graphics = WindowServerSessionAggregate()
        graphics.baseline = WindowServerBaselineSummary(averageCPU: 16, peakCPU: 20, validSampleCount: 3)
        graphics.currentPressure = .high
        graphics.maximumSustainedPressure = .high

        let viewModel = presenter().makeViewModel(from: .init(
            content: .active(record(graphics: graphics)),
            warningMessage: nil
        ))

        XCTAssertEqual(
            viewModel.graphicsAdvisoryText,
            "Graphics pressure was elevated before Performance Mode started."
        )
    }

    func testCompletedGraphicsRowsExposeBaselineActiveRestoreAndTimeInState() {
        var graphics = WindowServerSessionAggregate()
        graphics.baseline = WindowServerBaselineSummary(averageCPU: 9, peakCPU: 13, validSampleCount: 3)
        graphics.activeRunningSum = 40
        graphics.validActiveSampleCount = 2
        graphics.activePeakCPU = 30
        graphics.maximumSustainedPressure = .high
        graphics.normalSeconds = 12
        graphics.elevatedSeconds = 8
        graphics.highSeconds = 4
        graphics.finalPreRestoreCPU = 18
        graphics.postRestoreCPU = 11
        graphics.visualPerformanceActive = true
        graphics.visualPerformanceRestorationSucceeded = true

        let viewModel = presenter().makeViewModel(from: .init(
            content: .completed(report(graphics: graphics)),
            warningMessage: nil
        ))

        XCTAssertEqual(value("Maximum Pressure", in: viewModel), "High")
        XCTAssertEqual(value("Baseline Average", in: viewModel), "9.0%")
        XCTAssertEqual(value("Baseline Peak", in: viewModel), "13.0%")
        XCTAssertEqual(value("Session Average", in: viewModel), "20.0%")
        XCTAssertEqual(value("Session Peak", in: viewModel), "30.0%")
        XCTAssertEqual(value("Final Pre-Restore", in: viewModel), "18.0%")
        XCTAssertEqual(value("Post-Restore", in: viewModel), "11.0%")
        XCTAssertEqual(value("Time Normal", in: viewModel), "12s")
        XCTAssertEqual(value("Time Elevated", in: viewModel), "8s")
        XCTAssertEqual(value("Time High", in: viewModel), "4s")
        XCTAssertFalse(viewModel.graphicsRows.contains(where: { $0.label.hasPrefix("Visual Performance") }))
    }

    private func presenter() -> SessionDashboardPresenter {
        SessionDashboardPresenter(nowProvider: { self.date(20) })
    }

    private func value(_ label: String, in viewModel: SessionDashboardViewModel) -> String? {
        viewModel.graphicsRows.first(where: { $0.label == label })?.current
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
