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
        var config = Configuration(); config.hideDock = true; config.focus.grayscale = true
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
    func testTurningOffDuringFocusKeepsTheRoundAndRelinquishesDisplayControl() throws {
        try controller.startFocus(sessions: 2, now: start)
        try controller.setMode(false, now: at(10))
        XCTAssertFalse(try controller.status().active)
        XCTAssertTrue(try controller.status().focusing)
        XCTAssertEqual(try controller.status().state.focus?.phaseEnds, at(25))
        XCTAssertEqual(try controller.focusStats(now: at(10)).today.stopped, 0)
        try controller.setMode(true, now: at(12)) // the user's manual mode is now independent
        try controller.tick(now: at(25))
        XCTAssertEqual(try controller.status().state.focus?.phase, .rest)
        XCTAssertTrue(gray, "automatic breaks no longer override the manual display choice")
        try controller.tick(now: at(55))
        XCTAssertNil(try controller.status().state.focus)
        XCTAssertTrue(try controller.status().active, "the round no longer owns the manually enabled mode")
        XCTAssertEqual(try controller.focusStats(now: at(55)).today.completed, 2)
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
    func testColorPeekDuringFocusKeepsTheRoundRunning() throws {
        try controller.edit(now: start) { $0.grayscale = false } // profile off: focus still forces grayscale
        try controller.startFocus(sessions: 2, now: start)
        try controller.startTemporaryColor(for: 300, now: at(10))
        XCTAssertFalse(gray, "peek shows color mid-focus")
        XCTAssertEqual(try controller.status().temporaryColorRemaining(now: at(11)) ?? 0, 240, accuracy: 0.01)
        XCTAssertEqual(try controller.status().state.focus?.phaseEnds, at(25), "the round's timer is unchanged")
        try controller.tick(now: at(15)); XCTAssertTrue(gray, "grayscale returns when the peek ends")
        try controller.startTemporaryColor(now: at(16))
        try controller.endTemporaryColor(now: at(17)); XCTAssertTrue(gray, "cancel returns to focus grayscale")
        try controller.tick(now: at(26)); XCTAssertFalse(gray)
        XCTAssertThrowsError(try controller.startTemporaryColor(now: at(27)), "a break is already color")
        XCTAssertNil(try controller.status().temporaryColorRemaining(now: at(27)))
    }
    func testDailyGoalDefaultsToFourAndIsSettable() throws {
        XCTAssertEqual(FocusSettings().dailyGoal, 4)
        XCTAssertEqual(try controller.focusStats(now: start).goal, 4)
        try controller.edit(now: start) { $0.focus.dailyGoal = 6 }
        XCTAssertEqual(try controller.focusStats(now: start).goal, 6)
        XCTAssertThrowsError(try controller.edit(now: start) { $0.focus.dailyGoal = 0 })
    }
    func testUnreadableHistoryDoesNotPartiallyChangeDailyGoal() throws {
        try Data("corrupt".utf8).write(to: directory.appendingPathComponent("focus-history.json"))
        XCTAssertThrowsError(try controller.edit(now: start) { $0.focus.dailyGoal = 7 })
        XCTAssertEqual(try controller.status().configuration.focus.dailyGoal, 4)
    }
    func testChangingTodayGoalPreservesEarlierRecordedGoalAcrossDayBoundary() throws {
        try controller.startFocus(sessions: 1, now: start)
        try controller.tick(now: at(25))
        XCTAssertEqual(try controller.focusStats(now: at(25)).daysGoalMet, 0)
        try controller.edit(now: at(26)) { $0.focus.dailyGoal = 1 }
        XCTAssertEqual(try controller.focusStats(now: at(26)).daysGoalMet, 1)

        let nextDay = calendar.date(byAdding: .day, value: 1, to: start)!
        try controller.edit(now: nextDay) { $0.focus.dailyGoal = 5 }
        try controller.startFocus(sessions: 1, now: nextDay)
        try controller.tick(now: nextDay.addingTimeInterval(25 * 60))
        let stats = try controller.focusStats(now: nextDay.addingTimeInterval(25 * 60))
        XCTAssertEqual(stats.daysGoalMet, 1, "yesterday's saved goal remains met")
        XCTAssertEqual(stats.today.dailyGoal, 5)
        XCTAssertEqual(stats.week[5].goal, 1)
    }
    func testDelayedCompletionUsesGoalCapturedOnRoundStartDay() throws {
        let late = calendar.date(bySettingHour: 23, minute: 20, second: 0, of: start)!
        try controller.startFocus(sessions: 1, now: late)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: late)!
        try controller.edit(now: nextDay) { $0.focus.dailyGoal = 1 }
        try controller.tick(now: nextDay)
        let stats = try controller.focusStats(now: nextDay)
        XCTAssertEqual(stats.week[5].completed, 1)
        XCTAssertEqual(stats.week[5].goal, 4, "delayed recording must retain the goal at round start")
        XCTAssertEqual(stats.daysGoalMet, 0)
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
    func testStoppedPhaseIsAttributedToItsStartDayAcrossMidnight() throws {
        let late = calendar.date(bySettingHour: 23, minute: 50, second: 0, of: start)!
        try controller.startFocus(now: late)
        try controller.pauseFocus(now: late.addingTimeInterval(5 * 60))
        let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: late))!
        try controller.stopFocus(now: nextDay.addingTimeInterval(10 * 60))
        let previous = try controller.focusStats(now: nextDay).today
        XCTAssertEqual(previous.focusMinutes, 0, "the next day must not receive prior-day interrupted minutes")
        let historyData = try Data(contentsOf: directory.appendingPathComponent("focus-history.json"))
        let history = try JSONDecoder().decode(FocusHistory.self, from: historyData)
        XCTAssertEqual(history.days[FocusHistory.key(late, calendar: calendar)]?.focusMinutes, 5)
        XCTAssertNil(history.days[FocusHistory.key(nextDay, calendar: calendar)])
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
    func testPauseFreezesPhaseAndExcludesTimeAcrossRestart() throws {
        try controller.startFocus(sessions: 2, now: start)
        try controller.pauseFocus(now: at(10.5))
        try controller.pauseFocus(now: at(11))
        let restarted = Controller(store: Store(directory: directory), adapter: system, calendar: calendar)
        try restarted.tick(now: at(100))
        let paused = try XCTUnwrap(try restarted.status().state.focus)
        XCTAssertEqual(paused.phase, .focus)
        XCTAssertEqual(paused.round, 1)
        XCTAssertEqual(paused.remaining(now: at(100)), 14.5 * 60, accuracy: 0.01)
        XCTAssertEqual(try restarted.focusStats(now: at(100)).today.completed, 0)
        try restarted.resume(now: at(100)) // display recovery keeps the round paused
        XCTAssertNotNil(try restarted.status().state.focus?.pausedAt)
        try restarted.resumeFocus(now: at(100))
        try restarted.resumeFocus(now: at(101))
        XCTAssertEqual(try restarted.status().state.focus?.phaseEnds, at(114.5))
        try restarted.tick(now: at(114.5))
        XCTAssertEqual(try restarted.focusStats(now: at(115)).today.completed, 1)
        XCTAssertEqual(try restarted.focusStats(now: at(115)).today.focusMinutes, 25)
    }
    func testStopWhilePausedCreditsOnlyActiveMinutes() throws {
        try controller.startFocus(now: start)
        try controller.pauseFocus(now: at(12.5))
        try controller.stopFocus(now: at(90))
        try controller.stopFocus(now: at(91))
        let today = try controller.focusStats(now: at(91)).today
        XCTAssertEqual(today.completed, 0)
        XCTAssertEqual(today.stopped, 1)
        XCTAssertEqual(today.focusMinutes, 12)
    }
    func testPausedRoundRestoresWithDamagedConfig() throws {
        let original = system.values
        try controller.startFocus(now: start)
        try controller.pauseFocus(now: at(8))
        try Data("corrupt".utf8).write(to: directory.appendingPathComponent("config.json"))
        try controller.setMode(false, now: at(100))
        XCTAssertEqual(system.values, original)
        XCTAssertNotNil(try Store(directory: directory).read("state.json", default: RuntimeState()).focus?.pausedAt)
    }
    func testLegacyPersistedRoundDecodesWithoutPauseFields() throws {
        let old = #"{"phase":"focus","round":1,"rounds":4,"phaseStarted":0,"phaseEnds":1500,"focusSeconds":1500,"breakSeconds":300,"ownsMode":true}"#
        let focus = try JSONDecoder().decode(FocusSession.self, from: Data(old.utf8))
        XCTAssertNil(focus.pausedAt)
        XCTAssertTrue(focus.controlsGrayscale)
        XCTAssertEqual(focus.remaining(now: Date(timeIntervalSinceReferenceDate: 0)), 1500)
    }
    func testPauseBreakKeepsColorAndScheduleDefersUntilStop() throws {
        var config = try controller.status().configuration
        config.schedule.enabled = true; config.schedule.on = 8 * 60; config.schedule.off = 9 * 60 + 30
        try controller.update(config, now: start)
        try controller.startFocus(sessions: 2, now: start)
        try controller.tick(now: at(25))
        try controller.pauseFocus(now: at(27))
        try controller.tick(now: at(60))
        XCTAssertFalse(gray)
        XCTAssertEqual(try controller.status().state.focus?.phase, .rest)
        XCTAssertEqual(try XCTUnwrap(controller.status().state.focus).remaining(now: at(60)), 3 * 60, accuracy: 0.01)
        try controller.resumeFocus(now: at(60))
        try controller.tick(now: at(63))
        XCTAssertTrue(gray)
        XCTAssertEqual(try controller.status().state.focus?.round, 2)
    }
    func testColorPeekExpiresWhileFocusPausedWithoutAdvancingFocus() throws {
        try controller.startFocus(now: start)
        try controller.startTemporaryColor(for: 5 * 60, now: at(2))
        try controller.pauseFocus(now: at(3))
        XCTAssertFalse(gray)
        try controller.tick(now: at(7))
        XCTAssertTrue(gray)
        XCTAssertNotNil(try controller.status().state.focus?.pausedAt)
        XCTAssertEqual(try XCTUnwrap(controller.status().state.focus).remaining(now: at(7)), 22 * 60, accuracy: 0.01)
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

    func testNewAndLegacyPreferencesDefaultToTimerOnly() throws {
        XCTAssertFalse(FocusSettings().grayscale)
        let old = #"{"focusMinutes":25,"breakMinutes":5,"sessions":4,"dailyGoal":4}"#
        XCTAssertFalse(try JSONDecoder().decode(FocusSettings.self, from: Data(old.utf8)).grayscale)
        var settings = FocusSettings(); settings.grayscale = true
        XCTAssertEqual(try JSONDecoder().decode(FocusSettings.self, from: JSONEncoder().encode(settings)), settings)
    }

    func testTimerOnlyRoundLeavesEveryDisplaySettingAloneAndCatchesUpAfterRestart() throws {
        try controller.update(Configuration(), now: start)
        system.values.removeValue(forKey: "grayscale") // a timer does not require native grayscale support
        let original = system.values
        try controller.startFocus(sessions: 2, now: start)
        XCTAssertTrue(try controller.status().focusing)
        XCTAssertFalse(try controller.status().active)
        XCTAssertEqual(system.values, original)
        let restarted = Controller(store: Store(directory: directory), adapter: system, calendar: calendar)
        try restarted.tick(now: at(25))
        XCTAssertEqual(try restarted.status().state.focus?.phase, .rest)
        try restarted.skipBreak(now: at(27))
        XCTAssertEqual(try restarted.status().state.focus?.phaseEnds, at(52))
        try restarted.tick(now: at(60))
        XCTAssertNil(try restarted.status().state.focus)
        XCTAssertEqual(system.values, original)
        XCTAssertEqual(system.writes, 0, "a timer-only round must not write display settings")
        let stats = try restarted.focusStats(now: at(60))
        XCTAssertEqual(stats.today.completed, 2)
        XCTAssertEqual(stats.today.focusMinutes, 50)
        XCTAssertEqual(stats.today.rounds, 1)
    }

    func testTimerOnlyRoundDoesNotReapplyAnActiveDisplayProfile() throws {
        try controller.edit(now: start) { $0.focus.grayscale = false }
        try controller.setMode(true, now: start)
        let writes = system.writes
        try controller.startFocus(sessions: 2, now: start)
        try controller.pauseFocus(now: at(5))
        try controller.resumeFocus(now: at(6))
        try controller.tick(now: at(26))
        try controller.skipBreak(now: at(27))
        try controller.tick(now: at(52))
        XCTAssertNil(try controller.status().state.focus)
        XCTAssertEqual(system.writes, writes, "timer actions must not rewrite an active display profile")
    }

    func testTimerOnlyRoundKeepsExistingModeAndColorPeekAcrossBreaks() throws {
        try controller.edit(now: start) { $0.focus.grayscale = false }
        try controller.setMode(true, now: start)
        try controller.startTemporaryColor(for: 40 * 60, now: start)
        let original = system.values
        try controller.startFocus(sessions: 2, now: start)
        XCTAssertEqual(system.values, original)
        try controller.tick(now: at(25))
        XCTAssertEqual(try controller.status().temporaryColorRemaining(now: at(25)), 15 * 60)
        try controller.endTemporaryColor(now: at(26))
        XCTAssertTrue(gray, "timer-only breaks leave the existing grayscale profile alone")
        try controller.startTemporaryColor(now: at(27))
        XCTAssertFalse(gray, "timer-only breaks still allow the normal color peek")
        try controller.stopFocus(now: at(28))
        XCTAssertFalse(gray, "stopping a timer leaves the manual color peek alone")
        XCTAssertTrue(try controller.status().active)
    }

    func testManualGrayscaleSettingsWinWithoutChangingFocusDeadline() throws {
        try controller.startFocus(sessions: 2, now: start)
        try controller.edit(now: at(10)) { $0.grayscale = false }
        XCTAssertFalse(gray)
        XCTAssertEqual(try controller.status().state.focus?.phaseEnds, at(25))
        try controller.tick(now: at(30))
        XCTAssertFalse(gray, "next focus phase honors the manual grayscale choice")
        XCTAssertEqual(try controller.status().state.focus?.round, 2)
        XCTAssertEqual(try controller.focusStats(now: at(30)).today.stopped, 0)
    }

    func testToggleOffDuringPausedFocusSurvivesRestartAndFinishesNormally() throws {
        try controller.startFocus(sessions: 1, now: start)
        try controller.pauseFocus(now: at(10))
        try controller.toggle(now: at(11))
        let restarted = Controller(store: Store(directory: directory), adapter: system, calendar: calendar)
        try restarted.tick(now: at(100))
        XCTAssertEqual(try XCTUnwrap(restarted.status().state.focus).remaining(now: at(100)), 15 * 60)
        try restarted.resumeFocus(now: at(100))
        try restarted.tick(now: at(115))
        XCTAssertNil(try restarted.status().state.focus)
        XCTAssertFalse(try restarted.status().active)
        XCTAssertEqual(try restarted.focusStats(now: at(115)).today.completed, 1)
    }

    func testFocusDisplayPreferenceAppliesToNextRound() throws {
        try controller.edit(now: start) { $0.focus.grayscale = false }
        try controller.startFocus(sessions: 1, now: start)
        try controller.edit(now: at(5)) { $0.focus.grayscale = true }
        XCTAssertFalse(try controller.status().active)
        XCTAssertFalse(try XCTUnwrap(controller.status().state.focus).controlsGrayscale)
        try controller.tick(now: at(25))
        try controller.startFocus(sessions: 1, now: at(26))
        XCTAssertTrue(gray)
        XCTAssertTrue(try XCTUnwrap(controller.status().state.focus).controlsGrayscale)
    }

    func testQuitEndsTimerOnlyRoundAndCreditsActiveMinutes() throws {
        try controller.edit(now: start) { $0.focus.grayscale = false }
        let original = system.values
        try controller.startFocus(now: start)
        try controller.shutdown(resumeScheduleOnLaunch: false, now: at(12))
        XCTAssertNil(try controller.status().state.focus)
        XCTAssertEqual(system.values, original)
        XCTAssertEqual(try controller.focusStats(now: at(12)).today.focusMinutes, 12)
        XCTAssertEqual(try controller.focusStats(now: at(12)).today.stopped, 1)
    }
}

final class FocusStatsTests: XCTestCase {
    var calendar: Calendar!
    let locale = Locale(identifier: "en_US_POSIX")
    let now = ISO8601DateFormatter().date(from: "2026-09-16T15:00:00-05:00")! // a Wednesday
    override func setUp() { calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/Chicago")! }
    func history(_ days: [String: Int]) -> FocusHistory {
        var h = FocusHistory()
        for (key, n) in days { var r = DayRecord(); r.completed = n; r.focusMinutes = n * 25; r.dailyGoal = 4; h.days[key] = r }
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
    func testLegacyGoalIsUnknownAndExcludedWithoutChangingOtherTotals() throws {
        let old = #"{"days":{"2026-09-15":{"completed":6,"focusMinutes":150,"stopped":0,"rounds":1}}}"#
        let history = try JSONDecoder().decode(FocusHistory.self, from: Data(old.utf8))
        XCTAssertNil(history.days["2026-09-15"]?.dailyGoal)
        let stats = FocusStats(history: history, goal: 4, now: now, calendar: calendar, locale: locale)
        XCTAssertEqual(stats.totalCompleted, 6)
        XCTAssertEqual(stats.totalRounds, 1)
        XCTAssertEqual(stats.daysGoalMet, 0)
        XCTAssertEqual(stats.unknownGoalDays, 1)
        XCTAssertNil(stats.week[5].goal)
        let roundTrip = try JSONDecoder().decode(FocusHistory.self, from: JSONEncoder().encode(history))
        XCTAssertNil(roundTrip.days["2026-09-15"]?.dailyGoal)
    }
    func testDelayedRecordKeepsOriginalGoalAndLegacyUnknown() {
        var history = history(["2026-09-15": 2])
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        history.update(yesterday, calendar: calendar, goal: 24) { $0.completed += 1 }
        XCTAssertEqual(history.days["2026-09-15"]?.dailyGoal, 4)

        history.days["2026-09-15"]?.dailyGoal = nil
        history.update(yesterday, calendar: calendar, goal: 24) { $0.completed += 1 }
        XCTAssertNil(history.days["2026-09-15"]?.dailyGoal)
    }
    func testRetentionPrunesOldestAndKeepsSurvivingGoals() {
        var history = FocusHistory()
        let first = calendar.date(from: DateComponents(year: 2024, month: 1, day: 1))!
        for offset in 0..<801 {
            let date = calendar.date(byAdding: .day, value: offset, to: first)!
            history.update(date, calendar: calendar, goal: offset % 2 == 0 ? 2 : 3) { $0.completed = 2 }
        }
        XCTAssertEqual(history.days.count, 800)
        XCTAssertNil(history.days[FocusHistory.key(first, calendar: calendar)])
        let surviving = calendar.date(byAdding: .day, value: 1, to: first)!
        XCTAssertEqual(history.days[FocusHistory.key(surviving, calendar: calendar)]?.dailyGoal, 3)
        let final = calendar.date(byAdding: .day, value: 800, to: first)!
        let stats = FocusStats(history: history, goal: 24, now: final, calendar: calendar, locale: locale)
        XCTAssertEqual(stats.daysGoalMet, 400)
        XCTAssertEqual(stats.unknownGoalDays, 0)
    }
}
