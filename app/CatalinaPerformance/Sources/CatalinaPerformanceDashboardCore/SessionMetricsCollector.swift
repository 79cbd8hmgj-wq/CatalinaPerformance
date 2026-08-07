import Foundation
import CatalinaPerformancePriorityCore
import CatalinaPerformanceMemoryCore
#if os(Linux)
import Glibc
#else
import Darwin
#endif

public protocol DashboardDiskSpaceProviding {
    func startupVolumeFreeBytes() throws -> UInt64
}

public protocol AppPrioritySelectionProviding {
    func currentSelection() -> AppPrioritySelection
}

public protocol AppPriorityStatusProviding {
    func currentStatus() -> AppPriorityStatus?
}

public protocol DashboardCurrentUserProviding {
    var uid: UInt32 { get }
}

public protocol SessionMetricsCollecting: AnyObject {
    func capture(at date: Date, refreshThermal: Bool) -> SessionMetricSnapshot
}

public struct StartupVolumeDiskSpaceProvider: DashboardDiskSpaceProviding {
    public init() {}
    public func startupVolumeFreeBytes() throws -> UInt64 {
        let values = try URL(fileURLWithPath: "/", isDirectory: true)
            .resourceValues(forKeys: [.volumeAvailableCapacityKey])
        guard let capacity = values.volumeAvailableCapacity, capacity >= 0 else {
            throw DashboardNativeMetricError.invalidValue(operation: "disk space")
        }
        return UInt64(capacity)
    }
}

public struct UserDefaultsAppPrioritySelectionProvider: AppPrioritySelectionProviding {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func currentSelection() -> AppPrioritySelection { AppPriorityPreferences.load(from: defaults) }
}

public struct ProcessDashboardCurrentUserProvider: DashboardCurrentUserProviding {
    public init() {}
    public var uid: UInt32 { UInt32(getuid()) }
}

public final class JSONAppPriorityStatusProvider: AppPriorityStatusProviding {
    private let statusURL: URL
    private let fileManager: FileManager
    public init(statusURL: URL, fileManager: FileManager = .default) {
        self.statusURL = statusURL
        self.fileManager = fileManager
    }
    public func currentStatus() -> AppPriorityStatus? {
        guard fileManager.fileExists(atPath: statusURL.path),
              let data = try? Data(contentsOf: statusURL),
              data.count <= 65_536 else { return nil }
        return try? JSONDecoder().decode(AppPriorityStatus.self, from: data)
    }
}

private struct SelectedProcessKey: Hashable {
    let pid: Int32
    let startSeconds: Int64
    let startMicroseconds: Int32
    let executablePath: String
}

public final class SessionMetricsCollector: SessionMetricsCollecting {
    private let nativeMetrics: DashboardNativeMetricsProviding
    private let thermalProvider: ThermalLimitProviding
    private let diskSpaceProvider: DashboardDiskSpaceProviding
    private let selectionProvider: AppPrioritySelectionProviding
    private let statusProvider: AppPriorityStatusProviding
    private let currentUserProvider: DashboardCurrentUserProviding
    private let processInspector: AppPriorityProcessInspecting
    private let windowServerCollector: WindowServerMetricsCollecting?
    private let memoryTelemetryCollector: MemoryTelemetryCollecting?
    private let memoryManagementCoordinator: MemoryManagementCoordinating?

    private var previousHostTicks: HostCPUTicks?
    private var previousProcessCPU: [SelectedProcessKey: UInt64] = [:]
    private var previousSelectedCaptureAt: Date?
    private var cachedThermal: ThermalLimitSnapshot?

    public init(
        nativeMetrics: DashboardNativeMetricsProviding,
        thermalProvider: ThermalLimitProviding,
        diskSpaceProvider: DashboardDiskSpaceProviding,
        selectionProvider: AppPrioritySelectionProviding,
        statusProvider: AppPriorityStatusProviding,
        currentUserProvider: DashboardCurrentUserProviding,
        processInspector: AppPriorityProcessInspecting,
        windowServerCollector: WindowServerMetricsCollecting? = nil,
        memoryTelemetryCollector: MemoryTelemetryCollecting? = nil,
        memoryManagementCoordinator: MemoryManagementCoordinating? = nil
    ) {
        self.nativeMetrics = nativeMetrics
        self.thermalProvider = thermalProvider
        self.diskSpaceProvider = diskSpaceProvider
        self.selectionProvider = selectionProvider
        self.statusProvider = statusProvider
        self.currentUserProvider = currentUserProvider
        self.processInspector = processInspector
        self.windowServerCollector = windowServerCollector
        self.memoryTelemetryCollector = memoryTelemetryCollector
        self.memoryManagementCoordinator = memoryManagementCoordinator
    }

    public func capture(at date: Date, refreshThermal: Bool) -> SessionMetricSnapshot {
        let cpu = collectHostCPU(at: date)
        let memoryResult = collectMemory(at: date)
        let swap = collectSwap(at: date)
        let disk = collectDisk(at: date)
        let thermal = collectThermal(at: date, refresh: refreshThermal)
        let selected = collectSelectedApplication(at: date)
        let windowServer = windowServerCollector?.capture(at: date)
        let memoryManagement = collectMemoryManagement(at: date)

        return SessionMetricSnapshot(
            capturedAt: date,
            systemCPUPercent: cpu,
            memoryPressure: memoryResult.pressure,
            physicalMemoryUsedBytes: memoryResult.used,
            swapUsedBytes: swap,
            diskFreeBytes: disk,
            schedulerLimitPercent: thermal.schedulerLimitPercent,
            speedLimitPercent: thermal.speedLimitPercent,
            selectedAppCPUPercent: selected.cpu,
            selectedAppResidentBytes: selected.resident,
            selectedAppVerifiedProcessCount: selected.processCount,
            selectedAppPriorityConfirmedCount: selected.confirmedCount,
            focusedFirefoxPriority: selected.focusedFirefox,
            windowServerCPU: windowServer,
            memoryManagement: memoryManagement
        )
    }

    private func collectMemoryManagement(at date: Date) -> MemoryManagementStatusSnapshot? {
        guard let telemetryCollector = memoryTelemetryCollector,
              let coordinator = memoryManagementCoordinator else {
            return nil
        }
        let selection = selectionProvider.currentSelection()
        let priorityApplication = selection.enabled ? selection.application : nil
        _ = coordinator.updateAppPriorityApplication(priorityApplication, at: date)
        let telemetry = telemetryCollector.capture(at: date)
        return coordinator.evaluate(telemetry: telemetry)
    }

    private func collectHostCPU(at date: Date) -> MetricReading<Double> {
        do {
            let current = try nativeMetrics.hostCPUTicks()
            defer { previousHostTicks = current }
            guard let previous = previousHostTicks else {
                return .unavailable(at: date, note: "A second host counter reading is required.")
            }
            guard current.user >= previous.user,
                  current.system >= previous.system,
                  current.idle >= previous.idle,
                  current.nice >= previous.nice else {
                return .unavailable(at: date, note: "Host CPU counters decreased or rolled over.")
            }
            let user = current.user - previous.user
            let system = current.system - previous.system
            let idle = current.idle - previous.idle
            let nice = current.nice - previous.nice
            let busy = user + system + nice
            let total = busy + idle
            guard total > 0 else { return .unavailable(at: date, note: "Host CPU counter interval was empty.") }
            let percent = Double(busy) / Double(total) * 100.0
            guard percent.isFinite else { return .unavailable(at: date, note: "Host CPU percentage was invalid.") }
            return .available(min(100.0, max(0.0, percent)), at: date)
        } catch {
            return readingForError(error, at: date, operation: "hostCPU")
        }
    }

    private func collectMemory(at date: Date) -> (used: MetricReading<UInt64>, pressure: MetricReading<MemoryPressureLevel>) {
        do {
            let sample = try nativeMetrics.hostMemory()
            guard sample.physicalTotalBytes > 0,
                  sample.usedBytes > 0,
                  sample.usedBytes <= sample.physicalTotalBytes,
                  sample.availableBytes <= sample.physicalTotalBytes else {
                let note = "Host memory values were invalid."
                return (.unavailable(at: date, note: note), .unavailable(at: date, note: note))
            }
            return (
                .available(sample.usedBytes, at: date),
                .available(MemoryPressureMapper.level(totalBytes: sample.physicalTotalBytes, availableBytes: sample.availableBytes), at: date)
            )
        } catch {
            let note = errorNote(error, operation: "memory")
            return (.unavailable(at: date, note: note), .unavailable(at: date, note: note))
        }
    }

    private func collectSwap(at date: Date) -> MetricReading<UInt64> {
        do { return .available(try nativeMetrics.swap().usedBytes, at: date) }
        catch { return readingForError(error, at: date, operation: "swap") }
    }

    private func collectDisk(at date: Date) -> MetricReading<UInt64> {
        do { return .available(try diskSpaceProvider.startupVolumeFreeBytes(), at: date) }
        catch { return .unavailable(at: date, note: errorNote(error, operation: "disk")) }
    }

    private func collectThermal(at date: Date, refresh: Bool) -> ThermalLimitSnapshot {
        if refresh {
            let value = thermalProvider.readLimits(capturedAt: date)
            cachedThermal = value
            return value
        }
        guard let cached = cachedThermal else {
            return ThermalLimitSnapshot(
                capturedAt: date,
                schedulerLimitPercent: .unavailable(at: date, note: "Thermal limits have not been sampled yet."),
                speedLimitPercent: .unavailable(at: date, note: "Thermal limits have not been sampled yet.")
            )
        }
        let age = date.timeIntervalSince(cached.capturedAt)
        if age > 15.0 {
            return ThermalLimitSnapshot(
                capturedAt: date,
                schedulerLimitPercent: staleReading(cached.schedulerLimitPercent, at: date),
                speedLimitPercent: staleReading(cached.speedLimitPercent, at: date)
            )
        }
        return ThermalLimitSnapshot(
            capturedAt: date,
            schedulerLimitPercent: copiedReading(cached.schedulerLimitPercent, at: date),
            speedLimitPercent: copiedReading(cached.speedLimitPercent, at: date)
        )
    }

    private func copiedReading(_ reading: MetricReading<Double>, at date: Date) -> MetricReading<Double> {
        MetricReading(value: reading.value, availability: reading.availability, capturedAt: date, note: reading.note)
    }

    private func staleReading(_ reading: MetricReading<Double>, at date: Date) -> MetricReading<Double> {
        guard let value = reading.value else {
            return MetricReading(value: nil, availability: reading.availability, capturedAt: date, note: reading.note)
        }
        return .stale(value, at: date, note: "Thermal limit reading is older than 15 seconds.")
    }

    private func collectSelectedApplication(at date: Date) -> (
        cpu: MetricReading<Double>,
        resident: MetricReading<UInt64>,
        processCount: MetricReading<Int>,
        confirmedCount: MetricReading<Int>,
        focusedFirefox: FocusedFirefoxMetricDetails?
    ) {
        let selection = selectionProvider.currentSelection()
        guard selection.enabled, let application = selection.application else {
            previousProcessCPU.removeAll()
            previousSelectedCaptureAt = nil
            let note = "App Priority is not configured."
            return (
                .unsupported(at: date, note: note),
                .unsupported(at: date, note: note),
                .unsupported(at: date, note: note),
                .unsupported(at: date, note: note),
                nil
            )
        }

        do {
            let processes = try processInspector.allProcesses()
            let family = AppPriorityProcessFamilyResolver.resolve(
                application: application,
                requestingUID: currentUserProvider.uid,
                processes: processes
            )
            let policy = AppPriorityPolicy.policy(for: application)
            var currentCPU: [SelectedProcessKey: UInt64] = [:]
            var resident: UInt64 = 0
            var residentSampleCount = 0
            var validCount = 0
            var deltaNanoseconds: UInt64 = 0

            for identity in family.eligible {
                do {
                    let resource = try nativeMetrics.processResources(pid: identity.pid)
                    guard resource.startSeconds == identity.startSeconds,
                          resource.startMicroseconds == identity.startMicroseconds else { continue }
                    let key = SelectedProcessKey(
                        pid: identity.pid,
                        startSeconds: identity.startSeconds,
                        startMicroseconds: identity.startMicroseconds,
                        executablePath: identity.executablePath
                    )
                    if let previous = previousProcessCPU[key], resource.cpuTimeNanoseconds >= previous {
                        deltaNanoseconds += resource.cpuTimeNanoseconds - previous
                    }
                    currentCPU[key] = resource.cpuTimeNanoseconds
                    if resource.residentBytes > 0 {
                        let addition = resident.addingReportingOverflow(resource.residentBytes)
                        resident = addition.overflow ? UInt64.max : addition.partialValue
                        residentSampleCount += 1
                    }
                    validCount += 1
                } catch {
                    continue
                }
            }

            let previousDate = previousSelectedCaptureAt
            previousProcessCPU = currentCPU
            previousSelectedCaptureAt = date
            let cpuReading: MetricReading<Double>
            if let previousDate = previousDate {
                let elapsed = date.timeIntervalSince(previousDate)
                if elapsed > 0 {
                    let percent = Double(deltaNanoseconds) / (elapsed * 1_000_000_000.0) * 100.0
                    cpuReading = percent.isFinite ? .available(max(0, percent), at: date) : .unavailable(at: date, note: "Selected-app CPU percentage was invalid.")
                } else {
                    cpuReading = .unavailable(at: date, note: "Selected-app counter interval was empty.")
                }
            } else {
                cpuReading = .unavailable(at: date, note: "A second selected-app counter reading is required.")
            }

            let status = statusProvider.currentStatus()
            let activeStatus: AppPriorityStatus?
            if let status = status {
                switch status.state {
                case .starting, .waitingForSelectedApp, .active, .activeWithSkipped:
                    activeStatus = status
                case .disabled, .ready, .restorePending, .restored, .failed:
                    activeStatus = nil
                }
            } else {
                activeStatus = nil
            }

            let confirmedReading: MetricReading<Int>
            let focusedDetails: FocusedFirefoxMetricDetails?
            if let activeStatus = activeStatus {
                if policy.kind == .focusedFirefox {
                    if activeStatus.policyKind == .focusedFirefox,
                       let focused = activeStatus.focusedFirefox {
                        confirmedReading = MetricReading(
                            value: focused.actuallyBoostedCount,
                            availability: .available,
                            capturedAt: date,
                            note: activeStatus.message
                        )
                        focusedDetails = FocusedFirefoxMetricDetails(
                            policySummary: policy.summary,
                            trackedProcessCount: focused.trackedProcessCount,
                            actuallyBoostedCount: focused.actuallyBoostedCount,
                            parentPID: focused.parentPID,
                            gpuPID: focused.gpuPID,
                            contentPID: focused.contentPID,
                            waitingForStableContent: focused.waitingForStableContent,
                            warning: focused.warning
                        )
                    } else {
                        confirmedReading = .unavailable(
                            at: date,
                            note: "Focused Firefox App Priority status is unavailable."
                        )
                        focusedDetails = nil
                    }
                } else if activeStatus.policyKind == policy.kind || activeStatus.policyKind == nil {
                    confirmedReading = MetricReading(
                        value: activeStatus.boostedCount,
                        availability: .available,
                        capturedAt: date,
                        note: activeStatus.message
                    )
                    focusedDetails = nil
                } else {
                    confirmedReading = .unavailable(at: date, note: "App Priority status does not match the selected policy.")
                    focusedDetails = nil
                }
            } else {
                confirmedReading = .unavailable(at: date, note: "Active App Priority status is unavailable.")
                focusedDetails = nil
            }

            let residentReading: MetricReading<UInt64>
            if residentSampleCount > 0 {
                residentReading = .available(resident, at: date)
            } else {
                residentReading = .unavailable(
                    at: date,
                    note: "Resident memory was not reported for any verified selected-app process."
                )
            }
            return (
                cpuReading,
                residentReading,
                .available(validCount, at: date),
                confirmedReading,
                focusedDetails
            )
        } catch {
            previousProcessCPU.removeAll()
            previousSelectedCaptureAt = nil
            let note = errorNote(error, operation: "selectedApp")
            return (
                .unavailable(at: date, note: note),
                .unavailable(at: date, note: note),
                .unavailable(at: date, note: note),
                .unavailable(at: date, note: note),
                nil
            )
        }
    }

    private func readingForError<Value>(_ error: Error, at date: Date, operation: String) -> MetricReading<Value> where Value: Codable & Equatable {
        if (error as? DashboardNativeMetricError) == .unsupported {
            return .unsupported(at: date, note: "\(operation) is unsupported on this platform.")
        }
        return .unavailable(at: date, note: errorNote(error, operation: operation))
    }

    private func errorNote(_ error: Error, operation: String) -> String {
        "\(operation) unavailable: \(String(describing: error))"
    }
}
