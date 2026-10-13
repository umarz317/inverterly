import SwiftUI
import AppKit
import InverterCore

/// The menu bar glyph: a sun rising over a level bar. The bar is the battery's real state of
/// charge; the sun shows while the panels produce and gives way to a crescent moon otherwise. It is deliberately not
/// a battery outline, so it is never mistaken for the Mac's own battery beside it.
/// Motion, at a few frames a second and only while something is happening:
/// charging sweeps a lighter band from the charge level toward full, discharging makes the
/// leading edge of the fill breathe (both stay visible in the still frame), and solar production makes the rays twinkle.
/// Drawn as a template image so macOS tints it for any menu bar.
public enum MenuBarIcon {
    public static let phases = 4

    public enum Activity: Equatable { case idle, charging, discharging, unknown }

    public static func image(level: Double?, activity: Activity, solar: Bool, phase: Int) -> NSImage {
        let size = NSSize(width: 20, height: 17)
        let image = NSImage(size: size, flipped: false) { _ in
            let ink = NSColor.black
            let known = activity != .unknown
            let step = CGFloat(phase % phases) / CGFloat(phases - 1)   // 0…1

            // Level bar along the bottom: a faint track with a solid capsule for the charge.
            // No outline, so it never reads as a connector or as the Mac's own battery.
            let track = NSRect(x: 0.5, y: 0.5, width: 19, height: 6)
            let radius = track.height / 2
            func capsule(width: CGFloat, alpha: CGFloat) {
                guard width > 0.05 else { return }
                ink.withAlphaComponent(alpha).setFill()
                NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: width, height: track.height),
                             xRadius: radius, yRadius: radius).fill()
            }
            capsule(width: track.width, alpha: known ? 0.22 : 0.15)

            if let level, known {
                // Never narrower than a dot, so a nearly empty battery still reads.
                let filled = max(track.height, track.width * min(1, max(0, level)))
                switch activity {
                case .charging:
                    // A lighter band runs ahead of the charge, partly shown even when still,
                    // so charging is recognisable with animation off.
                    capsule(width: filled + (track.width - filled) * (0.35 + 0.65 * step), alpha: 0.5)
                    capsule(width: filled, alpha: 1)
                case .discharging:
                    // The leading edge of the fill fades, more or less in turn.
                    capsule(width: filled, alpha: 0.6 - 0.3 * step)
                    capsule(width: max(track.height, filled - min(3.4, filled / 2)), alpha: 1)
                default:
                    capsule(width: filled, alpha: 1)
                }
            }

            // Above the bar: a rising sun while the panels produce, a crescent moon when they do not.
            let alpha: CGFloat = known ? 1 : 0.4
            if solar && known {
                let center = NSPoint(x: size.width / 2, y: track.maxY + 1.4)
                let r: CGFloat = 3.9
                let disc = NSBezierPath()
                disc.appendArc(withCenter: center, radius: r, startAngle: 0, endAngle: 180)
                disc.close()
                ink.setFill()
                disc.fill()
                let rays = NSBezierPath()
                rays.lineWidth = 1.3
                rays.lineCapStyle = .round
                for index in 0..<5 {
                    let angle = CGFloat(index + 1) * .pi / 6        // 30, 60, 90, 120, 150 degrees
                    // Alternate rays stretch and relax in turn.
                    let pulse: CGFloat = index % 2 == phase % 2 ? 0.8 : 0
                    let inner = r + 1.5, outer = r + 2.8 + pulse
                    rays.move(to: NSPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner))
                    rays.line(to: NSPoint(x: center.x + cos(angle) * outer, y: center.y + sin(angle) * outer))
                }
                ink.setStroke()
                rays.stroke()
            } else {
                // Crescent: a full disc with an offset disc cut out of its upper right.
                let r: CGFloat = 4.3, cut: CGFloat = 3.6
                let mid = CGPoint(x: size.width / 2, y: track.maxY + 1.6 + r)
                let moon = CGPath(ellipseIn: CGRect(x: mid.x - r, y: mid.y - r, width: 2 * r, height: 2 * r), transform: nil)
                    .subtracting(CGPath(ellipseIn: CGRect(x: mid.x - cut + 2.4, y: mid.y - cut + 1.5,
                                                          width: 2 * cut, height: 2 * cut), transform: nil))
                let context = NSGraphicsContext.current!.cgContext
                context.addPath(moon)
                context.setFillColor(ink.withAlphaComponent(alpha).cgColor)
                context.fillPath()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Inverter"
        return image
    }
}
