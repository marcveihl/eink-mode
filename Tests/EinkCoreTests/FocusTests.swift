import XCTest
@testable import EinkCore

final class FocusTests: XCTestCase {
    var directory: URL!
    var system: FakeSystem!
    var controller: Controller!
    var calendar: Calendar!
    // 2026-09-16 09:00 America/Chicago
    let start = ISO8601DateFormatter().date(from: "2026-09-16T09:00:00-05:00")!
    override func setUp() {
        calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        system = FakeSystem(); system.values["grayscale"] = .flag(false)
        controller = Controller(store: Store(directory: directory), adapter: system, calendar: calendar)
        var config = Configuration(); config.hideDock = true
        try! controller.update(config, now: start)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: directory) }
    func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }
    var gray: Bool { system.values["grayscale"] == .flag(true) }

    func testFullRoundAlternatesGrayscaleFocusAndColorBreaks() throws {
        let original = system.values
        try controller.startFocus(sessions: 2, now: start)
        XCTAssertTrue(gray, "focus is grayscale")
        XCTAssertEqual(system.values["dock"], .flag(true), "the rest of the profile applies")
        XCTAssertEqual(try controller.status().state.focus?.round, 1)

        try controller.tick(now: at(24.9)); XCTAssertTrue(gray)
        try controller.tick(now: at(25)); XCTAssertFalse(gray, "break is color")
        XCTAssertEqual(system.values["dock"], .flag(true), "only grayscale lifts during the break")
        XCTAssertEqual(try controller.status().state.focus?.phase, .rest)

        try controller.tick(now: at(30)); XCTAssertTrue(gray, "back to grayscale for session 2")
        XCTAssertEqual(try controller.status().state.focus?.round, 2)

        try controller.tick(now: at(55))
        XCTAssertNil(try controller.status().state.focus, "round ends after the last focus session")
        XCTAssertEqual(system.values, original, "E-Ink was off before, so the display is fully restored")
        let stats = try controller.focusStats(now: at(56))
        XCTAssertEqual(stats.today.completed, 2)
        XCTAssertEqual(stats.today.focusMinutes, 50)
        XCTAssertEqual(stats.today.rounds, 1)
    }
    func testRoundStartedWhileOnKeepsModeOnAfterwards() throws {
        try controller.setMode(true, now: start)
        try controller.startFocus(sessions: 1, now: start)
        try controller.tick(now: at(25))
        XCTAssertTrue(try controller.status().active, "E-Ink stays on: the round didn't turn it on")
        XCTAssertTrue(gray)
    }
    func testFocusStaysGrayscaleEvenIfProfileGrayscaleIsOff() throws {
        try controller.edit(now: start) { $0.grayscale = false }
        try controller.startFocus(now: start)
        XCTAssertTrue(gray)
    }
    func testSleepThroughSeveralPhasesCatchesUpInOneTick() throws {
        try controller.startFocus(sessions: 4, now: start)
        // Asleep from 0 to 62 minutes: focus 1 (0-25), break (25-30), focus 2 (30-55), break (55-60), focus 3 from 60.
        try controller.tick(now: at(62))
        let focus = try XCTUnwrap(try controller.status().state.focus)
        XCTAssertEqual(focus.round, 3); XCTAssertEqual(focus.phase, .focus)
        XCTAssertEqual(focus.phaseEnds, at(85))
        XCTAssertTrue(gray)
        XCTAssertEqual(try controller.focusStats(now: at(62)).today.completed, 2)
    }
    func testStopEarlyCreditsMinutesAndRestoresOwnedMode() throws {
        let original = system.values
        try controller.startFocus(now: start)
        try controller.stopFocus(now: at(12.5))
        XCTAssertEqual(system.values, original)
        let today = try controller.focusStats(now: at(13)).today
        XCTAssertEqual(today.completed, 0); XCTAssertEqual(today.stopped, 1); XCTAssertEqual(today.focusMinutes, 12)
    }
    func testTurningOffDuringFocusEndsTheRound() throws {
        try controller.startFocus(now: start)
        try controller.setMode(false, now: at(10))
        XCTAssertNil(try controller.status().state.focus)
        XCTAssertEqual(try controller.focusStats(now: at(10)).today.stopped, 1)
    }
    func testSkipBreakStartsNextSessionNow() throws {
        try controller.startFocus(sessions: 3, now: start)
        try controller.tick(now: at(26))
        XCTAssertThrowsError(try controller.startFocus(now: at(26)), "only one round at a time")
        try controller.skipBreak(now: at(27))
        let focus = try XCTUnwrap(try controller.status().state.focus)
        XCTAssertEqual(focus.round, 2); XCTAssertEqual(focus.phaseEnds, at(52)); XCTAssertTrue(gray)
        XCTAssertThrowsError(try controller.skipBreak(now: at(28)), "no break during focus")
    }
    func testTemporaryColorIsUnavailableDuringFocus() throws {
        try controller.startFocus(now: start)
        XCTAssertThrowsError(try controller.startTemporaryColor(now: at(1)))
    }
    func testScheduleWaitsForTheRoundToFinish() throws {
        var config = try controller.status().configuration
        config.schedule.enabled = true; config.schedule.on = 8 * 60; config.schedule.off = 9 * 60 + 30
        try controller.setMode(true, now: start)
        try controller.update(config, now: start)
        try controller.startFocus(sessions: 2, now: start)
        try controller.tick(now: at(35)) // past 09:30 off boundary, mid-round
        XCTAssertNotNil(try controller.status().state.focus)
        XCTAssertTrue(try controller.status().active)
    }
    func testSettingsChangesDoNotDisruptRunningRound() throws {
        try controller.startFocus(now: start)
        try controller.edit(now: at(5)) { $0.focus.focusMinutes = 50 }
        XCTAssertEqual(try controller.status().state.focus?.phaseEnds, at(25))
    }
    func testFocusSurvivesRestartAndResume() throws {
        try controller.startFocus(now: start)
        let restarted = Controller(store: Store(directory: directory), adapter: system, calendar: calendar)
        system.values["grayscale"] = .flag(false)
        try restarted.resume(now: at(5))
        XCTAssertTrue(gray)
        try restarted.tick(now: at(25))
        XCTAssertFalse(gray)
    }
    func testSettingsValidation() {
        var settings = FocusSettings()
        XCTAssertNoThrow(try settings.validate())
        settings.sessions = 0; XCTAssertThrowsError(try settings.validate())
        settings = FocusSettings(); settings.focusMinutes = 181; XCTAssertThrowsError(try settings.validate())
        XCTAssertThrowsError(try controller.startFocus(sessions: 13, now: start))
    }
    func testOlderConfigFilesWithoutFocusStillLoad() throws {
        let old = #"{"grayscale":true,"brightness":0.35,"hideDock":true,"reduceMotion":false,"reduceTransparency":false,"schedule":{"enabled":false,"on":1260,"off":420}}"#
        let config = try JSONDecoder().decode(Configuration.self, from: Data(old.utf8))
        XCTAssertEqual(config.focus, FocusSettings())
        XCTAssertEqual(config.brightness, 0.35)
    }
}

final class FocusStatsTests: XCTestCase {
    var calendar: Calendar!
    let locale = Locale(identifier: "en_US_POSIX")
    let now = ISO8601DateFormatter().date(from: "2026-09-16T15:00:00-05:00")! // a Wednesday
    override func setUp() { calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/Chicago")! }
    func history(_ days: [String: Int]) -> FocusHistory {
        var h = FocusHistory()
        for (key, n) in days { var r = DayRecord(); r.completed = n; r.focusMinutes = n * 25; h.days[key] = r }
        return h
    }
    func stats(_ days: [String: Int], goal: Int = 4) -> FocusStats {
        FocusStats(history: history(days), goal: goal, now: now, calendar: calendar, locale: locale)
    }
    func testEmptyHistory() {
        let s = stats([:])
        XCTAssertEqual(s.streak, 0); XCTAssertEqual(s.totalCompleted, 0)
        XCTAssertEqual(s.message, "Start your first focus session to begin a streak.")
        XCTAssertEqual(s.week.map(\.label), ["Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Today"])
    }
    func testStreakCountsFromYesterdayWhenNothingYetToday() {
        let s = stats(["2026-09-13": 1, "2026-09-14": 2, "2026-09-15": 3])
        XCTAssertEqual(s.streak, 3)
        XCTAssertEqual(s.message, "Keep your 3-day streak alive — one session does it.")
    }
    func testStreakIncludesTodayAndBreaksOnGaps() {
        let s = stats(["2026-09-10": 5, "2026-09-11": 5, "2026-09-12": 5, "2026-09-13": 5, "2026-09-15": 1, "2026-09-16": 1])
        XCTAssertEqual(s.streak, 2)
        XCTAssertEqual(s.bestStreak, 4)
        XCTAssertEqual(s.message, "3 more sessions to reach today's goal of 4.")
    }
    func testGoalAndPersonalBestMessages() {
        XCTAssertEqual(stats(["2026-09-15": 9, "2026-09-16": 3]).message, "One more session to reach today's goal.")
        XCTAssertEqual(stats(["2026-09-15": 9, "2026-09-16": 4]).message, "Daily goal reached — 4 sessions. Great work!")
        XCTAssertEqual(stats(["2026-09-15": 5, "2026-09-16": 6]).message, "New personal best: 6 sessions in one day!")
    }
    func testTotalsAndWeek() {
        let s = stats(["2026-09-01": 8, "2026-09-12": 2, "2026-09-16": 4])
        XCTAssertEqual(s.totalCompleted, 14); XCTAssertEqual(s.totalMinutes, 350)
        XCTAssertEqual(s.weekCompleted, 6); XCTAssertEqual(s.bestDay, 8); XCTAssertEqual(s.daysGoalMet, 2)
        XCTAssertEqual(s.week.last?.completed, 4)
    }
}
