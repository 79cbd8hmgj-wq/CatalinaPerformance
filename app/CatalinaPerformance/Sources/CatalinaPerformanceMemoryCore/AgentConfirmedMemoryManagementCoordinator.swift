import Foundation
import CatalinaPerformancePriorityCore

public protocol MemoryAgentStatusProviding {
    func currentMemoryAgentStatus() -> MemoryAgentStatus?
}

public final class FileMemoryAgentStatusProvider: MemoryAgentStatusProviding {
    private let statusURL: URL
    private let fileManager: FileManager

    public init(statusURL: URL, fileManager: FileManager = .default) {
        self.statusURL = statusURL
        self.fileManager = fileManager
    }

    public func currentMemoryAgentStatus() -> MemoryAgentStatus? {
        guard fileManager.fileExists(atPath: statusURL.path),
              let data = try? Data(contentsOf: statusURL, options: [.mappedIfSafe]),
              !data.isEmpty,
              data.count <= 65_536 else {
            return nil
        }
        return try? JSONDecoder().decode(MemoryAgentStatus.self, from: data)
    }
}

public final class AgentConfirmedMemoryManagementCoordinator: MemoryManagementCoordinating {
    private let base: MemoryManagementCoordinating
    private let agentStatusProvider: MemoryAgentStatusProviding

    public init(
        base: MemoryManagementCoordinating,
        agentStatusProvider: MemoryAgentStatusProviding
    ) {
        self.base = base
        self.agentStatusProvider = agentStatusProvider
    }

    public func prepareSession(identifier: String, at date: Date) throws -> MemoryManagementStatusSnapshot {
        return reconcile(try base.prepareSession(identifier: identifier, at: date))
    }

    public func updateFrontmostApplication(
        _ application: AppPriorityApplication?,
        at date: Date
    ) -> MemoryManagementStatusSnapshot {
        return reconcile(base.updateFrontmostApplication(application, at: date))
    }

    public func updateAppPriorityApplication(
        _ application: AppPriorityApplication?,
        at date: Date
    ) -> MemoryManagementStatusSnapshot {
        return reconcile(base.updateAppPriorityApplication(application, at: date))
    }

    public func evaluate(telemetry: MemoryTelemetrySnapshot) -> MemoryManagementStatusSnapshot {
        return reconcile(base.evaluate(telemetry: telemetry))
    }

    public func requestImmediateRestore(at date: Date) -> MemoryManagementStatusSnapshot {
        return reconcile(base.requestImmediateRestore(at: date))
    }

    public func currentStatus(at date: Date) -> MemoryManagementStatusSnapshot {
        return reconcile(base.currentStatus(at: date))
    }

    private func reconcile(_ requested: MemoryManagementStatusSnapshot) -> MemoryManagementStatusSnapshot {
        guard let sessionIdentifier = requested.sessionIdentifier else {
            return requested
        }

        guard let agent = agentStatusProvider.currentMemoryAgentStatus(),
              agent.sessionIdentifier == sessionIdentifier else {
            return MemoryManagementStatusSnapshot(
                capturedAt: requested.capturedAt,
                sessionIdentifier: sessionIdentifier,
                pressureState: requested.pressureState,
                managedFamilyCount: 0,
                managedFamilyNames: [],
                interventionActive: false,
                ioPolicyStatus: requested.ioPolicyStatus,
                telemetry: requested.telemetry,
                note: awaitingConfirmationNote(requested)
            )
        }

        let confirmedNames = agent.managedFamilyNames ?? []
        let confirmedCount = max(0, agent.managedFamilyCount)
        let interventionActive = agent.state == .active && confirmedCount > 0
        let note = joinedNotes(requested.note, agent.message)

        return MemoryManagementStatusSnapshot(
            capturedAt: requested.capturedAt,
            sessionIdentifier: sessionIdentifier,
            pressureState: requested.pressureState,
            managedFamilyCount: confirmedCount,
            managedFamilyNames: confirmedNames,
            interventionActive: interventionActive,
            ioPolicyStatus: requested.ioPolicyStatus,
            telemetry: requested.telemetry,
            note: note
        )
    }

    private func awaitingConfirmationNote(_ requested: MemoryManagementStatusSnapshot) -> String? {
        guard requested.managedFamilyCount > 0 else { return requested.note }
        return joinedNotes(
            requested.note,
            "Scheduling was requested, but the privileged Memory Agent has not confirmed an applied intervention yet."
        )
    }

    private func joinedNotes(_ first: String?, _ second: String?) -> String? {
        let values = [first, second].compactMap { value -> String? in
            guard let value = value, !value.isEmpty else { return nil }
            return value
        }
        guard !values.isEmpty else { return nil }
        return values.joined(separator: " ")
    }
}
