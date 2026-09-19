import AppKit

/// Launch-time housekeeping: one running copy, living in Applications.
enum Installation {
    static let showMenuNotification = Notification.Name("local.eink.mode.showMenu")

    private static func version(of url: URL?) -> String {
        url.flatMap(Bundle.init(url:))?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    /// Returns false when this process should exit because another copy keeps running.
    static func resolveRunningCopies() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return true }
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id).filter { $0.processIdentifier != me }
        guard let other = others.first else { return true }
        let mine = Bundle.main.bundleURL.standardizedFileURL
        let theirs = other.bundleURL?.standardizedFileURL
        let myVersion = version(of: mine), theirVersion = version(of: theirs)
        if theirs == mine || myVersion == theirVersion {
            // Opening the app again just reveals the copy that is already in the menu bar.
            DistributedNotificationCenter.default().postNotificationName(showMenuNotification, object: nil, deliverImmediately: true)
            return false
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Another copy of E-Ink Mode is running"
        alert.informativeText = """
        Running: version \(theirVersion)
        \(theirs?.path ?? "unknown location")

        You opened: version \(myVersion)
        \(mine.path)

        Switching quits the running copy first, which restores your display.
        """
        alert.addButton(withTitle: "Use Version \(myVersion)")
        alert.addButton(withTitle: "Keep Version \(theirVersion)")
        guard alert.runModal() == .alertFirstButtonReturn else {
            DistributedNotificationCenter.default().postNotificationName(showMenuNotification, object: nil, deliverImmediately: true)
            return false
        }
        others.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(10)
        while others.contains(where: { !$0.isTerminated }) && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        if others.contains(where: { !$0.isTerminated }) {
            let failed = NSAlert()
            failed.messageText = "The running copy didn't quit"
            failed.informativeText = "It may still be restoring your display. Choose Quit and Restore Display from its menu bar icon, then open this copy again."
            failed.runModal()
            return false
        }
        return true
    }

    /// Offers to move a copy running from Downloads (or elsewhere) into Applications. Returns false when relaunching.
    static func offerMoveToApplications() -> Bool {
        let bundle = Bundle.main.bundleURL
        let path = bundle.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard bundle.pathExtension == "app",
              !path.hasPrefix("/Applications/"), !path.hasPrefix(home + "/Applications/"),
              !UserDefaults.standard.bool(forKey: "declinedMove") else { return true }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Move E-Ink Mode to your Applications folder?"
        alert.informativeText = "It's running from \(bundle.deletingLastPathComponent().path). Launch at login and automatic updates work reliably only from Applications."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else { UserDefaults.standard.set(true, forKey: "declinedMove"); return true }
        if path.contains("/AppTranslocation/") {
            explain("macOS opened this copy from a protected temporary location, so it can't move itself. In Finder, drag E-Ink Mode into Applications, then open it from there.")
            return true
        }
        for folder in ["/Applications", home + "/Applications"] {
            let destination = URL(fileURLWithPath: folder).appendingPathComponent(bundle.lastPathComponent)
            do {
                try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.trashItem(at: destination, resultingItemURL: nil)
                }
                try FileManager.default.moveItem(at: bundle, to: destination)
                try Updater.relaunch(replacing: destination, with: nil)
                return false
            } catch { continue }
        }
        explain("E-Ink Mode couldn't move itself. In Finder, drag it into Applications, then open it from there.")
        return true
    }

    private static func explain(_ text: String) {
        let alert = NSAlert(); alert.messageText = "Move E-Ink Mode manually"; alert.informativeText = text; alert.runModal()
    }
}
