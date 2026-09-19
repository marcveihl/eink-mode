import Foundation
import EinkCore

public enum EinkEnvironment {
    public static var directory: URL {
        if let path = ProcessInfo.processInfo.environment["EINK_HOME"] { return URL(fileURLWithPath: path) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/E-Ink Mode")
    }
    public static var legacyState: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["EINK_STATE"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state/eink/saved-state").path)
    }
    public static func checkLegacy() throws {
        guard ProcessInfo.processInfo.environment["EINK_SIMULATED"] != "1" else { return }
        if FileManager.default.fileExists(atPath: legacyState.path) {
            throw EinkError.message("Prototype 0 has an active saved session. Quit its menu bar app or run prototype0/eink off before using the new mode. Its original state has been preserved.")
        }
    }
    public static func makeController() throws -> Controller {
        let store = Store(directory: directory)
        try store.locked {
            if !FileManager.default.fileExists(atPath: directory.appendingPathComponent("config.json").path) {
                var config = Configuration()
                let old = URL(fileURLWithPath: ProcessInfo.processInfo.environment["EINK_CONFIG"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/eink/config").path)
                if ProcessInfo.processInfo.environment["EINK_HOME"] == nil, let contents = try? String(contentsOf: old) {
                    for line in contents.components(separatedBy: .newlines) {
                        let parts = line.components(separatedBy: "#")[0].split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                        guard parts.count == 2 else { continue }
                        let key = parts[0].trimmingCharacters(in: .whitespaces)
                        let value = parts[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                        if key == "EINK_BRIGHTNESS" { config.brightness = value.isEmpty ? nil : Double(value) }
                        if key == "EINK_HIDE_DOCK" { config.hideDock = ["yes", "true", "1", "on"].contains(value) }
                    }
                }
                try config.validate(); try store.write(config, name: "config.json")
            }
        }
        let adapter: SystemAdapter = ProcessInfo.processInfo.environment["EINK_SIMULATED"] == "1" ? SimulatedSystem(directory: directory) : MacSystem()
        return Controller(store: store, adapter: adapter)
    }
}

// An explicit isolated QA backend; it never writes real display settings.
private final class SimulatedSystem: SystemAdapter {
    let store: Store
    init(directory: URL) { store = Store(directory: directory) }
    func snapshot() throws -> SystemSnapshot {
        try store.read("simulated-system.json", default: SystemSnapshot(values: ["grayscale": .flag(false), "dock": .flag(false), "motion": .flag(false), "transparency": .flag(false), "brightness:simulated": .level(0.8)], warnings: ["SIMULATED — display settings are not changed."]))
    }
    func set(_ key: String, to value: SettingValue) throws {
        var snapshot = try snapshot(); snapshot.values[key] = value
        try store.write(snapshot, name: "simulated-system.json")
    }
}
