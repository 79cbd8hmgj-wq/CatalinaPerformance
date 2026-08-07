import XCTest
@testable import CatalinaPerformanceDashboardCore

final class ThermalLimitProviderTests: XCTestCase {
    private func date(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    func testParserReadsOnlyPercentageLimits() {
        let output = """
        CPU_Scheduler_Limit = 100
        CPU_Available_CPUs = 4
        CPU_Speed_Limit = 75
        """
        let result = ThermalLimitParser.parse(output, capturedAt: date(10))
        XCTAssertEqual(result.schedulerLimitPercent.value, 100)
        XCTAssertEqual(result.speedLimitPercent.value, 75)
    }

    func testAvailableCPUCountIsNeverTreatedAsPercentage() {
        let result = ThermalLimitParser.parse("CPU_Available_CPUs = 4", capturedAt: date(10))
        XCTAssertEqual(result.schedulerLimitPercent.availability, .unavailable)
        XCTAssertEqual(result.speedLimitPercent.availability, .unavailable)
    }

    func testUnsupportedOutputIsUnavailableNotZero() {
        let result = ThermalLimitParser.parse("No thermal warning level has been recorded", capturedAt: date(10))
        XCTAssertNil(result.schedulerLimitPercent.value)
        XCTAssertNil(result.speedLimitPercent.value)
    }

    func testProviderUsesInjectedCommandResult() {
        let runner = FakeThermalCommandRunner(result: ThermalCommandResult(output: "CPU_Scheduler_Limit = 90\nCPU_Speed_Limit = 80", errorOutput: "", exitStatus: 0, timedOut: false))
        let provider = PMSetThermalLimitProvider(commandRunner: runner)
        let result = provider.readLimits(capturedAt: date(3))
        XCTAssertEqual(result.schedulerLimitPercent.value, 90)
        XCTAssertEqual(result.speedLimitPercent.value, 80)
        XCTAssertEqual(runner.calls, 1)
    }

    func testProviderFailureReturnsUnavailable() {
        let runner = FakeThermalCommandRunner(result: ThermalCommandResult(output: "", errorOutput: "denied", exitStatus: 1, timedOut: false))
        let result = PMSetThermalLimitProvider(commandRunner: runner).readLimits(capturedAt: date(4))
        XCTAssertEqual(result.schedulerLimitPercent.availability, .unavailable)
        XCTAssertTrue(result.schedulerLimitPercent.note?.contains("denied") == true)
    }
}

private final class FakeThermalCommandRunner: ThermalCommandRunning {
    let result: ThermalCommandResult
    var calls = 0
    init(result: ThermalCommandResult) { self.result = result }
    func run(executablePath: String, arguments: [String], timeout: TimeInterval) -> ThermalCommandResult {
        calls += 1
        return result
    }
}
