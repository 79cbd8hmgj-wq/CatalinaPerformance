import XCTest
import Foundation
@testable import CatalinaPerformancePriorityCore

final class AppPriorityPreferencesTests: XCTestCase {
    func testTerminalIsEligibleButSystemApplicationsAreExcluded() {
        XCTAssertFalse(AppPriorityApplicationFilter.isExcluded(bundleIdentifier: "com.apple.Terminal", displayName: "Terminal"))
        XCTAssertFalse(AppPriorityApplicationFilter.isExcluded(bundleIdentifier: "com.googlecode.iterm2", displayName: "iTerm2"))
        XCTAssertTrue(AppPriorityApplicationFilter.isExcluded(bundleIdentifier: "com.apple.finder", displayName: "Finder"))
        XCTAssertTrue(AppPriorityApplicationFilter.isExcluded(bundleIdentifier: "local.CatalinaPerformance", displayName: "CatalinaPerformance"))
    }

    func testForegroundConflictUsesExactBundleIdentifier() {
        let selected = AppPriorityApplication(
            displayName: "Firefox",
            bundleIdentifier: "org.mozilla.firefox",
            bundlePath: "/Applications/Firefox.app",
            executablePath: "/Applications/Firefox.app/Contents/MacOS/firefox"
        )
        XCTAssertEqual(
            AppPriorityConfigurationConflict.conflictingBundleIdentifier(
                selection: selected,
                foregroundBundleIdentifiers: ["org.mozilla.firefox"]
            ),
            "org.mozilla.firefox"
        )
        XCTAssertNil(
            AppPriorityConfigurationConflict.conflictingBundleIdentifier(
                selection: selected,
                foregroundBundleIdentifiers: ["org.mozilla.firefox.helper"]
            )
        )
    }

    func testSelectionRoundTripsThroughUserDefaults() throws {
        let suiteName = "AppPriorityPreferencesTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let app = AppPriorityApplication(displayName: "TextEdit", bundleIdentifier: "com.apple.TextEdit", bundlePath: "/Applications/TextEdit.app", executablePath: "/Applications/TextEdit.app/Contents/MacOS/TextEdit")
        let selection = AppPrioritySelection(enabled: true, application: app)
        try AppPriorityPreferences.save(selection, to: defaults)
        XCTAssertEqual(AppPriorityPreferences.load(from: defaults), selection)
    }

    func testSelectionWritesAtomicallyWith0600Permissions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("selection.json")
        let app = AppPriorityApplication(displayName: "TextEdit", bundleIdentifier: "com.apple.TextEdit", bundlePath: "/Applications/TextEdit.app", executablePath: "/Applications/TextEdit.app/Contents/MacOS/TextEdit")
        try AppPrioritySelection(enabled: true, application: app).writeAtomically(to: file)
        let decoded = try JSONDecoder().decode(AppPrioritySelection.self, from: Data(contentsOf: file))
        XCTAssertEqual(decoded.application, app)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".selection.json.tmp").path))
    }

    func testSavedApplicationDataRemainsAvailableWhenNotRunning() {
        let app = AppPriorityApplication(displayName: "Firefox", bundleIdentifier: "org.mozilla.firefox", bundlePath: "/Applications/Firefox.app", executablePath: "/Applications/Firefox.app/Contents/MacOS/firefox")
        let selection = AppPrioritySelection(enabled: false, application: app)
        XCTAssertEqual(selection.application?.displayName, "Firefox")
        XCTAssertFalse(selection.enabled)
    }

    func testConflictTransitionAPIsAreSymmetric() {
        XCTAssertEqual(
            AppPriorityConfigurationConflict.validate(priorityEnabled: true, priorityBundleIdentifier: "org.mozilla.firefox", foregroundBundleIdentifiers: ["org.mozilla.firefox"]),
            .conflict(bundleIdentifier: "org.mozilla.firefox")
        )
        XCTAssertEqual(
            AppPriorityConfigurationConflict.validateForegroundAddition(bundleIdentifier: "org.mozilla.firefox", priorityEnabled: true, priorityBundleIdentifier: "org.mozilla.firefox"),
            .conflict(bundleIdentifier: "org.mozilla.firefox")
        )
    }
}
