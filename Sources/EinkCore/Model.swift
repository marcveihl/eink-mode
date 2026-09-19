import Foundation

public enum EinkError: Error, LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

public struct Schedule: Codable, Equatable {
    public var enabled = false
    public var on = 21 * 60
    public var off = 7 * 60
    public init() {}
    public func validate() throws {
        guard (0..<1440).contains(on), (0..<1440).contains(off), on != off else {
            throw EinkError.message("Schedule needs two different times between 00:00 and 23:59.")
        }
    }
    public static func parse(_ text: String) throws -> Int {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0..<24).contains(hour), (0..<60).contains(minute) else {
            throw EinkError.message("Use a 24-hour time such as 21:00.")
        }
        return hour * 60 + minute
    }
    public static func format(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }
    // Calendar matching preserves wall-clock schedules across DST; skipped times use the next valid time.
    public func boundary(at date: Date, calendar: Calendar) -> (date: Date, active: Bool) {
        func last(_ minutes: Int) -> Date {
            let today = calendar.startOfDay(for: date)
            // Resolve each civil day's occurrence forward, so a repeated DST hour
            // has exactly one boundary (the first occurrence), even after fallback.
            for offset in 0...2 {
                let day = calendar.date(byAdding: .day, value: -offset, to: today)!
                let candidate = calendar.nextDate(after: day.addingTimeInterval(-1),
                    matching: DateComponents(hour: minutes / 60, minute: minutes % 60, second: 0),
                    matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)!
                if candidate <= date { return candidate }
            }
            preconditionFailure("Calendar could not resolve a daily schedule boundary")
        }
        let start = last(on), end = last(off)
        return start > end ? (start, true) : (end, false)
    }
}

public struct Configuration: Codable, Equatable {
    public var grayscale = true
    public var brightness: Double? = 0.35
    public var hideDock = true
    public var reduceMotion = false
    public var reduceTransparency = false
    public var schedule = Schedule()
    public init() {}
    public func validate() throws {
        if let brightness, !brightness.isFinite || !(0.05...1).contains(brightness) {
            throw EinkError.message("Brightness must be 5–100%, or unchanged.")
        }
        try schedule.validate()
    }
}

public enum SettingValue: Codable, Equatable {
    case flag(Bool)
    case level(Double)
}

public struct SystemSnapshot: Codable, Equatable {
    public var values: [String: SettingValue]
    public var warnings: [String]
    public init(values: [String: SettingValue], warnings: [String] = []) { self.values = values; self.warnings = warnings }
}

public protocol SystemAdapter {
    func snapshot() throws -> SystemSnapshot
    func set(_ key: String, to value: SettingValue) throws
}

public struct Session: Codable {
    public var started: Date
    public var original: [String: SettingValue]
    public var managed: [String]
    public var phase: String
}

public struct RuntimeState: Codable {
    public var session: Session?
    public var manualUntilBoundary: Date?
    public var lastBoundary: Date?
    public init() {}
}

public struct Status: Codable {
    public var configuration: Configuration
    public var state: RuntimeState
    public var system: SystemSnapshot
    public var active: Bool { state.session != nil }
}
