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
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "1", "true", "yes":
            return true
        case "0", "false", "no":
            return false
        default:
            return nil
        }
    }

    public static func integer(from rawValue: String) -> Int64? {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return Int64(normalized)
    }

    public static func floatingPoint(from rawValue: String) -> Double? {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, let value = Double(normalized), value.isFinite else {
            return nil
        }
        return value
    }

    public static func value(from rawValue: String, expectedType: VisualScalarType) -> VisualScalarValue? {
        switch expectedType {
        case .boolean:
            guard let value = boolean(from: rawValue) else { return nil }
            return .boolean(value)
        case .integer:
            guard let value = integer(from: rawValue) else { return nil }
            return .integer(value)
        case .floatingPoint:
            guard let value = floatingPoint(from: rawValue) else { return nil }
            return .floatingPoint(value)
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
        guard let appliedValue = record.appliedValue else {
            return .cannotSafelyDecide("No verified applied value was recorded.")
        }
        guard isFiniteIfNeeded(appliedValue) else {
            return .cannotSafelyDecide("The recorded applied value is not finite.")
        }

        switch current {
        case .absent:
            return .preserveManualChange
        case .unsupportedType:
            return .preserveManualChange
        case .present(let currentValue):
            guard isFiniteIfNeeded(currentValue) else {
                return .cannotSafelyDecide("The current value is not finite.")
            }
            guard currentValue.scalarType == appliedValue.scalarType else {
                return .preserveManualChange
            }
            guard valuesMatch(currentValue, appliedValue) else {
                return .preserveManualChange
            }

            if record.priorWasPresent {
                guard let priorValue = record.priorValue else {
                    return .cannotSafelyDecide("The prior value was marked present but was not recorded.")
                }
                guard isFiniteIfNeeded(priorValue) else {
                    return .cannotSafelyDecide("The recorded prior value is not finite.")
                }
                return .restorePrior(priorValue)
            }
            guard record.priorValue == nil else {
                return .cannotSafelyDecide("The prior key was marked absent but contains a recorded value.")
            }
            return .deletePreviouslyAbsent
        }
    }

    private static func isFiniteIfNeeded(_ value: VisualScalarValue) -> Bool {
        switch value {
        case .floatingPoint(let number):
            return number.isFinite
        default:
            return true
        }
    }

    private static func valuesMatch(_ left: VisualScalarValue, _ right: VisualScalarValue) -> Bool {
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
