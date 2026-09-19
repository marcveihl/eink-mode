import AppKit

/// How shaded the menu bar icon is; both icon sets follow the same rule.
/// Unshaded: your screen is in color (off). Shaded: grayscale (on or focusing). Half: temporary color (peek or break).
enum IconShade {
    case unshaded, shaded, half
    /// The standard dot: ○ ● ◐
    var symbol: String {
        switch self { case .unshaded: return "circle"; case .shaded: return "circle.fill"; case .half: return "circle.lefthalf.filled" }
    }
    var wildcat: WildcatIcon.Style {
        switch self { case .unshaded: return .outline; case .shaded: return .filled; case .half: return .half }
    }
}

/// Wildcat mode: an original wildcat-head menu bar icon (not official mascot artwork).
enum WildcatIcon {
    enum Style { case outline, filled, half }

    static func image(_ style: Style, size: CGFloat = 18, accessibility: String) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            draw(style, in: rect); return true
        }
        image.isTemplate = true // adapts to light/dark menu bars and highlight states
        image.accessibilityDescription = accessibility
        return image
    }

    /// Draws in a 100×100 design space (y down), scaled to `rect`.
    static func draw(_ style: Style, in rect: NSRect, color: NSColor = .black) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: rect.width / 100, y: rect.height / 100)
        color.setFill(); color.setStroke()

        let head = polygon([(20, 6), (39, 25), (50, 23), (61, 25), (80, 6), (86, 37), (96, 50), (87, 57), (93, 70),
                            (77, 75), (62, 93), (50, 96), (38, 93), (23, 75), (7, 70), (13, 57), (4, 50), (14, 37)])
        let innerEars = [polygon([(23, 15), (35, 28), (19, 35)]), polygon([(77, 15), (65, 28), (81, 35)])]
        // Slanted, fierce eyes.
        let eyes = [polygon([(24, 46), (44, 52), (41, 58), (29, 56)]), polygon([(76, 46), (56, 52), (59, 58), (71, 56)])]
        let nose = polygon([(42, 64), (58, 64), (50, 73)])
        let stripes = [polygon([(47, 27), (53, 27), (50, 42)]), polygon([(38, 30), (43, 29), (42, 40)]),
                       polygon([(62, 30), (57, 29), (58, 40)])]
        let mouth = NSBezierPath()
        mouth.move(to: NSPoint(x: 50, y: 73)); mouth.line(to: NSPoint(x: 50, y: 79))
        mouth.move(to: NSPoint(x: 40, y: 82)); mouth.curve(to: NSPoint(x: 50, y: 79), controlPoint1: NSPoint(x: 44, y: 84), controlPoint2: NSPoint(x: 48, y: 82))
        mouth.curve(to: NSPoint(x: 60, y: 82), controlPoint1: NSPoint(x: 52, y: 82), controlPoint2: NSPoint(x: 56, y: 84))
        mouth.lineCapStyle = .round

        switch style {
        case .half:
            context.restoreGState()
            draw(.outline, in: rect, color: color)
            // Shade the left half solid, matching the half-filled dot.
            context.saveGState()
            context.clip(to: NSRect(x: rect.minX, y: rect.minY, width: rect.width / 2, height: rect.height))
            draw(.filled, in: rect, color: color)
            context.restoreGState()
            return
        case .filled:
            head.fill()
            // Knock the features out of the solid head so it reads as a face at 18 pt.
            context.setBlendMode(.destinationOut)
            (innerEars + eyes + stripes + [nose]).forEach { $0.fill() }
            mouth.lineWidth = 5; mouth.stroke()
            context.setBlendMode(.normal)
        case .outline:
            head.lineWidth = 7; head.lineJoinStyle = .round
            head.stroke()
            (eyes + stripes + [nose]).forEach { $0.fill() }
            mouth.lineWidth = 4.5; mouth.stroke()
        }
        context.restoreGState()
    }

    private static func polygon(_ points: [(CGFloat, CGFloat)]) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: points[0].0, y: points[0].1))
        points.dropFirst().forEach { path.line(to: NSPoint(x: $0.0, y: $0.1)) }
        path.close()
        return path
    }
}
