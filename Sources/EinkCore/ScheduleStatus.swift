import Foundation

extension Schedule {
    /// 9:00 PM – 7:00 AM every day.
    public static var evening: Schedule { var s = Schedule(); s.on = 21 * 60; s.off = 7 * 60; return s }
    public var isEvening: Bool { on == Schedule.evening.on && off == Schedule.evening.off }

    /// The next scheduled change strictly after `date`, and whether it turns the mode on.
    public func nextChange(after date: Date, calendar: Calendar) -> (date: Date, turnsOn: Bool) {
        func next(_ minutes: Int) -> Date {
            let today = calendar.startOfDay(for: date)
            for offset in 0...2 {
                let day = calendar.date(byAdding: .day, value: offset, to: today)!
                let candidate = calendar.nextDate(after: day.addingTimeInterval(-1),
                    matching: DateComponents(hour: minutes / 60, minute: minutes % 60, second: 0),
                    matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)!
                if candidate > date { return candidate }
            }
            preconditionFailure("Calendar could not resolve a daily schedule boundary")
        }
        let start = next(on), end = next(off)
        return start < end ? (start, true) : (end, false)
    }
}

/// Human-readable schedule state for menus and settings.
public struct ScheduleStatus: Equatable {
    public var enabled: Bool
    /// The mode was changed by hand; the schedule leaves it alone until `nextChange`.
    public var manualOverride: Bool
    public var nextChange: Date?
    public var turnsOn: Bool
    /// Short form for the menu, e.g. "Until 7:00 AM" or "Turns on tonight at 9:00 PM".
    public var short: String
    /// A sentence explaining what will happen next and why.
    public var detail: String

    public init(configuration: Configuration, state: RuntimeState, now: Date = Date(),
                calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) {
        let schedule = configuration.schedule
        enabled = schedule.enabled
        let active = state.session != nil
        guard schedule.enabled else {
            manualOverride = false; nextChange = nil; turnsOn = false
            short = "Off"; detail = "E-Ink Mode changes only when you switch it."
            return
        }
        let next = schedule.nextChange(after: now, calendar: calendar)
        nextChange = next.date; turnsOn = next.turnsOn
        let current = schedule.boundary(at: now, calendar: calendar)
        manualOverride = state.manualUntilBoundary != nil && state.manualUntilBoundary == current.date && active != current.active
        let when = ScheduleStatus.describe(next.date, now: now, calendar: calendar, locale: locale)
        let time = ScheduleStatus.time(next.date, calendar: calendar, locale: locale)
        if manualOverride {
            short = "\(active ? "On" : "Off") by hand · resumes \(time)"
            detail = "You switched E-Ink Mode by hand, so the schedule won't change it until \(when). After that it follows the schedule again."
        } else if next.turnsOn {
            short = "Turns on \(when)"
            detail = active
                ? "On now. The schedule turns it on again \(when); switching by hand pauses the schedule until then."
                : "The schedule turns E-Ink Mode on \(when). Switching by hand pauses the schedule until its next change."
        } else {
            short = active ? "Until \(time)" : "Turns off \(when)"
            detail = active
                ? "On until \(when). Turning it off by hand pauses the schedule until then."
                : "The schedule turns E-Ink Mode off \(when). Switching by hand pauses the schedule until its next change."
        }
    }

    static func time(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale; formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .none; formatter.timeStyle = .short
        // Modern ICU puts a narrow no-break space before AM/PM; keep plain spacing for menus.
        return formatter.string(from: date).replacingOccurrences(of: "\u{202F}", with: " ")
    }
    /// "tonight at 9:00 PM", "this morning at 7:00 AM", "today at 3:00 PM", "tomorrow at 7:00 AM", or "Saturday at 7:00 AM".
    static func describe(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let time = time(date, calendar: calendar, locale: locale)
        if calendar.isDate(date, inSameDayAs: now) {
            let hour = calendar.component(.hour, from: date)
            return hour >= 17 ? "tonight at \(time)" : hour < 12 ? "this morning at \(time)" : "today at \(time)"
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "tomorrow at \(time)"
        }
        let weekday = DateFormatter(); weekday.locale = locale; weekday.calendar = calendar; weekday.timeZone = calendar.timeZone
        weekday.dateFormat = "EEEE"
        return "\(weekday.string(from: date)) at \(time)"
    }
}

/// Formats a countdown like "4:32".
public func countdown(_ interval: TimeInterval) -> String {
    let seconds = max(0, Int(interval.rounded(.up)))
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
}
