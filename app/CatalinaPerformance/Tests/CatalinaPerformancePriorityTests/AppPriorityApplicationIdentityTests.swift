import XCTest
@testable import CatalinaPerformancePriorityCore

final class AppPriorityApplicationIdentityTests: XCTestCase {
    private var temporaryRoots: [URL] = []

    override func tearDown() {
        for root in temporaryRoots {
            try? FileManager.default.removeItem(at: root)
        }
        temporaryRoots.removeAll()
        super.tearDown()
    }

    private func makeBundle(
        identifier: String = "org.mozilla.firefox",
        executable: String? = "firefox",
        createExecutable: Bool = true
    ) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        temporaryRoots.append(root)
        let bundleURL = root.appendingPathComponent("Firefox.app", isDirectory: true)
        let contents = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        var plist: [String: Any] = ["CFBundleIdentifier": identifier]
        if let executable = executable {
            plist["CFBundleExecutable"] = executable
        }
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        if createExecutable, let executable = executable {
            _ = FileManager.default.createFile(
                atPath: macOS.appendingPathComponent(executable).path,
                contents: Data(),
                attributes: nil
            )
        }
        return bundleURL
    }

    func testCanonicalApplicationUsesBundleDeclaredExecutableNotHelperPath() throws {
        let bundleURL = try makeBundle()
        let canonicalizer = AppPriorityApplicationCanonicalizer()

        let application = try canonicalizer.canonicalApplication(
            displayName: "Firefox",
            bundleIdentifier: "org.mozilla.firefox",
            bundleURL: bundleURL
        )

        XCTAssertEqual(
            application.executablePath,
            bundleURL.appendingPathComponent("Contents/MacOS/firefox").standardizedFileURL.path
        )
    }

    func testHelperEnumerationCannotReplaceCanonicalFirefoxEntry() throws {
        let bundleURL = try makeBundle()
        let canonicalizer = AppPriorityApplicationCanonicalizer()
        let parent = try canonicalizer.canonicalApplication(
            displayName: "Firefox",
            bundleIdentifier: "org.mozilla.firefox",
            bundleURL: bundleURL
        )
        let duplicate = AppPriorityApplication(
            displayName: "Firefox Helper",
            bundleIdentifier: parent.bundleIdentifier,
            bundlePath: parent.bundlePath,
            executablePath: bundleURL.appendingPathComponent("Contents/MacOS/plugin-container").path
        )

        XCTAssertEqual(canonicalizer.deduplicate([parent, duplicate]), [parent])
    }

    func testLegacyHelperSelectionMigratesToBundleExecutable() throws {
        let bundleURL = try makeBundle()
        let legacy = AppPriorityApplication(
            displayName: "Firefox",
            bundleIdentifier: "org.mozilla.firefox",
            bundlePath: bundleURL.path,
            executablePath: bundleURL.appendingPathComponent("Contents/MacOS/plugin-container").path
        )

        let migrated = try AppPriorityApplicationCanonicalizer().migrate(legacy)

        XCTAssertEqual(
            migrated.executablePath,
            bundleURL.appendingPathComponent("Contents/MacOS/firefox").path
        )
    }

    func testMismatchedBundleIdentifierIsRejected() throws {
        let bundleURL = try makeBundle(identifier: "org.mozilla.firefox")
        XCTAssertThrowsError(
            try AppPriorityApplicationCanonicalizer().canonicalApplication(
                displayName: "Firefox",
                bundleIdentifier: "org.mozilla.nightly",
                bundleURL: bundleURL
            )
        ) { error in
            XCTAssertEqual(error as? AppPriorityApplicationIdentityError, .bundleIdentifierMismatch)
        }
    }

    func testMissingBundleExecutableMetadataIsRejected() throws {
        let bundleURL = try makeBundle(executable: nil)
        XCTAssertThrowsError(
            try AppPriorityApplicationCanonicalizer().canonicalApplication(
                displayName: "Firefox",
                bundleIdentifier: "org.mozilla.firefox",
                bundleURL: bundleURL
            )
        ) { error in
            XCTAssertEqual(error as? AppPriorityApplicationIdentityError, .bundleMetadataUnavailable)
        }
    }

    func testMissingDeclaredExecutableIsRejected() throws {
        let bundleURL = try makeBundle(createExecutable: false)
        XCTAssertThrowsError(
            try AppPriorityApplicationCanonicalizer().canonicalApplication(
                displayName: "Firefox",
                bundleIdentifier: "org.mozilla.firefox",
                bundleURL: bundleURL
            )
        ) { error in
            XCTAssertEqual(error as? AppPriorityApplicationIdentityError, .executableMissing)
        }
    }

    func testSymlinkedBundleDeduplicatesToCanonicalBundlePath() throws {
        let bundleURL = try makeBundle()
        let linkRoot = bundleURL.deletingLastPathComponent().appendingPathComponent("Links", isDirectory: true)
        try FileManager.default.createDirectory(at: linkRoot, withIntermediateDirectories: true)
        let linkURL = linkRoot.appendingPathComponent("Firefox Alias.app", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: bundleURL)

        let canonicalizer = AppPriorityApplicationCanonicalizer()
        let direct = try canonicalizer.canonicalApplication(
            displayName: "Firefox",
            bundleIdentifier: "org.mozilla.firefox",
            bundleURL: bundleURL
        )
        let linked = try canonicalizer.canonicalApplication(
            displayName: "Firefox",
            bundleIdentifier: "org.mozilla.firefox",
            bundleURL: linkURL
        )

        XCTAssertEqual(canonicalizer.deduplicate([linked, direct]), [direct])
    }
}
