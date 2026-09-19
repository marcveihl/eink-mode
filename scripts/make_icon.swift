// Draws the app icon (paper tile with a half-filled circle) into an .iconset folder.
import AppKit
let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
func draw(_ size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(size), inset = s * 0.1
    let tile = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shadow = NSShadow(); shadow.shadowBlurRadius = s * 0.02; shadow.shadowOffset = NSSize(width: 0, height: -s * 0.01)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3); shadow.set()
    NSColor(calibratedRed: 0.95, green: 0.94, blue: 0.91, alpha: 1).setFill()
    NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225).fill()
    NSShadow().set()
    let r = tile.width * 0.3, center = NSPoint(x: s / 2, y: s / 2)
    let circle = NSRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)
    let ink = NSColor(calibratedWhite: 0.13, alpha: 1)
    ink.setStroke()
    let ring = NSBezierPath(ovalIn: circle); ring.lineWidth = max(1, s * 0.03); ring.stroke()
    let half = NSBezierPath()
    half.move(to: NSPoint(x: center.x, y: center.y + r))
    half.appendArc(withCenter: center, radius: r, startAngle: 90, endAngle: 270)
    half.close(); ink.setFill(); half.fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
for base in [16, 32, 128, 256, 512] {
    try draw(base).write(to: output.appendingPathComponent("icon_\(base)x\(base).png"))
    try draw(base * 2).write(to: output.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
