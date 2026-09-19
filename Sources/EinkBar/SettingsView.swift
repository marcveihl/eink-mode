import SwiftUI
import EinkCore
import EinkMac

enum SettingsTab: String { case appearance, schedule, general }
final class SettingsNavigation: ObservableObject { @Published var tab: SettingsTab = .general }

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var navigation: SettingsNavigation
    let actions: SettingsActions
    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $navigation.tab) {
                Text("Appearance").tag(SettingsTab.appearance)
                Text("Schedule").tag(SettingsTab.schedule)
                Text("General").tag(SettingsTab.general)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 320).padding(.top, 16)
            Group {
                switch navigation.tab {
                case .appearance: AppearanceSettings(model: model)
                case .schedule: ScheduleSettings(model: model)
                case .general: GeneralSettings(model: model, actions: actions)
                }
            }
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct SettingsActions {
    var checkForUpdates: () -> Void
    var installUpdate: () -> Void
    var showWelcome: () -> Void
    var setShortcut: (String) -> Void
}

/// A caption under a control.
private struct Hint: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
}

struct AppearanceSettings: View {
    @ObservedObject var model: AppModel
    @State private var brightness = 50.0
    @State private var editing = false
    var body: some View {
        Form {
            if let status = model.status {
                Section {
                    Toggle("Grayscale", isOn: binding(\.grayscale)).disabled(status.system.values["grayscale"] == nil)
                    Hint("The core of E-Ink Mode. Use “Color for 5 minutes” in the menu for a quick look at color.")
                }
                Section("Optional — off unless you turn them on") {
                    Toggle("Dim the screen", isOn: Binding(get: { status.configuration.brightness != nil },
                                                          set: { on in model.change { $0.brightness = on ? brightness / 100 : nil } }))
                        .disabled(!model.hasBrightness)
                    if status.configuration.brightness != nil {
                        HStack {
                            Slider(value: $brightness, in: 5...100, step: 1) { editing in
                                self.editing = editing
                                if !editing { model.change { $0.brightness = brightness / 100 } }
                            }.accessibilityLabel("Brightness while on")
                            Text("\(Int(brightness))%").monospacedDigit().frame(width: 42, alignment: .trailing)
                        }.disabled(!model.hasBrightness)
                    }
                    Hint(model.hasBrightness ? "Your current brightness is saved and put back when E-Ink Mode turns off."
                                             : "This display doesn't allow brightness control. Use the monitor's own buttons.")
                    Toggle("Auto-hide the Dock", isOn: binding(\.hideDock))
                    Toggle("Reduce motion", isOn: binding(\.reduceMotion)).disabled(status.system.values["motion"] == nil)
                    Toggle("Reduce transparency", isOn: binding(\.reduceTransparency)).disabled(status.system.values["transparency"] == nil)
                    Hint("Changes apply right away while E-Ink Mode is on. Everything returns to how it was when you turn it off.")
                }
                if !status.system.warnings.isEmpty {
                    Section {
                        DisclosureGroup("What this Mac supports") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(status.system.warnings, id: \.self) { Hint($0) }
                            }
                        }
                    }
                }
            } else { ProgressView() }
        }
        .formStyle(.grouped)
        .disabled(model.needsRecovery)
        .onAppear(perform: sync)
        .onChange(of: model.status?.configuration.brightness) { _ in sync() }
    }
    private func sync() { if !editing { brightness = (model.status?.configuration.brightness ?? 0.5) * 100 } }
    private func binding(_ key: WritableKeyPath<Configuration, Bool>) -> Binding<Bool> {
        Binding(get: { model.status?.configuration[keyPath: key] ?? false }, set: { value in model.change { $0[keyPath: key] = value } })
    }
}

enum ScheduleChoice: Hashable { case off, evening, custom }

struct ScheduleSettings: View {
    @ObservedObject var model: AppModel
    @State private var on = Date()
    @State private var off = Date()
    @State private var customSelected = false
    var body: some View {
        Form {
            if let status = model.status, let summary = model.schedule {
                Section {
                    Picker("Automatically", selection: Binding(get: { choice(status) }, set: select)) {
                        Text("Never — I'll switch it myself").tag(ScheduleChoice.off)
                        Text("Evening · 9:00 PM to 7:00 AM").tag(ScheduleChoice.evening)
                        Text("Custom times").tag(ScheduleChoice.custom)
                    }.pickerStyle(.radioGroup)
                    if choice(status) == .custom {
                        DatePicker("Turn on at", selection: $on, displayedComponents: .hourAndMinute)
                        DatePicker("Turn off at", selection: $off, displayedComponents: .hourAndMinute)
                        if dirty(status) {
                            HStack {
                                Button("Use These Times", action: saveTimes).keyboardShortcut(.defaultAction)
                                Button("Revert") { sync() }
                            }
                        }
                    }
                }
                Section("What happens next") {
                    Label(summary.enabled ? summary.short : "Schedule is off", systemImage: summary.enabled ? "clock" : "hand.tap")
                    Hint(summary.detail)
                }
                Section("Good to know") {
                    Hint("Switching by hand always wins: the schedule waits until its next change before taking over again.")
                    Hint("The schedule runs while E-Ink Mode is open. Turn on “Open E-Ink Mode at login” in General so it works every day. It catches up after sleep.")
                }
            } else { ProgressView() }
        }
        .formStyle(.grouped)
        .disabled(model.needsRecovery)
        .onAppear(perform: sync)
        .onChange(of: model.status?.configuration.schedule) { _ in sync() }
    }
    private func choice(_ status: Status) -> ScheduleChoice {
        let schedule = status.configuration.schedule
        if customSelected { return .custom }
        if !schedule.enabled { return .off }
        return schedule.isEvening ? .evening : .custom
    }
    private func select(_ choice: ScheduleChoice) {
        customSelected = choice == .custom
        switch choice {
        case .off: model.change { $0.schedule.enabled = false }
        case .evening: model.change { $0.schedule = .evening; $0.schedule.enabled = true }
        case .custom: sync()
        }
    }
    private static func minutes(_ date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date); return parts.hour! * 60 + parts.minute!
    }
    private static func date(_ minutes: Int) -> Date {
        Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date())!
    }
    private func dirty(_ status: Status) -> Bool {
        let schedule = status.configuration.schedule
        return !schedule.enabled || Self.minutes(on) != schedule.on || Self.minutes(off) != schedule.off
    }
    private func sync() {
        guard let schedule = model.status?.configuration.schedule else { return }
        on = Self.date(schedule.on); off = Self.date(schedule.off)
    }
    private func saveTimes() {
        let start = Self.minutes(on), end = Self.minutes(off)
        guard start != end else { model.error = "Choose two different times."; return }
        model.change { $0.schedule.on = start; $0.schedule.off = end; $0.schedule.enabled = true }
    }
}

struct GeneralSettings: View {
    @ObservedObject var model: AppModel
    let actions: SettingsActions
    @AppStorage("shortcut") private var shortcut = Shortcut.presets[0].id
    var body: some View {
        Form {
            Section("Menu bar icon") {
                Toggle("Click the icon to switch E-Ink Mode on and off", isOn: $model.clickToFlip)
                Hint(model.clickToFlip ? "Click ◐ to switch. Right-click, Control-click, or press and hold to open the menu."
                                       : "Click ◐ to open the menu.")
            }
            Section("Keyboard shortcut") {
                Picker("Switch on and off", selection: Binding(get: { shortcut }, set: { shortcut = $0; actions.setShortcut($0) })) {
                    ForEach(Shortcut.presets) { Text($0.symbol).tag($0.id) }
                    Text("None").tag(Shortcut.none)
                }
                Hint(model.hotkeyMessage)
            }
            Section("Startup") {
                Toggle("Open E-Ink Mode at login", isOn: Binding(get: { model.loginEnabled }, set: model.setLogin))
                Hint("Needed for schedules. Opening the app never turns E-Ink Mode on by itself.")
            }
            Section("Updates") {
                LabeledContent("Version", value: EinkEnvironment.version)
                Toggle("Check for updates automatically", isOn: $model.autoCheckUpdates)
                HStack {
                    switch model.update {
                    case .available(let release):
                        Text("\(release.tagName) is available").foregroundStyle(.blue)
                        Spacer(); Button("Install and Relaunch", action: actions.installUpdate)
                    case .checking: Text("Checking…").foregroundStyle(.secondary); Spacer()
                    case .installing: Text("Downloading update…").foregroundStyle(.secondary); Spacer()
                    case .upToDate: Text("You're up to date.").foregroundStyle(.secondary); Spacer()
                        Button("Check Now", action: actions.checkForUpdates)
                    case .failed(let message): Text(message).font(.caption).foregroundStyle(.red); Spacer()
                        Button("Try Again", action: actions.checkForUpdates)
                    case .idle: Spacer(); Button("Check Now", action: actions.checkForUpdates)
                    }
                }
            }
            Section("Help") {
                HStack {
                    Button("Show Welcome Guide", action: actions.showWelcome)
                    Button("Restore Display Now") { model.restoreDisplay() }.disabled(!model.active && !model.needsRecovery)
                }
                Hint("Quitting always restores your display. From Terminal: “\(Bundle.main.bundlePath)/Contents/MacOS/eink off”.")
            }
        }
        .formStyle(.grouped)
    }
}
