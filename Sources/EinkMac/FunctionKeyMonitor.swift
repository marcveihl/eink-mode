import Foundation
import CoreGraphics

/// Reads only the Fn modifier state; it does not intercept keys or replace macOS's Globe action.
public final class FunctionKeyMonitor {
    private let readState: () -> Bool
    private let onPress: () -> Void
    private let onRelease: () -> Void
    private var timer: Timer?
    private var wasDown = false

    public static var isDown: Bool {
        CGEventSource.flagsState(.hidSystemState).contains(.maskSecondaryFn)
    }

    public init(readState: @escaping () -> Bool = { FunctionKeyMonitor.isDown },
                onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
        self.readState = readState
        self.onPress = onPress
        self.onRelease = onRelease
    }

    public func start() {
        stop()
        // Enabling the option while Fn is held must wait for a fresh press.
        wasDown = readState()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.poll() }
        timer.tolerance = 0.01
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func poll() {
        let down = readState()
        guard down != wasDown else { return }
        wasDown = down
        if down { onPress() } else { onRelease() }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        if wasDown { wasDown = false; onRelease() }
    }

    deinit { timer?.invalidate() }
}
