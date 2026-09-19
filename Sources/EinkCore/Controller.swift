import Foundation

public final class Controller {
    private let store: Store
    private let adapter: SystemAdapter
    private let calendar: Calendar
    public init(store: Store, adapter: SystemAdapter, calendar: Calendar = .autoupdatingCurrent) {
        self.store = store; self.adapter = adapter; self.calendar = calendar
    }
    private func configuration() throws -> Configuration {
        let c = try store.read("config.json", default: Configuration()); try c.validate(); return c
    }
    private func state() throws -> RuntimeState { try store.read("state.json", default: RuntimeState()) }
    private func save(_ state: RuntimeState) throws { try store.write(state, name: "state.json") }
    private func history() throws -> FocusHistory { try store.read("focus-history.json", default: FocusHistory()) }
    private func save(_ history: FocusHistory) throws { try store.write(history, name: "focus-history.json") }
    public func status() throws -> Status {
        try store.locked { Status(configuration: try configuration(), state: try state(), system: try adapter.snapshot()) }
    }
    /// `profile` activates with a one-off configuration (e.g. first-run preview) without saving it.
    public func setMode(_ active: Bool, manual: Bool = true, profile: Configuration? = nil, now: Date = Date()) throws {
        try store.locked {
            var state = try state()
            // An intact restoration journal remains usable even if config is damaged.
            if !active {
                if manual {
                    let config = try? configuration()
                    state.manualUntilBoundary = config?.schedule.enabled == true ? config?.schedule.boundary(at: now, calendar: calendar).date : nil
                    try save(state)
                }
                try restore(state: &state, now: now)
                return
            }
            let saved = try configuration()
            if let profile { try profile.validate() }
            if manual {
                state.manualUntilBoundary = saved.schedule.enabled ? saved.schedule.boundary(at: now, calendar: calendar).date : nil
                try save(state)
            }
            try transition(active, config: profile ?? saved, state: &state, now: now)
        }
    }
    /// Restores the display for app exit. A deliberate quit pauses the schedule until its next change;
    /// a logout/restart (`resumeScheduleOnLaunch`) lets the next launch catch up to the current period.
    public func shutdown(resumeScheduleOnLaunch: Bool, now: Date = Date()) throws {
        if !resumeScheduleOnLaunch { return try setMode(false, now: now) }
        try store.locked {
            var state = try state()
            let wasActive = state.session != nil
            try restore(state: &state, now: now)
            if wasActive { state.lastBoundary = nil; state.manualUntilBoundary = nil; try save(state) }
        }
    }
    public func toggle(now: Date = Date()) throws {
        try store.locked {
            var state = try state()
            if state.session != nil {
                let config = try? configuration()
                state.manualUntilBoundary = config?.schedule.enabled == true ? config?.schedule.boundary(at: now, calendar: calendar).date : nil
                try save(state); try restore(state: &state, now: now)
            } else {
                let config = try configuration()
                state.manualUntilBoundary = config.schedule.enabled ? config.schedule.boundary(at: now, calendar: calendar).date : nil
                try save(state); try transition(true, config: config, state: &state, now: now)
            }
        }
    }
    public func update(_ config: Configuration, now: Date = Date()) throws {
        try store.locked { try updateLocked(config, now: now) }
    }
    public func edit(now: Date = Date(), _ change: (inout Configuration) throws -> Void) throws {
        try store.locked {
            var config = try configuration()
            try change(&config)
            try updateLocked(config, now: now)
        }
    }
    private func updateLocked(_ config: Configuration, now: Date) throws {
        try config.validate()
        let previous = try configuration(); var state = try state()
        try store.write(config, name: "config.json")
        if previous.schedule != config.schedule {
            state.lastBoundary = nil; state.manualUntilBoundary = nil; try save(state)
        }
        if state.session != nil { try apply(config, state: &state, now: now) }
        if previous.schedule != config.schedule { try tick(config, state: &state, now: now) }
    }
    public func tick(now: Date = Date()) throws {
        try store.locked { var state = try state(); try tick(configuration(), state: &state, now: now) }
    }
    private func tick(_ config: Configuration, state: inout RuntimeState, now: Date) throws {
        if let until = state.colorUntil, until <= now {
            state.colorUntil = nil; try save(state)
            if state.session != nil { try apply(config, state: &state, now: now) }
        }
        try advanceFocus(config, state: &state, now: now)
        // A focus round owns the display until it ends; the schedule catches up afterwards.
        guard config.schedule.enabled, state.focus == nil else { return }
        let boundary = config.schedule.boundary(at: now, calendar: calendar)
        if let held = state.manualUntilBoundary, held == boundary.date { return }
        guard state.lastBoundary != boundary.date else { return }
        try transition(boundary.active, config: config, state: &state, now: now)
        state.lastBoundary = boundary.date; state.manualUntilBoundary = nil; try save(state)
    }
    public func resume(now: Date = Date()) throws {
        try store.locked {
            var state = try state()
            guard state.session != nil else { return }
            if let until = state.colorUntil, until <= now { state.colorUntil = nil }
            try apply(configuration(), state: &state, now: now)
        }
    }
    /// Lifts grayscale for a while; every other profile setting stays applied and the saved profile is untouched.
    public func startTemporaryColor(for duration: TimeInterval = 5 * 60, now: Date = Date()) throws {
        try store.locked {
            var state = try state(); let config = try configuration()
            guard state.session != nil else { throw EinkError.message("Turn on E-Ink Mode first.") }
            guard config.grayscale else { throw EinkError.message("Grayscale is already off in your profile.") }
            guard state.focus == nil else { throw EinkError.message("Color comes back on its own during focus breaks.") }
            state.colorUntil = now.addingTimeInterval(duration)
            try apply(config, state: &state, now: now)
        }
    }
    public func endTemporaryColor(now: Date = Date()) throws {
        try store.locked {
            var state = try state()
            guard state.colorUntil != nil else { return }
            state.colorUntil = nil; try save(state)
            if state.session != nil { try apply(configuration(), state: &state, now: now) }
        }
    }
    // MARK: Focus (Pomodoro)

    /// Starts a round of `sessions` focus sessions (default from settings), turning E-Ink Mode on if needed.
    public func startFocus(sessions: Int? = nil, now: Date = Date()) throws {
        try store.locked {
            var state = try state(); let config = try configuration()
            guard state.focus == nil else { throw EinkError.message("A focus session is already running.") }
            let rounds = sessions ?? config.focus.sessions
            guard (1...12).contains(rounds) else { throw EinkError.message("Sessions per round must be 1–12.") }
            let owns = state.session == nil
            if owns {
                state.manualUntilBoundary = config.schedule.enabled ? config.schedule.boundary(at: now, calendar: calendar).date : nil
                try save(state)
                try transition(true, config: config, state: &state, now: now)
            }
            let focusSeconds = TimeInterval(config.focus.focusMinutes * 60)
            state.colorUntil = nil
            state.focus = FocusSession(phase: .focus, round: 1, rounds: rounds, phaseStarted: now, phaseEnds: now.addingTimeInterval(focusSeconds),
                                       focusSeconds: focusSeconds, breakSeconds: TimeInterval(config.focus.breakMinutes * 60), ownsMode: owns)
            do { try apply(config, state: &state, now: now) }
            catch { state.focus = nil; try save(state); throw error }
        }
    }
    /// Stops the round early. Minutes already focused still count toward today.
    public func stopFocus(now: Date = Date()) throws {
        try store.locked {
            var state = try state()
            guard let focus = state.focus else { return }
            try endFocusEarly(state: &state, now: now)
            if focus.ownsMode { try restore(state: &state, now: now) } else { try apply(configuration(), state: &state, now: now) }
        }
    }
    /// Ends the current color break and starts the next focus session now.
    public func skipBreak(now: Date = Date()) throws {
        try store.locked {
            var state = try state()
            guard var focus = state.focus, focus.phase == .rest else { throw EinkError.message("There's no break to skip.") }
            focus.round += 1; focus.phase = .focus
            focus.phaseStarted = now; focus.phaseEnds = now.addingTimeInterval(focus.focusSeconds)
            state.focus = focus
            try apply(configuration(), state: &state, now: now)
        }
    }
    public func focusStats(now: Date = Date()) throws -> FocusStats {
        try store.locked { FocusStats(history: try history(), goal: try configuration().focus.dailyGoal, now: now, calendar: calendar) }
    }
    /// Moves a running round through every phase boundary up to `now` (so it catches up after sleep).
    private func advanceFocus(_ config: Configuration, state: inout RuntimeState, now: Date) throws {
        guard var focus = state.focus, now >= focus.phaseEnds else { return }
        guard state.session != nil else { state.focus = nil; return try save(state) } // display was restored elsewhere
        var history = try history(), finished = false
        while !finished && now >= focus.phaseEnds {
            switch focus.phase {
            case .focus:
                let minutes = Int(focus.focusSeconds / 60)
                history.update(focus.phaseEnds, calendar: calendar) { $0.completed += 1; $0.focusMinutes += minutes }
                if focus.round >= focus.rounds {
                    history.update(focus.phaseEnds, calendar: calendar) { $0.rounds += 1 }
                    finished = true
                } else {
                    focus.phase = .rest; focus.phaseStarted = focus.phaseEnds
                    focus.phaseEnds = focus.phaseEnds.addingTimeInterval(focus.breakSeconds)
                }
            case .rest:
                focus.round += 1; focus.phase = .focus; focus.phaseStarted = focus.phaseEnds
                focus.phaseEnds = focus.phaseEnds.addingTimeInterval(focus.focusSeconds)
            }
        }
        try save(history)
        if finished {
            state.focus = nil; try save(state)
            if focus.ownsMode { try restore(state: &state, now: now) } else { try apply(config, state: &state, now: now) }
        } else {
            state.focus = focus
            try apply(config, state: &state, now: now)
        }
    }
    /// Clears a running round, crediting minutes already focused and counting a stopped session.
    private func endFocusEarly(state: inout RuntimeState, now: Date) throws {
        guard let focus = state.focus else { return }
        if focus.phase == .focus {
            let minutes = Int(max(0, now.timeIntervalSince(focus.phaseStarted)) / 60)
            var history = try history()
            history.update(now, calendar: calendar) { $0.stopped += 1; $0.focusMinutes += minutes }
            try save(history)
        }
        state.focus = nil; try save(state)
    }

    private func transition(_ active: Bool, config: Configuration, state: inout RuntimeState, now: Date) throws {
        if active {
            guard state.session == nil else { return }
            let snapshot = try adapter.snapshot()
            guard snapshot.values["grayscale"] != nil else { throw EinkError.message("Native grayscale is unavailable on this Mac.") }
            state.session = Session(started: now, original: snapshot.values, managed: [], phase: "applying")
            try save(state)
            do { try apply(config, state: &state, now: now) }
            catch {
                let originalError = error
                do { try restore(state: &state) }
                catch { throw EinkError.message("Activation failed: \(originalError.localizedDescription). Restoration needs retry: \(error.localizedDescription)") }
                throw originalError
            }
        } else { try restore(state: &state, now: now) }
    }
    private func desired(_ config: Configuration, original: [String: SettingValue]) -> [String: SettingValue] {
        var values: [String: SettingValue] = ["grayscale": .flag(config.grayscale)]
        if config.hideDock { values["dock"] = .flag(true) }
        if config.reduceMotion { values["motion"] = .flag(true) }
        if config.reduceTransparency { values["transparency"] = .flag(true) }
        if let brightness = config.brightness {
            for key in original.keys where key.hasPrefix("brightness:") { values[key] = .level(brightness) }
        }
        return values.filter { original[$0.key] != nil }
    }
    private func apply(_ config: Configuration, state: inout RuntimeState, now: Date) throws {
        guard var session = state.session else { return }
        guard session.phase != "restoring" else { throw EinkError.message("Restore the unfinished session before changing settings.") }
        var effective = config
        if let focus = state.focus { effective.grayscale = focus.phase == .focus } // focus in grayscale, break in color
        else if let until = state.colorUntil, until > now { effective.grayscale = false }
        let targets = desired(effective, original: session.original)
        let keys = Set(targets.keys).union(session.managed).sorted()
        session.phase = "applying"
        session.managed = Array(Set(session.managed).union(targets.keys)).sorted()
        state.session = session; try save(state) // journal every possible mutation before applying
        do {
            for key in keys {
                if let value = targets[key] ?? session.original[key] { try adapter.set(key, to: value) }
            }
            session.phase = "active"; state.session = session; try save(state)
        } catch { throw EinkError.message("Settings could not be fully applied. Restore or retry. \(error.localizedDescription)") }
    }
    private func restore(state: inout RuntimeState, now: Date = Date()) throws {
        try endFocusEarly(state: &state, now: now)
        guard var session = state.session else { return } // never clear somebody else's grayscale
        session.phase = "restoring"; state.session = session; try save(state)
        var failures: [String] = []
        for key in session.managed {
            do { if let original = session.original[key] { try adapter.set(key, to: original) } }
            catch { failures.append("\(key): \(error.localizedDescription)") }
        }
        guard failures.isEmpty else { throw EinkError.message(failures.joined(separator: "\n")) }
        state.session = nil; state.colorUntil = nil; try save(state)
    }
}
