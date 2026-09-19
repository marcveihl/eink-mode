import AppKit
import SwiftUI
import Carbon
import ServiceManagement
import EinkCore
import EinkMac

final class Model: ObservableObject {
    @Published var status: Status?
    @Published var error: String?
    @Published var busy = false
    @Published var needsRecovery = false
    @Published var loginEnabled = false
    @Published var hotkeyMessage = "⌘⇧E toggles E-Ink Mode"
    @Published var notice: String?
    @Published var clickToFlip = UserDefaults.standard.bool(forKey: "clickToFlip") {
        didSet {
            UserDefaults.standard.set(clickToFlip, forKey: "clickToFlip")
            changed?()
        }
    }
    let controller: Controller
    private let work = DispatchQueue(label: "local.eink.operations")
    var changed: (() -> Void)?
    init(controller: Controller) { self.controller = controller }
    func load() {
        perform(checkLegacy: false) {
            let status = try self.controller.status()
            DispatchQueue.main.async { self.needsRecovery = status.active }
        }
        refreshLogin()
    }
    func perform(checkLegacy: Bool = true, _ operation: @escaping () throws -> Void = {}) {
        guard !busy else { return }
        busy = true
        work.async {
            var failure: String?
            do { if checkLegacy { try EinkEnvironment.checkLegacy() }; try operation() }
            catch { failure = error.localizedDescription }
            let result = Result { try self.controller.status() }
            DispatchQueue.main.async {
                self.busy = false
                if let failure { self.error = failure }
                switch result {
                case .success(let status): self.status = status
                case .failure(let error): self.error = error.localizedDescription
                }
                self.changed?()
            }
        }
    }
    func poll() {
        perform {
            if !self.needsRecovery { try self.controller.tick() }
        }
        refreshLogin()
    }
    func toggle() {
        guard !needsRecovery else { return }
        perform {
            try self.controller.toggle()
            let active = try self.controller.status().active
            DispatchQueue.main.async {
                self.notice = active ? "E-Ink Mode enabled" : "Display restored"
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.notice = nil }
            }
        }
    }
    func change(_ update: @escaping (inout Configuration) throws -> Void) {
        perform {
            try self.controller.edit(update)
        }
    }
    func recover(resume: Bool) {
        perform {
            if resume { try self.controller.resume() } else { try self.controller.setMode(false) }
            DispatchQueue.main.async { self.needsRecovery = false; self.error = nil }
        }
    }
    func refreshLogin() { loginEnabled = SMAppService.mainApp.status == .enabled }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            refreshLogin()
            if SMAppService.mainApp.status == .requiresApproval {
                error = "Approve E-Ink Mode in System Settings → General → Login Items."
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch { self.error = error.localizedDescription; refreshLogin() }
    }
}

struct SettingsView: View {
    @ObservedObject var model: Model
    let quit: () -> Void
    @State private var onTime = "21:00"
    @State private var offTime = "07:00"
    @State private var brightness = 35.0
    @State private var editingBrightness = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "circle.lefthalf.filled").font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("E-Ink Mode").font(.headline)
                    Text(model.notice ?? (model.status?.active == true ? "A quieter workspace" : "Ready when you are")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
            }
            if model.needsRecovery {
                Text("An unfinished E-Ink session was found. Restore your original display or resume that session.").font(.callout)
                HStack {
                    Button("Restore display") { model.recover(resume: false) }.buttonStyle(.borderedProminent)
                    Button("Resume") { model.recover(resume: true) }
                }.disabled(model.busy)
            } else {
                Button(action: model.toggle) {
                    HStack { Text(model.status?.active == true ? "Restore normal display" : "Enable E-Ink Mode"); Spacer(); Text("⌘⇧E").opacity(0.7) }
                }.buttonStyle(.borderedProminent).controlSize(.large).disabled(model.busy || model.status == nil)
            }
            if let status = model.status {
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Grayscale", isOn: binding(\.grayscale)).disabled(status.system.values["grayscale"] == nil)
                    if let live = status.system.values["grayscale"], case .flag(let enabled) = live {
                        Text("Display is currently \(enabled ? "grayscale" : "in color")").font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("Adjust brightness", isOn: Binding(get: { status.configuration.brightness != nil }, set: { enabled in model.change { $0.brightness = enabled ? brightness / 100 : nil } }))
                        .disabled(!hasBrightness(status))
                    if status.configuration.brightness != nil {
                        HStack {
                            Slider(value: $brightness, in: 5...100, step: 1, onEditingChanged: { editing in
                                editingBrightness = editing
                                if !editing { model.change { $0.brightness = brightness / 100 } }
                            }).accessibilityLabel("E-Ink brightness")
                            Text("\(Int(brightness))%").monospacedDigit().frame(width: 42)
                        }.disabled(!hasBrightness(status))
                    }
                    Toggle("Hide Dock", isOn: binding(\.hideDock))
                    Toggle("Reduce motion", isOn: binding(\.reduceMotion)).disabled(status.system.values["motion"] == nil)
                    Toggle("Reduce transparency", isOn: binding(\.reduceTransparency)).disabled(status.system.values["transparency"] == nil)
                }.disabled(model.busy || model.needsRecovery)
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Nightly schedule", isOn: Binding(get: { status.configuration.schedule.enabled }, set: { enabled in model.change { $0.schedule.enabled = enabled } }))
                    HStack {
                        Text("On").foregroundStyle(.secondary)
                        TextField("21:00", text: $onTime).frame(width: 57).accessibilityLabel("Schedule on time").onSubmit(saveTimes)
                        Text("Off").foregroundStyle(.secondary)
                        TextField("07:00", text: $offTime).frame(width: 57).accessibilityLabel("Schedule off time").onSubmit(saveTimes)
                        Button("Apply", action: saveTimes)
                    }.textFieldStyle(.roundedBorder)
                    Text(scheduleDescription(status)).font(.caption).foregroundStyle(.secondary)
                }.disabled(model.busy || model.needsRecovery)
                Divider()
                Toggle("Click to flip", isOn: $model.clickToFlip)
                Text("Click the menu bar icon to toggle E-Ink Mode. Long press or right-click for settings.").font(.caption).foregroundStyle(.secondary)
                Toggle("Launch at login", isOn: Binding(get: { model.loginEnabled }, set: model.setLogin))
                Text(model.hotkeyMessage).font(.caption).foregroundStyle(.secondary)
                if !status.system.warnings.isEmpty {
                    DisclosureGroup("System availability") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(status.system.warnings, id: \.self) { Text($0).font(.caption).fixedSize(horizontal: false, vertical: true) }
                            Button("Accessibility display settings") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?Seeing_Display")!)
                            }.font(.caption)
                        }.padding(.top, 5)
                    }.font(.caption)
                }
            }
            if let error = model.error {
                VStack(alignment: .leading, spacing: 5) {
                    Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Dismiss") { model.error = nil }
                        Button("Restore display") { model.recover(resume: false) }
                    }.font(.caption)
                }
            }
            HStack {
                Text("Settings save automatically").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Quit", action: quit).buttonStyle(.plain).font(.caption)
            }
        }
        .padding(20).frame(width: 350)
        .onAppear { sync() }
        .onChange(of: model.status?.configuration) { _ in sync() }
    }
    private func binding(_ key: WritableKeyPath<Configuration, Bool>) -> Binding<Bool> {
        Binding(get: { model.status?.configuration[keyPath: key] ?? false }, set: { value in model.change { $0[keyPath: key] = value } })
    }
    private func sync() {
        guard let config = model.status?.configuration else { return }
        onTime = Schedule.format(config.schedule.on); offTime = Schedule.format(config.schedule.off)
        if !editingBrightness { brightness = (config.brightness ?? 0.35) * 100 }
    }
    private func hasBrightness(_ status: Status) -> Bool { status.system.values.keys.contains { $0.hasPrefix("brightness:") } }
    private func saveTimes() {
        do {
            let on = try Schedule.parse(onTime), off = try Schedule.parse(offTime)
            model.change { $0.schedule.on = on; $0.schedule.off = off }
        } catch { model.error = error.localizedDescription }
    }
    private func scheduleDescription(_ status: Status) -> String {
        if status.state.manualUntilBoundary != nil && status.configuration.schedule.enabled { return "Manual override until the next scheduled change." }
        return status.configuration.schedule.enabled ? "Every day, local time. Catches up on wake while the app is running." : "Off by default. Enable to follow these times daily."
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private var popover = NSPopover()
    private var model: Model!
    private var timer: Timer?
    private var hotkey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var terminating = false
    private var qaWindow: NSWindow?
    private var recoveryPresented = false
    private var pressTimer: Timer?
    private var handledPress = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Finder launches are single-instance; protect command-line launches as well.
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApp.terminate(nil); return
        }
        do { model = Model(controller: try EinkEnvironment.makeController()) }
        catch { let alert = NSAlert(); alert.messageText = "E-Ink Mode could not start"; alert.informativeText = error.localizedDescription; alert.runModal(); NSApp.terminate(nil); return }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "circle.lefthalf.filled", accessibilityDescription: "E-Ink Mode")
        item.button?.target = self; item.button?.action = #selector(statusItemPressed)
        item.button?.sendAction(on: [.leftMouseDown, .leftMouseUp, .rightMouseUp])
        popover.behavior = .transient
        let settings = SettingsView(model: model, quit: { NSApp.terminate(nil) })
        let hosting = NSHostingController(rootView: settings)
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.contentSize = NSSize(width: 350, height: 620)
        if CommandLine.arguments.contains("--qa-window"), ProcessInfo.processInfo.environment["EINK_SIMULATED"] == "1" {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 350, height: 680), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "E-Ink Mode — Simulated QA"
            window.contentViewController = NSHostingController(rootView: settings)
            window.center(); window.makeKeyAndOrderFront(nil); qaWindow = window
            NSApp.activate(ignoringOtherApps: true)
        }
        model.changed = { [weak self] in
            guard let self else { return }
            let active = self.model.status?.active == true
            self.item.button?.image = NSImage(systemSymbolName: active ? "circle.fill" : "circle.lefthalf.filled", accessibilityDescription: active ? "E-Ink Mode on" : "E-Ink Mode off")
            let interaction = self.model.clickToFlip ? "click to flip; long press or right-click for settings" : "click for settings"
            self.item.button?.toolTip = "E-Ink Mode\(active ? " is on" : "") — \(interaction)"
            if self.model.error != nil { self.showSettings() }
            if self.model.needsRecovery && !self.recoveryPresented {
                self.recoveryPresented = true; self.showSettings()
            }
        }
        model.load()
        registerHotkey()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.model.poll() }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wake), name: NSWorkspace.didWakeNotification, object: nil)
        if CommandLine.arguments.contains("--show") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.showSettings() } }
    }
    @objc private func statusItemPressed() {
        guard let event = NSApp.currentEvent else { showSettings(); return }
        switch event.type {
        case .leftMouseDown:
            pressTimer?.invalidate()
            handledPress = false
            if event.modifierFlags.contains(.control) {
                handledPress = true
                showSettings()
                return
            }
            let timer = Timer(timeInterval: 0.5, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.handledPress = true
                if self.pointerIsOverButton { self.showSettings() }
            }
            pressTimer = timer
            // Status buttons track the mouse in a separate run-loop mode.
            RunLoop.main.add(timer, forMode: .common)
        case .leftMouseUp:
            pressTimer?.invalidate()
            pressTimer = nil
            guard !handledPress, pointerIsOverButton else { return }
            if event.modifierFlags.contains(.control) || !model.clickToFlip || model.needsRecovery || model.status == nil {
                showSettings()
            } else {
                popover.performClose(nil)
                model.toggle()
            }
        case .rightMouseUp:
            pressTimer?.invalidate()
            pressTimer = nil
            handledPress = true
            showSettings()
        default:
            // Keyboard and accessibility activation retain access to settings.
            showSettings()
        }
    }
    private var pointerIsOverButton: Bool {
        guard let button = item?.button, let window = button.window else { return false }
        let point = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        return button.bounds.contains(button.convert(point, from: nil))
    }
    @objc func showSettings() {
        guard let button = item?.button else { return }
        if !popover.isShown { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY); NSApp.activate(ignoringOtherApps: true) }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showSettings(); return true }
    @objc func wake() { model.poll() }
    func registerHotkey() {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let result = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { delegate.model.toggle() }
            return noErr
        }, 1, &event, context, &handler)
        let registered = RegisterEventHotKey(UInt32(kVK_ANSI_E), UInt32(cmdKey | shiftKey), EventHotKeyID(signature: 0x45494E4B, id: 1), GetApplicationEventTarget(), 0, &hotkey)
        if result != noErr || registered != noErr { model.hotkeyMessage = "⌘⇧E is unavailable (already in use). Use the menu toggle." }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model != nil, !terminating else { return .terminateNow }
        if model.busy { model.error = "Wait for the current change to finish, then quit."; showSettings(); return .terminateCancel }
        do {
            try model.controller.setMode(false)
            terminating = true; timer?.invalidate()
            if let hotkey { UnregisterEventHotKey(hotkey) }
            return .terminateNow
        } catch { model.error = "Could not restore your display. \(error.localizedDescription)"; showSettings(); return .terminateCancel }
    }
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
