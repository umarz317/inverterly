#if os(iOS)
import SwiftUI

/// Shown full screen, with no header or tab bar, until the first reading arrives. It uses the app
/// icon's navy and its sun and wave: the sun's rays pulse one after another and the wave runs along
/// beneath it, like power on a wire. The same screen as the Android app's.
struct LoadingScreen: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let navy = Color(red: 0x16 / 255, green: 0x26 / 255, blue: 0x3A / 255)
    private static let navyTop = Color(red: 0x22 / 255, green: 0x36 / 255, blue: 0x50 / 255)
    private static let sun = Color(red: 1, green: 0xD4 / 255, blue: 0x78 / 255)

    var body: some View {
        ZStack {
            LinearGradient(colors: [Self.navyTop, Self.navy], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 28) {
                TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion)) { timeline in
                    // With Reduce Motion the art rests on one fixed, mid-breath frame.
                    let time = reduceMotion ? 0.9 : timeline.date.timeIntervalSinceReferenceDate
                    Canvas { context, size in Self.draw(&context, size: size, time: time) }
                        .frame(width: 200, height: 200)
                }
                VStack(spacing: 6) {
                    Text("Reading your inverter")
                        .font(.title3.weight(.semibold)).foregroundStyle(.white)
                    RotatingLine()
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            }
        }
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Reading your inverter")
    }

    /// The artwork, drawn on the icon's 108 unit canvas scaled to `size`.
    private static func draw(_ context: inout GraphicsContext, size: CGSize, time: Double) {
        func fract(_ x: Double) -> Double { x - x.rounded(.down) }
        let u = size.width / 108
        // The ripple travels across the rays, the wave runs along, and the glow breathes in and out.
        let ripple = fract(time / 1.8)
        let wave = fract(time / 1.6) * 2 * .pi
        let half = fract(time / 3.6)
        let triangle = half < 0.5 ? half * 2 : (1 - half) * 2
        let breathe = triangle * triangle * (3 - 2 * triangle)

        let centre = CGPoint(x: 54 * u, y: (50 - 3 * breathe) * u)

        // Glow behind the sun that swells with the breath.
        let glow = CGRect(x: centre.x - 34 * u, y: centre.y - 34 * u, width: 68 * u, height: 68 * u)
        context.fill(Path(ellipseIn: glow),
                     with: .radialGradient(Gradient(colors: [sun.opacity(0.10 + 0.12 * breathe), .clear]),
                                           center: centre, startRadius: 0, endRadius: 34 * u))

        // Half sun: the top half of a circle, from the left edge over the top to the right edge.
        var sunPath = Path()
        sunPath.move(to: CGPoint(x: centre.x - 11 * u, y: centre.y))
        for step in 0...36 {
            let angle = Double.pi + Double.pi * Double(step) / 36
            sunPath.addLine(to: CGPoint(x: centre.x + 11 * u * cos(angle), y: centre.y + 11 * u * sin(angle)))
        }
        sunPath.closeSubpath()
        context.fill(sunPath, with: .color(sun))

        // Rays: each brightens and stretches as the ripple passes it.
        for (index, degrees) in [-160.0, -125, -90, -55, -20].enumerated() {
            let angle = degrees * .pi / 180
            let phase = fract(ripple - Double(index) / 5 + 1)
            let lit = pow(1 - min(phase * 2.2, 1), 2)
            let inner = (16 + 0.5 * lit) * u, outer = (23 + 3.5 * lit) * u
            var ray = Path()
            ray.move(to: CGPoint(x: centre.x + inner * cos(angle), y: centre.y + inner * sin(angle)))
            ray.addLine(to: CGPoint(x: centre.x + outer * cos(angle), y: centre.y + outer * sin(angle)))
            context.stroke(ray, with: .color(sun.opacity(0.45 + 0.55 * lit)), style: StrokeStyle(lineWidth: 3.4 * u, lineCap: .round))
        }

        // The wave runs left to right and fades out at both ends.
        let left = 28 * u, right = 80 * u, mid = 66 * u
        var wavePath = Path()
        var x = left
        while x <= right {
            let t = (x - left) / (right - left)
            let y = mid + sin(t * 4 * .pi - wave) * 5.2 * u
            if x == left { wavePath.move(to: CGPoint(x: x, y: y)) } else { wavePath.addLine(to: CGPoint(x: x, y: y)) }
            x += 1.5 * u
        }
        let fade = Gradient(stops: [.init(color: .white.opacity(0), location: 0), .init(color: .white, location: 1.0 / 3),
                                    .init(color: .white, location: 2.0 / 3), .init(color: .white.opacity(0), location: 1)])
        context.stroke(wavePath, with: .linearGradient(fade, startPoint: CGPoint(x: left, y: 0), endPoint: CGPoint(x: right, y: 0)),
                       style: StrokeStyle(lineWidth: 3.6 * u, lineCap: .round, lineJoin: .round))
    }
}

/// Said one after another under the title while the first reading is on its way.
private let lines = [
    "Getting the latest numbers",
    "Waking up the logger",
    "Asking the cloud nicely",
    "Checking on the sun",
    "Counting electrons",
    "Peeking at the battery",
    "Listening to the grid",
    "Almost there",
]

/// One line at a time, fading to the next every couple of seconds.
private struct RotatingLine: View {
    @State private var index = 0

    var body: some View {
        // Full width and centred, so a line longer or shorter than the last never sits off to one side mid-fade.
        ZStack {
            Text(lines[index] + "…")
                .id(index)
                .transition(.opacity)
        }
        .font(.subheadline).foregroundStyle(.white.opacity(0.6))
        .frame(maxWidth: .infinity)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2.4))
                // Stay on the last lines rather than loop back to "Getting the latest numbers".
                withAnimation(.easeInOut(duration: 0.5)) { index = index < lines.count - 1 ? index + 1 : 1 }
            }
        }
    }
}
#endif
