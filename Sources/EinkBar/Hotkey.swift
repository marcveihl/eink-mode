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
    static let functionKeyID = "fn-globe"
    static let holdPresets: [Shortcut] = [
        Shortcut(id: "ctrl-opt-cmd-c", keyCode: UInt32(kVK_ANSI_C), carbonModifiers: UInt32(controlKey | optionKey | cmdKey), symbol: "⌃⌥⌘C", key: "c", modifiers: [.control, .option, .command]),
        Shortcut(id: "ctrl-opt-cmd-h", keyCode: UInt32(kVK_ANSI_H), carbonModifiers: UInt32(controlKey | optionKey | cmdKey), symbol: "⌃⌥⌘H", key: "h", modifiers: [.control, .option, .command]),
        Shortcut(id: "ctrl-opt-shift-c", keyCode: UInt32(kVK_ANSI_C), carbonModifiers: UInt32(controlKey | optionKey | shiftKey), symbol: "⌃⌥⇧C", key: "c", modifiers: [.control, .option, .shift]),
        Shortcut(id: functionKeyID, keyCode: UInt32(kVK_Function), carbonModifiers: 0, symbol: "Fn / 🌐 Globe", key: "", modifiers: [.function]),
    ]
    static var saved: Shortcut? {
        let id = UserDefaults.standard.string(forKey: "shortcut") ?? presets[0].id
        return presets.first { $0.id == id }
    }
}

/// Owns one Carbon hotkey registration, including its release event for momentary actions.
final class HotkeyCenter {
    private var hotkey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let identifier: UInt32
    private let onPress: () -> Void
    private let onRelease: () -> Void
    init(identifier: UInt32 = 1, onPress: @escaping () -> Void, onRelease: @escaping () -> Void = {}) {
        self.identifier = identifier; self.onPress = onPress; self.onRelease = onRelease
        var events = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                      EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData, let event else { return OSStatus(eventNotHandledErr) }
            let center = Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
            var hotkeyID = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hotkeyID)
            guard result == noErr, hotkeyID.signature == 0x45494E4B, hotkeyID.id == center.identifier else { return OSStatus(eventNotHandledErr) }
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            DispatchQueue.main.async { if pressed { center.onPress() } else { center.onRelease() } }
            return noErr
        }, events.count, &events, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    /// Registers `shortcut` (or none) and returns a message describing the result.
    @discardableResult
    func register(_ shortcut: Shortcut?) -> String {
        if let hotkey { UnregisterEventHotKey(hotkey); self.hotkey = nil }
        guard let shortcut else { return "No keyboard shortcut. Use the menu bar icon." }
        let result = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, EventHotKeyID(signature: 0x45494E4B, id: identifier),
                                         GetApplicationEventTarget(), 0, &hotkey)
        if result != noErr || handler == nil {
            hotkey = nil
            return "\(shortcut.symbol) is already taken by another app or macOS. Choose a different shortcut."
        }
        return "\(shortcut.symbol) switches E-Ink Mode from any app. If nothing happens, another app may be intercepting it — pick another."
    }
    func unregister() { if let hotkey { UnregisterEventHotKey(hotkey); self.hotkey = nil } }
}
