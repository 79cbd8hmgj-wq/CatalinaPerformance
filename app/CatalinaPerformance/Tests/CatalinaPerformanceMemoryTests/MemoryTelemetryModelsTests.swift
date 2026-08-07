import XCTest
@testable import CatalinaPerformanceMemoryCore

final class MemoryTelemetryModelsTests: XCTestCase {
    func testMemoryPressureStateOrdersBySeverity() {
        XCTAssertLessThan(MemoryPressureState.healthy, .elevated)
        XCTAssertLessThan(MemoryPressureState.elevated, .high)
        XCTAssertLessThan(MemoryPressureState.high, .critical)
    }

    func testUnavailableRateRemainsNil() {
        let rates = MemoryTelemetryRates(
            compressionBytesPerSecond: nil,
            swapGrowthBytesPerSecond: nil,
            swapInBytesPerSecond: nil,
            swapOutBytesPerSecond: nil,
            pageOutsPerSecond: nil
        )
        XCTAssertNil(rates.swapOutBytesPerSecond)
    }

    func testUnsupportedCountersRemainNilInsteadOfUsingSentinelZero() {
        let counters = MemoryVMCounters(
            physicalBytes: 8_589_934_592,
            availableBytes: 2_147_483_648,
            compressedBytes: nil,
            swapUsedBytes: 0,
            compressions: nil,
            decompressions: nil,
            pageIns: nil,
            pageOuts: nil,
            swapIns: nil,
            swapOuts: nil,
            pageSizeBytes: 4096
        )

        XCTAssertNil(counters.compressedBytes)
        XCTAssertNil(counters.swapOuts)
        XCTAssertEqual(counters.swapUsedBytes, 0)
    }

    func testStatusSnapshotPreservesManagementState() {
        let date = Date(timeIntervalSince1970: 100)
        let status = MemoryManagementStatusSnapshot(
            capturedAt: date,
            pressureState: .high,
            managedFamilyCount: 2,
            managedFamilyNames: ["Browser", "Editor"],
            interventionActive: true,
            ioPolicyStatus: .unsupported,
            note: "CPU deprioritization active."
        )

        XCTAssertEqual(status.pressureState, .high)
        XCTAssertEqual(status.managedFamilyCount, 2)
        XCTAssertTrue(status.interventionActive)
        XCTAssertEqual(status.ioPolicyStatus, .unsupported)
    }
}
