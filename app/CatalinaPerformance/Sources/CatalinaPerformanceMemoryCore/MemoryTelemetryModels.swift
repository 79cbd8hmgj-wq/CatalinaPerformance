import Foundation

public enum MemoryPressureState: Int, Codable, Comparable {
    case healthy = 0
    case elevated = 1
    case high = 2
    case critical = 3

    public static func < (lhs: MemoryPressureState, rhs: MemoryPressureState) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }
}

public struct MemoryVMCounters: Codable, Equatable {
    public let physicalBytes: UInt64
    public let availableBytes: UInt64
    public let compressedBytes: UInt64?
    public let swapUsedBytes: UInt64
    public let compressions: UInt64?
    public let decompressions: UInt64?
    public let pageIns: UInt64?
    public let pageOuts: UInt64?
    public let swapIns: UInt64?
    public let swapOuts: UInt64?
    public let pageSizeBytes: UInt64

    public init(
        physicalBytes: UInt64,
        availableBytes: UInt64,
        compressedBytes: UInt64?,
        swapUsedBytes: UInt64,
        compressions: UInt64?,
        decompressions: UInt64?,
        pageIns: UInt64?,
        pageOuts: UInt64?,
        swapIns: UInt64?,
        swapOuts: UInt64?,
        pageSizeBytes: UInt64
    ) {
        self.physicalBytes = physicalBytes
        self.availableBytes = availableBytes
        self.compressedBytes = compressedBytes
        self.swapUsedBytes = swapUsedBytes
        self.compressions = compressions
        self.decompressions = decompressions
        self.pageIns = pageIns
        self.pageOuts = pageOuts
        self.swapIns = swapIns
        self.swapOuts = swapOuts
        self.pageSizeBytes = pageSizeBytes
    }
}

public struct MemoryTelemetryRates: Codable, Equatable {
    public let compressionBytesPerSecond: Double?
    public let swapGrowthBytesPerSecond: Double?
    public let swapInBytesPerSecond: Double?
    public let swapOutBytesPerSecond: Double?
    public let pageOutsPerSecond: Double?

    public init(
        compressionBytesPerSecond: Double?,
        swapGrowthBytesPerSecond: Double?,
        swapInBytesPerSecond: Double?,
        swapOutBytesPerSecond: Double?,
        pageOutsPerSecond: Double?
    ) {
        self.compressionBytesPerSecond = compressionBytesPerSecond
        self.swapGrowthBytesPerSecond = swapGrowthBytesPerSecond
        self.swapInBytesPerSecond = swapInBytesPerSecond
        self.swapOutBytesPerSecond = swapOutBytesPerSecond
        self.pageOutsPerSecond = pageOutsPerSecond
    }

    public static var unavailable: MemoryTelemetryRates {
        return MemoryTelemetryRates(
            compressionBytesPerSecond: nil,
            swapGrowthBytesPerSecond: nil,
            swapInBytesPerSecond: nil,
            swapOutBytesPerSecond: nil,
            pageOutsPerSecond: nil
        )
    }
}

public struct MemoryTelemetrySnapshot: Codable, Equatable {
    public let capturedAt: Date
    public let counters: MemoryVMCounters?
    public let rates: MemoryTelemetryRates
    public let note: String?

    public init(
        capturedAt: Date,
        counters: MemoryVMCounters?,
        rates: MemoryTelemetryRates,
        note: String?
    ) {
        self.capturedAt = capturedAt
        self.counters = counters
        self.rates = rates
        self.note = note
    }
}

public enum MemoryIOPolicyStatus: String, Codable, Equatable {
    case unsupported
    case available
    case active
}

public struct MemoryManagementStatusSnapshot: Codable, Equatable {
    public let capturedAt: Date
    public let pressureState: MemoryPressureState
    public let managedFamilyCount: Int
    public let managedFamilyNames: [String]
    public let interventionActive: Bool
    public let ioPolicyStatus: MemoryIOPolicyStatus
    public let note: String?

    public init(
        capturedAt: Date,
        pressureState: MemoryPressureState,
        managedFamilyCount: Int,
        managedFamilyNames: [String],
        interventionActive: Bool,
        ioPolicyStatus: MemoryIOPolicyStatus,
        note: String?
    ) {
        self.capturedAt = capturedAt
        self.pressureState = pressureState
        self.managedFamilyCount = managedFamilyCount
        self.managedFamilyNames = managedFamilyNames
        self.interventionActive = interventionActive
        self.ioPolicyStatus = ioPolicyStatus
        self.note = note
    }
}
