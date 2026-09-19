import XCTest
@testable import EinkCore

final class TemporaryColorTests: XCTestCase {
    var directory: URL!
    var system: FakeSystem!
    var controller: Controller!
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        system = FakeSystem(); system.values["grayscale"] = .flag(false)
        controller = Controller(store: Store(directory: directory), adapter: system)
        var config = Configuration(); config.hideDock = true; config.brightness = 0.4
        try! controller.update(config, now: start)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    func testDefaultsChangeGrayscaleOnly() throws {
        let fresh = Controller(store: Store(directory: directory.appendingPathComponent("fresh")), adapter: system)
        let before = system.values
        try fresh.setMode(true, now: start)
        var expected = before; expected["grayscale"] = .flag(true)
        XCTAssertEqual(system.values, expected)
        try fresh.setMode(false, now: start)
        XCTAssertEqual(system.values, before)
    }
    func testColorLiftsGrayscaleOnlyAndReturnsAutomatically() throws {
        try controller.setMode(true, now: start)
        let config = try controller.status().configuration
        try controller.startTemporaryColor(for: 300, now: start)
        XCTAssertEqual(system.values["grayscale"], .flag(false))
        XCTAssertEqual(system.values["dock"], .flag(true))
        XCTAssertEqual(system.values["brightness:A"], .level(0.4))
        XCTAssertEqual(try controller.status().configuration, config, "saved profile must be untouched")
        XCTAssertEqual(try controller.status().temporaryColorRemaining(now: start.addingTimeInterval(28)) ?? 0, 272, accuracy: 0.01)
        try controller.tick(now: start.addingTimeInterval(299))
        XCTAssertEqual(system.values["grayscale"], .flag(false))
        try controller.tick(now: start.addingTimeInterval(300))
        XCTAssertEqual(system.values["grayscale"], .flag(true))
        XCTAssertNil(try controller.status().state.colorUntil)
        XCTAssertTrue(try controller.status().active)
    }
    func testCancelResumesGrayscale() throws {
        try controller.setMode(true, now: start)
        try controller.startTemporaryColor(now: start)
        try controller.endTemporaryColor(now: start.addingTimeInterval(10))
        XCTAssertEqual(system.values["grayscale"], .flag(true))
        XCTAssertNil(try controller.status().temporaryColorRemaining(now: start.addingTimeInterval(11)))
    }
    func testWakeAfterExpiryCatchesUp() throws {
        try controller.setMode(true, now: start)
        try controller.startTemporaryColor(now: start)
        // Asleep for an hour: the first tick on wake returns to grayscale.
        try controller.tick(now: start.addingTimeInterval(3600))
        XCTAssertEqual(system.values["grayscale"], .flag(true))
    }
    func testTurningOffDuringColorRestoresOriginalAndClearsTimer() throws {
        let original = system.values
        try controller.setMode(true, now: start)
        try controller.startTemporaryColor(now: start)
        try controller.setMode(false, now: start.addingTimeInterval(5))
        XCTAssertEqual(system.values, original)
        XCTAssertNil(try controller.status().state.colorUntil)
        try controller.setMode(true, now: start.addingTimeInterval(10))
        XCTAssertEqual(system.values["grayscale"], .flag(true), "a later session starts in grayscale")
    }
    func testSettingsEditsDuringColorKeepColorUntilExpiry() throws {
        try controller.setMode(true, now: start)
        try controller.startTemporaryColor(now: start)
        try controller.edit(now: start.addingTimeInterval(20)) { $0.reduceMotion = true }
        XCTAssertEqual(system.values["grayscale"], .flag(false))
        XCTAssertEqual(system.values["motion"], .flag(true))
    }
    func testResumeAfterCrashHonorsExpiry() throws {
        try controller.setMode(true, now: start)
        try controller.startTemporaryColor(now: start)
        let restarted = Controller(store: Store(directory: directory), adapter: system)
        try restarted.resume(now: start.addingTimeInterval(60))
        XCTAssertEqual(system.values["grayscale"], .flag(false))
        try restarted.resume(now: start.addingTimeInterval(600))
        XCTAssertEqual(system.values["grayscale"], .flag(true))
    }
    func testColorRequiresActiveGrayscaleProfile() throws {
        XCTAssertThrowsError(try controller.startTemporaryColor(now: start))
        try controller.edit(now: start) { $0.grayscale = false }
        try controller.setMode(true, now: start)
        XCTAssertThrowsError(try controller.startTemporaryColor(now: start))
    }
    func testPreviewProfileIsNotSavedAndRestoresExactly() throws {
        let original = system.values
        let saved = try controller.status().configuration
        try controller.setMode(true, manual: false, profile: Configuration(), now: start)
        XCTAssertEqual(system.values["grayscale"], .flag(true))
        XCTAssertEqual(system.values["dock"], original["dock"], "preview must not touch the Dock")
        XCTAssertEqual(try controller.status().configuration, saved)
        try controller.setMode(false, manual: false, now: start.addingTimeInterval(10))
        XCTAssertEqual(system.values, original)
    }
    func testCountdownFormatting() {
        XCTAssertEqual(countdown(272), "4:32")
        XCTAssertEqual(countdown(299.2), "5:00")
        XCTAssertEqual(countdown(-3), "0:00")
    }
}

final class ScheduleStatusTests: XCTestCase {
    var calendar: Calendar!
    let locale = Locale(identifier: "en_US_POSIX")
    override func setUp() { calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/Chicago")! }
    func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    func status(_ config: Configuration, _ state: RuntimeState = RuntimeState(), at text: String) -> ScheduleStatus {
        ScheduleStatus(configuration: config, state: state, now: date(text), calendar: calendar, locale: locale)
    }
    var evening: Configuration { var c = Configuration(); c.schedule = .evening; c.schedule.enabled = true; return c }
    var activeState: RuntimeState {
        var s = RuntimeState(); s.session = Session(started: Date(), original: [:], managed: [], phase: "active"); return s
    }

    func testDisabled() {
        XCTAssertEqual(status(Configuration(), at: "2026-09-16T12:00:00-05:00").short, "Off")
    }
    func testTurnsOnTonight() {
        let s = status(evening, at: "2026-09-16T12:00:00-05:00")
        XCTAssertEqual(s.short, "Turns on tonight at 9:00 PM")
        XCTAssertTrue(s.turnsOn)
    }
    func testUntilMorningWhileActive() {
        XCTAssertEqual(status(evening, activeState, at: "2026-09-16T23:00:00-05:00").short, "Until 7:00 AM")
        XCTAssertEqual(status(evening, activeState, at: "2026-09-17T02:00:00-05:00").short, "Until 7:00 AM")
    }
    func testThisMorningPhrasing() {
        XCTAssertEqual(status(evening, activeState, at: "2026-09-17T00:30:00-05:00").detail.hasPrefix("On until this morning at 7:00 AM"), true)
    }
    func testTomorrowPhrasing() {
        var config = evening; config.schedule.on = 6 * 60; config.schedule.off = 8 * 60
        XCTAssertEqual(status(config, at: "2026-09-16T12:00:00-05:00").short, "Turns on tomorrow at 6:00 AM")
    }
    func testManualOverrideExplainsWhenScheduleResumes() {
        var state = RuntimeState()
        // Off by hand during the scheduled evening period.
        state.manualUntilBoundary = date("2026-09-16T21:00:00-05:00")
        let s = status(evening, state, at: "2026-09-16T22:00:00-05:00")
        XCTAssertTrue(s.manualOverride)
        XCTAssertEqual(s.short, "Off by hand · resumes 7:00 AM")
        XCTAssertTrue(s.detail.contains("won't change it until tomorrow at 7:00 AM"), s.detail)
    }
    func testEveningPreset() {
        XCTAssertTrue(Schedule.evening.isEvening)
        XCTAssertEqual(Schedule.format(Schedule.evening.on), "21:00")
        XCTAssertEqual(Schedule.format(Schedule.evening.off), "07:00")
    }
}

final class UpdateTests: XCTestCase {
    private func swap(target: URL, replacement: String) throws -> (status: Int32, opened: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", BundleSwap.script, "swap", "999999", target.path, replacement, "--activate"]
        process.environment = ["EINK_OPEN": "echo", "PATH": "/usr/bin:/bin"]
        let pipe = Pipe(); process.standardOutput = pipe
        try process.run(); process.waitUntilExit()
        return (process.terminationStatus, String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }
    func testBundleSwapReplacesAppAndReopensWithArguments() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("App.app"), new = root.appendingPathComponent("staged/App.app")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: target.appendingPathComponent("v"))
        try Data("new".utf8).write(to: new.appendingPathComponent("v"))
        let result = try swap(target: target, replacement: new.path)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("v")), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path + ".previous"))
        XCTAssertEqual(result.opened.trimmingCharacters(in: .whitespacesAndNewlines), "\(target.path) --args --activate")
    }
    func testBundleSwapRollsBackWhenReplacementIsMissing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("App.app")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: target.appendingPathComponent("v"))
        let result = try swap(target: target, replacement: root.appendingPathComponent("missing.app").path)
        XCTAssertEqual(result.status, 2)
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("v")), "old", "the working app must survive a failed update")
        XCTAssertTrue(result.opened.contains(target.path), "the old app is reopened")
    }
    func v(_ s: String) -> AppVersion { AppVersion(s)! }
    func testVersionOrdering() {
        XCTAssertLessThan(v("0.9.0-beta.1"), v("0.9.0-beta.2"))
        XCTAssertLessThan(v("0.9.0-beta.2"), v("0.9.0-beta.10"))
        XCTAssertLessThan(v("0.9.0-beta.9"), v("0.9.0"))
        XCTAssertLessThan(v("0.9.0"), v("0.10.0"))
        XCTAssertLessThan(v("0.9.0-alpha"), v("0.9.0-beta"))
        XCTAssertEqual(v("v1.2"), v("1.2.0"))
        XCTAssertNil(AppVersion("banana"))
        XCTAssertNil(AppVersion("1.2.3.4"))
    }
    func testPicksNewestReleaseWithArchive() throws {
        let json = """
        [{"tag_name":"v0.9.0-beta.3","html_url":"https://example.com/3","draft":true,"assets":[{"name":"a.zip","browser_download_url":"https://example.com/3.zip"}]},
         {"tag_name":"v0.9.0-beta.2","html_url":"https://example.com/2","draft":false,"body":"Notes","assets":[{"name":"E-Ink-Mode.zip","browser_download_url":"https://example.com/2.zip"}]},
         {"tag_name":"v0.9.0-beta.4","html_url":"https://example.com/4","draft":false,"assets":[]},
         {"tag_name":"nightly","html_url":"https://example.com/n","draft":false,"assets":[{"name":"n.zip","browser_download_url":"https://example.com/n.zip"}]}]
        """
        let releases = try UpdateCheck.decode(Data(json.utf8))
        let found = UpdateCheck.newest(in: releases, newerThan: v("0.9.0-beta.1"))
        XCTAssertEqual(found?.tagName, "v0.9.0-beta.2")
        XCTAssertEqual(found?.archive?.browserDownloadURL.absoluteString, "https://example.com/2.zip")
        XCTAssertNil(UpdateCheck.newest(in: releases, newerThan: v("0.9.0-beta.2")))
        XCTAssertThrowsError(try UpdateCheck.decode(Data(#"{"message":"Not Found"}"#.utf8)))
    }
}
