// EinkBar — menu bar toggle for E-Ink Mode.
//
// Deliberately thin: all state capture and restore lives in the `eink` shell
// script, and this only drives it. One brain, so the CLI and the menu bar can
// never disagree about what is captured or how it gets restored.
//
// Left click  : toggle
// Right click : menu

import Cocoa

let einkScript = Bundle.main.path(forResource: "eink", ofType: nil)
    ?? "\(NSHomeDirectory())/VibeCoding/eink/prototype0/eink"

@discardableResult
func runEink(_ arg: String) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = [einkScript, arg]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return "error: \(error.localizedDescription)" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

/// Source of truth is the script's state file, so a toggle from the CLI is
/// reflected in the icon within one poll.
func modeIsActive() -> Bool {
    let stateFile = ProcessInfo.processInfo.environment["EINK_STATE"]
        ?? "\(NSHomeDirectory())/.local/state/eink/saved-state"
    return FileManager.default.fileExists(atPath: stateFile)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var pollTimer: Timer?

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(buttonClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        refreshIcon()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshIcon()
        }
    }

    // Never leave the display grey with no UI left to un-grey it.
    func applicationWillTerminate(_ note: Notification) {
        if modeIsActive() { runEink("off") }
    }

    private func refreshIcon() {
        guard let button = statusItem.button else { return }
        let active = modeIsActive()
        let name = active ? "circle.fill" : "circle.lefthalf.filled"
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "E-Ink Mode")
        img?.isTemplate = true
        button.image = img
        button.toolTip = active ? "E-Ink Mode: ON — click to restore" : "E-Ink Mode: off — click to enable"
    }

    @objc private func buttonClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showMenu()
        } else {
            runEink("toggle")
            refreshIcon()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        let active = modeIsActive()

        let header = NSMenuItem(title: active ? "E-Ink Mode: ON" : "E-Ink Mode: off",
                                action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        menu.addItem(withTitle: active ? "Restore display" : "Enable E-Ink Mode",
                     action: #selector(toggleFromMenu), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Edit config…", action: #selector(openConfig), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q").target = self

        // popUpMenu is deprecated but remains the reliable way to show a menu on
        // right-click only while keeping left-click as a direct toggle.
        statusItem.popUpMenu(menu)
    }

    @objc private func toggleFromMenu() { runEink("toggle"); refreshIcon() }

    @objc private func quit() {
        if modeIsActive() { runEink("off") }
        NSApp.terminate(nil)
    }

    @objc private func openConfig() {
        let dir = "\(NSHomeDirectory())/.config/eink"
        let file = "\(dir)/config"
        if !FileManager.default.fileExists(atPath: file) {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? """
            # E-Ink Mode config
            EINK_BRIGHTNESS=0.35   # 0.0-1.0, empty to leave brightness alone
            EINK_HIDE_DOCK=yes
            EINK_INVERT=off        # tabled; Smart Invert and grayscale fight over images
            """.write(toFile: file, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: file))
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
app.run()
