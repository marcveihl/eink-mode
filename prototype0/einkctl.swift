// einkctl — runtime display toggles for E-Ink Mode Prototype 0.
//
// Uses private-but-stable system APIs resolved at runtime via dlsym, so there is
// no link-time dependency and a missing symbol degrades to a clear error instead
// of a crash on launch.
//
//   grayscale : UAGrayscaleSetEnabled / UAGrayscaleIsEnabled     (UniversalAccess)
//   invert    : UAInvertColorsUserInitiatedSetEnabled            (UniversalAccess)
//   brightness: DisplayServicesGet/SetBrightness                 (DisplayServices)
//
// NOTE: CGDisplayForceToGray was tried first and is a no-op on macOS 15 / Apple
// Silicon -- it stores a flag that CGDisplayUsesForceToGray reads straight back,
// so it round-trips perfectly while changing nothing on screen. Verify grayscale
// with your eyes, never with that pair. UAGrayscaleSetEnabled is what System
// Settings drives and it does affect real pixels.

import Foundation
import CoreGraphics

let RTLD_DEFAULT_PTR = UnsafeMutableRawPointer(bitPattern: -2)

@discardableResult
func loadFramework(_ path: String) -> Bool { dlopen(path, RTLD_NOW) != nil }

loadFramework("/System/Library/PrivateFrameworks/UniversalAccess.framework/UniversalAccess")
loadFramework("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices")

typealias SetBoolFn    = @convention(c) (Bool) -> Void
typealias GetBoolFn    = @convention(c) () -> Bool
typealias GetBrightFn  = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
typealias SetBrightFn  = @convention(c) (UInt32, Float) -> Int32

func sym(_ name: String) -> UnsafeMutableRawPointer? { dlsym(RTLD_DEFAULT_PTR, name) }

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(("einkctl: " + msg + "\n").data(using: .utf8)!)
    exit(1)
}

// MARK: - grayscale

func grayscaleGet() -> Bool {
    guard let p = sym("UAGrayscaleIsEnabled") else { die("grayscale API unavailable") }
    return unsafeBitCast(p, to: GetBoolFn.self)()
}

func grayscaleSet(_ on: Bool) {
    guard let p = sym("UAGrayscaleSetEnabled") else { die("grayscale API unavailable") }
    unsafeBitCast(p, to: SetBoolFn.self)(on)
}

// MARK: - invert  (TABLED -- kept only so `off` can guarantee it is cleared)
//
// UAWhiteOnBlackSetEnabled looks right and does nothing; the working symbol is
// UAInvertColorsUserInitiatedSetEnabled. There is no matching getter, so state
// is write-only: invertGet() always reports false and `off` clears
// unconditionally. Good enough to never strand the screen inverted.

func invertGet() -> Bool { false }

func invertSet(_ on: Bool) {
    guard let p = sym("UAInvertColorsUserInitiatedSetEnabled") else { return }
    unsafeBitCast(p, to: SetBoolFn.self)(on)
}

// MARK: - brightness

func activeDisplays() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    guard count > 0 else { return [] }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)
    return Array(ids.prefix(Int(count)))
}

/// Returns brightness of the main display, or nil if it cannot be read
/// (common for external monitors, which need DDC/CI rather than DisplayServices).
func brightnessGet() -> Float? {
    guard let p = sym("DisplayServicesGetBrightness") else { return nil }
    var value: Float = 0
    let err = unsafeBitCast(p, to: GetBrightFn.self)(CGMainDisplayID(), &value)
    return err == 0 ? value : nil
}

/// Applies to every display that accepts it. Returns the number that took it.
@discardableResult
func brightnessSet(_ value: Float) -> Int {
    guard let p = sym("DisplayServicesSetBrightness") else { die("brightness API unavailable") }
    let fn = unsafeBitCast(p, to: SetBrightFn.self)
    let clamped = min(max(value, 0.0), 1.0)
    return activeDisplays().filter { fn($0, clamped) == 0 }.count
}

// MARK: - CLI

func boolArg(_ s: String?) -> Bool? {
    switch s {
    case "on", "true", "1", "yes":  return true
    case "off", "false", "0", "no": return false
    default: return nil
    }
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    print("""
    usage: einkctl <command>

      gray  [get|on|off|toggle]
      invert[get|on|off|toggle]
      brightness [get|set <0.0-1.0>]
      state                          all three, shell-eval friendly
    """)
    exit(0)
}
let arg = args.count > 1 ? args[1] : nil

switch command {
case "gray", "grayscale":
    if arg == nil || arg == "get" { print(grayscaleGet() ? "on" : "off") }
    else if arg == "toggle"       { grayscaleSet(!grayscaleGet()) }
    else if let v = boolArg(arg)  { grayscaleSet(v) }
    else { die("gray: expected get|on|off|toggle") }

case "invert":
    if arg == nil || arg == "get" { print(invertGet() ? "on" : "off") }
    else if arg == "toggle"       { invertSet(!invertGet()) }
    else if let v = boolArg(arg)  { invertSet(v) }
    else { die("invert: expected get|on|off|toggle") }

case "brightness":
    if arg == nil || arg == "get" {
        guard let b = brightnessGet() else { die("brightness unreadable (external display?)") }
        print(String(format: "%.4f", b))
    } else if arg == "set" {
        guard args.count > 2, let v = Float(args[2]) else { die("brightness set: expected 0.0-1.0") }
        let n = brightnessSet(v)
        if n == 0 { die("no display accepted the brightness change") }
    } else { die("brightness: expected get|set <0.0-1.0>") }

case "state":
    // Emitted as shell assignments so the wrapper can `eval` this directly.
    print("GRAY=\(grayscaleGet() ? "on" : "off")")
    print("INVERT=\(invertGet() ? "on" : "off")")
    print("BRIGHTNESS=\(brightnessGet().map { String(format: "%.4f", $0) } ?? "")")

default:
    die("unknown command '\(command)'")
}
