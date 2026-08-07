import Foundation
import XCTest
@testable import CatalinaPerformanceVisualPerformanceCore

final class VisualPerformanceStateStoreTests: XCTestCase {
    private var rootURL: URL!

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("visual-performance-store-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let rootURL = rootURL {
            try? FileManager.default.removeItem(at: rootURL)
        }
    }

    func testWriteAndLoadActiveRoundTrip() throws {
        let store = makeStore()
        let record = VisualPerformanceSessionRecord.fixtureActive(identifier: "first")
        try store.writeActive(record)

        XCTAssertEqual(try store.loadActive(), record)
    }

    func testExistingActiveStateIsAtomicallyReplaced() throws {
        let store = makeStore()
        try store.writeActive(.fixtureActive(identifier: "first"))
        try store.writeActive(.fixtureActive(identifier: "second"))

        XCTAssertEqual(try store.loadActive()?.sessionIdentifier, "second")
        let temporaryFiles = try FileManager.default.contentsOfDirectory(atPath: rootURL.path)
            .filter { $0.contains(".tmp") }
        XCTAssertTrue(temporaryFiles.isEmpty)
    }

    func testCompleteWritesCompletedBeforeRemovingActive() throws {
        let store = makeStore()
        try store.writeActive(.fixtureActive(identifier: "complete"))
        let completed = VisualPerformanceSessionRecord.fixtureCompleted(identifier: "complete")

        try store.complete(completed)

        XCTAssertNil(try store.loadActive())
        XCTAssertEqual(try store.loadLastCompleted()?.aggregateStatus, .successful)
        XCTAssertEqual(try store.loadLastCompleted(), completed)
    }

    func testMalformedStateThrowsAndLeavesOriginalFileUntouched() throws {
        let store = makeStore()
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let malformed = Data("{not-json".utf8)
        try malformed.write(to: store.activeSessionURL)

        XCTAssertThrowsUnsupportedOrMalformed {
            _ = try store.loadActive()
        }
        XCTAssertEqual(try Data(contentsOf: store.activeSessionURL), malformed)
    }

    func testUnknownSchemaThrowsAndLeavesOriginalFileUntouched() throws {
        let store = makeStore()
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let unsupported = VisualPerformanceSessionRecord(
            schemaVersion: 999,
            sessionIdentifier: "unsupported",
            requestingUID: 501,
            startedAt: Date(timeIntervalSince1970: 90),
            completedAt: nil,
            settings: [],
            aggregateStatus: .preparing
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(unsupported)
        try data.write(to: store.activeSessionURL)

        XCTAssertThrowsUnsupportedOrMalformed {
            _ = try store.loadActive()
        }
        XCTAssertEqual(try Data(contentsOf: store.activeSessionURL), data)
    }

    func testCompleteKeepsDurableCompletedRecordWhenActiveRemovalIsUnsafe() throws {
        let store = makeStore()
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try "target".data(using: .utf8)!.write(to: rootURL.appendingPathComponent("target.json"))
        try FileManager.default.createSymbolicLink(
            at: store.activeSessionURL,
            withDestinationURL: rootURL.appendingPathComponent("target.json")
        )

        XCTAssertThrowsError(try store.complete(.fixtureCompleted(identifier: "durable"))) { error in
            XCTAssertEqual(error as? VisualPerformanceStateStoreError, .symbolicLinkRejected)
        }
        XCTAssertEqual(try store.loadLastCompleted()?.sessionIdentifier, "durable")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.activeSessionURL.path))
    }

    func testRemoveActiveDeletesOnlyRegularStateFile() throws {
        let store = makeStore()
        try store.writeActive(.fixtureActive(identifier: "remove"))
        try store.removeActive()
        XCTAssertNil(try store.loadActive())
    }

    #if os(macOS)
    func testDarwinPermissionsAreRestrictive() throws {
        let store = makeStore()
        try store.writeActive(.fixtureActive(identifier: "permissions"))

        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: rootURL.path)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: store.activeSessionURL.path)
        let directoryMode = (directoryAttributes[.posixPermissions] as? NSNumber)?.intValue
        let fileMode = (fileAttributes[.posixPermissions] as? NSNumber)?.intValue

        XCTAssertEqual(directoryMode, 0o700)
        XCTAssertEqual(fileMode, 0o600)
    }
    #endif

    private func makeStore() -> VisualPerformanceStateStore {
        return VisualPerformanceStateStore(directoryURL: rootURL)
    }

    private func XCTAssertThrowsUnsupportedOrMalformed(
        _ expression: () throws -> Void,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            XCTAssertEqual(
                error as? VisualPerformanceStateStoreError,
                .unsupportedOrMalformedState,
                file: file,
                line: line
            )
        }
    }
}

private extension VisualPerformanceSessionRecord {
    static func fixtureActive(identifier: String) -> VisualPerformanceSessionRecord {
        let setting = VisualSettingRecord(
            id: .reduceMotion,
            displayName: "Reduce Motion",
            priorWasPresent: true,
            priorValue: .boolean(false),
            appliedValue: .boolean(true),
            outcome: .applied,
            note: nil,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        return VisualPerformanceSessionRecord(
            sessionIdentifier: identifier,
            requestingUID: 501,
            startedAt: Date(timeIntervalSince1970: 90),
            completedAt: nil,
            settings: [setting],
            aggregateStatus: .applied
        )
    }

    static func fixtureCompleted(identifier: String) -> VisualPerformanceSessionRecord {
        let setting = VisualSettingRecord(
            id: .reduceMotion,
            displayName: "Reduce Motion",
            priorWasPresent: true,
            priorValue: .boolean(false),
            appliedValue: .boolean(true),
            outcome: .restored,
            note: nil,
            updatedAt: Date(timeIntervalSince1970: 120)
        )
        return VisualPerformanceSessionRecord(
            sessionIdentifier: identifier,
            requestingUID: 501,
            startedAt: Date(timeIntervalSince1970: 90),
            completedAt: Date(timeIntervalSince1970: 120),
            settings: [setting],
            aggregateStatus: .successful
        )
    }
}
