import Foundation
import AppKit
import CoreGraphics
import EinkCore

public final class MacSystem: SystemAdapter {
    private typealias GetFlag = @convention(c) () -> Bool
    private typealias SetFlag = @convention(c) (Bool) -> Void
    private typealias GetBrightness = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (UInt32, Float) -> Int32
    private let ua: UnsafeMutableRawPointer?
    private let displays: UnsafeMutableRawPointer?
    private let flags = ["grayscale": "UAGrayscale", "transparency": "UAReduceTransparency", "motion": "UAReduceMotion"]
    public init() {
        ua = dlopen("/System/Library/PrivateFrameworks/UniversalAccess.framework/UniversalAccess", RTLD_NOW)
        displays = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
    }
    private func symbol(_ handle: UnsafeMutableRawPointer?, _ name: String) -> UnsafeMutableRawPointer? {
        guard let handle else { return nil }; return dlsym(handle, name)
    }
    private func activeDisplays() throws -> [String: CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { throw EinkError.message("Cannot enumerate displays.") }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { throw EinkError.message("Cannot enumerate displays.") }
        var result: [String: CGDirectDisplayID] = [:]
        for id in ids.prefix(Int(count)) {
            if let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() {
                result["brightness:\(CFUUIDCreateString(nil, uuid)! as String)"] = id
            }
        }
        return result
    }
    public func snapshot() throws -> SystemSnapshot {
        var values: [String: SettingValue] = [:]
        var warnings = ["Paper warmth is managed by f.lux or Night Shift.", "Notification suppression is unavailable: macOS does not expose restorable Focus state."]
        for (key, prefix) in flags {
            if let getter = symbol(ua, prefix + "IsEnabled"), symbol(ua, prefix + "SetEnabled") != nil {
                values[key] = .flag(unsafeBitCast(getter, to: GetFlag.self)())
            } else { warnings.append("\(key.capitalized) control is unavailable on this macOS version.") }
        }
        let domain = "com.apple.dock" as CFString
        let dock = CFPreferencesCopyAppValue("autohide" as CFString, domain) as? NSNumber
        values["dock"] = .flag(dock?.boolValue ?? false)
        if let pointer = symbol(displays, "DisplayServicesGetBrightness"), symbol(displays, "DisplayServicesSetBrightness") != nil {
            let getter = unsafeBitCast(pointer, to: GetBrightness.self)
            for (key, id) in try activeDisplays() {
                var brightness: Float = 0
                if getter(id, &brightness) == 0, brightness.isFinite, (0...1).contains(brightness) {
                    values[key] = .level(Double(brightness))
                }
            }
        }
        if !values.keys.contains(where: { $0.hasPrefix("brightness:") }) {
            warnings.append("No display exposes native brightness control. External monitors may require their own controls.")
        }
        return SystemSnapshot(values: values, warnings: warnings)
    }
    public func set(_ key: String, to value: SettingValue) throws {
        if let prefix = flags[key], case .flag(let on) = value {
            guard let setter = symbol(ua, prefix + "SetEnabled"), let getter = symbol(ua, prefix + "IsEnabled") else {
                throw EinkError.message("\(key) control is unavailable.")
            }
            let read = unsafeBitCast(getter, to: GetFlag.self)
            if read() == on { return }
            unsafeBitCast(setter, to: SetFlag.self)(on)
            guard read() == on else { throw EinkError.message("macOS did not accept the \(key) change.") }
            return
        }
        if key == "dock", case .flag(let on) = value {
            let domain = "com.apple.dock" as CFString
            let current = CFPreferencesCopyAppValue("autohide" as CFString, domain) as? NSNumber
            if (current?.boolValue ?? false) == on { return }
            CFPreferencesSetAppValue("autohide" as CFString, on as CFBoolean, domain)
            guard CFPreferencesAppSynchronize(domain) else { throw EinkError.message("Cannot save Dock autohide.") }
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/killall"); process.arguments = ["Dock"]
            process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            guard process.terminationStatus == 0 || process.terminationStatus == 1 else { throw EinkError.message("Cannot refresh the Dock.") }
            return
        }
        if key.hasPrefix("brightness:"), case .level(let brightness) = value {
            guard let id = try activeDisplays()[key] else { throw EinkError.message("Reconnect display \(key.dropFirst(11)) to restore its brightness.") }
            guard let pointer = symbol(displays, "DisplayServicesSetBrightness") else { throw EinkError.message("Brightness control is unavailable.") }
            guard unsafeBitCast(pointer, to: SetBrightness.self)(id, Float(brightness)) == 0 else { throw EinkError.message("Display rejected the brightness change.") }
            return
        }
        throw EinkError.message("Unsupported setting \(key).")
    }
}
