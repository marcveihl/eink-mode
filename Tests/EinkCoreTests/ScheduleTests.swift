import XCTest
@testable import EinkCore

final class ScheduleTests: XCTestCase {
    var calendar: Calendar!
    var directory: URL!
    var system: FakeSystem!
    var controller: Controller!
    override func setUp() {
        calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        system = FakeSystem()
        controller = Controller(store: Store(directory: directory), adapter: system, calendar: calendar)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: directory) }
    func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    func enable(at date: Date) throws {
        var config = Configuration(); config.schedule.enabled = true; try controller.update(config, now: date)
    }
    func testOvernightBoundariesAndWakeCatchup() throws {
        try enable(at: date("2026-09-16T20:59:00-05:00"))
        XCTAssertFalse(try controller.status().active)
        try controller.tick(now: date("2026-09-16T21:00:00-05:00"))
        XCTAssertTrue(try controller.status().active)
        let capture = try controller.status().state.session?.started
        try controller.tick(now: date("2026-09-17T03:00:00-05:00"))
        XCTAssertEqual(try controller.status().state.session?.started, capture)
        try controller.tick(now: date("2026-09-17T09:30:00-05:00"))
        XCTAssertFalse(try controller.status().active)
        try controller.tick(now: date("2026-09-19T01:00:00-05:00"))
        XCTAssertTrue(try controller.status().active)
    }
    func testManualOverridePersistsAcrossRestartUntilNextBoundary() throws {
        try enable(at: date("2026-09-16T22:00:00-05:00"))
        try controller.setMode(false, now: date("2026-09-16T23:00:00-05:00"))
        let restarted = Controller(store: Store(directory: directory), adapter: system, calendar: calendar)
        try restarted.tick(now: date("2026-09-17T02:00:00-05:00"))
        XCTAssertFalse(try restarted.status().active)
        try restarted.tick(now: date("2026-09-17T21:00:00-05:00"))
        XCTAssertTrue(try restarted.status().active)
    }
    func testManualOnDuringDaySurvivesPolling() throws {
        try enable(at: date("2026-09-16T12:00:00-05:00"))
        try controller.setMode(true, now: date("2026-09-16T13:00:00-05:00"))
        try controller.tick(now: date("2026-09-16T14:00:00-05:00"))
        XCTAssertTrue(try controller.status().active)
        try controller.tick(now: date("2026-09-17T07:00:00-05:00"))
        XCTAssertFalse(try controller.status().active)
    }
    func testDisabledScheduleNeverActivatesAtLaunch() throws {
        try controller.tick(now: date("2026-09-16T23:00:00-05:00"))
        XCTAssertFalse(try controller.status().active)
        XCTAssertEqual(system.writes, 0)
    }
    func testDaytimeScheduleAndIdenticalTimeValidation() throws {
        var config = Configuration(); config.schedule.enabled = true; config.schedule.on = 9 * 60; config.schedule.off = 17 * 60
        try controller.update(config, now: date("2026-09-16T12:00:00-05:00"))
        XCTAssertTrue(try controller.status().active)
        try controller.tick(now: date("2026-09-16T17:00:00-05:00"))
        XCTAssertFalse(try controller.status().active)
        config.schedule.off = config.schedule.on
        XCTAssertThrowsError(try controller.update(config))
    }
    func testDSTKeepsLocalWallClockTimes() throws {
        let schedule = Schedule()
        XCTAssertTrue(schedule.boundary(at: date("2026-03-08T06:59:00-05:00"), calendar: calendar).active)
        XCTAssertFalse(schedule.boundary(at: date("2026-03-08T07:00:00-05:00"), calendar: calendar).active)
        XCTAssertTrue(schedule.boundary(at: date("2026-11-01T01:30:00-05:00"), calendar: calendar).active)
        XCTAssertTrue(schedule.boundary(at: date("2026-11-01T01:30:00-06:00"), calendar: calendar).active)
        XCTAssertFalse(schedule.boundary(at: date("2026-11-01T07:00:00-06:00"), calendar: calendar).active)
    }
    func testScheduleChangesReconcileImmediately() throws {
        try enable(at: date("2026-09-16T20:30:00-05:00"))
        XCTAssertFalse(try controller.status().active)
        var config = try controller.status().configuration; config.schedule.on = 20 * 60
        try controller.update(config, now: date("2026-09-16T20:30:00-05:00"))
        XCTAssertTrue(try controller.status().active)
    }
    func testTimeInputValidation() throws {
        XCTAssertEqual(try Schedule.parse("21:00"), 1260)
        for input in ["24:00", "21:60", "9pm", "-1:00", "", "21:00:00"] { XCTAssertThrowsError(try Schedule.parse(input)) }
    }
    func testRepeatedDSTHourHasOnlyOneDailyBoundary() throws {
        var config = Configuration(); config.schedule.enabled = true; config.schedule.on = 90
        try controller.update(config, now: date("2026-11-01T01:35:00-05:00"))
        XCTAssertTrue(try controller.status().active)
        try controller.setMode(false, now: date("2026-11-01T01:40:00-05:00"))
        try controller.tick(now: date("2026-11-01T01:45:00-06:00"))
        XCTAssertFalse(try controller.status().active)
        try controller.tick(now: date("2026-11-02T01:30:00-06:00"))
        XCTAssertTrue(try controller.status().active)
    }
    func testSkippedDSTTimeRunsAtNextValidWallTime() throws {
        var config = Configuration(); config.schedule.enabled = true; config.schedule.on = 150
        try controller.update(config, now: date("2026-03-08T01:59:00-06:00"))
        XCTAssertFalse(try controller.status().active)
        try controller.tick(now: date("2026-03-08T03:00:00-05:00"))
        XCTAssertTrue(try controller.status().active)
    }

    func testQuitPausesScheduleButLogoutCatchesUpOnNextLaunch() throws {
        try enable(at: date("2026-09-16T21:30:00-05:00"))
        XCTAssertTrue(try controller.status().active)
        try controller.shutdown(resumeScheduleOnLaunch: false, now: date("2026-09-16T22:00:00-05:00"))
        try controller.tick(now: date("2026-09-16T22:05:00-05:00"))
        XCTAssertFalse(try controller.status().active, "a deliberate quit holds until the next boundary")
        try controller.setMode(true, now: date("2026-09-16T22:10:00-05:00"))
        try controller.shutdown(resumeScheduleOnLaunch: true, now: date("2026-09-16T22:15:00-05:00"))
        XCTAssertEqual(system.values["grayscale"], .flag(true), "FakeSystem starts grayscale; restored exactly")
        XCTAssertFalse(try controller.status().active)
        try controller.tick(now: date("2026-09-16T22:20:00-05:00"))
        XCTAssertTrue(try controller.status().active, "after logout the schedule resumes on launch")
    }
}
