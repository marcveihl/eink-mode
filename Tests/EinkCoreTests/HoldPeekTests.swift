import XCTest
@testable import EinkCore

final class HoldPeekTests: XCTestCase {
    private var directory: URL!
    private var system: FakeSystem!
    private var controller: Controller!
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        system = FakeSystem()
        controller = Controller(store: Store(directory: directory), adapter: system)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: directory) }
    private var gray: SettingValue? { system.values["grayscale"] }

    func testPressRepeatReleaseRecomputesGrayscaleWithoutChangingSavedSettings() throws {
        try controller.setMode(true, now: start)
        let before = try controller.status().configuration
        try controller.beginHoldColor(now: start)
        try controller.beginHoldColor(now: start.addingTimeInterval(0.2))
        XCTAssertEqual(gray, .flag(false))
        try controller.endHoldColor(now: start.addingTimeInterval(0.3))
        XCTAssertEqual(gray, .flag(true))
        XCTAssertEqual(try controller.status().configuration, before)
        XCTAssertNil(try controller.status().state.colorUntil)
    }

    func testReleasePreservesTimedPeekAndFocusBreak() throws {
        try controller.setMode(true, now: start)
        try controller.startTemporaryColor(for: 60, now: start)
        try controller.beginHoldColor(now: start.addingTimeInterval(1))
        try controller.endHoldColor(now: start.addingTimeInterval(2))
        XCTAssertEqual(gray, .flag(false), "the timed peek still owns color")
        try controller.tick(now: start.addingTimeInterval(61))
        XCTAssertEqual(gray, .flag(true))

        var config = try controller.status().configuration
        config.focus.focusMinutes = 1; config.focus.breakMinutes = 1; config.focus.sessions = 2
        try controller.update(config, now: start.addingTimeInterval(62))
        try controller.startFocus(now: start.addingTimeInterval(62))
        try controller.tick(now: start.addingTimeInterval(122))
        XCTAssertEqual(try controller.status().state.focus?.phase, .rest)
        try controller.beginHoldColor(now: start.addingTimeInterval(123))
        try controller.endHoldColor(now: start.addingTimeInterval(124))
        XCTAssertEqual(gray, .flag(false), "the break still owns color")
    }

    func testMissedReleaseExpiresAndRestartDoesNotReviveHeldColor() throws {
        try controller.setMode(true, now: start)
        try controller.beginHoldColor(now: start)
        try controller.renewHoldColor(now: start.addingTimeInterval(0.5))
        try controller.tick(now: start.addingTimeInterval(1.9))
        XCTAssertEqual(gray, .flag(false))
        try controller.tick(now: start.addingTimeInterval(2.1))
        XCTAssertEqual(gray, .flag(true))
        try controller.beginHoldColor(now: start.addingTimeInterval(3))
        let restarted = Controller(store: Store(directory: directory), adapter: system)
        try restarted.resume(now: start.addingTimeInterval(3.2))
        XCTAssertEqual(gray, .flag(true))
        XCTAssertFalse(try restarted.status().holdColorActive)
    }

    func testOtherControllerReplacingSessionCannotReviveOldHold() throws {
        try controller.setMode(true, now: start)
        try controller.beginHoldColor(now: start)
        let other = Controller(store: Store(directory: directory), adapter: system)
        try other.setMode(false, now: start.addingTimeInterval(1))
        try other.setMode(true, now: start.addingTimeInterval(2))
        try controller.renewHoldColor(now: start.addingTimeInterval(2.1))
        try controller.tick(now: start.addingTimeInterval(2.2))
        XCTAssertEqual(gray, .flag(true))
        XCTAssertFalse(try controller.status().holdColorActive)
    }

    func testDelayedRenewalRestoresGrayscaleBeforeDiscardingExpiredLease() throws {
        try controller.setMode(true, now: start)
        try controller.beginHoldColor(now: start)
        XCTAssertEqual(gray, .flag(false))
        try controller.renewHoldColor(now: start.addingTimeInterval(3))
        XCTAssertEqual(gray, .flag(true))
        try controller.endHoldColor(now: start.addingTimeInterval(3.1))
        XCTAssertEqual(gray, .flag(true))
    }

    func testSettingsEditCancelsHoldAndFocusTimeKeepsRunning() throws {
        var config = Configuration(); config.focus.focusMinutes = 1
        try controller.update(config, now: start)
        try controller.startFocus(now: start)
        try controller.beginHoldColor(now: start.addingTimeInterval(5))
        XCTAssertEqual(gray, .flag(false))
        try controller.edit(now: start.addingTimeInterval(6)) { $0.hideDock = true }
        XCTAssertEqual(gray, .flag(true))
        XCTAssertEqual(try controller.status().state.focus?.phaseEnds, start.addingTimeInterval(60))
        try controller.renewHoldColor(now: start.addingTimeInterval(7))
        XCTAssertEqual(gray, .flag(true))
    }
}
