import XCTest
@testable import CatalinaPerformanceDashboardCore

final class BackgroundServiceDashboardTests: XCTestCase {
    private func date(_ seconds: TimeInterval) -> Date {
        return Date(timeIntervalSince1970: seconds)
    }

    func testPresentationDisplaysEveryCategoryLabelAndExactStateText() {
        let statuses = [
            status(category: "softwareUpdate", state: "notConfigured", note: nil),
            status(category: "appStoreUpdates", state: "unsupported", note: nil),
            status(category: "photos", state: "skipped", note: nil),
            status(category: "mail", state: "paused", note: nil),
            status(category: "messagesFaceTime", state: "resumedByUser", note: "user opened Photos"),
            status(category: "siriSpeech", state: "restored", note: nil),
            status(category: "iCloudDrive", state: "restoreFailed", note: nil)
        ]
        let record = activeRecord(backgroundStatuses: statuses)
        let viewModel = SessionDashboardPresenter(nowProvider: { self.date(5) }).makeViewModel(
            from: PerformanceSessionCoordinatorState(content: .active(record), warningMessage: nil)
        )

        XCTAssertEqual(row("macOS Updates", in: viewModel)?.current, "Not configured")
        XCTAssertEqual(row("App Store Updates", in: viewModel)?.current, "Unsupported")
        XCTAssertEqual(row("Photos Workers", in: viewModel)?.current, "Skipped")
        XCTAssertEqual(row("Mail Workers", in: viewModel)?.current, "Paused")
        XCTAssertEqual(row("Messages / FaceTime Workers", in: viewModel)?.current, "Resumed — user opened Photos")
        XCTAssertEqual(row("Siri / Speech Workers", in: viewModel)?.current, "Restored")
        XCTAssertEqual(row("iCloud Drive", in: viewModel)?.current, "Restore failed")
    }

    func testMissingCategoryEvidenceDisplaysUnknownNotRestored() {
        let record = activeRecord(backgroundStatuses: nil)
        let viewModel = SessionDashboardPresenter(nowProvider: { self.date(5) }).makeViewModel(
            from: PerformanceSessionCoordinatorState(content: .active(record), warningMessage: nil)
        )

        let labels = [
            "macOS Updates",
            "App Store Updates",
            "Photos Workers",
            "Mail Workers",
            "Messages / FaceTime Workers",
            "Siri / Speech Workers",
            "iCloud Drive"
        ]
        for label in labels {
            XCTAssertEqual(row(label, in: viewModel)?.current, "Unknown")
        }
    }

    func testBackgroundStatusReplacementDoesNotChangeMetricAggregates() {
        let recorder = PerformanceSessionRecorder()
        let snapshot = metricSnapshot()
        recorder.begin(identifier: "background", startedAt: date(0), baseline: snapshot, selectedApplication: nil)
        recorder.record(sample: snapshot)
        let before = recorder.activeRecord()?.aggregates

        recorder.replaceBackgroundServiceStatuses([
            status(category: "photos", state: "paused", note: "Verified workers paused.")
        ])

        XCTAssertEqual(recorder.activeRecord()?.aggregates, before)
        XCTAssertEqual(recorder.activeRecord()?.backgroundServiceStatuses?.first?.categoryRawValue, "photos")
    }

    func testLegacyRecordWithoutBackgroundStatusesDecodesWithNil() throws {
        let record = activeRecord(backgroundStatuses: nil)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try JSONSerialization.jsonObject(with: encoder.encode(record)) as! [String: Any]
        object.removeValue(forKey: "backgroundServiceStatuses")
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(PerformanceSessionRecord.self, from: data)
        XCTAssertNil(decoded.backgroundServiceStatuses)
    }

    func testAggregateStatusIsConservative() {
        let now = date(10)
        let applied = BackgroundServiceDashboardSummary.status(for: [
            status(category: "photos", state: "paused", note: nil),
            status(category: "mail", state: "resumedByUser", note: "user opened Mail")
        ], at: now)
        XCTAssertEqual(applied.state, .applied)

        let appliedWithUnsupported = BackgroundServiceDashboardSummary.status(for: [
            status(category: "photos", state: "paused", note: nil),
            status(category: "siriSpeech", state: "unsupported", note: nil),
            status(category: "iCloudDrive", state: "notConfigured", note: nil)
        ], at: now)
        XCTAssertEqual(appliedWithUnsupported.state, .applied)

        let restored = BackgroundServiceDashboardSummary.status(for: [
            status(category: "photos", state: "restored", note: nil),
            status(category: "mail", state: "resumedByUser", note: "user opened Mail")
        ], at: now)
        XCTAssertEqual(restored.state, .restored)

        let partialRestore = BackgroundServiceDashboardSummary.status(for: [
            status(category: "photos", state: "restored", note: nil),
            status(category: "mail", state: "restoreFailed", note: nil)
        ], at: now)
        XCTAssertEqual(partialRestore.state, .partiallyRestored)
    }

    private func status(category: String, state: String, note: String?) -> BackgroundServiceDashboardCategoryStatus {
        return BackgroundServiceDashboardCategoryStatus(
            categoryRawValue: category,
            stateRawValue: state,
            note: note,
            updatedAt: date(1)
        )
    }

    private func row(_ label: String, in viewModel: SessionDashboardViewModel) -> SessionDashboardMetricRow? {
        return viewModel.subsystemRows.first { $0.label == label }
    }

    private func activeRecord(backgroundStatuses: [BackgroundServiceDashboardCategoryStatus]?) -> PerformanceSessionRecord {
        let snapshot = metricSnapshot()
        return PerformanceSessionRecord(
            sessionIdentifier: "background",
            phase: .active,
            startedAt: date(0),
            completedAt: nil,
            selectedApplication: nil,
            baseline: snapshot,
            latest: snapshot,
            finalPreRestore: nil,
            postRestore: nil,
            aggregates: SessionMetricAggregates(),
            sampleCount: 0,
            subsystemStatuses: [],
            backgroundServiceStatuses: backgroundStatuses,
            monitoringGaps: [],
            metricErrors: [],
            completionReason: nil
        )
    }

    private func metricSnapshot() -> SessionMetricSnapshot {
        let now = date(1)
        return SessionMetricSnapshot.unavailable(capturedAt: now, note: "test")
    }
}
