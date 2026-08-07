import Foundation

public struct CatalinaMemoryCapabilities: Equatable {
    public let compressedBytes: Bool
    public let compressionCounters: Bool
    public let pageOutCounters: Bool
    public let swapInOutCounters: Bool
    public let nativePressureState: Bool
    public let taskPolicy: Bool

    public init(
        compressedBytes: Bool,
        compressionCounters: Bool,
        pageOutCounters: Bool,
        swapInOutCounters: Bool,
        nativePressureState: Bool,
        taskPolicy: Bool
    ) {
        self.compressedBytes = compressedBytes
        self.compressionCounters = compressionCounters
        self.pageOutCounters = pageOutCounters
        self.swapInOutCounters = swapInOutCounters
        self.nativePressureState = nativePressureState
        self.taskPolicy = taskPolicy
    }

    /// Reviewed against macOS Catalina 10.15.7 build 19H15 on the target Intel Mac.
    ///
    /// The probe confirmed 4 KiB pages, compressor occupancy/counters, pageouts,
    /// swapins, and swapouts. `vm.memory_pressure` exists but only the normal value
    /// was observed, so its nonzero semantics remain intentionally untrusted.
    /// `taskpolicy` remains disabled until its separate apply/restore calibration.
    public static let current = CatalinaMemoryCapabilities(
        compressedBytes: true,
        compressionCounters: true,
        pageOutCounters: true,
        swapInOutCounters: true,
        nativePressureState: false,
        taskPolicy: false
    )
}

public struct MemoryPressureThresholds: Equatable {
    public let availableModerateFraction: Double
    public let availableStrongFraction: Double
    public let availableSevereFraction: Double
    public let compressedModerateFraction: Double
    public let compressedStrongFraction: Double

    /// A reviewed zero floor means "positive sustained activity is evidence".
    /// The classifier still requires corroborating pressure signals and consecutive
    /// samples, so a single page/counter increment never authorizes mutation.
    public let compressionActivityBytesPerSecond: Double
    public let swapOutActivityBytesPerSecond: Double
    public let pageOutActivityPagesPerSecond: Double

    /// The first read-only probe captured swap usage once, so growth/churn rate
    /// thresholds are deliberately unavailable until a later Catalina runtime
    /// validation provides repeated swap-usage evidence under controlled pressure.
    public let swapGrowthBytesPerSecond: Double?
    public let swapChurnBytesPerSecond: Double?

    public init(
        availableModerateFraction: Double,
        availableStrongFraction: Double,
        availableSevereFraction: Double,
        compressedModerateFraction: Double,
        compressedStrongFraction: Double,
        compressionActivityBytesPerSecond: Double,
        swapOutActivityBytesPerSecond: Double,
        pageOutActivityPagesPerSecond: Double,
        swapGrowthBytesPerSecond: Double?,
        swapChurnBytesPerSecond: Double?
    ) {
        self.availableModerateFraction = availableModerateFraction
        self.availableStrongFraction = availableStrongFraction
        self.availableSevereFraction = availableSevereFraction
        self.compressedModerateFraction = compressedModerateFraction
        self.compressedStrongFraction = compressedStrongFraction
        self.compressionActivityBytesPerSecond = compressionActivityBytesPerSecond
        self.swapOutActivityBytesPerSecond = swapOutActivityBytesPerSecond
        self.pageOutActivityPagesPerSecond = pageOutActivityPagesPerSecond
        self.swapGrowthBytesPerSecond = swapGrowthBytesPerSecond
        self.swapChurnBytesPerSecond = swapChurnBytesPerSecond
    }

    public static let catalina10157 = MemoryPressureThresholds(
        availableModerateFraction: 0.15,
        availableStrongFraction: 0.08,
        availableSevereFraction: 0.05,
        compressedModerateFraction: 0.20,
        compressedStrongFraction: 0.30,
        compressionActivityBytesPerSecond: 0.0,
        swapOutActivityBytesPerSecond: 0.0,
        pageOutActivityPagesPerSecond: 0.0,
        swapGrowthBytesPerSecond: nil,
        swapChurnBytesPerSecond: nil
    )
}
