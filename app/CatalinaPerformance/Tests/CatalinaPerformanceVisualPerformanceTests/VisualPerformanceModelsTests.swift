import XCTest
@testable import CatalinaPerformanceVisualPerformanceCore

final class VisualPerformanceModelsTests: XCTestCase {
    func testStableAutomaticSettingOrder() {
        XCTAssertEqual(VisualSettingID.automaticOrder, [
            .finderAnimations,
            .dockLaunchAnimation,
            .missionControlTransitions,
            .windowOpeningAnimations,
            .reduceMotion,
            .reduceTransparency,
            .minimizeEffect,
            .dockAutoHideDelay,
            .dockAutoHideAnimation
        ])
    }

    func testScalarValueRoundTripUsesStableDiscriminator() throws {
        let values: [VisualScalarValue] = [
            .boolean(true),
            .integer(42),
            .floatingPoint(0.1),
            .string("scale")
        ]

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(values)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"type\":\"boolean\""))
        XCTAssertTrue(json.contains("\"type\":\"integer\""))
        XCTAssertTrue(json.contains("\"type\":\"floatingPoint\""))
        XCTAssertTrue(json.contains("\"type\":\"string\""))

        let decoded = try JSONDecoder().decode([VisualScalarValue].self, from: data)
        XCTAssertEqual(decoded, values)
    }

    func testSessionAndSnapshotRoundTripThroughPublicInitializers() throws {
        let timestamp = Date(timeIntervalSince1970: 100)
        let record = VisualSettingRecord(
            id: .finderAnimations,
            displayName: "Finder animations",
            priorWasPresent: true,
            priorValue: .boolean(false),
            appliedValue: .boolean(true),
            outcome: .applied,
            note: nil,
            updatedAt: timestamp
        )
        let session = VisualPerformanceSessionRecord(
            sessionIdentifier: "visual-session",
            requestingUID: 501,
            startedAt: timestamp,
            completedAt: nil,
            settings: [record],
            aggregateStatus: .applied
        )
        let snapshot = VisualPerformanceStatusSnapshot(
            sessionIdentifier: session.sessionIdentifier,
            aggregateStatus: session.aggregateStatus,
            settings: [record],
            updatedAt: timestamp
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        XCTAssertEqual(
            try decoder.decode(VisualPerformanceSessionRecord.self, from: encoder.encode(session)),
            session
        )
        XCTAssertEqual(
            try decoder.decode(VisualPerformanceStatusSnapshot.self, from: encoder.encode(snapshot)),
            snapshot
        )
    }

    func testUnsupportedAndNotApplicableDoNotDegradeAppliedStatus() {
        let records = [
            VisualSettingRecord.fixture(id: .finderAnimations, outcome: .applied),
            VisualSettingRecord.fixture(id: .reduceMotion, outcome: .unsupported),
            VisualSettingRecord.fixture(id: .dockAutoHideDelay, outcome: .notApplicable)
        ]
        XCTAssertEqual(VisualPerformanceAggregateStatus.active(for: records), .applied)
    }

    func testManualChangeCountsAsSuccessfulCompletion() {
        let records = [
            VisualSettingRecord.fixture(id: .reduceTransparency, outcome: .preservedManualChange)
        ]
        XCTAssertEqual(VisualPerformanceAggregateStatus.completed(for: records), .successful)
    }

    func testOutstandingRestorationRecognizesAppliedAndRecoveryStates() {
        XCTAssertTrue(VisualPerformanceSessionRecord.fixture(settings: [
            VisualSettingRecord.fixture(id: .reduceMotion, outcome: .applied)
        ]).hasOutstandingRestoration)
        XCTAssertTrue(VisualPerformanceSessionRecord.fixture(settings: [
            VisualSettingRecord.fixture(id: .reduceMotion, outcome: .recoveryRequired)
        ]).hasOutstandingRestoration)
        XCTAssertFalse(VisualPerformanceSessionRecord.fixture(settings: [
            VisualSettingRecord.fixture(id: .reduceMotion, outcome: .restored)
        ]).hasOutstandingRestoration)
    }
}

private extension VisualSettingRecord {
    static func fixture(
        id: VisualSettingID,
        prior: VisualScalarValue? = .boolean(false),
        applied: VisualScalarValue? = .boolean(true),
        outcome: VisualSettingOutcome
    ) -> VisualSettingRecord {
        return VisualSettingRecord(
            id: id,
            displayName: id.rawValue,
            priorWasPresent: prior != nil,
            priorValue: prior,
            appliedValue: applied,
            outcome: outcome,
            note: nil,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
    }
}

private extension VisualPerformanceSessionRecord {
    static func fixture(settings: [VisualSettingRecord]) -> VisualPerformanceSessionRecord {
        return VisualPerformanceSessionRecord(
            sessionIdentifier: "fixture",
            requestingUID: 501,
            startedAt: Date(timeIntervalSince1970: 90),
            completedAt: nil,
            settings: settings,
            aggregateStatus: VisualPerformanceAggregateStatus.active(for: settings)
        )
    }
}
