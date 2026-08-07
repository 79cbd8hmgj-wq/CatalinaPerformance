import XCTest
@testable import CatalinaPerformanceDashboardCore

final class PerformanceSubsystemEvidenceRuntimeRegressionTests: XCTestCase {
    private var root: URL!
    private var system: URL!
    private var foreground: URL!
    private var priority: URL!
    private var prioritySelection: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        system = root.appendingPathComponent("system_state", isDirectory: true)
        foreground = root.appendingPathComponent("foreground", isDirectory: true)
        priority = root.appendingPathComponent("status.json")
        prioritySelection = root.appendingPathComponent("selection.json")
        try FileManager.default.createDirectory(at: system, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: foreground, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testTimeMachinePreferenceSkipIsNotConfiguredWhilePerformanceModeIsActive() throws {
        try Data().write(to: system.appendingPathComponent("performance_mode_on"))
        try "Skipped Time Machine pause: Advanced preference disabled by user.\n".write(
            to: system.appendingPathComponent("actions_taken.txt"),
            atomically: true,
            encoding: .utf8
        )

        let status = reader().activationStatuses(at: Date()).first(where: { $0.subsystem == .timeMachine })

        XCTAssertEqual(status?.state, .notConfigured)
        XCTAssertEqual(status?.note, "Time Machine was not changed by Performance Mode.")
    }

    func testTimeMachineRestoreSkipIsNotConfiguredWhenPerformanceModeNeverChangedIt() throws {
        try "Skipped Time Machine restore: Performance Mode did not record disabling automatic backups.\n".write(
            to: system.appendingPathComponent("restore_actions_taken.txt"),
            atomically: true,
            encoding: .utf8
        )

        let status = reader().restorationStatuses(
            commandEvidence: [DashboardCommandEvidence(
                identifier: "performanceOff",
                succeeded: true,
                output: ""
            )],
            at: Date()
        ).first(where: { $0.subsystem == .timeMachine })

        XCTAssertEqual(status?.state, .notConfigured)
        XCTAssertEqual(status?.note, "Time Machine did not require restoration.")
    }

    private func reader() -> PerformanceSubsystemEvidenceReader {
        PerformanceSubsystemEvidenceReader(paths: PerformanceSubsystemPaths(
            systemStateDirectory: system,
            foregroundRuntimeDirectory: foreground,
            appPriorityStatusFile: priority,
            appPrioritySelectionFile: prioritySelection
        ))
    }
}
