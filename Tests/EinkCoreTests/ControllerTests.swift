import XCTest
@testable import EinkCore

final class FakeSystem: SystemAdapter {
    var values: [String: SettingValue] = ["grayscale": .flag(true), "dock": .flag(false), "motion": .flag(false), "transparency": .flag(true), "brightness:A": .level(0.81234567), "brightness:B": .level(0.62)]
    var failure: String?
    var failOnce: String?
    var writes = 0
    func snapshot() throws -> SystemSnapshot { SystemSnapshot(values: values) }
    func set(_ key: String, to value: SettingValue) throws {
        if failOnce == key { failOnce = nil; throw EinkError.message("one-shot failure") }
        if failure == key { throw EinkError.message("simulated failure") }
        writes += 1; values[key] = value
    }
}
final class ControllerTests: XCTestCase {
    var directory: URL!
    var system: FakeSystem!
    var controller: Controller!
    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        system = FakeSystem(); controller = Controller(store: Store(directory: directory), adapter: system)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: directory) }
    func testRestoresExactPerDisplayAndPreexistingAccessibilityState() throws {
        let original = system.values
        try controller.setMode(true)
        XCTAssertEqual(system.values["brightness:A"], .level(0.35))
        try controller.setMode(true) // no recapture
        try controller.setMode(false)
        XCTAssertEqual(system.values, original)
        XCTAssertFalse(try controller.status().active)
    }
    func testOffWithoutSessionDoesNotClearExistingGrayscale() throws {
        let original = system.values
        try controller.setMode(false)
        XCTAssertEqual(system.values, original)
        XCTAssertEqual(system.writes, 0)
    }
    func testGrayscaleCanChangeWithoutLosingCaptureOrExitingMode() throws {
        let original = system.values
        try controller.setMode(true)
        var config = try controller.status().configuration
        config.grayscale = false
        try controller.update(config)
        XCTAssertTrue(try controller.status().active)
        XCTAssertEqual(system.values["grayscale"], .flag(false))
        XCTAssertEqual(system.values["dock"], .flag(true))
        try controller.setMode(false)
        XCTAssertEqual(system.values, original)
    }
    func testFailedRestoreKeepsJournalAndCanRetryAfterRestart() throws {
        let original = system.values
        try controller.setMode(true)
        system.failure = "grayscale"
        XCTAssertThrowsError(try controller.setMode(false))
        XCTAssertEqual(try controller.status().state.session?.phase, "restoring")
        system.failure = nil
        let restarted = Controller(store: Store(directory: directory), adapter: system)
        try restarted.setMode(false)
        XCTAssertEqual(system.values, original)
        XCTAssertFalse(try restarted.status().active)
    }
    func testDisablingManagedSettingsRestoresTheirOriginalValuesImmediately() throws {
        let original = system.values
        try controller.setMode(true)
        var config = try controller.status().configuration
        config.brightness = nil; config.hideDock = false; config.reduceMotion = true
        try controller.update(config)
        XCTAssertEqual(system.values["brightness:A"], original["brightness:A"])
        XCTAssertEqual(system.values["dock"], .flag(false))
        XCTAssertEqual(system.values["motion"], .flag(true))
        try controller.setMode(false)
        XCTAssertEqual(system.values, original)
    }
    func testInvalidConfigDoesNotChangePersistedConfigOrSystem() throws {
        let original = system.values
        var config = Configuration(); config.brightness = .nan
        XCTAssertThrowsError(try controller.update(config))
        XCTAssertEqual(try controller.status().configuration, Configuration())
        XCTAssertEqual(system.values, original)
    }
    func testCorruptStateRefusesMutation() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: directory.appendingPathComponent("state.json"))
        XCTAssertThrowsError(try controller.setMode(true))
        XCTAssertEqual(system.writes, 0)
    }
    func testActivationFailureRollsBackAlreadyAppliedSettings() throws {
        let original = system.values
        system.failOnce = "grayscale"
        XCTAssertThrowsError(try controller.setMode(true))
        XCTAssertEqual(system.values, original)
        XCTAssertFalse(try controller.status().active)
    }
    func testActivationAndRollbackFailureRetainRecoveryJournal() throws {
        system.failure = "grayscale"
        XCTAssertThrowsError(try controller.setMode(true))
        XCTAssertEqual(try controller.status().state.session?.phase, "restoring")
        system.failure = nil
        try controller.setMode(false)
        XCTAssertFalse(try controller.status().active)
    }
    func testResumePreservesOriginalCaptureAfterRestart() throws {
        let original = system.values
        try controller.setMode(true)
        let started = try controller.status().state.session?.started
        let restarted = Controller(store: Store(directory: directory), adapter: system)
        system.values["grayscale"] = .flag(false)
        try restarted.resume()
        XCTAssertEqual(system.values["grayscale"], .flag(true))
        XCTAssertEqual(try restarted.status().state.session?.started, started)
        try restarted.setMode(false)
        XCTAssertEqual(system.values, original)
    }
    func testNewDisplayIsNeverChangedWithoutAnOriginalCapture() throws {
        try controller.setMode(true)
        system.values["brightness:C"] = .level(0.91)
        var config = try controller.status().configuration; config.brightness = 0.5
        try controller.update(config)
        XCTAssertEqual(system.values["brightness:C"], .level(0.91))
        try controller.setMode(false)
        XCTAssertEqual(system.values["brightness:C"], .level(0.91))
    }
    func testMissingOptionalControlsDoNotPreventGrayscale() throws {
        system.values = ["grayscale": .flag(false)]
        try controller.setMode(true)
        XCTAssertEqual(system.values, ["grayscale": .flag(true)])
        try controller.setMode(false)
        XCTAssertEqual(system.values, ["grayscale": .flag(false)])
    }
    func testMissingGrayscaleRefusesActivationWithoutOtherChanges() throws {
        system.values.removeValue(forKey: "grayscale")
        let original = system.values
        XCTAssertThrowsError(try controller.setMode(true))
        XCTAssertEqual(system.values, original)
        XCTAssertEqual(system.writes, 0)
    }

}
