import AppKit
import Carbon

/// A global shortcut choice. Presets avoid a key recorder while still letting people dodge collisions.
struct Shortcut: Identifiable {
    let id: String
    let keyCode: UInt32
    let carbonModifiers: UInt32
    let symbol: String
    let key: String
    let modifiers: NSEvent.ModifierFlags

    static let presets: [Shortcut] = [
        Shortcut(id: "cmd-shift-e", keyCode: UInt32(kVK_ANSI_E), carbonModifiers: UInt32(cmdKey | shiftKey), symbol: "⌘⇧E", key: "e", modifiers: [.command, .shift]),
        Shortcut(id: "ctrl-opt-cmd-e", keyCode: UInt32(kVK_ANSI_E), carbonModifiers: UInt32(controlKey | optionKey | cmdKey), symbol: "⌃⌥⌘E", key: "e", modifiers: [.control, .option, .command]),
        Shortcut(id: "ctrl-opt-e", keyCode: UInt32(kVK_ANSI_E), carbonModifiers: UInt32(controlKey | optionKey), symbol: "⌃⌥E", key: "e", modifiers: [.control, .option]),
        Shortcut(id: "ctrl-opt-cmd-g", keyCode: UInt32(kVK_ANSI_G), carbonModifiers: UInt32(controlKey | optionKey | cmdKey), symbol: "⌃⌥⌘G", key: "g", modifiers: [.control, .option, .command]),
    ]
    static let none = "none"
    static var saved: Shortcut? {
        let id = UserDefaults.standard.string(forKey: "shortcut") ?? presets[0].id
        return presets.first { $0.id == id }
    }
}

/// Owns the single Carbon hotkey registration.
final class HotkeyCenter {
    private var hotkey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    init(action: @escaping () -> Void) {
        self.action = action
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let center = Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { center.action() }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    /// Registers `shortcut` (or none) and returns a message describing the result.
    @discardableResult
    func register(_ shortcut: Shortcut?) -> String {
        if let hotkey { UnregisterEventHotKey(hotkey); self.hotkey = nil }
        guard let shortcut else { return "No keyboard shortcut. Use the menu bar icon." }
        let result = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, EventHotKeyID(signature: 0x45494E4B, id: 1),
                                         GetApplicationEventTarget(), 0, &hotkey)
        if result != noErr || handler == nil {
            hotkey = nil
            return "\(shortcut.symbol) is already taken by another app or macOS. Choose a different shortcut."
        }
        return "\(shortcut.symbol) switches E-Ink Mode from any app. If nothing happens, another app may be intercepting it — pick another."
    }
    func unregister() { if let hotkey { UnregisterEventHotKey(hotkey); self.hotkey = nil } }
}
