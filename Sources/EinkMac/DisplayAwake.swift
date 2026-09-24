import Foundation
import IOKit.pwr_mgt

/// Keeps the display from sleeping (and the screen saver from starting) while held.
///
/// This is a power assertion owned by the running process, not a saved system setting: macOS
/// drops it when E-Ink Mode quits or crashes, so this can never leave a Mac awake behind us.
/// Closing the lid or choosing Sleep still sleeps the Mac.
public final class DisplayAwake {
    public static let shared = DisplayAwake()
    private let simulated: Bool
    private var assertion: IOPMAssertionID = IOPMAssertionID(0)
    public private(set) var held = false

    public init(simulated: Bool = ProcessInfo.processInfo.environment["EINK_SIMULATED"] == "1") {
        self.simulated = simulated
    }

    /// Takes or drops the assertion. Returns a message to show the person if macOS refused; `nil` on success.
    /// Repeating the current state is a no-op, so one assertion is held at a time.
    @discardableResult
    public func hold(_ on: Bool, reason: String = "E-Ink Mode is keeping the display awake") -> String? {
        guard on != held else { return nil }
        guard !simulated else { held = on; return nil }
        if on {
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleDisplaySleep as CFString,
                                                     IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id)
            guard result == kIOReturnSuccess else { return "macOS wouldn't let E-Ink Mode keep the display awake." }
            assertion = id
        } else {
            IOPMAssertionRelease(assertion)
            assertion = IOPMAssertionID(0)
        }
        held = on
        return nil
    }
}
