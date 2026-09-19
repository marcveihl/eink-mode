import AppKit
import SwiftUI
import EinkCore

/// Simulated-mode only: renders the real windows to PNG for docs and visual QA, then exits.
enum QASnapshots {
    static func run(model: AppModel, navigation: SettingsNavigation, into directory: String) {
        let folder = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let actions = SettingsActions(checkForUpdates: {}, installUpdate: {}, showWelcome: {}, setShortcut: { _ in })
        let controller = model.controller
        let savedFlip = UserDefaults.standard.object(forKey: "clickToFlip") // don't leak QA choices into real preferences
        var shots: [(String, () -> Void, () -> AnyView)] = [
            ("welcome", { try? controller.setMode(false) }, { AnyView(OnboardingView(model: model) { _ in }) }),
            ("settings-appearance", {
                try? controller.edit { $0.brightness = 0.45; $0.hideDock = false }
                navigation.tab = .appearance
            }, { AnyView(SettingsView(model: model, navigation: navigation, actions: actions)) }),
            ("settings-schedule", {
                try? controller.edit { $0.schedule = .evening; $0.schedule.enabled = true }
                navigation.tab = .schedule
            }, { AnyView(SettingsView(model: model, navigation: navigation, actions: actions)) }),
            ("settings-general", {
                model.clickToFlip = true; model.update = .upToDate
                model.hotkeyMessage = "⌘⇧E switches E-Ink Mode from any app. If nothing happens, another app may be intercepting it — pick another."
                navigation.tab = .general
            }, { AnyView(SettingsView(model: model, navigation: navigation, actions: actions)) }),
        ]
        func next() {
            guard !shots.isEmpty else {
                captureMenus(model: model, into: folder)
                UserDefaults.standard.set(savedFlip, forKey: "clickToFlip")
                NSApp.terminate(nil); return
            }
            let (name, prepare, view) = shots.removeFirst()
            prepare()
            model.status = try? controller.status()
            let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .aqua)
            window.contentViewController = NSHostingController(rootView: view())
            window.setFrameOrigin(NSPoint(x: -4000, y: 0))
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil) // key windows draw controls with their accent color
            // Let SwiftUI lay out and AppKit controls draw before capturing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                window.makeFirstResponder(nil)
                if let content = window.contentView, let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                    content.cacheDisplay(in: content.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("\(name).png"))
                    print("snapshot \(name).png \(Int(content.bounds.width))x\(Int(content.bounds.height))")
                }
                window.orderOut(nil)
                next()
            }
        }
        next()
    }

    /// Pops the real status menu over a neutral backdrop and captures just that region of the screen.
    private static func captureMenus(model: AppModel, into folder: URL) {
        let controller = model.controller
        let scenarios: [(String, () -> Void)] = [
            ("menu-off", {
                try? controller.edit { $0.schedule = .evening; $0.schedule.enabled = true }
                try? controller.setMode(false, now: Date())
                model.clickToFlip = false
            }),
            ("menu-on", {
                try? controller.setMode(true); try? controller.endTemporaryColor()
                model.clickToFlip = true
            }),
            ("menu-color", { try? controller.startTemporaryColor(for: 272) }),
        ]
        let backdrop = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 480), styleMask: [.borderless], backing: .buffered, defer: false)
        backdrop.backgroundColor = NSColor(calibratedWhite: 0.93, alpha: 1)
        backdrop.appearance = NSAppearance(named: .aqua)
        backdrop.center(); backdrop.orderFrontRegardless()
        let inertTarget = NSObject() // menu item targets are weak; keep one alive while rendering
        for (name, prepare) in scenarios {
            prepare()
            model.status = try? controller.status()
            let menu = NSMenu(); menu.autoenablesItems = false; menu.appearance = NSAppearance(named: .aqua)
            var colorItem: NSMenuItem?
            MenuBuilder.build(menu, model: model, target: inertTarget, colorItem: &colorItem)
            let timer = Timer(timeInterval: 0.8, repeats: false) { _ in
                if let window = NSApp.windows.first(where: { $0.isVisible && $0 !== backdrop && $0.frame.width > 100 && String(describing: type(of: $0)).contains("Menu") }),
                   let screen = NSScreen.screens.first {
                    let frame = window.frame.insetBy(dx: -20, dy: -20).intersection(backdrop.frame)
                    let region = "\(Int(frame.minX)),\(Int(screen.frame.maxY - frame.maxY)),\(Int(frame.width)),\(Int(frame.height))"
                    let capture = Process()
                    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    capture.arguments = ["-x", "-R", region, folder.appendingPathComponent("\(name).png").path]
                    try? capture.run(); capture.waitUntilExit()
                    print("snapshot \(name).png \(region)")
                } else { print("snapshot \(name) failed: menu window not found") }
                menu.cancelTracking()
            }
            RunLoop.main.add(timer, forMode: .common)
            let origin = NSPoint(x: 40, y: backdrop.contentView!.bounds.height - 30)
            menu.popUp(positioning: nil, at: origin, in: backdrop.contentView)
        }
        backdrop.orderOut(nil)
    }
}
