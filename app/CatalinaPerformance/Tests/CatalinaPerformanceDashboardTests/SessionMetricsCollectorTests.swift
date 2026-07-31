import XCTest
import CatalinaPerformancePriorityCore
@testable import CatalinaPerformanceDashboardCore

final class SessionMetricsCollectorTests: XCTestCase {
    private func date(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    func testSecondHostCPUReadingCalculatesBusyPercentAcrossAllTicks() {
        let native = FakeNativeMetrics(hostTicks: [
            HostCPUTicks(user: 100, system: 50, idle: 850, nice: 0),
            HostCPUTicks(user: 140, system: 70, idle: 890, nice: 0)
        ])
        let collector = makeCollector(native: native)
        XCTAssertNil(collector.capture(at: date(0), refreshThermal: true).systemCPUPercent.value)
        XCTAssertEqual(collector.capture(at: date(2), refreshThermal: false).systemCPUPercent.value ?? -1, 60, accuracy: 0.001)
    }

    func testSelectedAppUsesVerifiedFamilyAndCanExceedOneHundredPercent() {
        let app = AppPriorityApplication(displayName: "Firefox", bundleIdentifier: "org.mozilla.firefox", bundlePath: "/Applications/Firefox.app", executablePath: "/Applications/Firefox.app/Contents/MacOS/firefox")
        let main = identity(pid: 10, parent: 1, path: app.executablePath, nice: -5)
        let child = identity(pid: 11, parent: 10, path: "/Applications/Firefox.app/Contents/Frameworks/helper", nice: -10)
        let unrelated = identity(pid: 12, parent: 1, path: "/usr/bin/other", nice: 0)
        let native = FakeNativeMetrics(hostTicks: [], processSequences: [
            10: [resource(pid: 10, cpu: 1_000_000_000), resource(pid: 10, cpu: 3_000_000_000)],
            11: [resource(pid: 11, cpu: 1_000_000_000), resource(pid: 11, cpu: 2_000_000_000)]
        ])
        let collector = makeCollector(native: native, selection: AppPrioritySelection(enabled: true, application: app), processes: [main, child, unrelated])
        _ = collector.capture(at: date(0), refreshThermal: true)
        let second = collector.capture(at: date(2), refreshThermal: false)
        XCTAssertEqual(second.selectedAppVerifiedProcessCount.value, 2)
        XCTAssertEqual(second.selectedAppPriorityConfirmedCount.value, 2)
        XCTAssertEqual(second.selectedAppCPUPercent.value ?? -1, 150, accuracy: 0.001)
    }

    func testDisabledSelectionIsUnsupportedNotZero() {
        let collector = makeCollector(native: FakeNativeMetrics(hostTicks: []), selection: AppPrioritySelection(enabled: false, application: nil))
        let snapshot = collector.capture(at: date(0), refreshThermal: true)
        XCTAssertEqual(snapshot.selectedAppCPUPercent.availability, .unsupported)
        XCTAssertEqual(snapshot.selectedAppCPUPercent.note, "App Priority is not configured.")
    }

    func testImpossibleZeroHostMemoryBecomesUnavailable() {
        let native = FakeNativeMetrics(
            hostTicks: [],
            hostMemorySample: HostMemorySample(physicalTotalBytes: 8_000, usedBytes: 0, availableBytes: 8_000)
        )
        let snapshot = makeCollector(native: native).capture(at: date(0), refreshThermal: true)
        XCTAssertEqual(snapshot.physicalMemoryUsedBytes.availability, .unavailable)
        XCTAssertNil(snapshot.physicalMemoryUsedBytes.value)
        XCTAssertEqual(snapshot.memoryPressure.availability, .unavailable)
    }

    func testSelectedAppMemoryIsUnavailableWhenAllVerifiedProcessesReportZeroResidentBytes() {
        let app = AppPriorityApplication(
            displayName: "Firefox",
            bundleIdentifier: "org.mozilla.firefox",
            bundlePath: "/Applications/Firefox.app",
            executablePath: "/Applications/Firefox.app/Contents/MacOS/firefox"
        )
        let main = identity(pid: 10, parent: 1, path: app.executablePath, nice: -5)
        let native = FakeNativeMetrics(
            hostTicks: [],
            processSequences: [10: [resource(pid: 10, cpu: 1_000_000_000, resident: 0)]]
        )
        let collector = makeCollector(
            native: native,
            selection: AppPrioritySelection(enabled: true, application: app),
            processes: [main]
        )
        let snapshot = collector.capture(at: date(0), refreshThermal: true)
        XCTAssertEqual(snapshot.selectedAppVerifiedProcessCount.value, 1)
        XCTAssertEqual(snapshot.selectedAppResidentBytes.availability, .unavailable)
        XCTAssertNil(snapshot.selectedAppResidentBytes.value)
    }

    func testThermalCacheBecomesStaleAfterFifteenSeconds() {
        let thermal = FakeThermalProvider()
        let collector = makeCollector(native: FakeNativeMetrics(hostTicks: []), thermal: thermal)
        _ = collector.capture(at: date(0), refreshThermal: true)
        XCTAssertEqual(collector.capture(at: date(8), refreshThermal: false).schedulerLimitPercent.availability, .available)
        XCTAssertEqual(collector.capture(at: date(16), refreshThermal: false).schedulerLimitPercent.availability, .stale)
        _ = collector.capture(at: date(20), refreshThermal: true)
        XCTAssertEqual(thermal.calls, 2)
    }

    private func makeCollector(
        native: FakeNativeMetrics,
        thermal: FakeThermalProvider = FakeThermalProvider(),
        selection: AppPrioritySelection = AppPrioritySelection(enabled: false, application: nil),
        processes: [AppPriorityProcessIdentity] = []
    ) -> SessionMetricsCollector {
        SessionMetricsCollector(
            nativeMetrics: native,
            thermalProvider: thermal,
            diskSpaceProvider: FakeDiskSpaceProvider(),
            selectionProvider: FakeSelectionProvider(selection: selection),
            statusProvider: FakeStatusProvider(),
            currentUserProvider: FakeUserProvider(uid: 501),
            processInspector: FakeProcessInspector(processes: processes)
        )
    }

    private func identity(pid: Int32, parent: Int32, path: String, nice: Int32) -> AppPriorityProcessIdentity {
        AppPriorityProcessIdentity(pid: pid, parentPID: parent, effectiveUID: 501, executablePath: path, startSeconds: 100, startMicroseconds: pid, processName: "proc", niceValue: nice)
    }

    private func resource(pid: Int32, cpu: UInt64, resident: UInt64? = nil) -> ProcessResourceSample {
        ProcessResourceSample(
            pid: pid,
            startSeconds: 100,
            startMicroseconds: pid,
            cpuTimeNanoseconds: cpu,
            residentBytes: resident ?? UInt64(pid) * 1000
        )
    }
}

private final class FakeNativeMetrics: DashboardNativeMetricsProviding {
    var hostTicks: [HostCPUTicks]
    let hostMemorySample: HostMemorySample
    var processSequences: [Int32: [ProcessResourceSample]]
    init(
        hostTicks: [HostCPUTicks],
        hostMemorySample: HostMemorySample = HostMemorySample(physicalTotalBytes: 1000, usedBytes: 600, availableBytes: 400),
        processSequences: [Int32: [ProcessResourceSample]] = [:]
    ) {
        self.hostTicks = hostTicks
        self.hostMemorySample = hostMemorySample
        self.processSequences = processSequences
    }
    func hostCPUTicks() throws -> HostCPUTicks {
        guard !hostTicks.isEmpty else { throw DashboardNativeMetricError.unsupported }
        return hostTicks.removeFirst()
    }
    func hostMemory() throws -> HostMemorySample { hostMemorySample }
    func swap() throws -> SwapSample { SwapSample(totalBytes: 1000, usedBytes: 200, freeBytes: 800) }
    func processResources(pid: Int32) throws -> ProcessResourceSample {
        guard var values = processSequences[pid], !values.isEmpty else { throw DashboardNativeMetricError.readFailed(operation: "process", code: -1) }
        let value = values.removeFirst(); processSequences[pid] = values; return value
    }
}

private final class FakeThermalProvider: ThermalLimitProviding {
    var calls = 0
    func readLimits(capturedAt: Date) -> ThermalLimitSnapshot {
        calls += 1
        return ThermalLimitSnapshot(capturedAt: capturedAt, schedulerLimitPercent: .available(100, at: capturedAt), speedLimitPercent: .available(100, at: capturedAt))
    }
}
private struct FakeDiskSpaceProvider: DashboardDiskSpaceProviding { func startupVolumeFreeBytes() throws -> UInt64 { 5000 } }
private struct FakeSelectionProvider: AppPrioritySelectionProviding { let selection: AppPrioritySelection; func currentSelection() -> AppPrioritySelection { selection } }
private struct FakeStatusProvider: AppPriorityStatusProviding { func currentStatus() -> AppPriorityStatus? { nil } }
private struct FakeUserProvider: DashboardCurrentUserProviding { let uid: UInt32 }
private final class FakeProcessInspector: AppPriorityProcessInspecting {
    let processes: [AppPriorityProcessIdentity]
    init(processes: [AppPriorityProcessIdentity]) { self.processes = processes }
    func allProcesses() throws -> [AppPriorityProcessIdentity] { processes }
    func process(pid: Int32) throws -> AppPriorityProcessIdentity { throw AppPriorityProcessError.unsupported }
}
