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
    public func status() throws -> Status {
        try store.locked { Status(configuration: try configuration(), state: try state(), system: try adapter.snapshot()) }
    }
    public func setMode(_ active: Bool, manual: Bool = true, now: Date = Date()) throws {
        try store.locked {
            var state = try state()
            // An intact restoration journal remains usable even if config is damaged.
            if !active {
                if manual {
                    let config = try? configuration()
                    state.manualUntilBoundary = config?.schedule.enabled == true ? config?.schedule.boundary(at: now, calendar: calendar).date : nil
                    try save(state)
                }
                try restore(state: &state)
                return
            }
            let config = try configuration()
            if manual {
                state.manualUntilBoundary = config.schedule.enabled ? config.schedule.boundary(at: now, calendar: calendar).date : nil
                try save(state)
            }
            try transition(active, config: config, state: &state, now: now)
        }
    }
    public func toggle(now: Date = Date()) throws {
        try store.locked {
            var state = try state()
            if state.session != nil {
                let config = try? configuration()
                state.manualUntilBoundary = config?.schedule.enabled == true ? config?.schedule.boundary(at: now, calendar: calendar).date : nil
                try save(state); try restore(state: &state)
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
        if state.session != nil { try apply(config, state: &state) }
        if previous.schedule != config.schedule { try tick(config, state: &state, now: now) }
    }
    public func tick(now: Date = Date()) throws {
        try store.locked { var state = try state(); try tick(configuration(), state: &state, now: now) }
    }
    private func tick(_ config: Configuration, state: inout RuntimeState, now: Date) throws {
        guard config.schedule.enabled else { return }
        let boundary = config.schedule.boundary(at: now, calendar: calendar)
        if let held = state.manualUntilBoundary, held == boundary.date { return }
        guard state.lastBoundary != boundary.date else { return }
        try transition(boundary.active, config: config, state: &state, now: now)
        state.lastBoundary = boundary.date; state.manualUntilBoundary = nil; try save(state)
    }
    public func resume() throws {
        try store.locked {
            var state = try state()
            guard state.session != nil else { return }
            try apply(configuration(), state: &state)
        }
    }
    private func transition(_ active: Bool, config: Configuration, state: inout RuntimeState, now: Date) throws {
        if active {
            guard state.session == nil else { return }
            let snapshot = try adapter.snapshot()
            guard snapshot.values["grayscale"] != nil else { throw EinkError.message("Native grayscale is unavailable on this Mac.") }
            state.session = Session(started: now, original: snapshot.values, managed: [], phase: "applying")
            try save(state)
            do { try apply(config, state: &state) }
            catch {
                let originalError = error
                do { try restore(state: &state) }
                catch { throw EinkError.message("Activation failed: \(originalError.localizedDescription). Restoration needs retry: \(error.localizedDescription)") }
                throw originalError
            }
        } else { try restore(state: &state) }
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
    private func apply(_ config: Configuration, state: inout RuntimeState) throws {
        guard var session = state.session else { return }
        guard session.phase != "restoring" else { throw EinkError.message("Restore the unfinished session before changing settings.") }
        let targets = desired(config, original: session.original)
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
    private func restore(state: inout RuntimeState) throws {
        guard var session = state.session else { return } // never clear somebody else's grayscale
        session.phase = "restoring"; state.session = session; try save(state)
        var failures: [String] = []
        for key in session.managed {
            do { if let original = session.original[key] { try adapter.set(key, to: original) } }
            catch { failures.append("\(key): \(error.localizedDescription)") }
        }
        guard failures.isEmpty else { throw EinkError.message(failures.joined(separator: "\n")) }
        state.session = nil; try save(state)
    }
}
