import XCTest
import CatalinaPerformancePriorityCore
@testable import CatalinaPerformanceMemoryCore

final class MemoryAgentConfirmedStateTests: XCTestCase {
    func testConfirmedSummaryIncludesOnlyVerifiedChangedProcesses() {
        let changed = processRecord(pid: 10, family: "browser", changed: true, state: .changed)
        let unchanged = processRecord(pid: 11, family: "browser", changed: false, state: .unchanged)
        let failed = processRecord(pid: 20, family: "editor", changed: true, state: .failed)
        let restored = processRecord(pid: 30, family: "chat", changed: true, state: .restored)
        let state = MemoryAgentRuntimeState(
            sessionIdentifier: "session",
            requestingUID: 501,
            startedAt: Date(timeIntervalSince1970: 1),
            lastAppliedGeneration: 2,
            monitorIdentity: nil,
            managedFamilies: [
                MemoryManagedFamilyRecord(
                    identifier: "browser",
                    displayName: "Browser",
                    bundlePath: "/Applications/Browser.app",
                    processes: [changed, unchanged]
                ),
                MemoryManagedFamilyRecord(
                    identifier: "editor",
                    displayName: "Editor",
                    bundlePath: "/Applications/Editor.app",
                    processes: [failed]
                ),
                MemoryManagedFamilyRecord(
                    identifier: "chat",
                    displayName: "Chat",
                    bundlePath: "/Applications/Chat.app",
                    processes: [restored]
                )
            ]
        )

        XCTAssertEqual(state.confirmedManagementSummary.managedFamilyNames, ["Browser"])
        XCTAssertEqual(state.confirmedManagementSummary.managedFamilyCount, 1)
        XCTAssertEqual(state.confirmedManagementSummary.managedProcessCount, 1)
    }

    func testAgentStatusDecodesWithoutNewFamilyNamesField() throws {
        let json = """
        {"state":"monitoring","sessionIdentifier":"old","managedFamilyCount":0,"managedProcessCount":0,"lastAppliedGeneration":1,"message":"old status"}
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(MemoryAgentStatus.self, from: json)

        XCTAssertNil(decoded.managedFamilyNames)
        XCTAssertEqual(decoded.managedFamilyCount, 0)
    }

    private func processRecord(
        pid: Int32,
        family: String,
        changed: Bool,
        state: MemoryRestorationState
    ) -> MemoryManagedProcessRecord {
        let identity = AppPriorityProcessIdentity(
            pid: pid,
            parentPID: 1,
            effectiveUID: 501,
            executablePath: "/Applications/Test.app/Contents/MacOS/Test",
            startSeconds: Int64(pid),
            startMicroseconds: 0,
            processName: "Test",
            niceValue: 0
        )
        return MemoryManagedProcessRecord(
            identity: identity,
            familyIdentifier: family,
            originalNiceValue: 0,
            appliedNiceValue: changed ? 5 : 8,
            didChangePriority: changed,
            restorationState: state,
            errorMessage: nil
        )
    }
}
