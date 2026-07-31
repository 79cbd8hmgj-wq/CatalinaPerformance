import XCTest
@testable import CatalinaPerformanceCore

final class ForegroundSessionTests: XCTestCase {
    func testTerminalAndITermArePermanentlyExcluded() {
        XCTAssertTrue(ForegroundApplicationFilter.isExcluded(bundleIdentifier: "com.apple.Terminal", displayName: "Terminal"))
        XCTAssertTrue(ForegroundApplicationFilter.isExcluded(bundleIdentifier: "com.googlecode.iterm2", displayName: "iTerm2"))
        XCTAssertFalse(ForegroundApplicationFilter.isExcluded(bundleIdentifier: "org.mozilla.firefox", displayName: "Firefox"))
    }

    func testFilterRejectsMissingUnsafeBackgroundAndDuplicateApplications() {
        let candidates = [
            ForegroundApplication(displayName: "Firefox", bundleIdentifier: "org.mozilla.firefox", isRunning: true, isRegularGUIApplication: true),
            ForegroundApplication(displayName: "Firefox duplicate", bundleIdentifier: "org.mozilla.firefox", isRunning: true, isRegularGUIApplication: true),
            ForegroundApplication(displayName: "Terminal", bundleIdentifier: "com.apple.Terminal", isRunning: true, isRegularGUIApplication: true),
            ForegroundApplication(displayName: "Background", bundleIdentifier: "org.example.background", isRunning: true, isRegularGUIApplication: false),
            ForegroundApplication(displayName: "Unsafe", bundleIdentifier: "bad id", isRunning: true, isRegularGUIApplication: true),
            ForegroundApplication(displayName: "TextEdit", bundleIdentifier: "com.apple.TextEdit", isRunning: true, isRegularGUIApplication: true)
        ]

        XCTAssertEqual(
            ForegroundApplicationFilter.eligibleApplications(from: candidates).map { $0.bundleIdentifier },
            ["org.mozilla.firefox", "com.apple.TextEdit"]
        )
    }

    func testPreferencesSerializeOnlyRecognizedSafeSelections() {
        let preferences = ForegroundSessionPreferences(
            featureEnabled: true,
            disableFinderAnimations: true,
            shortenDockAnimations: false,
            disableWindowAnimations: true,
            selectedBundleIdentifiers: ["org.mozilla.firefox", "com.apple.Terminal", "bad id", "org.mozilla.firefox"]
        )
        XCTAssertEqual(
            preferences.serializedEnvironment,
            "FOREGROUND_SESSION_ENABLED=1\nDISABLE_FINDER_ANIMATIONS=1\nSHORTEN_DOCK_ANIMATIONS=0\nDISABLE_WINDOW_ANIMATIONS=1\nSELECTED_BUNDLE_ID=org.mozilla.firefox\n"
        )
    }


    func testPreferencesWriteAtomicallyCreatesExpectedFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("preferences.env")
        let preferences = ForegroundSessionPreferences(
            featureEnabled: true,
            disableFinderAnimations: false,
            shortenDockAnimations: true,
            disableWindowAnimations: false,
            selectedBundleIdentifiers: ["com.apple.TextEdit", "bad id", "com.apple.Terminal"]
        )

        try preferences.write(to: url)

        XCTAssertEqual(try String(contentsOf: url), preferences.serializedEnvironment)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".preferences.env.tmp").path))
    }

    func testFeatureDisabledOnSequenceRunsOnlyPrivilegedPerformanceStep() {
        XCTAssertEqual(
            PerformanceSequenceFactory.performanceOn(featureEnabled: false),
            [ScriptSequenceStep(script: .performanceOn)]
        )
    }

    func testPriorityWrapperDoesNotChangeUserLevelOnSequenceOrdering() {
        XCTAssertEqual(
            PerformanceSequenceFactory.performanceOn(featureEnabled: true).map { $0.script },
            [.foregroundApply, .uiApply, .performanceOn]
        )
    }

    func testOffStillContinuesUserLevelRestoreAfterPrivilegedWrapperFailure() {
        XCTAssertEqual(
            PerformanceSequenceFactory.performanceOff(featureEnabled: true).map { $0.continueAfterFailure },
            [true, true, true]
        )
    }

    func testManualApplyRollsBackApplicationsWhenUIApplyFails() {
        let executor = FakeSequenceExecutor(results: [
            .foregroundApply: true,
            .uiApply: false,
            .foregroundRestore: true
        ])
        let coordinator = ScriptSequenceCoordinator(executor: executor)
        let expectation = self.expectation(description: "sequence")

        coordinator.run(steps: PerformanceSequenceFactory.manualApply()) { result in
            XCTAssertFalse(result.succeeded)
            XCTAssertEqual(result.executedScripts, [.foregroundApply, .uiApply, .foregroundRestore])
            expectation.fulfill()
        }

        waitForExpectations(timeout: 2)
    }

    func testSummaryParsesKnownKeysAndDefaultsMissingValuesToZero() {
        let summary = ForegroundSessionSummary.parse("session_active=1\nselected=3\nconfirmed_closed=2\npending_relaunch=1\nunknown=99\n")
        XCTAssertTrue(summary.sessionActive)
        XCTAssertEqual(summary.selected, 3)
        XCTAssertEqual(summary.confirmedClosed, 2)
        XCTAssertEqual(summary.skipped, 0)
        XCTAssertEqual(summary.pendingRelaunch, 1)
    }

    func testCoordinatorRunsRollbackAfterFailureAndCompletesOnce() {
        let executor = FakeSequenceExecutor(results: [
            .foregroundApply: true,
            .uiApply: true,
            .performanceOn: false,
            .uiRestore: true,
            .foregroundRestore: true
        ])
        let coordinator = ScriptSequenceCoordinator(executor: executor)
        let expectation = self.expectation(description: "sequence")
        var completionCount = 0

        coordinator.run(steps: PerformanceSequenceFactory.performanceOn(featureEnabled: true)) { result in
            completionCount += 1
            XCTAssertFalse(result.succeeded)
            XCTAssertEqual(result.executedScripts, [.foregroundApply, .uiApply, .performanceOn, .uiRestore, .foregroundRestore])
            expectation.fulfill()
        }

        waitForExpectations(timeout: 2)
        XCTAssertEqual(completionCount, 1)
    }

    func testOffSequenceContinuesRestorationAfterPrivilegedFailure() {
        let executor = FakeSequenceExecutor(results: [
            .performanceOff: false,
            .uiRestore: true,
            .foregroundRestore: true
        ])
        let coordinator = ScriptSequenceCoordinator(executor: executor)
        let expectation = self.expectation(description: "sequence")

        coordinator.run(steps: PerformanceSequenceFactory.performanceOff(featureEnabled: true)) { result in
            XCTAssertFalse(result.succeeded)
            XCTAssertEqual(result.executedScripts, [.performanceOff, .uiRestore, .foregroundRestore])
            expectation.fulfill()
        }

        waitForExpectations(timeout: 2)
    }
}

private final class FakeSequenceExecutor: SequenceScriptExecuting {
    private let results: [SequenceScript: Bool]

    init(results: [SequenceScript: Bool]) {
        self.results = results
    }

    func execute(_ script: SequenceScript, completion: @escaping (SequenceCommandResult) -> Void) {
        let succeeded = results[script] ?? true
        DispatchQueue.global().async {
            completion(SequenceCommandResult(script: script, command: script.rawValue, output: "", succeeded: succeeded))
        }
    }
}
