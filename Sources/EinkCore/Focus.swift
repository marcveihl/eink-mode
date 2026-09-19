import Foundation

/// Pomodoro preferences: focus in grayscale, take a color break, repeat.
public struct FocusSettings: Codable, Equatable {
    public var focusMinutes = 25
    public var breakMinutes = 5
    /// Focus sessions per round ("x number of sessions").
    public var sessions = 4
    /// Completed focus sessions that make a good day.
    public var dailyGoal = 8
    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FocusSettings()
        focusMinutes = try c.decodeIfPresent(Int.self, forKey: .focusMinutes) ?? d.focusMinutes
        breakMinutes = try c.decodeIfPresent(Int.self, forKey: .breakMinutes) ?? d.breakMinutes
        sessions = try c.decodeIfPresent(Int.self, forKey: .sessions) ?? d.sessions
        dailyGoal = try c.decodeIfPresent(Int.self, forKey: .dailyGoal) ?? d.dailyGoal
    }
    public func validate() throws {
        guard (1...180).contains(focusMinutes) else { throw EinkError.message("Focus length must be 1–180 minutes.") }
        guard (1...60).contains(breakMinutes) else { throw EinkError.message("Break length must be 1–60 minutes.") }
        guard (1...12).contains(sessions) else { throw EinkError.message("Sessions per round must be 1–12.") }
        guard (1...24).contains(dailyGoal) else { throw EinkError.message("Daily goal must be 1–24 sessions.") }
    }
}

/// A running round of focus sessions. Lengths are captured at start so editing settings never disrupts it.
public struct FocusSession: Codable, Equatable {
    public enum Phase: String, Codable { case focus, rest }
    public var phase: Phase
    /// 1-based index of the current focus session.
    public var round: Int
    public var rounds: Int
    public var phaseStarted: Date
    public var phaseEnds: Date
    public var focusSeconds: TimeInterval
    public var breakSeconds: TimeInterval
    /// E-Ink Mode was off when the round started, so finishing or stopping turns it off again.
    public var ownsMode: Bool
    public func remaining(now: Date) -> TimeInterval { max(0, phaseEnds.timeIntervalSince(now)) }
}

public struct DayRecord: Codable, Equatable {
    /// Focus sessions that ran their full length.
    public var completed = 0
    /// Minutes spent focusing, including stopped sessions.
    public var focusMinutes = 0
    /// Focus sessions stopped early.
    public var stopped = 0
    /// Full rounds finished (every session in a round).
    public var rounds = 0
    public init() {}
}

/// Per-day focus totals, keyed by local date ("2026-09-19").
public struct FocusHistory: Codable, Equatable {
    public var days: [String: DayRecord] = [:]
    public init() {}
    public static func key(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
    mutating func update(_ date: Date, calendar: Calendar, _ change: (inout DayRecord) -> Void) {
        var record = days[Self.key(date, calendar: calendar)] ?? DayRecord()
        change(&record)
        days[Self.key(date, calendar: calendar)] = record
        // Keep about two years; older days no longer affect streaks or the week view.
        if days.count > 800, let oldest = days.keys.min() { days.removeValue(forKey: oldest) }
    }
}

/// Motivational summary of focus history for today, the week, and all time.
public struct FocusStats: Equatable {
    public struct Day: Equatable { public var date: Date; public var label: String; public var completed: Int; public var minutes: Int }
    public var today: DayRecord
    public var goal: Int
    public var remainingToGoal: Int { max(0, goal - today.completed) }
    /// Consecutive days with at least one completed session, counting today or (if nothing yet today) yesterday.
    public var streak: Int
    public var bestStreak: Int
    /// The last seven days, oldest first, ending today.
    public var week: [Day]
    public var weekCompleted: Int { week.reduce(0) { $0 + $1.completed } }
    public var weekMinutes: Int { week.reduce(0) { $0 + $1.minutes } }
    public var totalCompleted: Int
    public var totalMinutes: Int
    public var totalRounds: Int
    public var bestDay: Int
    public var daysGoalMet: Int
    /// One encouraging line chosen from where you are right now.
    public var message: String

    public init(history: FocusHistory, goal: Int, now: Date = Date(), calendar: Calendar = .autoupdatingCurrent,
                locale: Locale = .autoupdatingCurrent) {
        func record(_ date: Date) -> DayRecord { history.days[FocusHistory.key(date, calendar: calendar)] ?? DayRecord() }
        let todayStart = calendar.startOfDay(for: now)
        today = record(now); self.goal = goal

        var streak = 0
        var day = today.completed > 0 ? todayStart : calendar.date(byAdding: .day, value: -1, to: todayStart)!
        while record(day).completed > 0 { streak += 1; day = calendar.date(byAdding: .day, value: -1, to: day)! }
        self.streak = streak

        var best = 0, run = 0, previous: Date?
        for key in history.days.keys.sorted() where history.days[key]!.completed > 0 {
            guard let date = Self.date(key, calendar: calendar) else { continue }
            if let previous, calendar.date(byAdding: .day, value: 1, to: previous) == date { run += 1 } else { run = 1 }
            best = max(best, run); previous = date
        }
        bestStreak = max(best, streak)

        let weekday = DateFormatter(); weekday.locale = locale; weekday.calendar = calendar; weekday.timeZone = calendar.timeZone
        weekday.dateFormat = "EEE"
        week = (0..<7).reversed().map { offset in
            let date = calendar.date(byAdding: .day, value: -offset, to: todayStart)!
            let r = record(date)
            return Day(date: date, label: offset == 0 ? "Today" : weekday.string(from: date), completed: r.completed, minutes: r.focusMinutes)
        }
        let all = Array(history.days.values)
        totalCompleted = all.reduce(0) { $0 + $1.completed }
        totalMinutes = all.reduce(0) { $0 + $1.focusMinutes }
        totalRounds = all.reduce(0) { $0 + $1.rounds }
        daysGoalMet = all.filter { $0.completed >= goal }.count
        let earlierBest = history.days.filter { $0.key != FocusHistory.key(now, calendar: calendar) }.map(\.value.completed).max() ?? 0
        bestDay = max(earlierBest, today.completed)

        let remaining = max(0, goal - today.completed)
        if today.completed > 0 && today.completed > earlierBest && earlierBest > 0 {
            message = "New personal best: \(today.completed) sessions in one day!"
        } else if today.completed >= goal {
            message = "Daily goal reached — \(today.completed) sessions. Great work!"
        } else if today.completed > 0 && remaining == 1 {
            message = "One more session to reach today's goal."
        } else if today.completed > 0 {
            message = "\(remaining) more sessions to reach today's goal of \(goal)."
        } else if streak > 0 {
            message = "Keep your \(streak)-day streak alive — one session does it."
        } else if totalCompleted > 0 {
            message = "A fresh start. One focus session begins a new streak."
        } else {
            message = "Start your first focus session to begin a streak."
        }
    }

    static func date(_ key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}
