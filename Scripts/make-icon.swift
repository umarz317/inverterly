// Draws the app icon (a sun rising over a level bar) into an .iconset folder.
//   swift Scripts/make-icon.swift <out.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset", isDirectory: true)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func draw(_ pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let s = CGFloat(pixels) / 1024

    // macOS icon grid: an 824 pt rounded square centred on a 1024 pt canvas.
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(colors: [NSColor(red: 0.16, green: 0.23, blue: 0.33, alpha: 1), NSColor(red: 0.06, green: 0.09, blue: 0.14, alpha: 1)])?
        .draw(in: shape, angle: -90)

    // Warm glow behind the sun, kept inside the tile.
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    let centre = NSPoint(x: 512 * s, y: 500 * s)
    NSGradient(colors: [NSColor(red: 1, green: 0.78, blue: 0.36, alpha: 0.42), NSColor(red: 1, green: 0.78, blue: 0.36, alpha: 0)])?
        .draw(fromCenter: centre, radius: 0, toCenter: centre, radius: 360 * s, options: [])
    NSGraphicsContext.restoreGraphicsState()

    let sun = NSColor(red: 1, green: 0.80, blue: 0.40, alpha: 1)
    let disc = NSBezierPath()
    disc.appendArc(withCenter: centre, radius: 118 * s, startAngle: 0, endAngle: 180)
    disc.close()
    sun.setFill()
    disc.fill()
    let rays = NSBezierPath()
    rays.lineWidth = 40 * s
    rays.lineCapStyle = .round
    for index in 0..<5 {
        let angle = CGFloat(index) * .pi / 4
        rays.move(to: NSPoint(x: centre.x + cos(angle) * 178 * s, y: centre.y + sin(angle) * 178 * s))
        rays.line(to: NSPoint(x: centre.x + cos(angle) * 246 * s, y: centre.y + sin(angle) * 246 * s))
    }
    sun.setStroke()
    rays.stroke()

    // Level bar: outline and a fill at about two thirds.
    let track = NSRect(x: 232 * s, y: 286 * s, width: 560 * s, height: 150 * s)
    let outline = NSBezierPath(roundedRect: track, xRadius: 75 * s, yRadius: 75 * s)
    outline.lineWidth = 34 * s
    NSColor.white.withAlphaComponent(0.95).setStroke()
    outline.stroke()
    let well = track.insetBy(dx: 48 * s, dy: 48 * s)
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: well, xRadius: well.height / 2, yRadius: well.height / 2).addClip()
    NSColor.white.setFill()
    NSRect(x: well.minX, y: well.minY, width: well.width * 0.68, height: well.height).fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    guard let data = draw(points * scale) else { print("could not draw \(name)"); exit(1) }
    try data.write(to: out.appendingPathComponent(name))
}
print("wrote \(out.path)")
