import Foundation
import CatalinaProcessSupport

public enum MemoryTelemetryCollectorError: Error, Equatable, CustomStringConvertible {
    case vmReadFailed(Int32)
    case swapReadFailed(Int32)
    case invalidSample

    public var description: String {
        switch self {
        case .vmReadFailed(let code):
            return "VM counter read failed (\(code))."
        case .swapReadFailed(let code):
            return "Swap read failed (\(code))."
        case .invalidSample:
            return "VM counter sample was invalid."
        }
    }
}

public protocol MemoryTelemetryCollecting {
    func capture(at date: Date) -> MemoryTelemetrySnapshot
}

public enum MemoryRateCalculator {
    public static func deltaRate(
        previous: UInt64,
        current: UInt64,
        elapsed: TimeInterval,
        unitBytes: UInt64
    ) -> Double? {
        guard elapsed.isFinite, elapsed > 0, unitBytes > 0, current >= previous else {
            return nil
        }
        let delta = current - previous
        return (Double(delta) * Double(unitBytes)) / elapsed
    }

    public static func signedByteRate(
        previous: UInt64,
        current: UInt64,
        elapsed: TimeInterval
    ) -> Double? {
        guard elapsed.isFinite, elapsed > 0 else { return nil }
        if current >= previous {
            return Double(current - previous) / elapsed
        }
        return -Double(previous - current) / elapsed
    }

    public static func rates(
        previous: MemoryVMCounters,
        current: MemoryVMCounters,
        elapsed: TimeInterval
    ) -> MemoryTelemetryRates {
        guard previous.pageSizeBytes == current.pageSizeBytes else {
            return .unavailable
        }

        return MemoryTelemetryRates(
            compressionBytesPerSecond: optionalDeltaRate(
                previous: previous.compressions,
                current: current.compressions,
                elapsed: elapsed,
                unitBytes: current.pageSizeBytes
            ),
            swapGrowthBytesPerSecond: signedByteRate(
                previous: previous.swapUsedBytes,
                current: current.swapUsedBytes,
                elapsed: elapsed
            ),
            swapInBytesPerSecond: optionalDeltaRate(
                previous: previous.swapIns,
                current: current.swapIns,
                elapsed: elapsed,
                unitBytes: current.pageSizeBytes
            ),
            swapOutBytesPerSecond: optionalDeltaRate(
                previous: previous.swapOuts,
                current: current.swapOuts,
                elapsed: elapsed,
                unitBytes: current.pageSizeBytes
            ),
            pageOutsPerSecond: optionalDeltaRate(
                previous: previous.pageOuts,
                current: current.pageOuts,
                elapsed: elapsed,
                unitBytes: 1
            )
        )
    }

    private static func optionalDeltaRate(
        previous: UInt64?,
        current: UInt64?,
        elapsed: TimeInterval,
        unitBytes: UInt64
    ) -> Double? {
        guard let previousValue = previous, let currentValue = current else {
            return nil
        }
        return deltaRate(
            previous: previousValue,
            current: currentValue,
            elapsed: elapsed,
            unitBytes: unitBytes
        )
    }
}

public final class DarwinMemoryTelemetryCollector: MemoryTelemetryCollecting {
    private enum AvailabilityMask {
        static let compressorPages: UInt64 = 1 << 6
        static let compressions: UInt64 = 1 << 8
        static let decompressions: UInt64 = 1 << 9
        static let pageIns: UInt64 = 1 << 10
        static let pageOuts: UInt64 = 1 << 11
        static let swapIns: UInt64 = 1 << 12
        static let swapOuts: UInt64 = 1 << 13
    }

    private let lock = NSLock()
    private var previousDate: Date?
    private var previousCounters: MemoryVMCounters?

    public init() {}

    public func capture(at date: Date) -> MemoryTelemetrySnapshot {
        lock.lock()
        defer { lock.unlock() }

        do {
            let current = try readCounters()
            let rates: MemoryTelemetryRates
            if let previousDate = previousDate, let previousCounters = previousCounters {
                let elapsed = date.timeIntervalSince(previousDate)
                rates = MemoryRateCalculator.rates(
                    previous: previousCounters,
                    current: current,
                    elapsed: elapsed
                )
            } else {
                rates = .unavailable
            }

            previousDate = date
            previousCounters = current
            return MemoryTelemetrySnapshot(
                capturedAt: date,
                counters: current,
                rates: rates,
                note: nil
            )
        } catch {
            return MemoryTelemetrySnapshot(
                capturedAt: date,
                counters: nil,
                rates: .unavailable,
                note: String(describing: error)
            )
        }
    }

    private func readCounters() throws -> MemoryVMCounters {
        var vm = CPVMMemoryInfo()
        let vmResult = cp_read_vm_memory_info(&vm)
        guard vmResult == 0 else {
            throw MemoryTelemetryCollectorError.vmReadFailed(vmResult)
        }

        var swap = CPSwapInfo()
        let swapResult = cp_read_swap(&swap)
        guard swapResult == 0 else {
            throw MemoryTelemetryCollectorError.swapReadFailed(swapResult)
        }

        let physical = UInt64(vm.physicalBytes)
        let pageSize = UInt64(vm.pageSize)
        guard physical > 0, pageSize > 0 else {
            throw MemoryTelemetryCollectorError.invalidSample
        }

        let freePages = UInt64(vm.freePages)
        let inactivePages = UInt64(vm.inactivePages)
        let availablePagesResult = freePages.addingReportingOverflow(inactivePages)
        guard !availablePagesResult.overflow else {
            throw MemoryTelemetryCollectorError.invalidSample
        }
        let availableBytes = safePageBytes(
            pages: availablePagesResult.partialValue,
            pageSize: pageSize,
            cap: physical
        )
        guard let validatedAvailableBytes = availableBytes else {
            throw MemoryTelemetryCollectorError.invalidSample
        }

        let mask = UInt64(vm.availabilityMask)
        let compressedBytes: UInt64?
        if has(mask: mask, flag: AvailabilityMask.compressorPages) {
            compressedBytes = safePageBytes(
                pages: UInt64(vm.compressorPages),
                pageSize: pageSize,
                cap: physical
            )
        } else {
            compressedBytes = nil
        }

        return MemoryVMCounters(
            physicalBytes: physical,
            availableBytes: validatedAvailableBytes,
            compressedBytes: compressedBytes,
            swapUsedBytes: UInt64(swap.usedBytes),
            compressions: optionalCounter(mask: mask, flag: AvailabilityMask.compressions, value: UInt64(vm.compressions)),
            decompressions: optionalCounter(mask: mask, flag: AvailabilityMask.decompressions, value: UInt64(vm.decompressions)),
            pageIns: optionalCounter(mask: mask, flag: AvailabilityMask.pageIns, value: UInt64(vm.pageIns)),
            pageOuts: optionalCounter(mask: mask, flag: AvailabilityMask.pageOuts, value: UInt64(vm.pageOuts)),
            swapIns: optionalCounter(mask: mask, flag: AvailabilityMask.swapIns, value: UInt64(vm.swapIns)),
            swapOuts: optionalCounter(mask: mask, flag: AvailabilityMask.swapOuts, value: UInt64(vm.swapOuts)),
            pageSizeBytes: pageSize
        )
    }

    private func safePageBytes(pages: UInt64, pageSize: UInt64, cap: UInt64) -> UInt64? {
        let product = pages.multipliedReportingOverflow(by: pageSize)
        guard !product.overflow else { return nil }
        return min(product.partialValue, cap)
    }

    private func has(mask: UInt64, flag: UInt64) -> Bool {
        return (mask & flag) != 0
    }

    private func optionalCounter(mask: UInt64, flag: UInt64, value: UInt64) -> UInt64? {
        return has(mask: mask, flag: flag) ? value : nil
    }
}
