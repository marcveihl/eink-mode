import XCTest
import EinkMac

final class DisplayAwakeTests: XCTestCase {
    func testSimulatedHoldTracksStateWithoutTouchingTheMac() {
        let awake = DisplayAwake(simulated: true)
        XCTAssertFalse(awake.held)
        XCTAssertNil(awake.hold(true)); XCTAssertTrue(awake.held)
        XCTAssertNil(awake.hold(true)); XCTAssertTrue(awake.held) // repeating is a no-op
        XCTAssertNil(awake.hold(false)); XCTAssertFalse(awake.held)
        XCTAssertNil(awake.hold(false)); XCTAssertFalse(awake.held)
    }
    /// The real assertion is what stops display sleep, so check macOS actually registers and drops it.
    func testRealAssertionIsRegisteredThenReleased() throws {
        let reason = "E-Ink Mode test assertion \(UUID().uuidString)"
        let awake = DisplayAwake(simulated: false)
        XCTAssertNil(awake.hold(true, reason: reason))
        XCTAssertTrue(try assertions().contains(reason), "macOS did not register the display-sleep assertion")
        XCTAssertNil(awake.hold(false, reason: reason))
        XCTAssertFalse(try assertions().contains(reason), "the assertion outlived its release")
    }
    private func assertions() throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "assertions"]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: output, as: UTF8.self)
    }
}
