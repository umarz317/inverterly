import SwiftUI
import AppKit
import InverterCore

/// The menu bar glyph: a sun rising over a level bar. The bar is the battery's real state of
/// charge; the sun is bright while the panels produce and faint at night. It is deliberately not
/// a battery outline, so it is never mistaken for the Mac's own battery beside it.
/// Motion, at a few frames a second and only while something is happening:
/// charging sweeps a lighter band from the charge level toward full, discharging makes the
/// leading edge of the fill breathe, and solar production makes the rays twinkle.
/// Drawn as a template image so macOS tints it for any menu bar.
public enum MenuBarIcon {
    public static let phases = 4

    public enum Activity: Equatable { case idle, charging, discharging, unknown }

    public static func image(level: Double?, activity: Activity, solar: Bool, phase: Int) -> NSImage {
        let size = NSSize(width: 23, height: 17)
        let image = NSImage(size: size, flipped: false) { _ in
            let ink = NSColor.black
            let known = activity != .unknown
            let step = CGFloat(phase % phases) / CGFloat(phases - 1)   // 0…1

            // Level bar along the bottom.
            let track = NSRect(x: 0.75, y: 0.75, width: 21.5, height: 6.5)
            let shell = NSBezierPath(roundedRect: track, xRadius: 3.25, yRadius: 3.25)
            shell.lineWidth = 1.2
            ink.withAlphaComponent(known ? 0.9 : 0.4).setStroke()
            shell.stroke()

            if let level, known {
                let well = track.insetBy(dx: 1.9, dy: 1.9)
                let filled = max(1.4, well.width * min(1, max(0, level)))
                func bar(from x: CGFloat, width: CGFloat, alpha: CGFloat) {
                    guard width > 0.05 else { return }
                    NSGraphicsContext.saveGraphicsState()
                    NSBezierPath(roundedRect: well, xRadius: 1.35, yRadius: 1.35).addClip()
                    ink.withAlphaComponent(alpha).setFill()
                    NSRect(x: well.minX + x, y: well.minY, width: width, height: well.height).fill()
                    NSGraphicsContext.restoreGraphicsState()
                }
                switch activity {
                case .charging:
                    bar(from: 0, width: filled, alpha: 1)
                    bar(from: filled, width: (well.width - filled) * step, alpha: 0.4)
                case .discharging:
                    let tip = min(filled, 3.2)
                    bar(from: 0, width: filled - tip, alpha: 1)
                    bar(from: filled - tip, width: tip, alpha: 1 - 0.65 * step)
                default:
                    bar(from: 0, width: filled, alpha: 1)
                }
            }

            // Half sun sitting on the bar.
            let center = NSPoint(x: size.width / 2, y: track.maxY + 2.1)
            let sunAlpha: CGFloat = !known ? 0.3 : solar ? 0.95 : 0.36
            let disc = NSBezierPath()
            disc.appendArc(withCenter: center, radius: 3.0, startAngle: 0, endAngle: 180)
            disc.close()
            ink.withAlphaComponent(sunAlpha).setFill()
            disc.fill()

            let rays = NSBezierPath()
            rays.lineWidth = 1.2
            rays.lineCapStyle = .round
            for index in 0..<5 {
                let angle = CGFloat(index) * .pi / 4            // 0, 45, 90, 135, 180 degrees
                // While producing, alternate rays stretch and relax in turn.
                let pulse: CGFloat = solar && known ? (index % 2 == phase % 2 ? 0.9 : 0) : 0
                let inner: CGFloat = 4.6, outer: CGFloat = 6.0 + pulse
                rays.move(to: NSPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner))
                rays.line(to: NSPoint(x: center.x + cos(angle) * outer, y: center.y + sin(angle) * outer))
            }
            ink.withAlphaComponent(sunAlpha).setStroke()
            rays.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Inverter"
        return image
    }
}
