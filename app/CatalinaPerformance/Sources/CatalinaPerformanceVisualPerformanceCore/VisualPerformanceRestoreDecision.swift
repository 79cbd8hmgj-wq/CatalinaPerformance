import Foundation

public enum VisualPreferenceObservation: Equatable {
    case absent
    case present(VisualScalarValue)
    case unsupportedType(String)
}

public enum VisualRestoreDisposition: Equatable {
    case restorePrior(VisualScalarValue)
    case deletePreviouslyAbsent
    case preserveManualChange
    case cannotSafelyDecide(String)
}

public enum VisualScalarNormalizer {
    public static func boolean(from rawValue: String) -> Bool? {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes": return true
        case "0", "false", "no": return false
        default: return nil
        }
    }

    public static func integer(from rawValue: String) -> Int64? {
        return Int64(rawValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public static func floatingPoint(from rawValue: String) -> Double? {
        let value = Double(rawValue.trimmingCharacters(in: .whitespacesAndNewlines))
        return value?.isFinite == true ? value : nil
    }

    public static func value(
        from rawValue: String,
        expectedType: VisualScalarType
    ) -> VisualScalarValue? {
        switch expectedType {
        case .boolean:
            return boolean(from: rawValue).map(VisualScalarValue.boolean)
        case .integer:
            return integer(from: rawValue).map(VisualScalarValue.integer)
        case .floatingPoint:
            return floatingPoint(from: rawValue).map(VisualScalarValue.floatingPoint)
        case .string:
            return .string(rawValue.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

public enum VisualRestoreDecision {
    public static func decide(
        record: VisualSettingRecord,
        current: VisualPreferenceObservation
    ) -> VisualRestoreDisposition {
        guard let applied = record.appliedValue else {
            return .cannotSafelyDecide("No verified applied value was recorded.")
        }
        switch current {
        case .absent, .unsupportedType:
            return .preserveManualChange
        case .present(let currentValue):
            guard currentValue.scalarType == applied.scalarType else {
                return .preserveManualChange
            }
            guard valuesMatch(currentValue, applied) else {
                return .preserveManualChange
            }
            if record.priorWasPresent {
                guard let prior = record.priorValue else {
                    return .cannotSafelyDecide(
                        "The prior value was marked present but was not recorded."
                    )
                }
                return .restorePrior(prior)
            }
            return record.priorValue == nil
                ? .deletePreviouslyAbsent
                : .cannotSafelyDecide(
                    "The prior key was marked absent but contains a recorded value."
                )
        }
    }

    public static func observationsMatch(
        _ left: VisualPreferenceObservation,
        _ right: VisualPreferenceObservation
    ) -> Bool {
        switch (left, right) {
        case (.absent, .absent):
            return true
        case (.present(let first), .present(let second)):
            return valuesMatch(first, second)
        case (.unsupportedType(let first), .unsupportedType(let second)):
            return first == second
        default:
            return false
        }
    }

    public static func valuesMatch(
        _ left: VisualScalarValue,
        _ right: VisualScalarValue
    ) -> Bool {
        switch (left, right) {
        case (.boolean(let first), .boolean(let second)):
            return first == second
        case (.integer(let first), .integer(let second)):
            return first == second
        case (.floatingPoint(let first), .floatingPoint(let second)):
            guard first.isFinite, second.isFinite else { return false }
            return Decimal(string: String(first)) == Decimal(string: String(second))
        case (.string(let first), .string(let second)):
            return first == second
        default:
            return false
        }
    }
}
