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


    func testVersionOneRuntimeStateDecodesWithoutFocusedFields() throws {
        let json = """
        {
          "version": 1,
          "sessionIdentifier": "legacy-session",
          "selectedApplication": {
            "displayName": "Firefox",
            "bundleIdentifier": "org.mozilla.firefox",
            "bundlePath": "/Applications/Firefox.app",
            "executablePath": "/Applications/Firefox.app/Contents/MacOS/firefox"
          },
          "requestingUID": 501,
          "monitorIdentity": null,
          "records": [],
          "startedAt": "1970-01-01T00:01:40Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(AppPriorityRuntimeState.self, from: Data(json.utf8))
        XCTAssertEqual(state.version, 1)
        XCTAssertNil(state.focusedFirefoxState)
        XCTAssertNil(state.policyKind)
    }

    func testFocusedRuntimeStateRoundTripsRoleTaggedRecordsAndSelectorState() throws {
        let temporaryRoot = root()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let store = AppPriorityStateStore(runtimeRoot: temporaryRoot, requestingUID: 501)
        let application = AppPriorityApplication(
            displayName: "Firefox",
            bundleIdentifier: "org.mozilla.firefox",
            bundlePath: "/Applications/Firefox.app",
            executablePath: "/Applications/Firefox.app/Contents/MacOS/firefox"
        )
        let parent = AppPriorityProcessIdentity(pid: 612, parentPID: 1, effectiveUID: 501, executablePath: application.executablePath, startSeconds: 10, startMicroseconds: 1, processName: "firefox", niceValue: 0)
        let gpu = AppPriorityProcessIdentity(pid: 616, parentPID: 612, effectiveUID: 501, executablePath: "/Applications/Firefox.app/Contents/MacOS/gpu-helper.app/Contents/MacOS/Firefox GPU Helper", startSeconds: 11, startMicroseconds: 1, processName: "Firefox GPU Helper", niceValue: 0)
        let content = AppPriorityProcessIdentity(pid: 844, parentPID: 612, effectiveUID: 501, executablePath: "/Applications/Firefox.app/Contents/MacOS/plugin-container.app/Contents/MacOS/plugin-container", startSeconds: 12, startMicroseconds: 1, processName: "plugin-container", niceValue: 0)
        let selectorState = FocusedFirefoxContentSelectionState(
            priorCounters: [FocusedFirefoxCPUCounter(identity: content, cumulativeNanoseconds: 5_000)],
            currentTarget: content,
            candidateIdentity: nil,
            candidateWinCount: 0
        )
        let focused = FocusedFirefoxRuntimeState(
            parentIdentity: parent,
            gpuIdentity: gpu,
            contentTargetIdentity: content,
            contentSelectionState: selectorState,
            trackedProcessCount: 13,
            warning: nil
        )
        let record = AppPriorityRestoreRecord(
            identity: content,
            originalNiceValue: 0,
            didChangePriority: true,
            lastObservedStatus: .changed,
            errorMessage: nil,
            role: .contentTarget
        )
        let runtime = AppPriorityRuntimeState(
            sessionIdentifier: "focused-session",
            selectedApplication: application,
            requestingUID: 501,
            monitorIdentity: nil,
            records: [record],
            startedAt: Date(timeIntervalSince1970: 100),
            policyKind: .focusedFirefox,
            focusedFirefoxState: focused
        )

        try store.writeRuntimeState(runtime)
        let decoded = try store.loadRuntimeState()

        XCTAssertEqual(decoded.version, 2)
        XCTAssertEqual(decoded.policyKind, .focusedFirefox)
        XCTAssertEqual(decoded.focusedFirefoxState, focused)
        XCTAssertEqual(decoded.records.first?.role, .contentTarget)
    }
}
