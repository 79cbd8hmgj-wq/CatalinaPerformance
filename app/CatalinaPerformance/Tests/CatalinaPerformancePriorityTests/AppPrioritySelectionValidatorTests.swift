import XCTest
import Foundation
@testable import CatalinaPerformancePriorityCore
#if os(Linux)
import Glibc
#else
import Darwin
#endif

final class AppPrioritySelectionValidatorTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let home: URL
        let selection: URL
        let app: AppPriorityApplication
    }

    private struct FixedMetadataProvider: AppPriorityFileMetadataProviding {
        let metadataValue: AppPriorityFileMetadata
        func metadata(at url: URL) throws -> AppPriorityFileMetadata { metadataValue }
    }

    private func fixture(bundleIdentifier: String = "local.fixture.app") throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let selection = home
            .appendingPathComponent("Library/Application Support/CatalinaPerformance/app_priority", isDirectory: true)
            .appendingPathComponent("selection.json")
        let bundle = root.appendingPathComponent("Fixture.app", isDirectory: true)
        let macOS = bundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let executable = macOS.appendingPathComponent("FixtureApp")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o755))], ofItemAtPath: executable.path)
        let plist: [String: Any] = ["CFBundleIdentifier": bundleIdentifier, "CFBundleExecutable": "FixtureApp"]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        let app = AppPriorityApplication(displayName: "Fixture", bundleIdentifier: bundleIdentifier, bundlePath: bundle.path, executablePath: executable.path)
        try AppPrioritySelection(enabled: true, application: app).writeAtomically(to: selection)
        return Fixture(root: root, home: home, selection: selection, app: app)
    }

    func testAcceptsValidSelection() throws {
        let value = try fixture()
        defer { try? FileManager.default.removeItem(at: value.root) }
        let result = try AppPrioritySelectionValidator().validate(selectionFileURL: value.selection, requestingUID: UInt32(getuid()), consoleUID: UInt32(getuid()), expectedHomeDirectory: value.home)
        XCTAssertTrue(result.enabled)
        XCTAssertEqual(result.application?.bundleIdentifier, value.app.bundleIdentifier)
    }


    func testAcceptsCanonicalStableFirefoxSelection() throws {
        let value = try fixture(bundleIdentifier: "org.mozilla.firefox")
        defer { try? FileManager.default.removeItem(at: value.root) }

        let result = try AppPrioritySelectionValidator().validate(
            selectionFileURL: value.selection,
            requestingUID: UInt32(getuid()),
            consoleUID: UInt32(getuid()),
            expectedHomeDirectory: value.home
        )

        XCTAssertEqual(result.application?.bundleIdentifier, "org.mozilla.firefox")
        XCTAssertEqual(result.application?.executablePath, value.app.executablePath)
    }

    func testRejectsFirefoxHelperExecutableInsteadOfDeclaredExecutable() throws {
        let value = try fixture(bundleIdentifier: "org.mozilla.firefox")
        defer { try? FileManager.default.removeItem(at: value.root) }
        let helperDirectory = URL(fileURLWithPath: value.app.bundlePath, isDirectory: true)
            .appendingPathComponent("Contents/MacOS/plugin-container.app/Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: helperDirectory, withIntermediateDirectories: true)
        let helper = helperDirectory.appendingPathComponent("plugin-container")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o755))], ofItemAtPath: helper.path)
        let tampered = AppPriorityApplication(
            displayName: "Firefox",
            bundleIdentifier: "org.mozilla.firefox",
            bundlePath: value.app.bundlePath,
            executablePath: helper.path
        )
        try AppPrioritySelection(enabled: true, application: tampered).writeAtomically(to: value.selection)

        XCTAssertThrowsError(try AppPrioritySelectionValidator().validate(
            selectionFileURL: value.selection,
            requestingUID: UInt32(getuid()),
            consoleUID: UInt32(getuid()),
            expectedHomeDirectory: value.home
        )) { error in
            XCTAssertEqual(error as? AppPriorityValidationError, .executablePathMismatch)
        }
    }

    func testRejectsMissingBundleDeclaredExecutable() throws {
        let value = try fixture()
        defer { try? FileManager.default.removeItem(at: value.root) }
        try FileManager.default.removeItem(atPath: value.app.executablePath)

        XCTAssertThrowsError(try AppPrioritySelectionValidator().validate(
            selectionFileURL: value.selection,
            requestingUID: UInt32(getuid()),
            consoleUID: UInt32(getuid()),
            expectedHomeDirectory: value.home
        )) { error in
            XCTAssertEqual(error as? AppPriorityValidationError, .executablePathMismatch)
        }
    }

    func testAcceptsCanonicalBundleSymlinkWhenExecutableRemainsInsideBundle() throws {
        let value = try fixture()
        defer { try? FileManager.default.removeItem(at: value.root) }
        let alias = value.root.appendingPathComponent("FixtureAlias.app")
        try FileManager.default.createSymbolicLink(
            at: alias,
            withDestinationURL: URL(fileURLWithPath: value.app.bundlePath, isDirectory: true)
        )
        let aliased = AppPriorityApplication(
            displayName: value.app.displayName,
            bundleIdentifier: value.app.bundleIdentifier,
            bundlePath: alias.path,
            executablePath: alias.appendingPathComponent("Contents/MacOS/FixtureApp").path
        )
        try AppPrioritySelection(enabled: true, application: aliased).writeAtomically(to: value.selection)

        let result = try AppPrioritySelectionValidator().validate(
            selectionFileURL: value.selection,
            requestingUID: UInt32(getuid()),
            consoleUID: UInt32(getuid()),
            expectedHomeDirectory: value.home
        )

        XCTAssertEqual(result.application?.bundlePath, value.app.bundlePath)
        XCTAssertEqual(result.application?.executablePath, value.app.executablePath)
    }

    func testRejectsDeclaredExecutableSymlinkThatEscapesBundle() throws {
        let value = try fixture()
        defer { try? FileManager.default.removeItem(at: value.root) }
        let executable = URL(fileURLWithPath: value.app.executablePath)
        try FileManager.default.removeItem(at: executable)
        try FileManager.default.createSymbolicLink(at: executable, withDestinationURL: URL(fileURLWithPath: "/bin/sh"))

        XCTAssertThrowsError(try AppPrioritySelectionValidator().validate(
            selectionFileURL: value.selection,
            requestingUID: UInt32(getuid()),
            consoleUID: UInt32(getuid()),
            expectedHomeDirectory: value.home
        )) { error in
            XCTAssertEqual(error as? AppPriorityValidationError, .executablePathMismatch)
        }
    }

    func testRejectsGroupWritableSelectionFile() throws {
        let value = try fixture()
        defer { try? FileManager.default.removeItem(at: value.root) }
        chmod(value.selection.path, 0o620)
        XCTAssertThrowsError(try AppPrioritySelectionValidator().validate(selectionFileURL: value.selection, requestingUID: UInt32(getuid()), consoleUID: UInt32(getuid()), expectedHomeDirectory: value.home)) { error in
            XCTAssertEqual(error as? AppPriorityValidationError, .unsafeSelectionPermissions)
        }
    }

    func testRejectsWrongOwnerThroughMetadataBoundary() throws {
        let value = try fixture()
        defer { try? FileManager.default.removeItem(at: value.root) }
        let attrs = try FileManager.default.attributesOfItem(atPath: value.selection.path)
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 1
        let provider = FixedMetadataProvider(metadataValue: AppPriorityFileMetadata(ownerUID: UInt32(getuid()) + 1, mode: 0o600, size: size, isRegularFile: true, isDirectory: false, isSymbolicLink: false))
        XCTAssertThrowsError(try AppPrioritySelectionValidator(metadataProvider: provider).validate(selectionFileURL: value.selection, requestingUID: UInt32(getuid()), consoleUID: UInt32(getuid()), expectedHomeDirectory: value.home)) { error in
            XCTAssertEqual(error as? AppPriorityValidationError, .wrongSelectionOwner)
        }
    }

    func testRejectsSymlinkSelection() throws {
        let value = try fixture()
        defer { try? FileManager.default.removeItem(at: value.root) }
        let target = value.home.appendingPathComponent("target.json")
        try FileManager.default.moveItem(at: value.selection, to: target)
        try FileManager.default.createSymbolicLink(at: value.selection, withDestinationURL: target)
        XCTAssertThrowsError(try AppPrioritySelectionValidator().validate(selectionFileURL: value.selection, requestingUID: UInt32(getuid()), consoleUID: UInt32(getuid()), expectedHomeDirectory: value.home))
    }

    func testRejectsMalformedJsonAndWrongPath() throws {
        let value = try fixture()
        defer { try? FileManager.default.removeItem(at: value.root) }
        try Data("not-json".utf8).write(to: value.selection)
        chmod(value.selection.path, 0o600)
        XCTAssertThrowsError(try AppPrioritySelectionValidator().validate(selectionFileURL: value.selection, requestingUID: UInt32(getuid()), consoleUID: UInt32(getuid()), expectedHomeDirectory: value.home)) { error in
            XCTAssertEqual(error as? AppPriorityValidationError, .malformedSelection)
        }
        let other = value.home.appendingPathComponent("selection.json")
        XCTAssertThrowsError(try AppPrioritySelectionValidator().validate(selectionFileURL: other, requestingUID: UInt32(getuid()), consoleUID: UInt32(getuid()), expectedHomeDirectory: value.home)) { error in
            XCTAssertEqual(error as? AppPriorityValidationError, .unsafeSelectionPath)
        }
    }

    func testRejectsBundleIdentifierAndExecutableMismatch() throws {
        let value = try fixture()
        defer { try? FileManager.default.removeItem(at: value.root) }
        let wrongID = AppPriorityApplication(displayName: "Fixture", bundleIdentifier: "wrong.identifier", bundlePath: value.app.bundlePath, executablePath: value.app.executablePath)
        try AppPrioritySelection(enabled: true, application: wrongID).writeAtomically(to: value.selection)
        XCTAssertThrowsError(try AppPrioritySelectionValidator().validate(selectionFileURL: value.selection, requestingUID: UInt32(getuid()), consoleUID: UInt32(getuid()), expectedHomeDirectory: value.home)) { error in
            XCTAssertEqual(error as? AppPriorityValidationError, .bundleIdentifierMismatch)
        }

        let wrongExecutable = AppPriorityApplication(displayName: "Fixture", bundleIdentifier: value.app.bundleIdentifier, bundlePath: value.app.bundlePath, executablePath: "/bin/false")
        try AppPrioritySelection(enabled: true, application: wrongExecutable).writeAtomically(to: value.selection)
        XCTAssertThrowsError(try AppPrioritySelectionValidator().validate(selectionFileURL: value.selection, requestingUID: UInt32(getuid()), consoleUID: UInt32(getuid()), expectedHomeDirectory: value.home)) { error in
            XCTAssertEqual(error as? AppPriorityValidationError, .executablePathMismatch)
        }
    }

    func testRejectsNonConsoleUserAndEnabledWithoutApplication() throws {
        let value = try fixture()
        defer { try? FileManager.default.removeItem(at: value.root) }
        XCTAssertThrowsError(try AppPrioritySelectionValidator().validate(selectionFileURL: value.selection, requestingUID: UInt32(getuid()), consoleUID: UInt32(getuid()) + 1, expectedHomeDirectory: value.home)) { error in
            XCTAssertEqual(error as? AppPriorityValidationError, .requestingUserIsNotConsoleUser)
        }
        try AppPrioritySelection(enabled: true, application: nil).writeAtomically(to: value.selection)
        XCTAssertThrowsError(try AppPrioritySelectionValidator().validate(selectionFileURL: value.selection, requestingUID: UInt32(getuid()), consoleUID: UInt32(getuid()), expectedHomeDirectory: value.home)) { error in
            XCTAssertEqual(error as? AppPriorityValidationError, .featureEnabledWithoutApplication)
        }
    }
}
