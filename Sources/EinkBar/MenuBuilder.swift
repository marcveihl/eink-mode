import AppKit
import EinkCore

/// Menu items whose titles tick every second while the menu is open.
struct LiveMenuItems {
    var color: NSMenuItem?
    var focus: NSMenuItem?
}

/// Builds the status menu:
///   E-Ink Mode · On / Turn off / Color for 5 minutes
///   Schedule · Until 7:00 AM / Customize appearance… / Settings…
///   Quit and restore display
enum MenuBuilder {
    static func build(_ menu: NSMenu, model: AppModel, target: AnyObject, live: inout LiveMenuItems) {
        menu.removeAllItems(); live = LiveMenuItems()
        func add(_ title: String, _ action: Selector?, key: String = "", modifiers: NSEvent.ModifierFlags = [.command], enabled: Bool = true) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = target; item.isEnabled = enabled && action != nil; item.keyEquivalentModifierMask = modifiers
            menu.addItem(item); return item
        }
        func note(_ text: String) {
            let item = NSMenuItem(); item.isEnabled = false
            item.attributedTitle = NSAttributedString(string: text, attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor])
            menu.addItem(item)
        }

        if model.needsRecovery {
            header(menu, "Unfinished session found")
            _ = add("Restore Display", #selector(AppDelegate.restoreDisplay))
            _ = add("Continue Session", #selector(AppDelegate.resumeSession))
            menu.addItem(.separator())
        } else if let error = model.error {
            header(menu, "⚠︎ Something needs attention")
            let details = add(String(error.prefix(60)) + (error.count > 60 ? "…" : ""), #selector(AppDelegate.showError))
            details.toolTip = error
            _ = add("Restore Display", #selector(AppDelegate.restoreDisplay))
            menu.addItem(.separator())
        }

        let active = model.active
        let color = model.colorRemaining
        let loading = model.status == nil
        let focus = model.focus
        let state = focus.map { $0.phase == .focus ? "Focusing" : "Break, showing color" }
            ?? (active ? (color == nil ? "On" : "On, showing color") : "Off")
        header(menu, loading ? "E-Ink Mode" : "E-Ink Mode · \(state)")
        let shortcut = Shortcut.saved
        let toggle = add(active ? "Turn Off" : "Turn On", active ? #selector(AppDelegate.turnOff) : #selector(AppDelegate.turnOn),
                         key: shortcut?.key ?? "", modifiers: shortcut?.modifiers ?? [],
                         enabled: !loading && !model.needsRecovery && model.previewRemaining == nil)
        toggle.toolTip = active ? "Puts your display back exactly as it was." : nil
        if let focus {
            live.focus = add(focusLine(focus), nil)
            live.focus?.isEnabled = true
            if focus.phase == .rest { _ = add("Skip Break", #selector(AppDelegate.skipBreak)) }
            _ = add("Stop Focus Session", #selector(AppDelegate.stopFocus))
        } else if active, model.status?.configuration.grayscale == true {
            if let color {
                live.color = add("Resume grayscale · \(countdown(color)) remaining", #selector(AppDelegate.endColor))
            } else {
                _ = add("Color for 5 Minutes", #selector(AppDelegate.startColor))
            }
        }

        menu.addItem(.separator())
        if focus == nil {
            let settings = model.focusSettings
            _ = add("Start Focus · \(settings.sessions) × \(settings.focusMinutes) min", #selector(AppDelegate.startFocus),
                    enabled: !loading && !model.needsRecovery && model.previewRemaining == nil)
        }
        _ = add("Focus Stats…", #selector(AppDelegate.showStats))
        if let stats = model.stats {
            note("Today \(stats.today.completed) of \(stats.goal)" + (stats.streak > 0 ? " · \(stats.streak)-day streak" : ""))
        }

        menu.addItem(.separator())
        if let summary = model.schedule {
            let schedule = add("Schedule · \(summary.short)", nil)
            schedule.isEnabled = true
            schedule.submenu = scheduleMenu(model: model, summary: summary, target: target)
        }
        _ = add("Customize Appearance…", #selector(AppDelegate.customize))
        _ = add("Settings…", #selector(AppDelegate.openSettings), key: ",")
        if case .available(let release) = model.update {
            _ = add("Update Available: \(release.tagName)…", #selector(AppDelegate.installUpdate))
        }

        menu.addItem(.separator())
        if model.clickToFlip { note("Tip: click ◐ to switch · right-click for this menu") }
        _ = add("Quit and Restore Display", #selector(AppDelegate.quit), key: "q")
    }

    /// "Focus 2 of 4 · 18:32 left" or "Break · 4:12 left, then focus 3 of 4".
    static func focusLine(_ focus: FocusSession, now: Date = Date()) -> String {
        let left = countdown(focus.remaining(now: now))
        return focus.phase == .focus
            ? "Focus \(focus.round) of \(focus.rounds) · \(left) left"
            : "Break · \(left) left, then focus \(focus.round + 1) of \(focus.rounds)"
    }

    private static func header(_ menu: NSMenu, _ title: String) {
        let item = NSMenuItem(); item.isEnabled = false
        item.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.menuFont(ofSize: 0).bold, .foregroundColor: NSColor.labelColor])
        menu.addItem(item)
    }

    private static func scheduleMenu(model: AppModel, summary: ScheduleStatus, target: AnyObject) -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        let schedule = model.status?.configuration.schedule ?? Schedule()
        func add(_ title: String, _ action: Selector, checked: Bool) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = target; item.state = checked ? .on : .off; menu.addItem(item)
        }
        add("Off", #selector(AppDelegate.scheduleOff), checked: !schedule.enabled)
        add("Evening · 9:00 PM – 7:00 AM", #selector(AppDelegate.scheduleEvening), checked: schedule.enabled && schedule.isEvening)
        if !schedule.isEvening {
            add("Custom · \(Schedule.format(schedule.on)) – \(Schedule.format(schedule.off))", #selector(AppDelegate.scheduleCustom),
                checked: schedule.enabled)
        }
        menu.addItem(.separator())
        let detail = NSMenuItem(); detail.isEnabled = false
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byWordWrapping
        detail.attributedTitle = NSAttributedString(string: wrap(summary.detail, width: 46), attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph])
        menu.addItem(detail)
        menu.addItem(.separator())
        let edit = NSMenuItem(title: "Edit Schedule…", action: #selector(AppDelegate.editSchedule), keyEquivalent: "")
        edit.target = target; menu.addItem(edit)
        return menu
    }

    /// Menu items don't wrap on their own; break long explanations into lines.
    static func wrap(_ text: String, width: Int) -> String {
        var lines: [String] = [], line = ""
        for word in text.split(separator: " ") {
            if !line.isEmpty, line.count + word.count + 1 > width { lines.append(line); line = "" }
            line += (line.isEmpty ? "" : " ") + word
        }
        if !line.isEmpty { lines.append(line) }
        return lines.joined(separator: "\n")
    }
}

private extension NSFont {
    var bold: NSFont { NSFontManager.shared.convert(self, toHaveTrait: .boldFontMask) }
}
