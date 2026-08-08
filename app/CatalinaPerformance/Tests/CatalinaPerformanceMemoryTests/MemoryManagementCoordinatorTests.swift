import XCTest
import CatalinaPerformancePriorityCore
@testable import CatalinaPerformanceMemoryCore

final class MemoryManagementCoordinatorTests: XCTestCase {
    private let baseDate = Date(timeIntervalSince1970: 1_000)
    private let mib: UInt64 = 1_048_576

    func testHighPressureIsReportedWithoutIntervention() throws {
        let coordinator = MemoryManagementCoordinator()
        _ = try coordinator.prepareSession(identifier: "session", at: baseDate)

        _ = coordinator.evaluate(telemetry: highTelemetry(second: 0))
        _ = coordinator.evaluate(telemetry: highTelemetry(second: 2))
        let status = coordinator.evaluate(telemetry: highTelemetry(second: 4))

        XCTAssertEqual(status.pressureState, .high)
        XCTAssertFalse(status.interventionActive)
        XCTAssertEqual(status.managedFamilyCount, 0)
        XCTAssertEqual(status.managedFamilyNames, [])
        XCTAssertEqual(status.ioPolicyStatus, .unsupported)
        XCTAssertTrue(status.note?.localizedCaseInsensitiveContains("read-only") == true)
    }

    func testForegroundAndAppPriorityUpdatesNeverCreateManagedWorkloads() throws {
        let coordinator = MemoryManagementCoordinator()
        _ = try coordinator.prepareSession(identifier: "session", at: baseDate)
        let application = AppPriorityApplication(
            displayName: "Example",
            bundleIdentifier: "test.example",
            bundlePath: "/Applications/Example.app",
            executablePath: "/Applications/Example.app/Contents/MacOS/Example"
        )

        let foreground = coordinator.updateFrontmostApplication(application, at: baseDate)
        let priority = coordinator.updateAppPriorityApplication(application, at: baseDate)

        XCTAssertFalse(foreground.interventionActive)
        XCTAssertEqual(foreground.managedFamilyCount, 0)
        XCTAssertFalse(priority.interventionActive)
        XCTAssertEqual(priority.managedFamilyCount, 0)
    }

    func testRestoreRequestIsReadOnlyNoOp() throws {
        let coordinator = MemoryManagementCoordinator()
        _ = try coordinator.prepareSession(identifier: "session", at: baseDate)
        let status = coordinator.requestImmediateRestore(at: baseDate.addingTimeInterval(2))

        XCTAssertFalse(status.interventionActive)
        XCTAssertEqual(status.managedFamilyCount, 0)
        XCTAssertTrue(status.note?.localizedCaseInsensitiveContains("no restoration is required") == true)
    }

    func testUnavailableTelemetryRemainsReadOnlyAndDoesNotFabricatePressure() throws {
        let coordinator = MemoryManagementCoordinator()
        _ = try coordinator.prepareSession(identifier: "session", at: baseDate)
        let telemetry = MemoryTelemetrySnapshot(
            capturedAt: baseDate.addingTimeInterval(2),
            counters: nil,
            rates: .unavailable,
            note: "VM counters unavailable"
        )

        let status = coordinator.evaluate(telemetry: telemetry)

        XCTAssertEqual(status.pressureState, .healthy)
        XCTAssertFalse(status.interventionActive)
        XCTAssertEqual(status.managedFamilyCount, 0)
        XCTAssertEqual(status.telemetry, telemetry)
        XCTAssertTrue(status.note?.contains("VM counters unavailable") == true)
    }

    private func highTelemetry(second: Int) -> MemoryTelemetrySnapshot {
        let physical: UInt64 = 4_294_967_296
        return MemoryTelemetrySnapshot(
            capturedAt: baseDate.addingTimeInterval(TimeInterval(second)),
            counters: MemoryVMCounters(
                physicalBytes: physical,
                availableBytes: UInt64(Double(physical) * 0.07),
                compressedBytes: UInt64(Double(physical) * 0.24),
                swapUsedBytes: 128 * mib,
                compressions: 1,
                decompressions: 1,
                pageIns: 1,
                pageOuts: 1,
                swapIns: 1,
                swapOuts: 1,
                pageSizeBytes: 4096
            ),
            rates: MemoryTelemetryRates(
                compressionBytesPerSecond: 4096,
                swapGrowthBytesPerSecond: nil,
                swapInBytesPerSecond: 0,
                swapOutBytesPerSecond: 4096,
                pageOutsPerSecond: 1
            ),
            note: nil
        )
    }
}
