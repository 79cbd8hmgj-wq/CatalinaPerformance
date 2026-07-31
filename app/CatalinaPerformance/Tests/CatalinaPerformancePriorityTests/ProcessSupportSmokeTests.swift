import XCTest
import CatalinaProcessSupport
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
}
