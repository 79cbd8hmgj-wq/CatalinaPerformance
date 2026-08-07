import XCTest
@testable import CatalinaPerformanceDashboardCore

final class WindowServerMetricsCollectorTests: XCTestCase {
    enum FakeError: Error {
        case failed
    }

    final class FakeWindowServerInspector: WindowServerProcessInspecting {
        var results: [Result<WindowServerProcessSample, Error>]

        init(results: [Result<WindowServerProcessSample, Error>]) {
            self.results = results
        }

        func readWindowServer() throws -> WindowServerProcessSample {
            guard !results.isEmpty else { throw FakeError.failed }
            return try results.removeFirst().get()
        }
    }

    private func key(
        pid: Int32 = 202,
        uid: UInt32 = 88,
        path: String = "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer",
        start: Int64 = 5
    ) -> WindowServerProcessKey {
        WindowServerProcessKey(
            pid: pid,
            effectiveUID: uid,
            executablePath: path,
            startSeconds: start,
            startMicroseconds: 0
        )
    }

    private func sample(
        pid: Int32 = 202,
        uid: UInt32 = 88,
        path: String = "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer",
        start: Int64 = 5,
        cpu: UInt64
    ) -> WindowServerProcessSample {
        WindowServerProcessSample(
            processKey: key(pid: pid, uid: uid, path: path, start: start),
            cumulativeCPUTimeNanoseconds: cpu
        )
    }

    func testFirstReadingEstablishesBaselineWithoutFabricatingZero() {
        let inspector = FakeWindowServerInspector(results: [
            .success(sample(cpu: 1_000_000_000))
        ])
        let collector = WindowServerMetricsCollector(processInspector: inspector)

        let first = collector.capture(at: Date(timeIntervalSince1970: 10))

        XCTAssertNil(first.cpuPercent)
        XCTAssertEqual(first.processKey?.pid, 202)
        XCTAssertEqual(first.availability, .unavailable)
    }

    func testSecondCounterReadingProducesNumericCPUPercentage() {
        let inspector = FakeWindowServerInspector(results: [
            .success(sample(cpu: 1_000_000_000)),
            .success(sample(cpu: 1_400_000_000))
        ])
        let collector = WindowServerMetricsCollector(processInspector: inspector)

        _ = collector.capture(at: Date(timeIntervalSince1970: 10))
        let second = collector.capture(at: Date(timeIntervalSince1970: 12))

        XCTAssertEqual(second.cpuPercent ?? -1, 20.0, accuracy: 0.001)
        XCTAssertEqual(second.availability, .available)
    }

    func testDoesNotClampAboveOneHundredPercent() {
        let inspector = FakeWindowServerInspector(results: [
            .success(sample(cpu: 1_000_000_000)),
            .success(sample(cpu: 4_000_000_000))
        ])
        let collector = WindowServerMetricsCollector(processInspector: inspector)

        _ = collector.capture(at: Date(timeIntervalSince1970: 10))
        let second = collector.capture(at: Date(timeIntervalSince1970: 12))

        XCTAssertEqual(second.cpuPercent ?? -1, 150.0, accuracy: 0.001)
    }

    func testInspectionFailureIsUnavailableAndForcesFreshBaseline() {
        let inspector = FakeWindowServerInspector(results: [
            .success(sample(cpu: 1_000)),
            .failure(FakeError.failed),
            .success(sample(cpu: 2_000)),
            .success(sample(cpu: 3_000))
        ])
        let collector = WindowServerMetricsCollector(processInspector: inspector)

        _ = collector.capture(at: Date(timeIntervalSince1970: 10))
        let failed = collector.capture(at: Date(timeIntervalSince1970: 12))
        let reacquired = collector.capture(at: Date(timeIntervalSince1970: 14))
        let delta = collector.capture(at: Date(timeIntervalSince1970: 16))

        XCTAssertEqual(failed.availability, .unavailable)
        XCTAssertEqual(reacquired.availability, .unavailable)
        XCTAssertEqual(delta.availability, .available)
    }

    func testDecreasingCounterIsUnavailableAndRebasesNextInterval() {
        let inspector = FakeWindowServerInspector(results: [
            .success(sample(cpu: 1_000)),
            .success(sample(cpu: 900)),
            .success(sample(cpu: 1_100))
        ])
        let collector = WindowServerMetricsCollector(processInspector: inspector)

        _ = collector.capture(at: Date(timeIntervalSince1970: 10))
        let invalid = collector.capture(at: Date(timeIntervalSince1970: 12))
        let next = collector.capture(at: Date(timeIntervalSince1970: 14))

        XCTAssertEqual(invalid.availability, .unavailable)
        XCTAssertEqual(next.availability, .available)
    }

    func testZeroElapsedTimeIsUnavailable() {
        let inspector = FakeWindowServerInspector(results: [
            .success(sample(cpu: 1_000)),
            .success(sample(cpu: 2_000))
        ])
        let collector = WindowServerMetricsCollector(processInspector: inspector)

        _ = collector.capture(at: Date(timeIntervalSince1970: 10))
        let invalid = collector.capture(at: Date(timeIntervalSince1970: 10))

        XCTAssertEqual(invalid.availability, .unavailable)
        XCTAssertNil(invalid.cpuPercent)
    }

    func testPIDReplacementRequiresFreshBaseline() {
        let inspector = FakeWindowServerInspector(results: [
            .success(sample(pid: 202, start: 5, cpu: 1_000)),
            .success(sample(pid: 303, start: 7, cpu: 500)),
            .success(sample(pid: 303, start: 7, cpu: 700))
        ])
        let collector = WindowServerMetricsCollector(processInspector: inspector)

        _ = collector.capture(at: Date(timeIntervalSince1970: 10))
        let replacementBaseline = collector.capture(at: Date(timeIntervalSince1970: 12))
        let replacementDelta = collector.capture(at: Date(timeIntervalSince1970: 14))

        XCTAssertEqual(replacementBaseline.availability, .unavailable)
        XCTAssertEqual(replacementBaseline.processKey?.pid, 303)
        XCTAssertEqual(replacementDelta.availability, .available)
    }

    func testSamePIDDifferentStartTimeRequiresFreshBaseline() {
        let inspector = FakeWindowServerInspector(results: [
            .success(sample(pid: 202, start: 5, cpu: 1_000)),
            .success(sample(pid: 202, start: 8, cpu: 500))
        ])
        let collector = WindowServerMetricsCollector(processInspector: inspector)

        _ = collector.capture(at: Date(timeIntervalSince1970: 10))
        let reading = collector.capture(at: Date(timeIntervalSince1970: 12))

        XCTAssertEqual(reading.availability, .unavailable)
        XCTAssertEqual(reading.processKey?.startSeconds, 8)
    }
}
