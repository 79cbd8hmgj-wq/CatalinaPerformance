import XCTest
import CatalinaProcessSupport
import CatalinaPerformancePriorityCore
#if os(Linux)
import Glibc
#else
import Darwin
#endif

final class ProcessSupportSmokeTests: XCTestCase {
    func testCurrentProcessCanBeReadOnMacOS() {
        #if os(macOS)
        var info = CPProcessInfo()
        XCTAssertEqual(cp_read_process(getpid(), &info), 0)
        XCTAssertEqual(info.pid, getpid())
        XCTAssertGreaterThan(info.startSeconds, 0)
        XCTAssertGreaterThan(info.pathLength, 0)
        #else
        XCTAssertEqual(cp_process_support_available(), 0)
        #endif
    }

    func testCurrentProcessArgumentsCanBeReadOnMacOS() throws {
        #if os(macOS)
        let inspector = DarwinAppPriorityProcessInspector()
        let arguments = try inspector.arguments(pid: getpid())
        XCTAssertFalse(arguments.isEmpty)
        XCTAssertFalse(arguments[0].isEmpty)
        XCTAssertGreaterThan(try inspector.cpuTimeNanoseconds(pid: getpid()), 0)
        #else
        throw XCTSkip("Darwin process arguments are macOS-only")
        #endif
    }
}
