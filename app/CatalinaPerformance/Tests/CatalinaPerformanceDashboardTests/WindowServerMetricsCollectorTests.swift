import XCTest
@testable import CatalinaPerformanceDashboardCore
import CatalinaPerformancePriorityCore

final class WindowServerMetricsCollectorTests: XCTestCase {
    enum FakeError: Error {
        case failed
    }

    final class FakeProcessInspector: AppPriorityProcessInspecting {
        var processLists: [[AppPriorityProcessIdentity]]
        var currentByPID: [Int32: AppPriorityProcessIdentity]
        var failList = false
        var failRead = false
        private var listIndex = 0

        init(processLists: [[AppPriorityProcessIdentity]]) {
            self.processLists = processLists
            self.currentByPID = Dictionary(
                uniqueKeysWithValues: (processLists.first ?? []).map { ($0.pid, $0) }
            )
        }

        func allProcesses() throws -> [AppPriorityProcessIdentity] {
            if failList { throw FakeError.failed }
            let index = min(listIndex, processLists.count - 1)
            let value = processLists[index]
            listIndex += 1
            currentByPID = Dictionary(uniqueKeysWithValues: value.map { ($0.pid, $0) })
            return value
        }

        func process(pid: Int32) throws -> AppPriorityProcessIdentity {
            if failRead { throw FakeError.failed }
            guard let value = currentByPID[pid] else { throw FakeError.failed }
            return value
        }
    }

    final class FakeNativeMetrics: DashboardNativeMetricsProviding {
        var samplesByPID: [Int32: [ProcessResourceSample]]
        var indexes: [Int32: Int] = [:]
        var fail = false

        init(samplesByPID: [Int32: [ProcessResourceSample]]) {
            self.samplesByPID = samplesByPID
        }

        func hostCPUTicks() throws -> HostCPUTicks { throw FakeError.failed }
        func hostMemory() throws -> HostMemorySample { throw FakeError.failed }
        func swap() throws -> SwapSample { throw FakeError.failed }

        func processResources(pid: Int32) throws -> ProcessResourceSample {
            if fail { throw FakeError.failed }
            guard let samples = samplesByPID[pid], !samples.isEmpty else {
                throw FakeError.failed
            }
            let index = indexes[pid] ?? 0
            indexes[pid] = index + 1
            return samples[min(index, samples.count - 1)]
        }
    }

    private func process(
        pid: Int32 = 202,
        name: String = "WindowServer",
        path: String = "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer",
        uid: UInt32 = 88,
        start: Int64 = 5
    ) -> AppPriorityProcessIdentity {
        AppPriorityProcessIdentity(
            pid: pid,
            parentPID: 1,
            effectiveUID: uid,
            executablePath: path,
            startSeconds: start,
            startMicroseconds: 0,
            processName: name,
            niceValue: 0
        )
    }

    private func resource(
        pid: Int32 = 202,
        start: Int64 = 5,
        cpu: UInt64
    ) -> ProcessResourceSample {
        ProcessResourceSample(
            pid: pid,
            startSeconds: start,
            startMicroseconds: 0,
            cpuTimeNanoseconds: cpu,
            residentBytes: 0
        )
    }

    func testDiscoversOnlyExactWindowServerProcessName() {
        let valid = process()
        let inspector = FakeProcessInspector(processLists: [[
            process(
                pid: 101,
                name: "WindowServerHelper",
                path: "/tmp/WindowServerHelper"
            ),
            valid
        ]])
        let native = FakeNativeMetrics(samplesByPID: [
            202: [resource(cpu: 1_000_000_000)]
        ])
        let collector = WindowServerMetricsCollector(
            processInspector: inspector,
            nativeMetrics: native
        )

        let first = collector.capture(at: Date(timeIntervalSince1970: 10))
        XCTAssertNil(first.cpuPercent)
        XCTAssertEqual(first.processKey?.pid, 202)
        XCTAssertEqual(first.availability, .unavailable)
    }

    func testSecondCounterReadingProducesNumericCPUPercentage() {
        let valid = process()
        let inspector = FakeProcessInspector(processLists: [[valid], [valid]])
        let native = FakeNativeMetrics(samplesByPID: [
            202: [
                resource(cpu: 1_000_000_000),
                resource(cpu: 1_400_000_000)
            ]
        ])
        let collector = WindowServerMetricsCollector(
            processInspector: inspector,
            nativeMetrics: native
        )

        _ = collector.capture(at: Date(timeIntervalSince1970: 10))
        let second = collector.capture(at: Date(timeIntervalSince1970: 12))
        XCTAssertEqual(second.cpuPercent ?? -1, 20.0, accuracy: 0.001)
        XCTAssertEqual(second.availability, .available)
    }

    func testDoesNotClampAboveOneHundredPercent() {
        let valid = process()
        let inspector = FakeProcessInspector(processLists: [[valid], [valid]])
        let native = FakeNativeMetrics(samplesByPID: [
            202: [
                resource(cpu: 1_000_000_000),
                resource(cpu: 4_000_000_000)
            ]
        ])
        let collector = WindowServerMetricsCollector(
            processInspector: inspector,
            nativeMetrics: native
        )

        _ = collector.capture(at: Date(timeIntervalSince1970: 10))
        let second = collector.capture(at: Date(timeIntervalSince1970: 12))
        XCTAssertEqual(second.cpuPercent ?? -1, 150.0, accuracy: 0.001)
    }

    func testMultipleExactCandidatesAreUnavailable() {
        let first = process(pid: 202)
        let second = process(pid: 303)
        let inspector = FakeProcessInspector(processLists: [[first, second]])
        let native = FakeNativeMetrics(samplesByPID: [:])
        let collector = WindowServerMetricsCollector(
            processInspector: inspector,
            nativeMetrics: native
        )

        let reading = collector.capture(at: Date(timeIntervalSince1970: 10))
        XCTAssertEqual(reading.availability, .unavailable)
        XCTAssertNil(reading.processKey)
    }

    func testDecreasingCounterIsUnavailableAndRebasesNextInterval() {
        let valid = process()
        let inspector = FakeProcessInspector(processLists: [[valid], [valid], [valid]])
        let native = FakeNativeMetrics(samplesByPID: [
            202: [resource(cpu: 1_000), resource(cpu: 900), resource(cpu: 1_100)]
        ])
        let collector = WindowServerMetricsCollector(
            processInspector: inspector,
            nativeMetrics: native
        )

        _ = collector.capture(at: Date(timeIntervalSince1970: 10))
        let invalid = collector.capture(at: Date(timeIntervalSince1970: 12))
        let next = collector.capture(at: Date(timeIntervalSince1970: 14))
        XCTAssertEqual(invalid.availability, .unavailable)
        XCTAssertEqual(next.availability, .available)
    }

    func testZeroElapsedTimeIsUnavailable() {
        let valid = process()
        let inspector = FakeProcessInspector(processLists: [[valid], [valid]])
        let native = FakeNativeMetrics(samplesByPID: [
            202: [resource(cpu: 1_000), resource(cpu: 2_000)]
        ])
        let collector = WindowServerMetricsCollector(
            processInspector: inspector,
            nativeMetrics: native
        )

        _ = collector.capture(at: Date(timeIntervalSince1970: 10))
        let invalid = collector.capture(at: Date(timeIntervalSince1970: 10))
        XCTAssertEqual(invalid.availability, .unavailable)
        XCTAssertNil(invalid.cpuPercent)
    }

    func testPIDReplacementRequiresFreshBaseline() {
        let first = process(pid: 202, start: 5)
        let replacement = process(pid: 303, start: 7)
        let inspector = FakeProcessInspector(processLists: [[first], [replacement], [replacement]])
        let native = FakeNativeMetrics(samplesByPID: [
            202: [resource(pid: 202, start: 5, cpu: 1_000)],
            303: [
                resource(pid: 303, start: 7, cpu: 500),
                resource(pid: 303, start: 7, cpu: 700)
            ]
        ])
        let collector = WindowServerMetricsCollector(
            processInspector: inspector,
            nativeMetrics: native
        )

        _ = collector.capture(at: Date(timeIntervalSince1970: 10))
        let replacementBaseline = collector.capture(at: Date(timeIntervalSince1970: 12))
        let replacementDelta = collector.capture(at: Date(timeIntervalSince1970: 14))
        XCTAssertEqual(replacementBaseline.availability, .unavailable)
        XCTAssertEqual(replacementBaseline.processKey?.pid, 303)
        XCTAssertEqual(replacementDelta.availability, .available)
    }

    func testSamePIDDifferentStartTimeRequiresFreshBaseline() {
        let first = process(pid: 202, start: 5)
        let replacement = process(pid: 202, start: 8)
        let inspector = FakeProcessInspector(processLists: [[first], [replacement]])
        let native = FakeNativeMetrics(samplesByPID: [
            202: [
                resource(start: 5, cpu: 1_000),
                resource(start: 8, cpu: 500)
            ]
        ])
        let collector = WindowServerMetricsCollector(
            processInspector: inspector,
            nativeMetrics: native
        )

        _ = collector.capture(at: Date(timeIntervalSince1970: 10))
        let reading = collector.capture(at: Date(timeIntervalSince1970: 12))
        XCTAssertEqual(reading.availability, .unavailable)
        XCTAssertEqual(reading.processKey?.startSeconds, 8)
    }

    func testTemporaryDiscoveryFailureForcesReacquisitionBaseline() {
        let valid = process()
        let inspector = FakeProcessInspector(processLists: [[valid], [], [valid], [valid]])
        let native = FakeNativeMetrics(samplesByPID: [
            202: [resource(cpu: 1_000), resource(cpu: 2_000), resource(cpu: 3_000)]
        ])
        let collector = WindowServerMetricsCollector(
            processInspector: inspector,
            nativeMetrics: native
        )

        _ = collector.capture(at: Date(timeIntervalSince1970: 10))
        let failed = collector.capture(at: Date(timeIntervalSince1970: 12))
        let reacquired = collector.capture(at: Date(timeIntervalSince1970: 14))
        let delta = collector.capture(at: Date(timeIntervalSince1970: 16))
        XCTAssertEqual(failed.availability, .unavailable)
        XCTAssertEqual(reacquired.availability, .unavailable)
        XCTAssertEqual(delta.availability, .available)
    }

    func testResourceStartMismatchIsUnavailable() {
        let valid = process(start: 5)
        let inspector = FakeProcessInspector(processLists: [[valid]])
        let native = FakeNativeMetrics(samplesByPID: [
            202: [resource(start: 99, cpu: 1_000)]
        ])
        let collector = WindowServerMetricsCollector(
            processInspector: inspector,
            nativeMetrics: native
        )

        let reading = collector.capture(at: Date(timeIntervalSince1970: 10))
        XCTAssertEqual(reading.availability, .unavailable)
        XCTAssertNil(reading.cpuPercent)
    }
}
