import XCTest
import CatalinaPerformancePriorityCore
@testable import CatalinaPerformanceMemoryCore

final class MemoryManagementRecoveryTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_000)

    func testCurrentStatusRecoversPersistedActiveSession() {
        let store = RecoveryDesiredStateStore(state: desiredState(generation: 7, stop: false))
        let coordinator = makeCoordinator(store: store)

        let status = coordinator.currentStatus(at: date)

        XCTAssertEqual(status.sessionIdentifier, "persisted-session")
        XCTAssertEqual(status.managedFamilyCount, 1)
        XCTAssertEqual(status.managedFamilyNames, ["Browser"])
        XCTAssertTrue(status.interventionActive)
    }

    func testFrontmostUpdateAfterRelaunchRemovesRecoveredFamilyImmediately() {
        let store = RecoveryDesiredStateStore(state: desiredState(generation: 7, stop: false))
        let coordinator = makeCoordinator(store: store)
        let browser = AppPriorityApplication(
            displayName: "Browser",
            bundleIdentifier: "example.browser",
            bundlePath: "/Applications/Browser.app",
            executablePath: "/Applications/Browser.app/Contents/MacOS/Browser"
        )

        let status = coordinator.updateFrontmostApplication(browser, at: date)

        XCTAssertEqual(status.managedFamilyCount, 0)
        XCTAssertEqual(store.state?.generation, 8)
        XCTAssertEqual(store.state?.families, [])
        XCTAssertEqual(store.state?.shouldStopAndRestore, false)
    }

    func testImmediateRestoreCanRecoverStoredSessionBeforeWritingStopRequest() {
        let store = RecoveryDesiredStateStore(state: desiredState(generation: 11, stop: false))
        let coordinator = makeCoordinator(store: store)

        let status = coordinator.requestImmediateRestore(at: date)

        XCTAssertEqual(status.sessionIdentifier, "persisted-session")
        XCTAssertEqual(status.managedFamilyCount, 0)
        XCTAssertEqual(store.state?.generation, 12)
        XCTAssertEqual(store.state?.families, [])
        XCTAssertEqual(store.state?.shouldStopAndRestore, true)
    }

    private func makeCoordinator(store: RecoveryDesiredStateStore) -> MemoryManagementCoordinator {
        return MemoryManagementCoordinator(
            desiredStateStore: store,
            processInspector: RecoveryProcessInspector(),
            resourceInspector: RecoveryResourceInspector(),
            requestingUID: 501
        )
    }

    private func desiredState(generation: UInt64, stop: Bool) -> MemoryDesiredState {
        let identity = AppPriorityProcessIdentity(
            pid: 10,
            parentPID: 1,
            effectiveUID: 501,
            executablePath: "/Applications/Browser.app/Contents/MacOS/Browser",
            startSeconds: 100,
            startMicroseconds: 0,
            processName: "Browser",
            niceValue: 0
        )
        let identifier = "/applications/browser.app"
        return MemoryDesiredState(
            sessionIdentifier: "persisted-session",
            requestingUID: 501,
            generation: generation,
            shouldStopAndRestore: stop,
            families: stop ? [] : [MemoryDesiredFamily(
                identifier: identifier,
                displayName: "Browser",
                bundlePath: "/Applications/Browser.app",
                processes: [MemoryDesiredProcess(
                    identity: identity,
                    familyIdentifier: identifier,
                    requestedNiceValue: 5
                )]
            )]
        )
    }
}

private final class RecoveryDesiredStateStore: MemoryDesiredStateStoring {
    var state: MemoryDesiredState?
    init(state: MemoryDesiredState?) { self.state = state }
    func load() throws -> MemoryDesiredState? { return state }
    func save(_ state: MemoryDesiredState) throws { self.state = state }
    func remove() throws { state = nil }
}

private final class RecoveryProcessInspector: AppPriorityProcessInspecting {
    func allProcesses() throws -> [AppPriorityProcessIdentity] { return [] }
    func process(pid: Int32) throws -> AppPriorityProcessIdentity {
        throw AppPriorityProcessError.unsupported
    }
}

private final class RecoveryResourceInspector: AppPriorityProcessResourceInspecting {
    func residentBytes(pid: Int32) throws -> UInt64 { return 0 }
}
