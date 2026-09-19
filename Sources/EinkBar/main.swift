import AppKit
import SwiftUI
import EinkCore
import EinkMac

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private var model: AppModel!
    private let menu = NSMenu()
    private var live = LiveMenuItems()
    private var statsWindow: NSWindow?
    private var lastFocus: FocusSession?
    private var menuTimer: Timer?
    private var pollTimer: Timer?
    private var secondTimer: Timer?
    private var hotkeys: HotkeyCenter?
    private var terminating = false
    private var poweringOff = false
    private var launchHandled = false
    private var settingsWindow: NSWindow?
    private var welcomeWindow: NSWindow?
    private let navigation = SettingsNavigation()
    private var pressTimer: Timer?
    private var handledPress = false
    private var hint: NSPopover?
    private var signalSources: [DispatchSourceSignal] = []
    private var simulated: Bool { ProcessInfo.processInfo.environment["EINK_SIMULATED"] == "1" }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let snapshotDirectory = argument("--qa-snapshots")
        if snapshotDirectory == nil {
            let qaDuplicate = simulated && ProcessInfo.processInfo.environment["EINK_QA_ALLOW_DUPLICATE"] == "1"
            guard qaDuplicate || Installation.resolveRunningCopies() else { NSApp.terminate(nil); return }
            if !simulated, !Installation.offerMoveToApplications() { terminating = true; NSApp.terminate(nil); return }
        }
        do { model = AppModel(controller: try EinkEnvironment.makeController()) }
        catch {
            let alert = NSAlert(); alert.messageText = "E-Ink Mode could not start"; alert.informativeText = error.localizedDescription
            alert.runModal(); NSApp.terminate(nil); return
        }
        if let snapshotDirectory { return QASnapshots.run(model: model, navigation: navigation, into: snapshotDirectory) }

        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.imagePosition = .imageLeading
        item.button?.target = self; item.button?.action = #selector(statusItemPressed)
        item.button?.sendAction(on: [.leftMouseDown, .leftMouseUp, .rightMouseUp])
        menu.delegate = self; menu.autoenablesItems = false
        refreshIcon()

        var wasFlipping = model.clickToFlip
        model.changed = { [weak self] in
            guard let self else { return }
            self.refreshIcon()
            if self.model.clickToFlip && !wasFlipping { self.showHint("Click ◐ to switch E-Ink Mode.\nRight-click or hold for the menu.") }
            wasFlipping = self.model.clickToFlip
            if !self.launchHandled, self.model.status != nil { self.launchHandled = true; self.lastFocus = self.model.focus; self.handleLaunch() }
            else { self.announceFocusChanges() }
        }
        model.onUserError = { [weak self] message in self?.presentError(message) }
        model.load()
        hotkeys = HotkeyCenter { [weak self] in self?.model.toggle() }
        applyShortcut(UserDefaults.standard.string(forKey: "shortcut") ?? Shortcut.presets[0].id)

        pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.model.poll() }
        // Ends temporary color and focus phases on time and keeps countdowns fresh.
        secondTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let state = self.model.status?.state else { return }
            guard let due = state.focus?.phaseEnds ?? state.colorUntil else { return }
            if due <= Date() { self.model.poll() } else { self.refreshIcon() }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(wake), name: NSWorkspace.didWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(willPowerOff), name: NSWorkspace.willPowerOffNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(revealFromAnotherLaunch),
                                                            name: Installation.showMenuNotification, object: nil)
        installSignalHandlers()
        scheduleUpdateChecks()
    }

    private func argument(_ name: String) -> String? {
        guard simulated, let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[index + 1]
    }

    /// Runs once, after the first status read: recovery first, then welcome, then post-update activation.
    private func handleLaunch() {
        if model.needsRecovery { return presentRecovery() }
        if !UserDefaults.standard.bool(forKey: "onboarded") { showWelcome() }
        else if CommandLine.arguments.contains("--activate"), !model.active { model.setActive(true) }
        if CommandLine.arguments.contains("--show-menu") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.showMenu() } }
        if simulated, CommandLine.arguments.contains("--qa-verify-menu") { verifyMenuOpens() }
    }

    // MARK: Status item

    private func refreshIcon() {
        guard let button = item?.button else { return }
        let symbol: String, label: String
        var countdownText = ""
        var wildcat: WildcatIcon.Style?
        if model.error != nil || model.needsRecovery { symbol = "exclamationmark.circle"; label = "E-Ink Mode needs attention" }
        else if let focus = model.focus {
            wildcat = focus.phase == .rest || model.colorRemaining != nil ? .half : .filled
            symbol = focus.phase == .focus ? "timer" : "cup.and.saucer"
            label = MenuBuilder.focusLine(focus)
            if model.menuBarCountdown { countdownText = countdown(focus.remaining(now: Date())) }
        }
        else if let left = model.colorRemaining { symbol = "circle.dotted"; label = "E-Ink Mode — color for \(countdown(left))"; wildcat = .half }
        else if model.active { symbol = "circle.fill"; label = "E-Ink Mode is on"; wildcat = .filled }
        else { symbol = "circle.lefthalf.filled"; label = "E-Ink Mode is off"; wildcat = .outline }
        if model.wildcatMode, let wildcat { button.image = WildcatIcon.image(wildcat, accessibility: label) }
        else { button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) }
        button.title = countdownText
        button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        button.toolTip = label + (model.clickToFlip ? " — click to switch, right-click for menu" : "")
    }

    @objc private func statusItemPressed() {
        guard let event = NSApp.currentEvent else { showMenu(); return }
        switch event.type {
        case .leftMouseDown:
            pressTimer?.invalidate(); handledPress = false
            if event.modifierFlags.contains(.control) || !model.clickToFlip { handledPress = true; showMenu(); return }
            let timer = Timer(timeInterval: 0.5, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.handledPress = true
                if self.pointerIsOverButton { self.showMenu() }
            }
            pressTimer = timer
            RunLoop.main.add(timer, forMode: .common) // status buttons track the mouse in a separate run-loop mode
        case .leftMouseUp:
            pressTimer?.invalidate(); pressTimer = nil
            guard !handledPress, pointerIsOverButton else { return }
            if model.needsRecovery || model.status == nil || model.error != nil { showMenu() } else { model.toggle() }
        case .rightMouseUp:
            pressTimer?.invalidate(); pressTimer = nil; handledPress = true
            showMenu()
        default:
            showMenu() // keyboard and accessibility activation
        }
    }
    private var pointerIsOverButton: Bool {
        guard let button = item?.button, let window = button.window else { return false }
        let point = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        return button.bounds.contains(button.convert(point, from: nil))
    }
    @objc func showMenu() {
        guard let item else { return }
        hint?.close()
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }
    /// Simulated QA: opens the status menu through the real click path and reports whether it appeared.
    private func verifyMenuOpens() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let check = Timer(timeInterval: 0.8, repeats: false) { _ in
                let titles = self.menu.items.map(\.title).filter { !$0.isEmpty }
                let open = NSApp.windows.contains { $0.isVisible && String(describing: type(of: $0)).contains("Menu") }
                print("qa-verify-menu open=\(open) items=\(titles)")
                if let frame = self.item.button?.window?.frame, let screen = NSScreen.screens.first {
                    print("qa-status-item \(Int(frame.minX)),\(Int(screen.frame.maxY - frame.maxY)),\(Int(frame.width)),\(Int(frame.height))")
                }
                self.menu.cancelTracking()
                DispatchQueue.main.async { self.terminating = true; NSApp.terminate(nil) }
            }
            RunLoop.main.add(check, forMode: .common)
            self.showMenu()
        }
    }
    @objc private func revealFromAnotherLaunch() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if self.welcomeWindow?.isVisible == true { self.welcomeWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
            else { self.showHint("E-Ink Mode is already running — it lives here in the menu bar.") }
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { revealFromAnotherLaunch(); return true }

    private func showHint(_ text: String) {
        guard let button = item?.button else { return }
        hint?.close()
        let popover = NSPopover(); popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: Text(text).font(.callout).multilineTextAlignment(.center).padding(12))
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        hint = popover
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak popover] in popover?.close() }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) { MenuBuilder.build(menu, model: model, target: self, live: &live) }
    func menuWillOpen(_ menu: NSMenu) {
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            if let item = self.live.color, let left = self.model.colorRemaining { item.title = "Resume grayscale · \(countdown(left)) remaining" }
            if let item = self.live.focus, let focus = self.model.focus { item.title = MenuBuilder.focusLine(focus) }
        }
        RunLoop.main.add(timer, forMode: .common); menuTimer = timer
    }
    func menuDidClose(_ menu: NSMenu) { menuTimer?.invalidate(); menuTimer = nil }

    @objc func turnOn() { model.setActive(true) }
    @objc func turnOff() { model.setActive(false) }
    @objc func startColor() { model.startColor() }
    @objc func startFocus() { model.startFocus() }
    @objc func stopFocus() { model.stopFocus() }
    @objc func skipBreak() { model.skipBreak() }
    @objc func showStats() {
        if statsWindow == nil {
            let view = FocusStatsView(model: model, start: { [weak self] in self?.model.startFocus() })
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Focus Stats"; window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false; window.center()
            statsWindow = window
        }
        model.poll()
        statsWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    /// Plays a cue and shows a short hint when a focus round changes phase.
    private func announceFocusChanges() {
        let previous = lastFocus, current = model.focus
        lastFocus = current
        guard previous?.phase != current?.phase || previous?.round != current?.round else { return }
        let message: String, sound: String
        switch (previous, current) {
        case (nil, let now?): message = "Focus \(now.round) of \(now.rounds) — \(Int(now.focusSeconds / 60)) minutes in grayscale."; sound = "Tink"
        case (_, let now?) where now.phase == .rest:
            message = "Break time — color is on for \(Int(now.breakSeconds / 60)) minutes."; sound = "Glass"
        case (_, let now?): message = "Back to focus · session \(now.round) of \(now.rounds)."; sound = "Tink"
        case (let was?, nil):
            guard let stats = model.stats else { return }
            let finished = was.phase == .focus && was.remaining(now: Date()) <= 1 && was.round == was.rounds
            message = finished ? "Round complete! \(stats.today.completed) sessions today. \(stats.message)" : "Focus session stopped."
            sound = finished ? "Hero" : "Pop"
        default: return
        }
        if model.focusSound { NSSound(named: NSSound.Name(sound))?.play() }
        showHint(message)
    }
    @objc func endColor() { model.endColor() }
    @objc func restoreDisplay() { model.restoreDisplay() }
    @objc func resumeSession() { model.recover(resume: true) }
    @objc func showError() { if let error = model.error { presentError(error) } }
    @objc func scheduleOff() { model.change { $0.schedule.enabled = false } }
    @objc func scheduleEvening() { model.change { $0.schedule = .evening; $0.schedule.enabled = true } }
    @objc func scheduleCustom() { model.change { $0.schedule.enabled = true } }
    @objc func editSchedule() { showSettings(.schedule) }
    @objc func customize() { showSettings(.appearance) }
    @objc func openSettings() { showSettings(.general) }
    @objc func installUpdate() { confirmUpdate() }
    @objc func quit() { NSApp.terminate(nil) }

    // MARK: Windows

    private func showSettings(_ tab: SettingsTab) {
        navigation.tab = tab
        if settingsWindow == nil {
            let actions = SettingsActions(checkForUpdates: { [weak self] in self?.checkForUpdates(interactive: true) },
                                          installUpdate: { [weak self] in self?.confirmUpdate() },
                                          showWelcome: { [weak self] in self?.showWelcome() },
                                          setShortcut: { [weak self] in self?.applyShortcut($0) },
                                          showStats: { [weak self] in self?.showStats() })
            let hosting = NSHostingController(rootView: SettingsView(model: model, navigation: navigation, actions: actions))
            hosting.sizingOptions = [.preferredContentSize] // resize as tabs change height
            let window = NSWindow(contentViewController: hosting)
            window.title = "E-Ink Mode Settings"; window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false; window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private func showWelcome() {
        if welcomeWindow == nil {
            let view = OnboardingView(model: model) { [weak self] turnOn in
                UserDefaults.standard.set(true, forKey: "onboarded")
                self?.welcomeWindow?.close()
                if turnOn { self?.model.setActive(true) }
                self?.showHint(turnOn ? "E-Ink Mode is on. Find it here any time." : "E-Ink Mode lives here in the menu bar.")
            }
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Welcome to E-Ink Mode"; window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false; window.center()
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                self?.model.endPreview() // closing the window never leaves a preview running
                UserDefaults.standard.set(true, forKey: "onboarded")
            }
            welcomeWindow = window
        }
        welcomeWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Alerts

    private func presentRecovery() {
        showMenuBarAlert { alert in
            alert.messageText = "E-Ink Mode didn't shut down cleanly"
            alert.informativeText = "Your display may still be grayscale, dimmed, or have the Dock hidden. Restore it to exactly how it was before, or continue where you left off."
            alert.addButton(withTitle: "Restore Display"); alert.addButton(withTitle: "Continue Session")
        } response: { [weak self] response in self?.model.recover(resume: response == .alertSecondButtonReturn) }
    }
    private func presentError(_ message: String) {
        showMenuBarAlert { alert in
            alert.alertStyle = .warning
            alert.messageText = "E-Ink Mode couldn't finish that"
            alert.informativeText = message + "\n\nIf a display was disconnected, reconnect it and choose Restore Display."
            alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Restore Display")
        } response: { [weak self] response in
            self?.model.error = nil
            if response == .alertSecondButtonReturn { self?.model.restoreDisplay() }
            self?.refreshIcon()
        }
    }
    private func showMenuBarAlert(_ configure: @escaping (NSAlert) -> Void, response: @escaping (NSApplication.ModalResponse) -> Void) {
        DispatchQueue.main.async {
            let alert = NSAlert(); configure(alert)
            NSApp.activate(ignoringOtherApps: true)
            response(alert.runModal())
        }
    }

    // MARK: Shortcut

    private func applyShortcut(_ id: String) {
        UserDefaults.standard.set(id, forKey: "shortcut")
        model.hotkeyMessage = hotkeys?.register(Shortcut.presets.first { $0.id == id }) ?? ""
    }

    // MARK: Updates

    private func scheduleUpdateChecks() {
        guard Updater.feed != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.checkForUpdates(interactive: false) }
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.checkForUpdates(interactive: false) }
    }
    private func checkForUpdates(interactive: Bool) {
        guard interactive || model.autoCheckUpdates else { return }
        if interactive { model.update = .checking }
        Updater.check { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let release?): self.model.update = .available(release)
            case .success(nil): if interactive || self.model.update == .checking { self.model.update = .upToDate }
            case .failure(let error): if interactive { self.model.update = .failed(error.localizedDescription) }
            }
        }
    }
    private func confirmUpdate() {
        guard case .available(let release) = model.update else { return }
        showMenuBarAlert { alert in
            alert.messageText = "Update to \(release.tagName)?"
            let notes = (release.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            alert.informativeText = "You have \(EinkEnvironment.version). E-Ink Mode will restore your display, install the update, and reopen."
                + (notes.isEmpty ? "" : "\n\nWhat's new:\n" + String(notes.prefix(600)))
            alert.addButton(withTitle: "Install and Relaunch"); alert.addButton(withTitle: "View Release Page"); alert.addButton(withTitle: "Later")
        } response: { [weak self] response in
            guard let self else { return }
            if response == .alertSecondButtonReturn { NSWorkspace.shared.open(release.htmlURL) }
            guard response == .alertFirstButtonReturn else { return }
            self.model.update = .installing
            Updater.install(release, relaunchActive: self.model.active) { error in
                if let error {
                    self.model.update = .available(release)
                    self.presentError(error.localizedDescription + "\n\nYou can download it from the release page instead.")
                    NSWorkspace.shared.open(release.htmlURL)
                } else { NSApp.terminate(nil) }
            }
        }
    }

    // MARK: Lifecycle and restoration

    @objc func wake() { model.poll() }
    @objc func willPowerOff() { poweringOff = true }
    /// `kill`, logout via launchd, or Ctrl-C still put the display back.
    private func installSignalHandlers() {
        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                try? self?.model.controller.shutdown(resumeScheduleOnLaunch: true)
                exit(0)
            }
            source.resume(); signalSources.append(source)
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model != nil, item != nil, !terminating else { return .terminateNow }
        model.endPreview()
        while true {
            do {
                try model.controller.shutdown(resumeScheduleOnLaunch: poweringOff)
                terminating = true; pollTimer?.invalidate(); secondTimer?.invalidate(); hotkeys?.unregister()
                return .terminateNow
            } catch {
                let alert = NSAlert(); alert.alertStyle = .critical
                alert.messageText = "Your display couldn't be fully restored"
                alert.informativeText = "\(error.localizedDescription)\n\nIf you disconnected a display, reconnect it and try again. E-Ink Mode stays open so nothing is lost."
                alert.addButton(withTitle: "Try Again"); alert.addButton(withTitle: "Keep E-Ink Mode Open")
                NSApp.activate(ignoringOtherApps: true)
                if alert.runModal() != .alertFirstButtonReturn { poweringOff = false; return .terminateCancel }
            }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
