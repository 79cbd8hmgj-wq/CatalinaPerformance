import XCTest
@testable import CatalinaPerformanceDashboardCore

final class DashboardNativeMetricsTests: XCTestCase {
    func testNativeProviderReportsUnsupportedOrRealValuesWithoutFabricatingZeroes() {
        let provider = DarwinDashboardNativeMetrics()
        #if os(macOS)
        XCTAssertNoThrow(try provider.hostCPUTicks())
        XCTAssertNoThrow(try provider.hostMemory())
        XCTAssertNoThrow(try provider.swap())
        #else
        XCTAssertThrowsError(try provider.hostCPUTicks()) { error in
            XCTAssertEqual(error as? DashboardNativeMetricError, .unsupported)
        }
        #endif
    }
}
