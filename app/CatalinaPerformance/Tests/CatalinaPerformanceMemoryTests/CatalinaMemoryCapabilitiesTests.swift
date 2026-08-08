import XCTest
@testable import CatalinaPerformanceMemoryCore

final class CatalinaMemoryCapabilitiesTests: XCTestCase {
    func testCatalina10157CapabilitiesMatchReviewedProbe() {
        let capabilities = CatalinaMemoryCapabilities.current

        XCTAssertTrue(capabilities.compressedBytes)
        XCTAssertTrue(capabilities.compressionCounters)
        XCTAssertTrue(capabilities.pageOutCounters)
        XCTAssertTrue(capabilities.swapInOutCounters)
        XCTAssertFalse(capabilities.nativePressureState)
        XCTAssertFalse(capabilities.taskPolicy)
    }

    func testCatalina10157FixedPercentageThresholds() {
        let profile = MemoryPressureThresholds.catalina10157

        XCTAssertEqual(profile.availableModerateFraction, 0.15)
        XCTAssertEqual(profile.availableStrongFraction, 0.08)
        XCTAssertEqual(profile.availableSevereFraction, 0.05)
        XCTAssertEqual(profile.compressedModerateFraction, 0.20)
        XCTAssertEqual(profile.compressedStrongFraction, 0.30)
    }

    func testCatalina10157RateThresholdsReflectProbeEvidence() {
        let profile = MemoryPressureThresholds.catalina10157

        XCTAssertEqual(profile.compressionActivityBytesPerSecond, 0.0)
        XCTAssertEqual(profile.swapOutActivityBytesPerSecond, 0.0)
        XCTAssertEqual(profile.pageOutActivityPagesPerSecond, 0.0)
        XCTAssertNil(profile.swapGrowthBytesPerSecond)
        XCTAssertNil(profile.swapChurnBytesPerSecond)
    }
}
