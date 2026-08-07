import XCTest
import CatalinaPerformancePriorityCore
@testable import CatalinaPerformanceDashboardCore

final class PerformanceSubsystemEvidenceTests: XCTestCase {
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

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testRecordedSpotlightAndTimeMachineActionsAreApplied() throws {
        try "Paused Spotlight indexing on the boot volume with mdutil -i off /.\nPaused Time Machine automatic backups with tmutil disable.\n".write(to: system.appendingPathComponent("actions_taken.txt"), atomically: true, encoding: .utf8)
        let statuses = reader().activationStatuses(at: Date(timeIntervalSince1970: 10))
        XCTAssertEqual(statuses.status(for: .spotlight)?.state, .applied)
        XCTAssertEqual(statuses.status(for: .timeMachine)?.state, .applied)
    }

    func testConfirmedApplicationsAndMixedUIStateAreMappedConservatively() throws {
        try "bundle_identifier\tdisplay_name\twas_running\tquit_requested\tconfirmed_closed\tshould_relaunch\trelaunch_result\na\tA\t1\t1\t1\t1\tpending\nb\tB\t1\t1\t1\t1\tpending\n".write(to: foreground.appendingPathComponent("applications.tsv"), atomically: true, encoding: .utf8)
        try "domain\tkey\tprevious_exists\tprevious_type\tprevious_value\tapplied_type\tapplied_value\trestore_status\na\tb\t0\tabsent\tx\tbool\t1\tpending\nc\td\t0\tabsent\tx\tbool\t1\trestored\n".write(to: foreground.appendingPathComponent("ui_preferences.tsv"), atomically: true, encoding: .utf8)
        let statuses = reader().activationStatuses(at: Date())
        XCTAssertEqual(statuses.status(for: .temporarilyClosedApplications)?.note, "2 apps closed")
        XCTAssertEqual(statuses.status(for: .uiResponsiveness)?.state, .partiallyApplied)
    }

    func testSanitizedPriorityStatusMapsActiveAndRestored() throws {
        try AppPrioritySelection(enabled: true, application: fixtureApplication()).writeAtomically(to: prioritySelection)
        let active = AppPriorityStatus(state: .active, boostedCount: 3, skippedCount: 0, message: "Active", sessionIdentifier: "s")
        try JSONEncoder().encode(active).write(to: priority)
        XCTAssertEqual(reader().activationStatuses(at: Date()).status(for: .appPriority)?.state, .applied)
        let restored = AppPriorityStatus(state: .restored, boostedCount: 0, skippedCount: 0, message: "Restored", sessionIdentifier: nil)
        try JSONEncoder().encode(restored).write(to: priority)
        XCTAssertEqual(reader().restorationStatuses(commandEvidence: [DashboardCommandEvidence(identifier: "performanceOff", succeeded: true, output: "")], at: Date()).status(for: .appPriority)?.state, .restored)
    }

    func testDisabledPrioritySelectionOverridesStaleRestoredStatus() throws {
        try AppPrioritySelection(enabled: false, application: nil).writeAtomically(to: prioritySelection)
        let stale = AppPriorityStatus(state: .restored, boostedCount: 0, skippedCount: 0, message: "Restored", sessionIdentifier: nil)
        try JSONEncoder().encode(stale).write(to: priority)

        let status = reader().restorationStatuses(
            commandEvidence: [DashboardCommandEvidence(identifier: "performanceOff", succeeded: true, output: "")],
            at: Date()
        ).status(for: .appPriority)

        XCTAssertEqual(status?.state, .notConfigured)
    }

    func testMissingRestoreProofIsUnknown() {
        let statuses = reader().restorationStatuses(commandEvidence: [DashboardCommandEvidence(identifier: "performanceOff", succeeded: true, output: "")], at: Date())
        XCTAssertEqual(statuses.status(for: .spotlight)?.state, .unknown)
        XCTAssertEqual(statuses.status(for: .powerSettings)?.state, .unknown)
    }

    func testMissingUIRestoreStateIsNotConfigured() {
        let statuses = reader().restorationStatuses(
            commandEvidence: [DashboardCommandEvidence(identifier: "performanceOff", succeeded: true, output: "")],
            at: Date()
        )
        XCTAssertEqual(statuses.status(for: .uiResponsiveness)?.state, .notConfigured)
        XCTAssertNil(statuses.status(for: .uiResponsiveness)?.note)
    }

    private func reader() -> PerformanceSubsystemEvidenceReader {
        PerformanceSubsystemEvidenceReader(paths: PerformanceSubsystemPaths(systemStateDirectory: system, foregroundRuntimeDirectory: foreground, appPriorityStatusFile: priority, appPrioritySelectionFile: prioritySelection))
    }

    private func fixtureApplication() -> AppPriorityApplication {
        AppPriorityApplication(
            displayName: "Fixture",
            bundleIdentifier: "local.fixture",
            bundlePath: "/Applications/Fixture.app",
            executablePath: "/Applications/Fixture.app/Contents/MacOS/Fixture"
        )
    }
}

private extension Array where Element == PerformanceSubsystemStatus {
    func status(for subsystem: PerformanceSubsystem) -> PerformanceSubsystemStatus? { first { $0.subsystem == subsystem } }
}
