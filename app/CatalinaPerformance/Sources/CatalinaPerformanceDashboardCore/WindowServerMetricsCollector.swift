import Foundation
import CatalinaPerformancePriorityCore

public protocol WindowServerMetricsCollecting: AnyObject {
    func capture(at date: Date) -> WindowServerCPUReading
    func reset()
}

public final class WindowServerMetricsCollector: WindowServerMetricsCollecting {
    private struct Counter {
        let key: WindowServerProcessKey
        let capturedAt: Date
        let cpuTimeNanoseconds: UInt64
    }

    private let processInspector: AppPriorityProcessInspecting
    private let nativeMetrics: DashboardNativeMetricsProviding
    private var previousCounter: Counter?

    public init(
        processInspector: AppPriorityProcessInspecting,
        nativeMetrics: DashboardNativeMetricsProviding
    ) {
        self.processInspector = processInspector
        self.nativeMetrics = nativeMetrics
    }

    public func reset() {
        previousCounter = nil
    }

    public func capture(at date: Date) -> WindowServerCPUReading {
        let candidate: AppPriorityProcessIdentity
        do {
            let processes = try processInspector.allProcesses()
            guard let exact = exactCandidate(from: processes) else {
                previousCounter = nil
                return .unavailable(
                    processKey: nil,
                    at: date,
                    note: "WindowServer could not be identified uniquely."
                )
            }
            candidate = exact
        } catch {
            previousCounter = nil
            return .unavailable(
                processKey: nil,
                at: date,
                note: "WindowServer process discovery failed."
            )
        }

        let resources: ProcessResourceSample
        do {
            resources = try nativeMetrics.processResources(pid: candidate.pid)
        } catch {
            previousCounter = nil
            return .unavailable(
                processKey: processKey(from: candidate),
                at: date,
                note: "WindowServer resource counters were unavailable."
            )
        }

        guard resources.pid == candidate.pid,
              resources.startSeconds == candidate.startSeconds,
              resources.startMicroseconds == candidate.startMicroseconds else {
            previousCounter = nil
            return .unavailable(
                processKey: processKey(from: candidate),
                cumulativeCPUTimeNanoseconds: resources.cpuTimeNanoseconds,
                at: date,
                note: "WindowServer identity changed while collecting resource counters."
            )
        }

        do {
            let current = try processInspector.process(pid: candidate.pid)
            guard exactIdentity(candidate, matches: current) else {
                previousCounter = nil
                return .unavailable(
                    processKey: processKey(from: current),
                    cumulativeCPUTimeNanoseconds: resources.cpuTimeNanoseconds,
                    at: date,
                    note: "WindowServer identity could not be reverified."
                )
            }
        } catch {
            previousCounter = nil
            return .unavailable(
                processKey: processKey(from: candidate),
                cumulativeCPUTimeNanoseconds: resources.cpuTimeNanoseconds,
                at: date,
                note: "WindowServer identity could not be reverified."
            )
        }

        let key = processKey(from: candidate)
        let currentCounter = Counter(
            key: key,
            capturedAt: date,
            cpuTimeNanoseconds: resources.cpuTimeNanoseconds
        )

        guard let previous = previousCounter else {
            previousCounter = currentCounter
            return .unavailable(
                processKey: key,
                cumulativeCPUTimeNanoseconds: resources.cpuTimeNanoseconds,
                at: date,
                note: "WindowServer CPU baseline established; another sample is required."
            )
        }

        guard previous.key == key else {
            previousCounter = currentCounter
            return .unavailable(
                processKey: key,
                cumulativeCPUTimeNanoseconds: resources.cpuTimeNanoseconds,
                at: date,
                note: "WindowServer process identity changed; a fresh CPU baseline is required."
            )
        }

        let elapsed = date.timeIntervalSince(previous.capturedAt)
        guard elapsed > 0,
              elapsed.isFinite,
              resources.cpuTimeNanoseconds >= previous.cpuTimeNanoseconds else {
            previousCounter = currentCounter
            return .unavailable(
                processKey: key,
                cumulativeCPUTimeNanoseconds: resources.cpuTimeNanoseconds,
                at: date,
                note: "WindowServer CPU counter interval was invalid."
            )
        }

        let delta = resources.cpuTimeNanoseconds - previous.cpuTimeNanoseconds
        let percent = Double(delta) / (elapsed * 1_000_000_000.0) * 100.0
        previousCounter = currentCounter

        guard percent.isFinite, percent >= 0 else {
            return .unavailable(
                processKey: key,
                cumulativeCPUTimeNanoseconds: resources.cpuTimeNanoseconds,
                at: date,
                note: "WindowServer CPU percentage was invalid."
            )
        }

        return .available(
            processKey: key,
            cumulativeCPUTimeNanoseconds: resources.cpuTimeNanoseconds,
            cpuPercent: percent,
            at: date
        )
    }

    private func exactCandidate(
        from processes: [AppPriorityProcessIdentity]
    ) -> AppPriorityProcessIdentity? {
        let matches = processes.filter { process in
            process.processName == "WindowServer" &&
                process.pid > 0 &&
                process.executablePath.hasSuffix("/WindowServer")
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    private func exactIdentity(
        _ expected: AppPriorityProcessIdentity,
        matches current: AppPriorityProcessIdentity
    ) -> Bool {
        expected.pid == current.pid &&
            expected.effectiveUID == current.effectiveUID &&
            expected.executablePath == current.executablePath &&
            expected.startSeconds == current.startSeconds &&
            expected.startMicroseconds == current.startMicroseconds &&
            current.processName == "WindowServer"
    }

    private func processKey(from process: AppPriorityProcessIdentity) -> WindowServerProcessKey {
        WindowServerProcessKey(
            pid: process.pid,
            effectiveUID: process.effectiveUID,
            executablePath: process.executablePath,
            startSeconds: process.startSeconds,
            startMicroseconds: process.startMicroseconds
        )
    }
}
