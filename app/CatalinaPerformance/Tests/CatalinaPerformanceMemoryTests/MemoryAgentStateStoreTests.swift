import XCTest
import CatalinaPerformancePriorityCore
@testable import CatalinaPerformanceMemoryCore

final class MemoryAgentStateStoreTests: XCTestCase {
    func testRuntimeStateRoundTripsAndUsesExpectedPaths() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryAgentStateStore(runtimeRoot: root, requestingUID: 501)
        let state = runtimeState(restorationState: .changed)

        try store.writeRuntimeState(state)

        XCTAssertEqual(try store.loadRuntimeState(), state)
        XCTAssertTrue(store.paths.runtimeStateFile.path.contains("/501/memory_management/private/session.json"))
    }

    func testOutstandingRestorationPreventsRuntimeDeletion() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryAgentStateStore(runtimeRoot: root, requestingUID: 501)
        try store.writeRuntimeState(runtimeState(restorationState: .changed))

        store.removeRuntimeFilesAfterSuccessfulRestore()

        XCTAssertTrue(FileManager.default.fileExists(atPath: store.paths.runtimeStateFile.path))
    }

    func testResolvedStateCanBeRemoved() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryAgentStateStore(runtimeRoot: root, requestingUID: 501)
        try store.writeRuntimeState(runtimeState(restorationState: .restored))

        store.removeRuntimeFilesAfterSuccessfulRestore()

        XCTAssertFalse(FileManager.default.fileExists(atPath: store.paths.runtimeStateFile.path))
    }

    func testCorruptRuntimeStateThrowsWithoutBeingSilentlyAccepted() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryAgentStateStore(runtimeRoot: root, requestingUID: 501)
        try store.prepareDirectories()
        try Data("not-json".utf8).write(to: store.paths.runtimeStateFile)

        XCTAssertThrowsError(try store.loadRuntimeState()) { error in
            XCTAssertEqual(error as? MemoryAgentStateStoreError, .corruptState)
        }
    }

    func testStopRequestLifecycle() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryAgentStateStore(runtimeRoot: root, requestingUID: 501)

        try store.createStopRequest()
        XCTAssertTrue(store.stopRequested())
        store.clearStopRequest()
        XCTAssertFalse(store.stopRequested())
    }

    private func runtimeState(restorationState: MemoryRestorationState) -> MemoryAgentRuntimeState {
        let identity = AppPriorityProcessIdentity(
            pid: 10,
            parentPID: 1,
            effectiveUID: 501,
            executablePath: "/Applications/App.app/Contents/MacOS/App",
            startSeconds: 100,
            startMicroseconds: 0,
            processName: "App",
            niceValue: 0
        )
        let process = MemoryManagedProcessRecord(
            identity: identity,
            familyIdentifier: "/applications/app.app",
            originalNiceValue: 0,
            appliedNiceValue: 5,
            didChangePriority: true,
            restorationState: restorationState,
            errorMessage: nil
        )
        let family = MemoryManagedFamilyRecord(
            identifier: "/applications/app.app",
            displayName: "App",
            bundlePath: "/Applications/App.app",
            processes: [process]
        )
        return MemoryAgentRuntimeState(
            sessionIdentifier: "session",
            requestingUID: 501,
            startedAt: Date(timeIntervalSince1970: 100),
            lastAppliedGeneration: 1,
            monitorIdentity: nil,
            managedFamilies: [family]
        )
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
