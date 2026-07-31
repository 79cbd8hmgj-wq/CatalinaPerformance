import XCTest
import Foundation
@testable import CatalinaPerformancePriorityCore

final class AppPriorityStateStoreTests: XCTestCase {
    private func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func permissions(_ url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func state(records: [AppPriorityRestoreRecord] = []) -> AppPriorityRuntimeState {
        let application = AppPriorityApplication(displayName: "TextEdit", bundleIdentifier: "com.apple.TextEdit", bundlePath: "/Applications/TextEdit.app", executablePath: "/Applications/TextEdit.app/Contents/MacOS/TextEdit")
        return AppPriorityRuntimeState(sessionIdentifier: "session-1", selectedApplication: application, requestingUID: 501, monitorIdentity: nil, records: records, startedAt: Date(timeIntervalSince1970: 100))
    }

    func testWritesPrivateStateAndPublicStatusWithExpectedModes() throws {
        let temporaryRoot = root()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let store = AppPriorityStateStore(runtimeRoot: temporaryRoot, requestingUID: 501)
        try store.prepareDirectories()
        try store.writeRuntimeState(state())
        try store.writeStatus(AppPriorityStatus(state: .active, boostedCount: 2, skippedCount: 1, message: "Active", sessionIdentifier: "session-1"))
        XCTAssertEqual(permissions(store.paths.privateDirectory), 0o700)
        XCTAssertEqual(permissions(store.paths.runtimeStateFile), 0o600)
        XCTAssertEqual(permissions(store.paths.statusFile), 0o644)
    }

    func testAtomicReplacementRoundTripsLatestState() throws {
        let temporaryRoot = root()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let store = AppPriorityStateStore(runtimeRoot: temporaryRoot, requestingUID: 501)
        try store.writeRuntimeState(state())
        let identity = AppPriorityProcessIdentity(pid: 10, parentPID: 1, effectiveUID: 501, executablePath: "/tmp/app", startSeconds: 1, startMicroseconds: 0, processName: "app", niceValue: 0)
        let record = AppPriorityRestoreRecord(identity: identity, originalNiceValue: 0, didChangePriority: true, lastObservedStatus: .failed, errorMessage: "restore failed")
        try store.writeRuntimeState(state(records: [record]))
        XCTAssertEqual(try store.loadRuntimeState().records, [record])
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: store.paths.privateDirectory.path).filter { $0.contains(".tmp.") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testStatusContainsNoPrivateRecordDetails() throws {
        let temporaryRoot = root()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let store = AppPriorityStateStore(runtimeRoot: temporaryRoot, requestingUID: 501)
        try store.writeStatus(AppPriorityStatus(state: .active, boostedCount: 1, skippedCount: 0, message: "Active", sessionIdentifier: "session"))
        let text = String(data: try Data(contentsOf: store.paths.statusFile), encoding: .utf8)!
        XCTAssertFalse(text.contains("executablePath"))
        XCTAssertFalse(text.contains("originalNiceValue"))
    }

    func testStopRequestCanBeCreatedAndCleared() throws {
        let temporaryRoot = root()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let store = AppPriorityStateStore(runtimeRoot: temporaryRoot, requestingUID: 501)
        XCTAssertFalse(store.stopRequested())
        try store.createStopRequest()
        XCTAssertTrue(store.stopRequested())
        XCTAssertEqual(permissions(store.paths.stopRequestFile), 0o600)
        store.clearStopRequest()
        XCTAssertFalse(store.stopRequested())
    }

    func testFailedRecordsRemainUntilSuccessfulCleanup() throws {
        let temporaryRoot = root()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let store = AppPriorityStateStore(runtimeRoot: temporaryRoot, requestingUID: 501)
        let identity = AppPriorityProcessIdentity(pid: 10, parentPID: 1, effectiveUID: 501, executablePath: "/tmp/app", startSeconds: 1, startMicroseconds: 0, processName: "app", niceValue: 0)
        let record = AppPriorityRestoreRecord(identity: identity, originalNiceValue: 0, didChangePriority: true, lastObservedStatus: .failed, errorMessage: "failed")
        try store.writeRuntimeState(state(records: [record]))
        XCTAssertEqual(store.runtimeStateIfPresent()?.records.count, 1)
        store.removeRuntimeFilesAfterSuccessfulRestore()
        XCTAssertNil(store.runtimeStateIfPresent())
    }
}
