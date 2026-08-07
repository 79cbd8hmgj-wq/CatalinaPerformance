import Foundation

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

    private let processInspector: WindowServerProcessInspecting
    private var previousCounter: Counter?

    public init(processInspector: WindowServerProcessInspecting) {
        self.processInspector = processInspector
    }

    public func reset() {
        previousCounter = nil
    }

    public func capture(at date: Date) -> WindowServerCPUReading {
        let sample: WindowServerProcessSample
        do {
            sample = try processInspector.readWindowServer()
        } catch {
            previousCounter = nil
            return .unavailable(
                processKey: nil,
                at: date,
                note: "WindowServer read-only telemetry was unavailable: \(error)"
            )
        }

        let key = sample.processKey
        let currentCounter = Counter(
            key: key,
            capturedAt: date,
            cpuTimeNanoseconds: sample.cumulativeCPUTimeNanoseconds
        )

        guard let previous = previousCounter else {
            previousCounter = currentCounter
            return .unavailable(
                processKey: key,
                cumulativeCPUTimeNanoseconds: sample.cumulativeCPUTimeNanoseconds,
                at: date,
                note: "WindowServer CPU baseline established; another sample is required."
            )
        }

        guard previous.key == key else {
            previousCounter = currentCounter
            return .unavailable(
                processKey: key,
                cumulativeCPUTimeNanoseconds: sample.cumulativeCPUTimeNanoseconds,
                at: date,
                note: "WindowServer process identity changed; a fresh CPU baseline is required."
            )
        }

        let elapsed = date.timeIntervalSince(previous.capturedAt)
        guard elapsed > 0,
              elapsed.isFinite,
              sample.cumulativeCPUTimeNanoseconds >= previous.cpuTimeNanoseconds else {
            previousCounter = currentCounter
            return .unavailable(
                processKey: key,
                cumulativeCPUTimeNanoseconds: sample.cumulativeCPUTimeNanoseconds,
                at: date,
                note: "WindowServer CPU counter interval was invalid."
            )
        }

        let delta = sample.cumulativeCPUTimeNanoseconds - previous.cpuTimeNanoseconds
        let percent = Double(delta) / (elapsed * 1_000_000_000.0) * 100.0
        previousCounter = currentCounter

        guard percent.isFinite, percent >= 0 else {
            return .unavailable(
                processKey: key,
                cumulativeCPUTimeNanoseconds: sample.cumulativeCPUTimeNanoseconds,
                at: date,
                note: "WindowServer CPU percentage was invalid."
            )
        }

        return .available(
            processKey: key,
            cumulativeCPUTimeNanoseconds: sample.cumulativeCPUTimeNanoseconds,
            cpuPercent: percent,
            at: date
        )
    }
}
