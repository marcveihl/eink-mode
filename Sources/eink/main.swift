import Foundation
import EinkCore
import EinkMac

func boolean(_ value: String) throws -> Bool {
    switch value { case "on", "true", "yes": return true; case "off", "false", "no": return false
    default: throw EinkError.message("Expected on or off.") }
}
let usage = """
E-Ink Mode
  eink on | off | toggle | status | resume | tick
  eink config                         show configuration
  eink set grayscale on|off
  eink set brightness 5..100|unchanged
  eink set dock|motion|transparency on|off
  eink set schedule on|off
  eink set schedule-on|schedule-off HH:MM

Schedule runs while the menu bar app is open (enable Launch at login for daily use).
EINK_HOME selects an isolated config/state directory; EINK_SIMULATED=1 enables safe simulation.
"""
do {
    let args = Array(CommandLine.arguments.dropFirst())
    let command = args.first ?? "status"
    if ["help", "--help", "-h"].contains(command) { print(usage); exit(0) }
    let controller = try EinkEnvironment.makeController()
    if !["status", "config"].contains(command) { try EinkEnvironment.checkLegacy() }
    switch command {
    case "on": try controller.setMode(true)
    case "off": try controller.setMode(false)
    case "toggle": try controller.toggle()
    case "resume": try controller.resume()
    case "tick": try controller.tick()
    case "status": break
    case "config":
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(controller.status().configuration), as: UTF8.self)); exit(0)
    case "set":
        guard args.count == 3 else { throw EinkError.message(usage) }
        try controller.edit { config in
        switch args[1] {
        case "grayscale": config.grayscale = try boolean(args[2])
        case "brightness":
            if args[2] == "unchanged" { config.brightness = nil }
            else if let number = Double(args[2]) { config.brightness = number / 100 }
            else { throw EinkError.message("Brightness needs a percentage or unchanged.") }
        case "dock": config.hideDock = try boolean(args[2])
        case "motion": config.reduceMotion = try boolean(args[2])
        case "transparency": config.reduceTransparency = try boolean(args[2])
        case "schedule": config.schedule.enabled = try boolean(args[2])
        case "schedule-on": config.schedule.on = try Schedule.parse(args[2])
        case "schedule-off": config.schedule.off = try Schedule.parse(args[2])
        default: throw EinkError.message(usage)
        }
        }
    default: throw EinkError.message(usage)
    }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    do { print(String(decoding: try encoder.encode(controller.status()), as: UTF8.self)) }
    catch {
        if command == "off" { print("Display restored. Status unavailable: \(error.localizedDescription)") }
        else { throw error }
    }
} catch {
    FileHandle.standardError.write(Data("eink: \(error.localizedDescription)\n".utf8)); exit(1)
}
