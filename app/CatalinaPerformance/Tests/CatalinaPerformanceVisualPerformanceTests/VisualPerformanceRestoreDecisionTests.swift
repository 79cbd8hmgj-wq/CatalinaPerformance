import XCTest
@testable import CatalinaPerformanceVisualPerformanceCore

final class VisualPerformanceRestoreDecisionTests: XCTestCase {
    func testBooleanRepresentationsNormalize() {
        XCTAssertEqual(VisualScalarNormalizer.boolean(from: "1"), true)
        XCTAssertEqual(VisualScalarNormalizer.boolean(from: "true"), true)
        XCTAssertEqual(VisualScalarNormalizer.boolean(from: "YES"), true)
        XCTAssertEqual(VisualScalarNormalizer.boolean(from: "0"), false)
        XCTAssertEqual(VisualScalarNormalizer.boolean(from: "false"), false)
        XCTAssertEqual(VisualScalarNormalizer.boolean(from: " no "), false)
        XCTAssertNil(VisualScalarNormalizer.boolean(from: "enabled"))
    }

    func testIntegerAndFloatingPointNormalizationRejectsInvalidValues() {
        XCTAssertEqual(VisualScalarNormalizer.integer(from: " -12 "), -12)
        XCTAssertNil(VisualScalarNormalizer.integer(from: "1.5"))
        XCTAssertEqual(VisualScalarNormalizer.floatingPoint(from: "0.1"), 0.1)
        XCTAssertNil(VisualScalarNormalizer.floatingPoint(from: "nan"))
        XCTAssertNil(VisualScalarNormalizer.floatingPoint(from: "inf"))
        XCTAssertNil(VisualScalarNormalizer.floatingPoint(from: "-infinity"))
    }

    func testTypedNormalizationBuildsExpectedScalarValue() {
        XCTAssertEqual(
            VisualScalarNormalizer.value(from: "true", expectedType: .boolean),
            .boolean(true)
        )
        XCTAssertEqual(
            VisualScalarNormalizer.value(from: "7", expectedType: .integer),
            .integer(7)
        )
        XCTAssertEqual(
            VisualScalarNormalizer.value(from: "0.25", expectedType: .floatingPoint),
            .floatingPoint(0.25)
        )
        XCTAssertEqual(
            VisualScalarNormalizer.value(from: " scale ", expectedType: .string),
            .string("scale")
        )
    }

    func testMatchingAppliedValueRestoresPrior() {
        let record = VisualSettingRecord.fixture(
            id: .reduceTransparency,
            prior: .boolean(false),
            applied: .boolean(true),
            outcome: .applied
        )
        XCTAssertEqual(
            VisualRestoreDecision.decide(record: record, current: .present(.boolean(true))),
            .restorePrior(.boolean(false))
        )
    }

    func testMatchingAppliedValueDeletesPreviouslyAbsentKey() {
        let record = VisualSettingRecord.fixture(
            id: .windowOpeningAnimations,
            prior: nil,
            applied: .boolean(false),
            outcome: .applied
        )
        XCTAssertEqual(
            VisualRestoreDecision.decide(record: record, current: .present(.boolean(false))),
            .deletePreviouslyAbsent
        )
    }

    func testManualChangeIsPreserved() {
        let record = VisualSettingRecord.fixture(
            id: .minimizeEffect,
            prior: .string("genie"),
            applied: .string("scale"),
            outcome: .applied
        )
        XCTAssertEqual(
            VisualRestoreDecision.decide(record: record, current: .present(.string("suck"))),
            .preserveManualChange
        )
    }

    func testCurrentTypeChangeIsPreservedAsManualChange() {
        let record = VisualSettingRecord.fixture(
            id: .reduceMotion,
            prior: .boolean(false),
            applied: .boolean(true),
            outcome: .applied
        )
        XCTAssertEqual(
            VisualRestoreDecision.decide(record: record, current: .present(.integer(1))),
            .preserveManualChange
        )
        XCTAssertEqual(
            VisualRestoreDecision.decide(record: record, current: .unsupportedType("dictionary")),
            .preserveManualChange
        )
    }

    func testAbsentCurrentValueIsPreservedRatherThanRecreated() {
        let record = VisualSettingRecord.fixture(
            id: .dockLaunchAnimation,
            prior: .boolean(true),
            applied: .boolean(false),
            outcome: .applied
        )
        XCTAssertEqual(
            VisualRestoreDecision.decide(record: record, current: .absent),
            .preserveManualChange
        )
    }

    func testNonFiniteAppliedOrCurrentValueCannotBeComparedSafely() {
        let appliedNaN = VisualSettingRecord.fixture(
            id: .missionControlTransitions,
            prior: .floatingPoint(1.0),
            applied: .floatingPoint(Double.nan),
            outcome: .applied
        )
        switch VisualRestoreDecision.decide(
            record: appliedNaN,
            current: .present(.floatingPoint(Double.nan))
        ) {
        case .cannotSafelyDecide:
            break
        default:
            XCTFail("Expected non-finite values to be rejected")
        }

        let valid = VisualSettingRecord.fixture(
            id: .missionControlTransitions,
            prior: .floatingPoint(1.0),
            applied: .floatingPoint(0.1),
            outcome: .applied
        )
        switch VisualRestoreDecision.decide(
            record: valid,
            current: .present(.floatingPoint(Double.infinity))
        ) {
        case .cannotSafelyDecide:
            break
        default:
            XCTFail("Expected non-finite current values to be rejected")
        }
    }

    func testMissingAppliedOrPriorValueCannotBeDecided() {
        let missingApplied = VisualSettingRecord.fixture(
            id: .reduceMotion,
            prior: .boolean(false),
            applied: nil,
            outcome: .applied
        )
        XCTAssertCannotSafelyDecide(
            VisualRestoreDecision.decide(record: missingApplied, current: .present(.boolean(true)))
        )

        let inconsistentPrior = VisualSettingRecord(
            id: .reduceMotion,
            displayName: "Reduce Motion",
            priorWasPresent: true,
            priorValue: nil,
            appliedValue: .boolean(true),
            outcome: .applied,
            note: nil,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        XCTAssertCannotSafelyDecide(
            VisualRestoreDecision.decide(record: inconsistentPrior, current: .present(.boolean(true)))
        )
    }

    private func XCTAssertCannotSafelyDecide(
        _ disposition: VisualRestoreDisposition,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        switch disposition {
        case .cannotSafelyDecide:
            return
        default:
            XCTFail("Expected cannotSafelyDecide, got \(disposition)", file: file, line: line)
        }
    }
}

private extension VisualSettingRecord {
    static func fixture(
        id: VisualSettingID,
        prior: VisualScalarValue?,
        applied: VisualScalarValue?,
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
