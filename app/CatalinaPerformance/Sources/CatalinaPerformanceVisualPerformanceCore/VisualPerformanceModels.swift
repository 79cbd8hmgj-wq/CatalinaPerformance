import Foundation

public enum VisualSettingID: String, Codable, CaseIterable {
    case finderAnimations
    case dockLaunchAnimation
    case missionControlTransitions
    case windowOpeningAnimations
    case reduceMotion
    case reduceTransparency
    case minimizeEffect
    case dockAutoHideDelay
    case dockAutoHideAnimation

    public static let automaticOrder: [VisualSettingID] = [
        .finderAnimations,
        .dockLaunchAnimation,
        .missionControlTransitions,
        .windowOpeningAnimations,
        .reduceMotion,
        .reduceTransparency,
        .minimizeEffect,
        .dockAutoHideDelay,
        .dockAutoHideAnimation
    ]
}

public enum VisualScalarType: String, Codable, CaseIterable, Hashable {
    case boolean
    case integer
    case floatingPoint
    case string
}

public enum VisualScalarValue: Equatable, Codable {
    case boolean(Bool)
    case integer(Int64)
    case floatingPoint(Double)
    case string(String)

    public var scalarType: VisualScalarType {
        switch self {
        case .boolean: return .boolean
        case .integer: return .integer
        case .floatingPoint: return .floatingPoint
        case .string: return .string
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case boolean
        case integer
        case floatingPoint
        case string
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(VisualScalarType.self, forKey: .type)
        switch type {
        case .boolean:
            self = .boolean(try container.decode(Bool.self, forKey: .boolean))
        case .integer:
            self = .integer(try container.decode(Int64.self, forKey: .integer))
        case .floatingPoint:
            self = .floatingPoint(try container.decode(Double.self, forKey: .floatingPoint))
        case .string:
            self = .string(try container.decode(String.self, forKey: .string))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(scalarType, forKey: .type)
        switch self {
        case .boolean(let value):
            try container.encode(value, forKey: .boolean)
        case .integer(let value):
            try container.encode(value, forKey: .integer)
        case .floatingPoint(let value):
            try container.encode(value, forKey: .floatingPoint)
        case .string(let value):
            try container.encode(value, forKey: .string)
        }
    }
}

public enum VisualSettingApplicability: String, Codable {
    case always
    case dockAutoHideEnabled
}

public enum VisualRefreshBehavior: String, Codable {
    case immediate
    case deferredComponentRefresh
}

public struct VisualSettingCatalogEntry: Equatable {
    public let id: VisualSettingID
    public let displayName: String
    public let domain: String
    public let key: String
    public let acceptedExistingTypes: Set<VisualScalarType>
    public let appliedValue: VisualScalarValue
    public let applicability: VisualSettingApplicability
    public let refreshBehavior: VisualRefreshBehavior

    public init(
        id: VisualSettingID,
        displayName: String,
        domain: String,
        key: String,
        acceptedExistingTypes: Set<VisualScalarType>,
        appliedValue: VisualScalarValue,
        applicability: VisualSettingApplicability,
        refreshBehavior: VisualRefreshBehavior
    ) {
        self.id = id
        self.displayName = displayName
        self.domain = domain
        self.key = key
        self.acceptedExistingTypes = acceptedExistingTypes
        self.appliedValue = appliedValue
        self.applicability = applicability
        self.refreshBehavior = refreshBehavior
    }
}

public enum VisualSettingOutcome: String, Codable {
    case pending
    case applied
    case appliedDeferred
    case restored
    case preservedManualChange
    case notApplicable
    case unsupported
    case applyFailed
    case restoreFailed
    case recoveryRequired
}

public struct VisualSettingRecord: Codable, Equatable {
    public let id: VisualSettingID
    public let displayName: String
    public let priorWasPresent: Bool
    public let priorValue: VisualScalarValue?
    public let appliedValue: VisualScalarValue?
    public let outcome: VisualSettingOutcome
    public let note: String?
    public let updatedAt: Date

    public init(
        id: VisualSettingID,
        displayName: String,
        priorWasPresent: Bool,
        priorValue: VisualScalarValue?,
        appliedValue: VisualScalarValue?,
        outcome: VisualSettingOutcome,
        note: String?,
        updatedAt: Date
    ) {
        self.id = id
        self.displayName = displayName
        self.priorWasPresent = priorWasPresent
        self.priorValue = priorValue
        self.appliedValue = appliedValue
        self.outcome = outcome
        self.note = note
        self.updatedAt = updatedAt
    }

    public func replacing(
        outcome: VisualSettingOutcome,
        note: String?,
        updatedAt: Date
    ) -> VisualSettingRecord {
        return VisualSettingRecord(
            id: id,
            displayName: displayName,
            priorWasPresent: priorWasPresent,
            priorValue: priorValue,
            appliedValue: appliedValue,
            outcome: outcome,
            note: note,
            updatedAt: updatedAt
        )
    }
}

public enum VisualPerformanceAggregateStatus: String, Codable {
    case notConfigured
    case preparing
    case applied
    case appliedWithLimitations
    case failed
    case restoring
    case recoveryRequired
    case successful
    case partiallyRestored

    public static func active(for records: [VisualSettingRecord]) -> VisualPerformanceAggregateStatus {
        guard !records.isEmpty else { return .notConfigured }
        if records.contains(where: {
            $0.outcome == .recoveryRequired || $0.outcome == .restoreFailed
        }) {
            return .recoveryRequired
        }
        if records.contains(where: { $0.outcome == .pending }) {
            return .preparing
        }

        let hasApplied = records.contains(where: {
            $0.outcome == .applied || $0.outcome == .appliedDeferred
        })
        let hasApplyFailure = records.contains(where: {
            $0.outcome == .applyFailed
        })
        let hasUnsupported = records.contains(where: {
            $0.outcome == .unsupported
        })

        if hasApplyFailure || hasUnsupported {
            return hasApplied ? .appliedWithLimitations : .failed
        }
        if hasApplied {
            return .applied
        }
        return .appliedWithLimitations
    }

    public static func completed(for records: [VisualSettingRecord]) -> VisualPerformanceAggregateStatus {
        guard !records.isEmpty else { return .notConfigured }
        let incomplete = records.contains { record in
            switch record.outcome {
            case .pending, .applied, .appliedDeferred, .restoreFailed, .recoveryRequired:
                return true
            default:
                return false
            }
        }
        return incomplete ? .partiallyRestored : .successful
    }
}

public struct VisualPerformanceSessionRecord: Codable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let sessionIdentifier: String
    public let requestingUID: UInt32
    public let startedAt: Date
    public let completedAt: Date?
    public let settings: [VisualSettingRecord]
    public let aggregateStatus: VisualPerformanceAggregateStatus

    public init(
        schemaVersion: Int = VisualPerformanceSessionRecord.currentSchemaVersion,
        sessionIdentifier: String,
        requestingUID: UInt32,
        startedAt: Date,
        completedAt: Date?,
        settings: [VisualSettingRecord],
        aggregateStatus: VisualPerformanceAggregateStatus
    ) {
        self.schemaVersion = schemaVersion
        self.sessionIdentifier = sessionIdentifier
        self.requestingUID = requestingUID
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.settings = settings
        self.aggregateStatus = aggregateStatus
    }

    public var hasOutstandingRestoration: Bool {
        if aggregateStatus == .recoveryRequired || aggregateStatus == .partiallyRestored {
            return true
        }
        return settings.contains { record in
            switch record.outcome {
            case .pending, .applied, .appliedDeferred, .restoreFailed, .recoveryRequired:
                return true
            default:
                return false
            }
        }
    }
}

public struct VisualPerformanceStatusSnapshot: Codable, Equatable {
    public let schemaVersion: Int
    public let sessionIdentifier: String?
    public let aggregateStatus: VisualPerformanceAggregateStatus
    public let settings: [VisualSettingRecord]
    public let updatedAt: Date

    public init(
        schemaVersion: Int = VisualPerformanceSessionRecord.currentSchemaVersion,
        sessionIdentifier: String?,
        aggregateStatus: VisualPerformanceAggregateStatus,
        settings: [VisualSettingRecord],
        updatedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.sessionIdentifier = sessionIdentifier
        self.aggregateStatus = aggregateStatus
        self.settings = settings
        self.updatedAt = updatedAt
    }

    public var hasUnresolvedRestoration: Bool {
        if aggregateStatus == .recoveryRequired || aggregateStatus == .partiallyRestored {
            return true
        }
        return settings.contains {
            $0.outcome == .restoreFailed || $0.outcome == .recoveryRequired
        }
    }
}
