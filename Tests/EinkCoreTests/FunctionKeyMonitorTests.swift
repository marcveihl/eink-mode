import XCTest
@testable import EinkMac

final class FunctionKeyMonitorTests: XCTestCase {
    func testHoldStartsOnceAndReleaseEndsIt() {
        var down = false
        var presses = 0, releases = 0
        let monitor = FunctionKeyMonitor(readState: { down }, onPress: { presses += 1 }, onRelease: { releases += 1 })
        monitor.start()
        defer { monitor.stop() }
        down = true
        monitor.poll()
        monitor.poll()
        XCTAssertEqual(presses, 1)
        XCTAssertEqual(releases, 0)
        down = false
        monitor.poll()
        monitor.poll()
        XCTAssertEqual(releases, 1)
    }

    func testEnablingWhileHeldRequiresReleaseAndStoppingEndsTheHold() {
        var down = true
        var presses = 0, releases = 0
        let monitor = FunctionKeyMonitor(readState: { down }, onPress: { presses += 1 }, onRelease: { releases += 1 })
        monitor.start()
        monitor.poll()
        XCTAssertEqual(presses, 0)
        down = false
        monitor.poll()
        down = true
        monitor.poll()
        XCTAssertEqual(presses, 1)
        monitor.stop()
        XCTAssertEqual(releases, 2)
        monitor.stop()
        XCTAssertEqual(releases, 2, "stopping twice must not duplicate release")
    }
}
