import XCTest
@testable import CatalinaPerformanceDashboardCore

final class WindowServerPSProcessInspectorTests: XCTestCase {
    func testObservedCatalinaCPUTimeParsesAsCumulativeNanoseconds() {
        XCTAssertEqual(
            WindowServerPSParser.cpuTimeNanoseconds("24:12.03"),
            1_452_030_000_000
        )
    }

    func testCPUTimeParserAcceptsHourAndDayForms() {
        XCTAssertEqual(
            WindowServerPSParser.cpuTimeNanoseconds("1:02:03.50"),
            3_723_500_000_000
        )
        XCTAssertEqual(
            WindowServerPSParser.cpuTimeNanoseconds("2-01:02:03.25"),
            176_523_250_000_000
        )
    }

    func testCPUTimeParserRejectsMalformedValues() {
        XCTAssertNil(WindowServerPSParser.cpuTimeNanoseconds("bad"))
        XCTAssertNil(WindowServerPSParser.cpuTimeNanoseconds("-1:00"))
        XCTAssertNil(WindowServerPSParser.cpuTimeNanoseconds("1:99.0"))
    }

    func testObservedCatalinaPSRecordParsesIdentityPathAndCumulativeTime() {
        let output = "  236    88     1 Thu Aug  6 11:19:51 2026      24:12.03 /System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer -daemon\n"

        let record = WindowServerPSParser.parseRecord(
            output,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        XCTAssertEqual(record?.pid, 236)
        XCTAssertEqual(record?.effectiveUID, 88)
        XCTAssertEqual(record?.parentPID, 1)
        XCTAssertEqual(
            record?.executablePath,
            "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer"
        )
        XCTAssertEqual(record?.cpuTimeNanoseconds, 1_452_030_000_000)
        XCTAssertNotNil(record?.startedAt)
    }

    func testInspectorUsesExactPgrepAndCumulativePSTimeWithoutPercentCPU() throws {
        let runner = FakeWindowServerCommandRunner(results: [
            WindowServerCommandResult(
                output: "236\n",
                errorOutput: "",
                exitStatus: 0,
                timedOut: false
            ),
            WindowServerCommandResult(
                output: "236 88 1 Thu Aug 6 11:19:51 2026 24:12.03 /System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer -daemon\n",
                errorOutput: "",
                exitStatus: 0,
                timedOut: false
            )
        ])
        let inspector = DarwinWindowServerProcessInspector(
            commandRunner: runner,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        let sample = try inspector.readWindowServer()

        XCTAssertEqual(sample.processKey.pid, 236)
        XCTAssertEqual(sample.processKey.effectiveUID, 88)
        XCTAssertEqual(sample.cumulativeCPUTimeNanoseconds, 1_452_030_000_000)
        XCTAssertEqual(runner.requests.count, 2)
        XCTAssertEqual(runner.requests[0].executablePath, "/usr/bin/pgrep")
        XCTAssertEqual(runner.requests[0].arguments, ["-x", "WindowServer"])
        XCTAssertEqual(runner.requests[1].executablePath, "/bin/ps")
        XCTAssertTrue(runner.requests[1].arguments.contains("time="))
        XCTAssertFalse(runner.requests[1].arguments.contains("%cpu="))
    }

    func testInspectorRejectsMultipleExactWindowServerPIDs() {
        let runner = FakeWindowServerCommandRunner(results: [
            WindowServerCommandResult(
                output: "236\n777\n",
                errorOutput: "",
                exitStatus: 0,
                timedOut: false
            )
        ])
        let inspector = DarwinWindowServerProcessInspector(commandRunner: runner)

        XCTAssertThrowsError(try inspector.readWindowServer())
    }

    func testInspectorRejectsNonSystemWindowServerPath() {
        let runner = FakeWindowServerCommandRunner(results: [
            WindowServerCommandResult(
                output: "236\n",
                errorOutput: "",
                exitStatus: 0,
                timedOut: false
            ),
            WindowServerCommandResult(
                output: "236 88 1 Thu Aug 6 11:19:51 2026 24:12.03 /tmp/WindowServer -daemon\n",
                errorOutput: "",
                exitStatus: 0,
                timedOut: false
            )
        ])
        let inspector = DarwinWindowServerProcessInspector(commandRunner: runner)

        XCTAssertThrowsError(try inspector.readWindowServer())
    }
}

private final class FakeWindowServerCommandRunner: WindowServerCommandRunning {
    struct Request: Equatable {
        let executablePath: String
        let arguments: [String]
    }

    private var results: [WindowServerCommandResult]
    private(set) var requests: [Request] = []

    init(results: [WindowServerCommandResult]) {
        self.results = results
    }

    func run(
        executablePath: String,
        arguments: [String],
        timeout: TimeInterval
    ) -> WindowServerCommandResult {
        requests.append(Request(executablePath: executablePath, arguments: arguments))
        guard !results.isEmpty else {
            return WindowServerCommandResult(
                output: "",
                errorOutput: "fixture exhausted",
                exitStatus: nil,
                timedOut: false
            )
        }
        return results.removeFirst()
    }
}
