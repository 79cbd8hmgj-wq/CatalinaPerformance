import XCTest
import Foundation
@testable import CatalinaPerformanceBackgroundServicesCore

final class BackgroundServiceStateStoreTests: XCTestCase {
    private func makeDirectory() -> URL {
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("background-service-store-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeStore() -> (BackgroundServiceStateStore, URL) {
        let directory = makeDirectory()
        return (BackgroundServiceStateStore(directoryURL: directory), directory)
    }

    private func category(_ state: BackgroundServiceCategoryState) -> BackgroundServiceCategoryRecord {
        return BackgroundServiceCategoryRecord(
            category: .photos,
            requested: true,
            state: state,
            note: nil,
            workers: [],
            userResume: nil,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
    }

    private func session(_ state: BackgroundServiceCategoryState, identifier: String = "session-1", schemaVersion: Int = 1) -> BackgroundServiceSessionRecord {
        return BackgroundServiceSessionRecord(
            schemaVersion: schemaVersion,
            sessionIdentifier: identifier,
            requestingUID: 501,
            startedAt: Date(timeIntervalSince1970: 90),
            completedAt: state == .restored ? Date(timeIntervalSince1970: 110) : nil,
            categories: [category(state)]
        )
    }

    private func permissions(_ url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func testMissingActiveFileLoadsAsNil() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertNil(try store.loadActive())
    }

    func testSaveUsesPrivateModesAndLatestAtomicReplacementWins() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try store.saveActive(session(.pending, identifier: "first"))
        try store.saveActive(session(.paused, identifier: "second"))

        XCTAssertEqual(try store.loadActive()?.sessionIdentifier, "second")
        XCTAssertEqual(permissions(directory), 0o700)
        XCTAssertEqual(permissions(store.activeSessionURL), 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.contains(".tmp.") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testResolvedSessionCanBeRemovedButRestoreFailureCannot() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try store.saveActive(session(.restoreFailed))
        XCTAssertThrowsError(try store.removeActiveIfResolved()) { error in
            XCTAssertEqual(error as? BackgroundServiceStateStoreError, .outstandingRestoration)
        }

        try store.saveActive(session(.restored))
        XCTAssertNoThrow(try store.removeActiveIfResolved())
        XCTAssertNil(try store.loadActive())
    }

    func testCompleteWritesCompletedBeforeRemovingResolvedActiveState() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = session(.restored)

        try store.saveActive(record)
        try store.complete(record)

        XCTAssertNil(try store.loadActive())
        XCTAssertEqual(try store.loadCompleted(), record)
        XCTAssertEqual(permissions(store.completedSessionURL), 0o600)
    }

    func testCompletePreservesUnresolvedActiveState() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = session(.restoreFailed)

        try store.saveActive(record)
        XCTAssertThrowsError(try store.complete(record)) { error in
            XCTAssertEqual(error as? BackgroundServiceStateStoreError, .outstandingRestoration)
        }

        XCTAssertEqual(try store.loadActive(), record)
    }

    func testUnsupportedSchemaIsRejected() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(session(.pending, schemaVersion: 2)).write(to: store.activeSessionURL)

        XCTAssertThrowsError(try store.loadActive()) { error in
            XCTAssertEqual(error as? BackgroundServiceStateStoreError, .unsupportedSchema(2))
        }
    }

    func testCorruptJSONIsBackedUpAndReported() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        try Data("not-json".utf8).write(to: store.activeSessionURL)

        XCTAssertThrowsError(try store.loadActive()) { error in
            XCTAssertEqual(error as? BackgroundServiceStateStoreError, .corruptState)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: store.activeSessionURL.path))
        let backups = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("active-session.corrupt-") && $0.hasSuffix(".json") }
        XCTAssertEqual(backups.count, 1)
    }

    func testSymlinkedDirectoryAndFileAreRejected() throws {
        let root = makeDirectory()
        let real = root.appendingPathComponent("real", isDirectory: true)
        let linked = root.appendingPathComponent("linked", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true, attributes: nil)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: real)

        let directoryStore = BackgroundServiceStateStore(directoryURL: linked)
        XCTAssertThrowsError(try directoryStore.saveActive(session(.pending))) { error in
            XCTAssertEqual(error as? BackgroundServiceStateStoreError, .symbolicLinkRejected)
        }

        let fileStore = BackgroundServiceStateStore(directoryURL: real)
        let destination = real.appendingPathComponent("other.json")
        try Data("{}".utf8).write(to: destination)
        try FileManager.default.createSymbolicLink(at: fileStore.activeSessionURL, withDestinationURL: destination)
        XCTAssertThrowsError(try fileStore.loadActive()) { error in
            XCTAssertEqual(error as? BackgroundServiceStateStoreError, .symbolicLinkRejected)
        }
    }

    func testOversizedStateIsRejected() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        try Data(repeating: 0x20, count: BackgroundServiceStateStore.maximumFileSize + 1)
            .write(to: store.activeSessionURL)

        XCTAssertThrowsError(try store.loadActive()) { error in
            XCTAssertEqual(error as? BackgroundServiceStateStoreError, .fileTooLarge)
        }
    }
}
