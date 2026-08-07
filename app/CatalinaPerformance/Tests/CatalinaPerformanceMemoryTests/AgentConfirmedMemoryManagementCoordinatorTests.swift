import XCTest
import CatalinaPerformancePriorityCore
@testable import CatalinaPerformanceMemoryCore

final class AgentConfirmedMemoryManagementCoordinatorTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_000)

    func testRequestedFamilyIsNotReportedManagedBeforeAgentConfirmation() {
        let base = ConfirmationBaseCoordinator(status: requestedStatus())
        let provider = ConfirmationAgentProvider(status: nil)
        let coordinator = AgentConfirmedMemoryManagementCoordinator(
            base: base,
            agentStatusProvider: provider
        )

        let status = coordinator.currentStatus(at: date)

        XCTAssertEqual(status.managedFamilyCount, 0)
        XCTAssertEqual(status.managedFamilyNames, [])
        XCTAssertFalse(status.interventionActive)
        XCTAssertTrue(status.note?.contains("has not confirmed") == true)
    }

    func testMatchingActiveAgentStatusPublishesConfirmedFamilyOnly() {
        let base = ConfirmationBaseCoordinator(status: requestedStatus())
        let provider = ConfirmationAgentProvider(status: MemoryAgentStatus(
            state: .active,
            sessionIdentifier: "session",
            managedFamilyCount: 1,
            managedProcessCount: 3,
            managedFamilyNames: ["Browser"],
            lastAppliedGeneration: 4,
            message: "confirmed"
        ))
        let coordinator = AgentConfirmedMemoryManagementCoordinator(
            base: base,
            agentStatusProvider: provider
        )

        let status = coordinator.currentStatus(at: date)

        XCTAssertEqual(status.managedFamilyCount, 1)
        XCTAssertEqual(status.managedFamilyNames, ["Browser"])
        XCTAssertTrue(status.interventionActive)
        XCTAssertTrue(status.note?.contains("confirmed") == true)
    }

    func testStaleAgentSessionIsIgnored() {
        let base = ConfirmationBaseCoordinator(status: requestedStatus())
        let provider = ConfirmationAgentProvider(status: MemoryAgentStatus(
            state: .active,
            sessionIdentifier: "old-session",
            managedFamilyCount: 1,
            managedProcessCount: 2,
            managedFamilyNames: ["Old App"],
            lastAppliedGeneration: 9,
            message: "stale"
        ))
        let coordinator = AgentConfirmedMemoryManagementCoordinator(
            base: base,
            agentStatusProvider: provider
        )

        let status = coordinator.currentStatus(at: date)

        XCTAssertEqual(status.managedFamilyCount, 0)
        XCTAssertEqual(status.managedFamilyNames, [])
        XCTAssertFalse(status.interventionActive)
    }

    func testRestoreRequestDoesNotPretendInterventionEndedBeforeAgentConfirms() {
        let requestedRestore = MemoryManagementStatusSnapshot(
            capturedAt: date,
            sessionIdentifier: "session",
            pressureState: .healthy,
            managedFamilyCount: 0,
            managedFamilyNames: [],
            interventionActive: false,
            ioPolicyStatus: .unsupported,
            telemetry: nil,
            note: "restore requested"
        )
        let base = ConfirmationBaseCoordinator(status: requestedRestore)
        let provider = ConfirmationAgentProvider(status: MemoryAgentStatus(
            state: .active,
            sessionIdentifier: "session",
            managedFamilyCount: 1,
            managedProcessCount: 1,
            managedFamilyNames: ["Browser"],
            lastAppliedGeneration: 5,
            message: "agent still active"
        ))
        let coordinator = AgentConfirmedMemoryManagementCoordinator(
            base: base,
            agentStatusProvider: provider
        )

        let status = coordinator.requestImmediateRestore(at: date)

        XCTAssertEqual(status.managedFamilyCount, 1)
        XCTAssertEqual(status.managedFamilyNames, ["Browser"])
        XCTAssertTrue(status.interventionActive)
    }

    private func requestedStatus() -> MemoryManagementStatusSnapshot {
        return MemoryManagementStatusSnapshot(
            capturedAt: date,
            sessionIdentifier: "session",
            pressureState: .high,
            managedFamilyCount: 2,
            managedFamilyNames: ["Browser", "Editor"],
            interventionActive: true,
            ioPolicyStatus: .unsupported,
            telemetry: nil,
            note: "scheduling requested"
        )
    }
}

private final class ConfirmationAgentProvider: MemoryAgentStatusProviding {
    var status: MemoryAgentStatus?
    init(status: MemoryAgentStatus?) { self.status = status }
    func currentMemoryAgentStatus() -> MemoryAgentStatus? { return status }
}

private final class ConfirmationBaseCoordinator: MemoryManagementCoordinating {
    var status: MemoryManagementStatusSnapshot
    init(status: MemoryManagementStatusSnapshot) { self.status = status }

    func prepareSession(identifier: String, at date: Date) throws -> MemoryManagementStatusSnapshot { return status }
    func updateFrontmostApplication(_ application: AppPriorityApplication?, at date: Date) -> MemoryManagementStatusSnapshot { return status }
    func updateAppPriorityApplication(_ application: AppPriorityApplication?, at date: Date) -> MemoryManagementStatusSnapshot { return status }
    func evaluate(telemetry: MemoryTelemetrySnapshot) -> MemoryManagementStatusSnapshot { return status }
    func requestImmediateRestore(at date: Date) -> MemoryManagementStatusSnapshot { return status }
    func currentStatus(at date: Date) -> MemoryManagementStatusSnapshot { return status }
}
