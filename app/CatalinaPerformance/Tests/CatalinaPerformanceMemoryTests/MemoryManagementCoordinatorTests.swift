import XCTest
import CatalinaPerformancePriorityCore
@testable import CatalinaPerformanceMemoryCore

final class MemoryManagementCoordinatorTests: XCTestCase {
    private let uid: UInt32 = 501
    private let baseDate = Date(timeIntervalSince1970: 1_000)
    private let mib: UInt64 = 1_048_576

    func testPrepareSessionWritesEmptyDesiredStateBeforeAgentStart() throws {
        let harness = makeHarness()

        let status = try harness.coordinator.prepareSession(identifier: "session", at: baseDate)

        XCTAssertEqual(harness.store.saved.last?.sessionIdentifier, "session")
        XCTAssertEqual(harness.store.saved.last?.generation, 1)
        XCTAssertEqual(harness.store.saved.last?.families.count, 0)
        XCTAssertEqual(harness.store.saved.last?.shouldStopAndRestore, false)
        XCTAssertFalse(status.interventionActive)
    }

    func testThreeHighSamplesAdmitVerifiedBackgroundFamily() throws {
        let harness = makeHarness()
        try harness.coordinator.prepareSession(identifier: "session", at: baseDate)
        harness.coordinator.updateFrontmostApplication(otherApplication(), at: baseDate)

        _ = harness.coordinator.evaluate(telemetry: highTelemetry(second: 0))
        _ = harness.coordinator.evaluate(telemetry: highTelemetry(second: 2))
        let third = harness.coordinator.evaluate(telemetry: highTelemetry(second: 4))

        XCTAssertEqual(third.pressureState, .high)
        XCTAssertTrue(third.interventionActive)
        XCTAssertEqual(third.managedFamilyNames, ["Browser"])
        XCTAssertEqual(harness.store.saved.last?.families.count, 1)
        XCTAssertEqual(harness.store.saved.last?.families.first?.processes.first?.requestedNiceValue, 5)
    }

    func testTwoCriticalSamplesConfirmCriticalAfterBackgroundHistoryExists() throws {
        let harness = makeHarness()
        try harness.coordinator.prepareSession(identifier: "session", at: baseDate)
        harness.coordinator.updateFrontmostApplication(otherApplication(), at: baseDate)

        _ = harness.coordinator.evaluate(telemetry: healthyTelemetry(second: 0))
        _ = harness.coordinator.evaluate(telemetry: criticalTelemetry(second: 2))
        let second = harness.coordinator.evaluate(telemetry: criticalTelemetry(second: 4))

        XCTAssertEqual(second.pressureState, .critical)
        XCTAssertTrue(second.interventionActive)
        XCTAssertEqual(second.managedFamilyNames, ["Browser"])
    }

    func testFiveHealthySamplesRestoreDesiredFamilies() throws {
        let harness = makeHarness()
        try harness.coordinator.prepareSession(identifier: "session", at: baseDate)
        harness.coordinator.updateFrontmostApplication(otherApplication(), at: baseDate)
        _ = harness.coordinator.evaluate(telemetry: highTelemetry(second: 0))
        _ = harness.coordinator.evaluate(telemetry: highTelemetry(second: 2))
        _ = harness.coordinator.evaluate(telemetry: highTelemetry(second: 4))

        var status: MemoryManagementStatusSnapshot?
        for index in 0..<5 {
            status = harness.coordinator.evaluate(telemetry: healthyTelemetry(second: 6 + index * 2))
        }

        XCTAssertEqual(status?.interventionActive, false)
        XCTAssertEqual(harness.store.saved.last?.families.count, 0)
        XCTAssertEqual(harness.store.saved.last?.shouldStopAndRestore, false)
    }

    func testFrontmostFamilyIsRemovedImmediately() throws {
        let harness = makeHarness()
        try activate(harness)

        let status = harness.coordinator.updateFrontmostApplication(browserApplication(), at: baseDate.addingTimeInterval(8))

        XCTAssertFalse(status.interventionActive)
        XCTAssertEqual(harness.store.saved.last?.families.count, 0)
    }

    func testAppPriorityFamilyIsRemovedImmediately() throws {
        let harness = makeHarness()
        try activate(harness)

        let status = harness.coordinator.updateAppPriorityApplication(browserApplication(), at: baseDate.addingTimeInterval(8))

        XCTAssertFalse(status.interventionActive)
        XCTAssertEqual(harness.store.saved.last?.families.count, 0)
    }

    func testUnavailableTelemetryConservativelyRemovesDesiredFamilies() throws {
        let harness = makeHarness()
        try activate(harness)
        let unavailable = MemoryTelemetrySnapshot(
            capturedAt: baseDate.addingTimeInterval(8),
            counters: nil,
            rates: .unavailable,
            note: "unavailable"
        )

        let status = harness.coordinator.evaluate(telemetry: unavailable)

        XCTAssertFalse(status.interventionActive)
        XCTAssertEqual(harness.store.saved.last?.families.count, 0)
        XCTAssertTrue(status.note?.contains("unavailable") == true)
    }

    func testImmediateRestoreWritesStopAndRestoreState() throws {
        let harness = makeHarness()
        try activate(harness)

        let status = harness.coordinator.requestImmediateRestore(at: baseDate.addingTimeInterval(8))

        XCTAssertFalse(status.interventionActive)
        XCTAssertEqual(harness.store.saved.last?.families.count, 0)
        XCTAssertEqual(harness.store.saved.last?.shouldStopAndRestore, true)
    }

    func testBackgroundServiceRecheckRunsOnlyWhenInterventionFirstActivates() throws {
        var recheckCount = 0
        let harness = makeHarness(backgroundServiceRecheck: { recheckCount += 1 })
        try harness.coordinator.prepareSession(identifier: "session", at: baseDate)
        harness.coordinator.updateFrontmostApplication(otherApplication(), at: baseDate)

        _ = harness.coordinator.evaluate(telemetry: highTelemetry(second: 0))
        _ = harness.coordinator.evaluate(telemetry: highTelemetry(second: 2))
        _ = harness.coordinator.evaluate(telemetry: highTelemetry(second: 4))
        _ = harness.coordinator.evaluate(telemetry: highTelemetry(second: 6))

        XCTAssertEqual(recheckCount, 1)
    }

    private func activate(_ harness: CoordinatorHarness) throws {
        try harness.coordinator.prepareSession(identifier: "session", at: baseDate)
        harness.coordinator.updateFrontmostApplication(otherApplication(), at: baseDate)
        _ = harness.coordinator.evaluate(telemetry: highTelemetry(second: 0))
        _ = harness.coordinator.evaluate(telemetry: highTelemetry(second: 2))
        _ = harness.coordinator.evaluate(telemetry: highTelemetry(second: 4))
        XCTAssertTrue(harness.store.saved.last?.families.isEmpty == false)
    }

    private func makeHarness(backgroundServiceRecheck: @escaping () -> Void = {}) -> CoordinatorHarness {
        let browser = process(pid: 10, path: "/Applications/Browser.app/Contents/MacOS/Browser", name: "Browser")
        let inspector = CoordinatorProcessInspector(values: [10: browser])
        let resources = CoordinatorResourceInspector(values: [10: 300 * mib])
        let store = CoordinatorDesiredStore()
        let coordinator = MemoryManagementCoordinator(
            desiredStateStore: store,
            processInspector: inspector,
            resourceInspector: resources,
            requestingUID: uid,
            backgroundServiceRecheck: backgroundServiceRecheck
        )
        return CoordinatorHarness(
            coordinator: coordinator,
            store: store,
            inspector: inspector,
            resources: resources
        )
    }

    private func process(pid: Int32, path: String, name: String) -> AppPriorityProcessIdentity {
        return AppPriorityProcessIdentity(
            pid: pid,
            parentPID: 1,
            effectiveUID: uid,
            executablePath: path,
            startSeconds: Int64(pid) * 10,
            startMicroseconds: 0,
            processName: name,
            niceValue: 0
        )
    }

    private func browserApplication() -> AppPriorityApplication {
        return AppPriorityApplication(
            displayName: "Browser",
            bundleIdentifier: "test.browser",
            bundlePath: "/Applications/Browser.app",
            executablePath: "/Applications/Browser.app/Contents/MacOS/Browser"
        )
    }

    private func otherApplication() -> AppPriorityApplication {
        return AppPriorityApplication(
            displayName: "Other",
            bundleIdentifier: "test.other",
            bundlePath: "/Applications/Other.app",
            executablePath: "/Applications/Other.app/Contents/MacOS/Other"
        )
    }

    private func healthyTelemetry(second: Int) -> MemoryTelemetrySnapshot {
        return telemetry(
            second: second,
            availableFraction: 0.40,
            compressedFraction: 0.10,
            compressionRate: 0,
            swapOutRate: 0,
            pageOutRate: 0
        )
    }

    private func highTelemetry(second: Int) -> MemoryTelemetrySnapshot {
        return telemetry(
            second: second,
            availableFraction: 0.07,
            compressedFraction: 0.24,
            compressionRate: 4096,
            swapOutRate: 4096,
            pageOutRate: 1
        )
    }

    private func criticalTelemetry(second: Int) -> MemoryTelemetrySnapshot {
        return telemetry(
            second: second,
            availableFraction: 0.04,
            compressedFraction: 0.32,
            compressionRate: 8192,
            swapOutRate: 8192,
            pageOutRate: 2
        )
    }

    private func telemetry(
        second: Int,
        availableFraction: Double,
        compressedFraction: Double,
        compressionRate: Double,
        swapOutRate: Double,
        pageOutRate: Double
    ) -> MemoryTelemetrySnapshot {
        let physical: UInt64 = 4_294_967_296
        let counters = MemoryVMCounters(
            physicalBytes: physical,
            availableBytes: UInt64(Double(physical) * availableFraction),
            compressedBytes: UInt64(Double(physical) * compressedFraction),
            swapUsedBytes: 128 * mib,
            compressions: 1,
            decompressions: 1,
            pageIns: 1,
            pageOuts: 1,
            swapIns: 1,
            swapOuts: 1,
            pageSizeBytes: 4096
        )
        return MemoryTelemetrySnapshot(
            capturedAt: baseDate.addingTimeInterval(TimeInterval(second)),
            counters: counters,
            rates: MemoryTelemetryRates(
                compressionBytesPerSecond: compressionRate,
                swapGrowthBytesPerSecond: nil,
                swapInBytesPerSecond: 0,
                swapOutBytesPerSecond: swapOutRate,
                pageOutsPerSecond: pageOutRate
            ),
            note: nil
        )
    }
}

private struct CoordinatorHarness {
    let coordinator: MemoryManagementCoordinator
    let store: CoordinatorDesiredStore
    let inspector: CoordinatorProcessInspector
    let resources: CoordinatorResourceInspector
}

private final class CoordinatorDesiredStore: MemoryDesiredStateStoring {
    var saved: [MemoryDesiredState] = []

    func load() throws -> MemoryDesiredState? {
        return saved.last
    }

    func save(_ state: MemoryDesiredState) throws {
        saved.append(state)
    }

    func remove() throws {
        saved.removeAll()
    }
}

private final class CoordinatorProcessInspector: AppPriorityProcessInspecting {
    var values: [Int32: AppPriorityProcessIdentity]

    init(values: [Int32: AppPriorityProcessIdentity]) {
        self.values = values
    }

    func allProcesses() throws -> [AppPriorityProcessIdentity] {
        return Array(values.values)
    }

    func process(pid: Int32) throws -> AppPriorityProcessIdentity {
        guard let value = values[pid] else {
            throw AppPriorityProcessError.readFailed(pid: pid, code: -3)
        }
        return value
    }
}

private final class CoordinatorResourceInspector: AppPriorityProcessResourceInspecting {
    var values: [Int32: UInt64]

    init(values: [Int32: UInt64]) {
        self.values = values
    }

    func residentBytes(pid: Int32) throws -> UInt64 {
        return values[pid] ?? 0
    }
}
