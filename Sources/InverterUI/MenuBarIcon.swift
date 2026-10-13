import SwiftUI
import AppKit
import InverterCore

/// The menu bar glyph, the app icon in small: a sun rising over a sine wave. The sun shows while the
/// panels produce and gives way to a crescent moon otherwise; with no fresh reading the glyph is dimmed.
/// Motion, at a few frames a second and only for a moment after a new reading: the wave rolls along
/// and the rays twinkle. Drawn as a template image so macOS tints it for any menu bar.
public enum MenuBarIcon {
    public static let phases = 4

    /// Symbol-and-number pairs drawn as one template image, for two readings side by side
    /// ("☀ 3.42 kW  🔌 600 W"). Drawn black; macOS tints it for the menu bar like the glyph.
    public static func pairs(_ items: [(symbol: String, text: String)]) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let pieces = items.map { item in (symbol(item.symbol), NSAttributedString(string: item.text, attributes: attributes)) }
        let gap: CGFloat = 3, between: CGFloat = 9, height: CGFloat = 18
        let width = pieces.reduce(0) { $0 + ($1.0?.size.width ?? 0) + gap + ceil($1.1.size().width) }
            + between * CGFloat(max(0, pieces.count - 1))
        let image = NSImage(size: NSSize(width: ceil(width), height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for (symbol, text) in pieces {
                if let symbol {
                    symbol.draw(in: NSRect(x: x, y: (height - symbol.size.height) / 2, width: symbol.size.width, height: symbol.size.height))
                    x += symbol.size.width + gap
                }
                let size = text.size()
                text.draw(at: NSPoint(x: x, y: (height - size.height) / 2))
                x += ceil(size.width) + between
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// An SF Symbol at menu bar size, as a template image.
    public static func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        image?.isTemplate = true
        return image
    }

    /// `known` is false with no fresh reading; `phase` steps the motion (0 when still).
    public static func image(solar: Bool, known: Bool, phase: Int) -> NSImage {
        let size = NSSize(width: 20, height: 17)
        let image = NSImage(size: size, flipped: false) { _ in
            let ink = NSColor.black.withAlphaComponent(known ? 1 : 0.4)
            let step = CGFloat(phase % phases) / CGFloat(phases)   // 0…1 of one wave period

            // Wave along the bottom: two periods, rolling one period over the four phases.
            let wave = NSBezierPath()
            wave.lineWidth = 1.6
            wave.lineCapStyle = .round
            wave.lineJoinStyle = .round
            for index in 0...40 {
                let t = CGFloat(index) / 40
                let point = NSPoint(x: 1.5 + 17 * t, y: 4.2 + 2.2 * sin((t * 2 - step) * 2 * .pi))
                if index == 0 { wave.move(to: point) } else { wave.line(to: point) }
            }
            ink.setStroke()
            wave.stroke()

            // Above it: a rising sun while the panels produce, a crescent moon when they do not.
            let base: CGFloat = 8.8
            if solar && known {
                let center = NSPoint(x: size.width / 2, y: base)
                let r: CGFloat = 3.4
                let disc = NSBezierPath()
                disc.appendArc(withCenter: center, radius: r, startAngle: 0, endAngle: 180)
                disc.close()
                ink.setFill()
                disc.fill()
                let rays = NSBezierPath()
                rays.lineWidth = 1.2
                rays.lineCapStyle = .round
                for (index, degrees) in [20.0, 55, 90, 125, 160].enumerated() {
                    let angle = CGFloat(degrees) * .pi / 180
                    // Alternate rays stretch and relax in turn.
                    let pulse: CGFloat = phase > 0 && index % 2 == phase % 2 ? 0.7 : 0
                    let inner = r + 1.3, outer = r + 2.5 + pulse
                    rays.move(to: NSPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner))
                    rays.line(to: NSPoint(x: center.x + cos(angle) * outer, y: center.y + sin(angle) * outer))
                }
                rays.stroke()
            } else {
                // Crescent: a full disc with an offset disc cut out of its upper right.
                let r: CGFloat = 3.9, cut: CGFloat = 3.3
                let mid = CGPoint(x: size.width / 2, y: base + r - 0.4)
                let moon = CGPath(ellipseIn: CGRect(x: mid.x - r, y: mid.y - r, width: 2 * r, height: 2 * r), transform: nil)
                    .subtracting(CGPath(ellipseIn: CGRect(x: mid.x - cut + 2.2, y: mid.y - cut + 1.4,
                                                          width: 2 * cut, height: 2 * cut), transform: nil))
                let context = NSGraphicsContext.current!.cgContext
                context.addPath(moon)
                context.setFillColor(ink.cgColor)
                context.fillPath()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Inverterly"
        return image
    }
}
