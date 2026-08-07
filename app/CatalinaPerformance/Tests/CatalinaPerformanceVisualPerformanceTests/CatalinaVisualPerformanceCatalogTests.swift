import XCTest
@testable import CatalinaPerformanceVisualPerformanceCore

final class CatalinaVisualPerformanceCatalogTests: XCTestCase {
    func testCatalogUsesStableAutomaticOrder() {
        XCTAssertEqual(
            CatalinaVisualPerformanceCatalog.current.entries.map { $0.id },
            VisualSettingID.automaticOrder
        )
    }

    func testCatalogContainsApprovedValues() {
        let catalog = CatalinaVisualPerformanceCatalog.current
        XCTAssertEqual(catalog[.finderAnimations]?.appliedValue, .boolean(true))
        XCTAssertEqual(catalog[.dockLaunchAnimation]?.appliedValue, .boolean(false))
        XCTAssertEqual(catalog[.missionControlTransitions]?.appliedValue, .floatingPoint(0.1))
        XCTAssertEqual(catalog[.windowOpeningAnimations]?.appliedValue, .boolean(false))
        XCTAssertEqual(catalog[.reduceMotion]?.appliedValue, .boolean(true))
        XCTAssertEqual(catalog[.reduceTransparency]?.appliedValue, .boolean(true))
        XCTAssertEqual(catalog[.minimizeEffect]?.appliedValue, .string("scale"))
        XCTAssertEqual(catalog[.dockAutoHideDelay]?.appliedValue, .floatingPoint(0))
        XCTAssertEqual(catalog[.dockAutoHideAnimation]?.appliedValue, .floatingPoint(0))
    }

    func testConditionalDockSettingsRequireAutoHide() {
        let catalog = CatalinaVisualPerformanceCatalog.current
        XCTAssertEqual(catalog[.dockAutoHideDelay]?.applicability, .dockAutoHideEnabled)
        XCTAssertEqual(catalog[.dockAutoHideAnimation]?.applicability, .dockAutoHideEnabled)
    }

    func testCatalogContainsNoWildcardsOrUnknownSettings() {
        let catalog = CatalinaVisualPerformanceCatalog.current
        XCTAssertEqual(Set(catalog.entries.map { $0.id }), Set(VisualSettingID.automaticOrder))
        for entry in catalog.entries {
            XCTAssertFalse(entry.domain.contains("*"))
            XCTAssertFalse(entry.key.contains("*"))
            XCTAssertFalse(entry.domain.isEmpty)
            XCTAssertFalse(entry.key.isEmpty)
        }
    }
}
