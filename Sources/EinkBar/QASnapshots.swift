import AppKit
import SwiftUI
import EinkCore
import EinkMac

/// Simulated-mode only: renders the real windows to PNG for docs and visual QA, then exits.
enum QASnapshots {
    static func run(model: AppModel, navigation: SettingsNavigation, into directory: String) {
        let folder = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let actions = SettingsActions(checkForUpdates: {}, installUpdate: {}, showWelcome: {}, setShortcut: { _ in })
        let controller = model.controller
        let savedFlip = UserDefaults.standard.object(forKey: "clickToFlip") // don't leak QA choices into real preferences
        let savedWildcat = UserDefaults.standard.object(forKey: "wildcatMode")
        var shots: [(String, () -> Void, () -> AnyView)] = [
            ("welcome", { try? controller.setMode(false); model.clickToFlip = false /* new-user default */ }, { AnyView(OnboardingView(model: model) { _ in }) }),
            ("settings-appearance", {
                try? controller.edit { $0.brightness = 0.45; $0.hideDock = false }
                navigation.tab = .appearance
            }, { AnyView(SettingsView(model: model, navigation: navigation, actions: actions)) }),
            ("settings-schedule", {
                try? controller.edit { $0.schedule = .evening; $0.schedule.enabled = true }
                navigation.tab = .schedule
            }, { AnyView(SettingsView(model: model, navigation: navigation, actions: actions)) }),
            ("settings-focus", {
                seedHistory(controller: controller)
                model.stats = try? controller.focusStats()
                navigation.tab = .focus
            }, { AnyView(SettingsView(model: model, navigation: navigation, actions: actions)) }),
            ("focus-stats", {
                seedHistory(controller: controller)
                model.stats = try? controller.focusStats()
            }, { AnyView(FocusStatsView(model: model, start: {})) }),
            ("settings-general", {
                model.clickToFlip = true; model.wildcatMode = true; model.update = .upToDate
                model.hotkeyMessage = "⌘⇧E switches E-Ink Mode from any app. If nothing happens, another app may be intercepting it — pick another."
                navigation.tab = .general
            }, { AnyView(SettingsView(model: model, navigation: navigation, actions: actions)) }),
        ]
        func next() {
            guard !shots.isEmpty else {
                captureMenus(model: model, into: folder)
                renderIconComparison(into: folder)
                UserDefaults.standard.set(savedFlip, forKey: "clickToFlip")
                UserDefaults.standard.set(savedWildcat, forKey: "wildcatMode")
                NSApp.terminate(nil); return
            }
            let (name, prepare, view) = shots.removeFirst()
            prepare()
            model.status = try? controller.status()
            let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .aqua)
            window.isReleasedWhenClosed = false
            window.title = ["welcome": "Welcome to E-Ink Mode", "focus-stats": "Focus Stats"][name] ?? "E-Ink Mode Settings"
            window.contentViewController = NSHostingController(rootView: view())
            window.setFrameOrigin(NSPoint(x: -4000, y: 0))
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil) // key windows draw controls with their accent color
            // Let SwiftUI lay out and AppKit controls draw before capturing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil) // re-assert key status so the title bar renders active
                window.makeFirstResponder(nil)
                // Capture the real window (title bar included, no system shadow), then frame it on a backdrop
                // so the image is opaque and readable on light and dark pages alike.
                let raw = FileManager.default.temporaryDirectory.appendingPathComponent("eink-\(name)-raw.png")
                let capture = Process()
                capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                capture.arguments = ["-x", "-o", "-l\(window.windowNumber)", raw.path]
                try? capture.run(); capture.waitUntilExit()
                if let image = NSImage(contentsOf: raw), let framed = framedOnBackdrop(image) {
                    try? framed.write(to: folder.appendingPathComponent("\(name).png"))
                    print("snapshot \(name).png \(Int(image.size.width))x\(Int(image.size.height))")
                } else { print("snapshot \(name) failed") }
                try? FileManager.default.removeItem(at: raw)
                window.close()
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
            ("menu-focus", {
                try? controller.endTemporaryColor(); try? controller.setMode(false)
                try? controller.startFocus(sessions: 4, now: Date().addingTimeInterval(-6.5 * 60))
            }),
            ("menu-focus-color", { try? controller.startTemporaryColor(for: 272) }),
            ("menu-break", {
                try? controller.stopFocus()
                try? controller.startFocus(sessions: 4, now: Date().addingTimeInterval(-(25 + 25 + 5 + 0.5) * 60))
                try? controller.tick()
            }),
        ]
        let backdrop = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 480), styleMask: [.borderless], backing: .buffered, defer: false)
        backdrop.backgroundColor = QASnapshots.backdrop
        backdrop.appearance = NSAppearance(named: .aqua)
        backdrop.center(); backdrop.orderFrontRegardless()
        let inertTarget = NSObject() // menu item targets are weak; keep one alive while rendering
        for (name, prepare) in scenarios {
            prepare()
            model.status = try? controller.status(); model.stats = try? controller.focusStats()
            let menu = NSMenu(); menu.autoenablesItems = false; menu.appearance = NSAppearance(named: .aqua)
            var live = LiveMenuItems()
            MenuBuilder.build(menu, model: model, target: inertTarget, live: &live)
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

    /// Three weeks of plausible study history: a 7-day streak, today 3 of 4.
    private static func seedHistory(controller: Controller) {
        var history = FocusHistory()
        let calendar = Calendar.autoupdatingCurrent
        let pattern = [4, 6, 0, 5, 8, 3, 0, 7, 6, 9, 0, 2, 5, 0, 6, 8, 4, 7, 5, 3]
        for (offset, sessions) in pattern.enumerated() {
            let date = calendar.date(byAdding: .day, value: -(pattern.count - offset), to: Date())!
            var day = DayRecord(); day.completed = sessions; day.focusMinutes = sessions * 25; day.rounds = sessions / 4
            if sessions > 0 { history.days[FocusHistory.key(date, calendar: calendar)] = day }
        }
        var today = DayRecord(); today.completed = 3; today.focusMinutes = 75 + 12; today.stopped = 1
        history.days[FocusHistory.key(Date(), calendar: calendar)] = today
        try? Store(directory: EinkEnvironment.directory).write(history, name: "focus-history.json")
    }

    /// Standard and wildcat menu bar icons side by side, as a menu bar would show them.
    private static func renderIconComparison(into folder: URL) {
        let size = NSSize(width: 420, height: 128), scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        backdrop.setFill(); NSRect(origin: .zero, size: size).fill()
        let label: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor(calibratedWhite: 0.4, alpha: 1)] // fixed ink: docs render the same in any appearance
        let heading: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: NSColor(calibratedWhite: 0.12, alpha: 1)]
        let columns: [(String, String, WildcatIcon.Style)] = [("Off", "circle.lefthalf.filled", .outline), ("On", "circle.fill", .filled),
                                                               ("Showing color", "circle.dotted", .half)]
        for (row, name) in ["Standard", "Wildcat mode"].enumerated() {
            let y = size.height - 64 - CGFloat(row) * 46
            NSString(string: name).draw(at: NSPoint(x: 20, y: y + 3), withAttributes: heading)
            for (column, entry) in columns.enumerated() {
                let x = 150 + CGFloat(column) * 95
                let bar = NSRect(x: x - 6, y: y - 5, width: 34, height: 30)
                NSColor.white.withAlphaComponent(0.9).setFill(); NSBezierPath(roundedRect: bar, xRadius: 6, yRadius: 6).fill()
                let icon = row == 0 ? NSImage(systemSymbolName: entry.1, accessibilityDescription: nil)!.withSymbolConfiguration(.init(pointSize: 15, weight: .regular))!
                                    : WildcatIcon.image(entry.2, accessibility: entry.0)
                let tinted = NSImage(size: icon.size, flipped: false) { rect in
                    icon.draw(in: rect); NSColor.black.set(); rect.fill(using: .sourceAtop); return true
                }
                tinted.draw(in: NSRect(x: x + 11 - icon.size.width / 2, y: y + 10 - icon.size.height / 2, width: icon.size.width, height: icon.size.height))
            }
        }
        for (column, entry) in columns.enumerated() {
            NSString(string: entry.0).draw(at: NSPoint(x: 150 + CGFloat(column) * 95 - 6, y: size.height - 30), withAttributes: label)
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("wildcat-icons.png"))
        print("snapshot wildcat-icons.png")
    }

    static let backdrop = NSColor(calibratedWhite: 0.93, alpha: 1)

    /// Draws `image` with a soft window shadow on an opaque backdrop, at the capture's pixel density.
    private static func framedOnBackdrop(_ image: NSImage, padding: CGFloat = 36) -> Data? {
        guard let source = image.representations.first else { return nil }
        let scale = CGFloat(source.pixelsWide) / image.size.width
        let size = NSSize(width: image.size.width + padding * 2, height: image.size.height + padding * 2)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        backdrop.setFill(); NSRect(origin: .zero, size: size).fill()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowBlurRadius = 18; shadow.shadowOffset = NSSize(width: 0, height: -6)
        shadow.set()
        image.draw(in: NSRect(x: padding, y: padding, width: image.size.width, height: image.size.height))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
