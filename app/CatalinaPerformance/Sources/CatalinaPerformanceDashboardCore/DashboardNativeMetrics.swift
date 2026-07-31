import Foundation
import CatalinaProcessSupport
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum DashboardNativeMetricError: Error, Equatable {
    case unsupported
    case readFailed(operation: String, code: Int32)
    case invalidValue(operation: String)
}

public struct HostCPUTicks: Equatable {
    public let user: UInt64
    public let system: UInt64
    public let idle: UInt64
    public let nice: UInt64
    public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }
}

public struct HostMemorySample: Equatable {
    public let physicalTotalBytes: UInt64
    public let usedBytes: UInt64
    public let availableBytes: UInt64
    public init(physicalTotalBytes: UInt64, usedBytes: UInt64, availableBytes: UInt64) {
        self.physicalTotalBytes = physicalTotalBytes
        self.usedBytes = usedBytes
        self.availableBytes = availableBytes
    }
}

public struct SwapSample: Equatable {
    public let totalBytes: UInt64
    public let usedBytes: UInt64
    public let freeBytes: UInt64
    public init(totalBytes: UInt64, usedBytes: UInt64, freeBytes: UInt64) {
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
        self.freeBytes = freeBytes
    }
}

public struct ProcessResourceSample: Equatable {
    public let pid: Int32
    public let startSeconds: Int64
    public let startMicroseconds: Int32
    public let cpuTimeNanoseconds: UInt64
    public let residentBytes: UInt64
    public init(pid: Int32, startSeconds: Int64, startMicroseconds: Int32, cpuTimeNanoseconds: UInt64, residentBytes: UInt64) {
        self.pid = pid
        self.startSeconds = startSeconds
        self.startMicroseconds = startMicroseconds
        self.cpuTimeNanoseconds = cpuTimeNanoseconds
        self.residentBytes = residentBytes
    }
}

public protocol DashboardNativeMetricsProviding {
    func hostCPUTicks() throws -> HostCPUTicks
    func hostMemory() throws -> HostMemorySample
    func swap() throws -> SwapSample
    func processResources(pid: Int32) throws -> ProcessResourceSample
}

public struct DarwinDashboardNativeMetrics: DashboardNativeMetricsProviding {
    public init() {}

    public func hostCPUTicks() throws -> HostCPUTicks {
        var value = CPHostCPUTicks()
        try check(cp_read_host_cpu_ticks(&value), operation: "host CPU ticks")
        return HostCPUTicks(user: value.userTicks, system: value.systemTicks, idle: value.idleTicks, nice: value.niceTicks)
    }

    public func hostMemory() throws -> HostMemorySample {
        var value = CPHostMemoryInfo()
        try check(cp_read_host_memory(&value), operation: "host memory")
        guard value.physicalTotalBytes > 0, value.usedBytes > 0 else {
            throw DashboardNativeMetricError.invalidValue(operation: "host memory")
        }
        return HostMemorySample(physicalTotalBytes: value.physicalTotalBytes, usedBytes: value.usedBytes, availableBytes: value.availableBytes)
    }

    public func swap() throws -> SwapSample {
        var value = CPSwapInfo()
        try check(cp_read_swap(&value), operation: "swap")
        return SwapSample(totalBytes: value.totalBytes, usedBytes: value.usedBytes, freeBytes: value.freeBytes)
    }

    public func processResources(pid: Int32) throws -> ProcessResourceSample {
        var value = CPProcessResourceInfo()
        try check(cp_read_process_resources(pid, &value), operation: "process resources")
        guard value.pid == pid else { throw DashboardNativeMetricError.invalidValue(operation: "process resources") }
        return ProcessResourceSample(pid: value.pid, startSeconds: value.startSeconds, startMicroseconds: value.startMicroseconds, cpuTimeNanoseconds: value.cpuTimeNanoseconds, residentBytes: value.residentBytes)
    }

    private func check(_ code: Int32, operation: String) throws {
        guard code != 0 else { return }
        if code == -Int32(ENOTSUP) { throw DashboardNativeMetricError.unsupported }
        throw DashboardNativeMetricError.readFailed(operation: operation, code: code)
    }
}
