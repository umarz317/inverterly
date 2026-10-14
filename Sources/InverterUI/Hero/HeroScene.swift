import SwiftUI
import InverterCore

/// "Scene" hero: a small side-view landscape in hairlines. A house with a solar array on its roof,
/// a sun that climbs with PV power (a moon and stars at night, a cloud on a day with no PV), a utility
/// pole whose service wire reaches the inverter on the house wall, and a battery cabinet beside it.
/// Energy runs along the wires as comets, from source to sink, faster and denser with power.
///
/// A pure function of `(frame, now)`: no state, no timers. Read-only, like everything else here.
struct HeroScene: View {
    let frame: HeroFrame
    let now: Date
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Canvas { canvas, size in
            ScenePainter(frame: frame, now: now, dark: colorScheme == .dark).draw(canvas, size: size)
        }
    }
}

// MARK: - Motion

/// How one power level looks on a wire. Everything follows from the watts alone, so a steady stream
/// can be drawn for any instant without knowing its history.
private struct Pace {
    let presence: Double    // soft 0…1 over the first few watts
    let level: Double       // 0…1, close to linear in watts (the shared intensity is logarithmic)
    let alpha: Double
    let speed: Double       // points per second
    let gap: Double         // points between comet heads
    let body: Double        // comet length
    let width: CGFloat

    /// Comets per second. A stream's phase is `rate × absolute time`, which is what keeps it stateless.
    var rate: Double { speed / gap }

    init(watts: Double) {
        let magnitude = abs(watts)
        let intensity = HeroMath.intensity(magnitude)
        presence = min(1, magnitude / 30)
        level = pow(intensity, 2.5)
        alpha = presence * (0.42 + 0.58 * intensity)
        speed = 12 + 40 * level
        gap = 34 - 19 * level
        body = 7.5 + 4.5 * level
        width = 1.25 + 0.55 * level
    }
}

/// One steady stream of comets and how much of it to show right now.
private struct Train {
    let pace: Pace
    let forward: Bool       // false only for the battery discharging
    let weight: Double      // 0…1
    let reveal: Double      // below 1 while a new flow is still reaching along its wire
    let clear: Double       // above 0 while a dying flow drains out toward its sink
}

/// One of the four flows during a change. Comet positions depend on how long a flow has run at its
/// speed, which a stateless hero cannot know, so a change is drawn as two steady streams: the previous
/// one fading out and the new one fading in over the ramp. Nothing jumps when a reading arrives. A
/// battery that changes direction fades out completely before the opposite stream starts.
private struct Flow {
    let presence: Double    // soft 0…1 for the eased power: static parts (wires, windows, array) follow this
    let level: Double       // 0…1 for the eased power
    let trains: [Train]

    init(previous: Double, target: Double, eased: Double) {
        let pace = Pace(watts: previous + (target - previous) * eased)
        presence = pace.presence
        level = pace.level

        let had = abs(previous) > 1, has = abs(target) > 1
        let flips = had && has && (previous > 0) != (target > 0)
        var old = 1 - eased, new = eased
        if flips {
            let cross = abs(previous) / (abs(previous) + abs(target))    // where the eased watts pass zero
            old = max(0, 1 - eased / cross)
            new = max(0, (eased - cross) / (1 - cross))
        }
        var trains: [Train] = []
        if had, old > 0.004 {
            trains.append(Train(pace: Pace(watts: previous), forward: previous > 0, weight: old, reveal: 1,
                                clear: !has || flips ? 1 - old : 0))
        }
        if has, new > 0.004 {
            trains.append(Train(pace: Pace(watts: target), forward: target > 0, weight: new,
                                reveal: !had || flips ? new : 1, clear: 0))
        }
        self.trains = trains
    }

    /// 0…1 for how much is being delivered in one direction (the arrowhead at that end).
    func delivery(forward: Bool = true) -> Double {
        min(1, trains.reduce(0) { $0 + ($1.forward == forward ? $1.weight * $1.pace.alpha : 0) })
    }
}

/// A polyline with cumulative lengths, so a comet can be cut out of it by distance.
private struct Route: Sendable {
    let points: [CGPoint]
    let marks: [CGFloat]

    var length: CGFloat { marks.last ?? 0 }

    init(_ points: [CGPoint]) {
        self.points = points
        var total: CGFloat = 0
        var marks: [CGFloat] = []
        marks.reserveCapacity(points.count)
        for index in points.indices {
            if index > 0 { total += hypot(points[index].x - points[index - 1].x, points[index].y - points[index - 1].y) }
            marks.append(total)
        }
        self.marks = marks
    }

    var reversed: Route { Route(points.reversed()) }

    var path: Path { path(from: 0, to: length) }

    func point(at distance: CGFloat) -> CGPoint {
        guard points.count > 1 else { return points.first ?? .zero }
        let d = min(max(distance, 0), length)
        var index = 1
        while index < points.count - 1 && marks[index] < d { index += 1 }
        let span = marks[index] - marks[index - 1]
        let t = span > 0 ? (d - marks[index - 1]) / span : 0
        let a = points[index - 1], b = points[index]
        return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    func path(from start: CGFloat, to end: CGFloat) -> Path {
        var path = Path()
        path.move(to: point(at: start))
        for index in points.indices where marks[index] > start && marks[index] < end { path.addLine(to: points[index]) }
        path.addLine(to: point(at: end))
        return path
    }

    /// Straight runs joined by rounded corners.
    static func rounded(_ corners: [CGPoint], radius: CGFloat) -> Route {
        guard corners.count > 2 else { return Route(corners) }
        var out: [CGPoint] = [corners[0]]
        for index in 1..<(corners.count - 1) {
            let a = corners[index - 1], b = corners[index], c = corners[index + 1]
            let inLength = hypot(a.x - b.x, a.y - b.y), outLength = hypot(c.x - b.x, c.y - b.y)
            let r = min(radius, inLength / 2, outLength / 2)
            let enter = CGPoint(x: b.x + (a.x - b.x) / inLength * r, y: b.y + (a.y - b.y) / inLength * r)
            let leave = CGPoint(x: b.x + (c.x - b.x) / outLength * r, y: b.y + (c.y - b.y) / outLength * r)
            for step in 0...6 {
                let t = CGFloat(step) / 6, u = 1 - t
                out.append(CGPoint(x: u * u * enter.x + 2 * u * t * b.x + t * t * leave.x,
                                   y: u * u * enter.y + 2 * u * t * b.y + t * t * leave.y))
            }
        }
        out.append(corners[corners.count - 1])
        return Route(out)
    }

    /// A wire hanging between two points.
    static func hanging(from a: CGPoint, to b: CGPoint, sag: CGFloat, steps: Int = 18) -> Route {
        Route((0...steps).map { step in
            let t = CGFloat(step) / CGFloat(steps)
            return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t + sag * 4 * t * (1 - t))
        })
    }
}

/// A piece of moving energy: one stroke, brightest at its head and fading to nothing at its tail.
private struct Comet {
    let path: Path
    let tail: CGPoint
    let head: CGPoint
    let tailAlpha: Double
    let midAlpha: Double
    let headAlpha: Double
    let color: Color
    let width: CGFloat
    let glow: Double        // 0 = none
}

// MARK: - Painter

private struct ScenePainter {
    static let design = CGSize(width: 348, height: 180)

    // Layout, in design points.
    private static let ground: CGFloat = 140
    private static let wallLeft: CGFloat = 76, wallRight: CGFloat = 180
    private static let eaveY: CGFloat = 90, ridgeY: CGFloat = 62
    private static let array = CGRect(x: 101, y: 67, width: 54, height: 18)
    /// Mounted on the outside wall, under the eave.
    private static let inverter = CGRect(x: 183, y: 94, width: 22, height: 26)
    private static let cabinet = CGRect(x: 232, y: 106, width: 28, height: 34)
    private static let poleX: CGFloat = 314
    private static let busY: CGFloat = 100
    private static let windows = [CGRect(x: 112, y: 110, width: 20, height: 18), CGRect(x: 146, y: 110, width: 20, height: 18)]
    private static let captionX: (solar: CGFloat, home: CGFloat, battery: CGFloat, grid: CGFloat) = (40, 128, 246, 314)
    /// The logger reports about every five minutes; after this long a reading is drawn fainter.
    private static let staleAfter: TimeInterval = 15 * 60

    // Deeper versions of the shared accents for the light panel, where the pastel originals wash out.
    private static let lightSolar = deepen(.solarAccent)
    private static let lightBattery = deepen(.batteryAccent)
    private static let lightGrid = deepen(.gridAccent)
    private static let lightAlert = deepen(.alertAccent)

    private static func deepen(_ color: Color) -> Color {
        var environment = EnvironmentValues()
        environment.colorScheme = .light
        let c = color.resolve(in: environment)
        let top = max(c.red, c.green, c.blue)
        func channel(_ v: Float) -> Double { Double(max(0, top - (top - v) * 1.35) * 0.80) }
        return Color(red: channel(c.red), green: channel(c.green), blue: channel(c.blue))
    }

    private let dark: Bool
    private let snapshot: EnergySnapshot?
    private let previous: EnergyFlows
    private let flows: EnergyFlows
    private let progress: Double
    private let time: Double
    private let dim: Double
    private let energy: Double
    private let night: Double
    private let outage: Double
    private let solar: Flow, grid: Flow, battery: Flow, load: Flow

    private let ink = Color.primary
    private let solarColor: Color, batteryColor: Color, gridColor: Color, alertColor: Color
    private let lampColor: Color, loadColor: Color
    private let recess: Color

    init(frame: HeroFrame, now: Date, dark: Bool) {
        self.dark = dark
        snapshot = frame.snapshot
        // A reading the parser could not make sense of must not reach the drawing code as NaN.
        let previous = Self.finite(frame.previous), target = Self.finite(frame.target)
        let eased = frame.progress(at: now)
        self.previous = previous
        progress = eased
        flows = previous.mix(target, eased)
        time = now.timeIntervalSinceReferenceDate
        dim = frame.snapshot == nil ? 0.62 : 1

        // A reading the logger has not refreshed for a while is still drawn, but its motion is fainter.
        if let reported = frame.snapshot?.deviceTime {
            energy = 1 - 0.5 * Self.smooth((now.timeIntervalSince(reported) - Self.staleAfter) / 4)
        } else {
            energy = 1
        }
        night = Self.nightness(at: now)
        // The grid dropping out eases in with the last of its power; there is no way to know when an idle grid went.
        if let snapshot = frame.snapshot, !snapshot.gridPresent {
            outage = previous.gridW > 1 ? eased : 1
        } else {
            outage = 0
        }

        solar = Flow(previous: previous.solarW, target: target.solarW, eased: eased)
        grid = Flow(previous: previous.gridW, target: target.gridW, eased: eased)
        battery = Flow(previous: previous.batteryW, target: target.batteryW, eased: eased)
        load = Flow(previous: previous.loadW, target: target.loadW, eased: eased)

        solarColor = dark ? .solarAccent : Self.lightSolar
        batteryColor = dark ? .batteryAccent : Self.lightBattery
        gridColor = dark ? .gridAccent : Self.lightGrid
        alertColor = dark ? .alertAccent : Self.lightAlert
        // What the house uses is plain ink, and its lit windows a barely warm white: neither is a fifth accent.
        lampColor = dark ? Color(red: 1.0, green: 0.95, blue: 0.85) : Color(red: 1.0, green: 0.93, blue: 0.74)
        loadColor = dark ? Color(red: 1.0, green: 0.97, blue: 0.92) : Color.primary.opacity(0.62)
        recess = Color.black.opacity(dark ? 0.34 : 0.09)
    }

    private static func finite(_ flows: EnergyFlows) -> EnergyFlows {
        func clean(_ value: Double) -> Double { value.isFinite ? value : 0 }
        return EnergyFlows(solarW: clean(flows.solarW), gridW: clean(flows.gridW), batteryW: clean(flows.batteryW), loadW: clean(flows.loadW),
                           exportW: clean(flows.exportW))
    }

    private static func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
    private static func smooth(_ x: Double) -> Double { let c = clamp(x); return c * c * (3 - 2 * c) }

    /// 1 in the dark hours, 0 in daylight, by the local clock. PV always wins: this only decides what an
    /// empty sky holds, so an overcast noon at 0 W shows a cloud and not a moon.
    private static func nightness(at date: Date) -> Double {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        let hour = Double(parts.hour ?? 0) + Double(parts.minute ?? 0) / 60
        return hour < 12 ? 1 - smooth((hour - 5.5) / 1.5) : smooth((hour - 17) / 1.5)
    }

    private var percent: Double? {
        guard let value = snapshot?.batteryPercent, value.isFinite else { return nil }
        return min(100, max(0, value))
    }
    private var lowBattery: Bool { (percent ?? 100) < 20 }
    /// 0 with the sun on the horizon (a few watts of PV), 1 at full output.
    private var sunRise: Double { clamp((HeroMath.intensity(flows.solarW) - 0.12) / 0.88) }
    private var sunCenter: CGPoint {
        let climb = pow(sunRise, 0.7)
        return p(26 + 20 * climb, 116 - 88 * climb)
    }

    private func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
    private func line(_ alpha: Double) -> GraphicsContext.Shading { .color(ink.opacity(alpha * dim)) }
    private func clamp(_ x: Double) -> Double { Self.clamp(x) }
    private func smooth(_ x: Double) -> Double { Self.smooth(x) }
    private func dot(_ center: CGPoint, _ radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    // MARK: Routes (each runs from source to sink)

    private static let solarWire = Route.rounded([CGPoint(x: array.maxX, y: 76), CGPoint(x: inverter.midX, y: 76),
                                                  CGPoint(x: inverter.midX, y: inverter.minY)], radius: 5)
    private static let serviceDrop = Route.hanging(from: CGPoint(x: poleX - 10, y: 48.5), to: CGPoint(x: inverter.maxX, y: 101), sag: 7)
    private static let batteryWire = Route.rounded([CGPoint(x: inverter.midX, y: inverter.maxY), CGPoint(x: inverter.midX, y: 130),
                                                    CGPoint(x: cabinet.minX, y: 130)], radius: 5)
    private static let serviceReturn = serviceDrop.reversed
    private static let batteryReturn = batteryWire.reversed
    /// The house circuit: one run under the eave from the inverter, dropping into each window.
    private static let houseCircuits = windows.map { window in
        Route.rounded([CGPoint(x: inverter.minX, y: busY), CGPoint(x: window.midX, y: busY), CGPoint(x: window.midX, y: window.minY)], radius: 3)
    }
    /// Where the nearer window's drop leaves the shared run.
    private static let branch = inverter.minX - windows[1].midX - 3

    private static let hillStart = CGPoint(x: 4, y: ground), hillControl = CGPoint(x: 36, y: 92), hillEnd = CGPoint(x: wallLeft, y: 128)
    private static let moon: Path = {
        let center = CGPoint(x: 44, y: 34)
        return Path(ellipseIn: CGRect(x: center.x - 7.5, y: center.y - 7.5, width: 15, height: 15))
            .subtracting(Path(ellipseIn: CGRect(x: center.x - 3.4, y: center.y - 10.2, width: 14, height: 14)))
    }()
    private static let cloud: Path = {
        Path(roundedRect: CGRect(x: 29, y: 34, width: 30, height: 9), cornerRadius: 4.5)
            .union(Path(ellipseIn: CGRect(x: 34, y: 26.5, width: 13, height: 13)))
            .union(Path(ellipseIn: CGRect(x: 43.5, y: 30, width: 10, height: 10)))
    }()

    // MARK: Draw

    func draw(_ canvas: GraphicsContext, size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        var ctx = canvas
        // Drawn at its design size and centred; a tighter frame scales it down instead of clipping it.
        let scale = min(1, size.width / Self.design.width, size.height / Self.design.height)
        ctx.translateBy(x: (size.width - Self.design.width * scale) / 2, y: (size.height - Self.design.height * scale) / 2)
        ctx.scaleBy(x: scale, y: scale)
        drawSky(&ctx)
        drawGround(&ctx)
        drawPole(&ctx)
        drawHouse(&ctx)
        drawEquipment(&ctx)
        drawEnergy(&ctx)
        drawLabels(&ctx)
    }

    private func drawSky(_ ctx: inout GraphicsContext) {
        var hill = Path()
        hill.move(to: Self.hillStart)
        hill.addQuadCurve(to: Self.hillEnd, control: Self.hillControl)
        ctx.stroke(hill, with: line(0.16), lineWidth: 1)

        // The sun follows the eased PV power, so it also sets when the data goes away. The rest of the sky needs a reading.
        let day = smooth(flows.solarW / 14)
        let empty = snapshot == nil ? 0 : 1 - day

        if day > 0.01 {
            let rise = sunRise, center = sunCenter
            let radius = 7 + 1.5 * rise
            // Everything above the hill line: a weak sun sits half behind it.
            var sky = Path()
            sky.move(to: p(-20, Self.ground))
            sky.addLine(to: Self.hillStart)
            sky.addQuadCurve(to: Self.hillEnd, control: Self.hillControl)
            sky.addLine(to: p(140, Self.hillEnd.y))
            sky.addLine(to: p(140, -20))
            sky.addLine(to: p(-20, -20))
            sky.closeSubpath()
            var above = ctx
            above.clip(to: sky)

            above.drawLayer { halo in
                halo.addFilter(.blur(radius: 7))
                halo.fill(dot(center, radius + 4 + 4 * rise), with: .color(solarColor.opacity((0.12 + (dark ? 0.30 : 0.22) * rise) * day)))
            }
            let disc = dot(center, radius)
            above.fill(disc, with: .color(solarColor.opacity((0.06 + (dark ? 0.16 : 0.12) * rise) * day)))
            above.stroke(disc, with: .color(ink.opacity((0.34 + 0.26 * rise) * day)), lineWidth: 1.1)

            var rays = Path()
            let turn = time * 0.14
            for ray in 0..<10 {
                let angle = turn + Double(ray) / 10 * 2 * .pi
                let breath = 1 + 0.14 * sin(time * 1.5 + Double(ray) * 1.9)
                let reach = (ray % 2 == 0 ? 1.0 : 0.55) * (1.2 + 4.8 * rise) * breath
                let inner = radius + 3.4
                rays.move(to: p(center.x + cos(angle) * inner, center.y + sin(angle) * inner))
                rays.addLine(to: p(center.x + cos(angle) * (inner + reach), center.y + sin(angle) * (inner + reach)))
            }
            above.stroke(rays, with: .color(ink.opacity((0.18 + 0.30 * rise) * day)), style: StrokeStyle(lineWidth: 1, lineCap: .round))
        }

        let dusk = empty * night, overcast = empty * (1 - night)
        if dusk > 0.01 {
            ctx.fill(Self.moon, with: .color(ink.opacity(0.14 * dusk)))
            ctx.stroke(Self.moon, with: .color(ink.opacity(0.46 * dusk)), style: StrokeStyle(lineWidth: 1, lineJoin: .round))

            let stars: [(CGFloat, CGFloat, CGFloat)] = [(18, 22, 1.0), (72, 46, 0.8), (128, 30, 0.9), (150, 14, 0.7),
                                                        (212, 36, 0.8), (240, 20, 1.1), (276, 38, 0.8), (338, 30, 0.9)]
            for (index, star) in stars.enumerated() {
                let twinkle = 0.62 + 0.38 * sin(time * (0.7 + 0.23 * Double(index)) + Double(index) * 2.4)
                ctx.fill(dot(p(star.0, star.1), star.2), with: .color(ink.opacity(0.46 * twinkle * dusk)))
            }
        }
        if overcast > 0.01 {
            ctx.fill(Self.cloud, with: .color(ink.opacity(0.08 * overcast)))
            ctx.stroke(Self.cloud, with: .color(ink.opacity(0.40 * overcast)), style: StrokeStyle(lineWidth: 1, lineJoin: .round))
        }
    }

    private func drawGround(_ ctx: inout GraphicsContext) {
        var ground = Path()
        ground.move(to: p(6, Self.ground))
        ground.addLine(to: p(342, Self.ground))
        let edge = ink.opacity(0), body = ink.opacity(0.30 * dim)
        ctx.stroke(ground, with: .linearGradient(Gradient(stops: [.init(color: edge, location: 0), .init(color: body, location: 0.08),
                                                                  .init(color: body, location: 0.92), .init(color: edge, location: 1)]),
                                                 startPoint: p(6, Self.ground), endPoint: p(342, Self.ground)), lineWidth: 1)
    }

    private func drawPole(_ ctx: inout GraphicsContext) {
        let x = Self.poleX
        let strength = 1 - 0.40 * outage

        var pole = Path()
        pole.move(to: p(x, 45)); pole.addLine(to: p(x, Self.ground))
        ctx.stroke(pole, with: line(0.40 * strength), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
        var arm = Path()
        arm.move(to: p(x - 12, 52)); arm.addLine(to: p(x + 12, 52))
        ctx.stroke(arm, with: line(0.40 * strength), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
        var braces = Path()
        braces.move(to: p(x, 61)); braces.addLine(to: p(x - 7, 52.5))
        braces.move(to: p(x, 61)); braces.addLine(to: p(x + 7, 52.5))
        ctx.stroke(braces, with: line(0.24 * strength), lineWidth: 1)
        var insulators = Path()
        insulators.move(to: p(x - 10, 51.5)); insulators.addLine(to: p(x - 10, 48.5))
        insulators.move(to: p(x + 10, 51.5)); insulators.addLine(to: p(x + 10, 48.5))
        ctx.stroke(insulators, with: line(0.46 * strength), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))

        // The line arrives from beyond the frame; the service drop carries it to the inverter.
        let live = (0.23 + 0.09 * grid.presence) * dim * (1 - outage)
        let dead = 0.24 * dim * outage
        var feeder = Path()
        feeder.move(to: p(x + 10, 48.5)); feeder.addQuadCurve(to: p(350, 50), control: p(x + 20, 51.5))
        let drop = Self.serviceDrop
        if live > 0.004 {
            let solid = StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round)
            ctx.stroke(feeder, with: .linearGradient(Gradient(colors: [ink.opacity(live), ink.opacity(0)]), startPoint: p(x + 10, 50), endPoint: p(347, 50)), style: solid)
            ctx.stroke(drop.path, with: .color(ink.opacity(live)), style: solid)
        }
        if dead > 0.004 {
            // In an outage the line goes dashed and dim, and the drop is visibly broken part-way along.
            let dashed = StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round, dash: [2.5, 3.5])
            ctx.stroke(feeder, with: .linearGradient(Gradient(colors: [ink.opacity(dead), ink.opacity(0)]), startPoint: p(x + 10, 50), endPoint: p(347, 50)), style: dashed)
            // Both halves are dashed outward from their fixed ends, so each still meets what it hangs from.
            let middle = drop.length * 0.46
            var broken = drop.path(from: 0, to: middle - 6.5)
            broken.addPath(Self.serviceReturn.path(from: 0, to: drop.length - middle - 6.5))
            ctx.stroke(broken, with: .color(ink.opacity(dead)), style: dashed)
            let at = drop.point(at: middle), arm: CGFloat = 2.8
            var cross = Path()
            cross.move(to: p(at.x - arm, at.y - arm)); cross.addLine(to: p(at.x + arm, at.y + arm))
            cross.move(to: p(at.x + arm, at.y - arm)); cross.addLine(to: p(at.x - arm, at.y + arm))
            ctx.stroke(cross, with: .color(alertColor.opacity(0.95 * outage * dim)), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
        }
    }

    private func drawHouse(_ ctx: inout GraphicsContext) {
        let left = Self.wallLeft, right = Self.wallRight, eave = Self.eaveY, ridge = Self.ridgeY, ground = Self.ground

        // Walls.
        let body = CGRect(x: left, y: eave, width: right - left, height: ground - eave)
        ctx.fill(Path(body), with: .linearGradient(Gradient(colors: [ink.opacity(0.07 * dim), ink.opacity(0.035 * dim)]),
                                                   startPoint: p(0, eave), endPoint: p(0, ground)))
        var walls = Path()
        walls.move(to: p(left, eave)); walls.addLine(to: p(left, ground))
        walls.move(to: p(right, eave)); walls.addLine(to: p(right, ground))
        ctx.stroke(walls, with: line(0.36), lineWidth: 1)

        // Hip roof, seen face-on.
        var roof = Path()
        roof.move(to: p(left - 6, eave))
        roof.addLine(to: p(left + 18, ridge))
        roof.addLine(to: p(right - 18, ridge))
        roof.addLine(to: p(right + 6, eave))
        roof.closeSubpath()
        ctx.fill(roof, with: .linearGradient(Gradient(colors: [ink.opacity(0.11 * dim), ink.opacity(0.05 * dim)]),
                                             startPoint: p(0, ridge), endPoint: p(0, eave)))
        ctx.stroke(roof, with: line(0.40), style: StrokeStyle(lineWidth: 1, lineJoin: .round))

        // Solar array: a dark panel field with a cell grid, and a sheen while it is producing.
        let array = Self.array
        let field = Path(roundedRect: array, cornerRadius: 1.5, style: .continuous)
        ctx.fill(field, with: .color(recess))
        if solar.presence > 0.01 {
            let strength = solar.presence * (0.05 + 0.17 * solar.level)
            ctx.fill(field, with: .linearGradient(Gradient(colors: [solarColor.opacity(strength), solarColor.opacity(strength * 0.4)]),
                                                  startPoint: p(array.minX, array.minY), endPoint: p(array.maxX, array.maxY)))
        }
        var cells = Path()
        for column in 1..<6 {
            let x = array.minX + array.width * CGFloat(column) / 6
            cells.move(to: p(x, array.minY)); cells.addLine(to: p(x, array.maxY))
        }
        cells.move(to: p(array.minX, array.midY)); cells.addLine(to: p(array.maxX, array.midY))
        ctx.stroke(cells, with: line(0.20), lineWidth: 1)
        ctx.stroke(field, with: line(0.42), lineWidth: 1)

        // Door.
        let door = CGRect(x: left + 10, y: 114, width: 13, height: ground - 114)
        ctx.stroke(Path(door), with: line(0.26), lineWidth: 1)
        ctx.fill(dot(p(door.maxX - 3.2, door.midY + 1), 0.8), with: line(0.34))

        // Windows glow with the load: barely at a trickle, bright when the house is drawing hard.
        let glow = load.presence * (0.22 + 0.78 * load.level)
        if glow > 0.01 {
            ctx.drawLayer { halo in
                halo.addFilter(.blur(radius: 5))
                for window in Self.windows {
                    halo.fill(Path(roundedRect: window.insetBy(dx: -1.5, dy: -1.5), cornerRadius: 3),
                              with: .color(lampColor.opacity((dark ? 0.34 : 0.55) * glow)))
                }
            }
        }
        var mullions = Path()
        for window in Self.windows {
            let frame = Path(roundedRect: window, cornerRadius: 1.5, style: .continuous)
            ctx.fill(frame, with: .color(recess.opacity(0.7)))
            if glow > 0.01 {
                // Lit glass, brighter toward the top: warm white on the dark panel; on the light one, lighter than the wall.
                let top = dark ? 0.08 + 0.50 * glow : 0.35 + 0.60 * glow
                let tint = dark ? lampColor : Color.white
                ctx.fill(frame, with: .linearGradient(Gradient(colors: [tint.opacity(top), tint.opacity(top * 0.62)]),
                                                      startPoint: p(0, window.minY), endPoint: p(0, window.maxY)))
                if !dark { ctx.fill(frame, with: .color(lampColor.opacity(0.10 + 0.22 * glow))) }
            }
            ctx.stroke(frame, with: line(0.34), lineWidth: 1)
            mullions.move(to: p(window.midX, window.minY)); mullions.addLine(to: p(window.midX, window.maxY))
            mullions.move(to: p(window.minX, window.midY)); mullions.addLine(to: p(window.maxX, window.midY))
        }
        ctx.stroke(mullions, with: line(0.20), lineWidth: 1)
    }

    private func drawEquipment(_ ctx: inout GraphicsContext) {
        // Wires first, so the boxes sit on top of their ends. A wire that is carrying power is a touch stronger.
        let wire = StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round)
        ctx.stroke(Self.solarWire.path, with: line(0.19 + 0.10 * solar.presence), style: wire)
        ctx.stroke(Self.batteryWire.path, with: line(0.19 + 0.10 * battery.presence), style: wire)
        let far = Self.houseCircuits[0], near = Self.houseCircuits[1]
        ctx.stroke(far.path, with: line(0.18 + 0.08 * load.presence), style: wire)
        // The nearer window's drop branches off the same run; draw only the part that is its own.
        ctx.stroke(near.path(from: Self.branch, to: near.length), with: line(0.18 + 0.08 * load.presence), style: wire)

        // Inverter.
        let box = Self.inverter
        let shell = Path(roundedRect: box, cornerRadius: 3.5, style: .continuous)
        ctx.fill(shell, with: .linearGradient(Gradient(colors: [ink.opacity(0.13 * dim), ink.opacity(0.06 * dim)]),
                                              startPoint: p(0, box.minY), endPoint: p(0, box.maxY)))
        ctx.stroke(shell, with: line(0.46), lineWidth: 1)
        let display = CGRect(x: box.minX + 4, y: box.minY + 4.5, width: box.width - 8, height: 6.5)
        ctx.fill(Path(roundedRect: display, cornerRadius: 1.6, style: .continuous), with: .color(recess))
        var wave = Path()
        wave.move(to: p(display.minX + 2.2, display.midY))
        wave.addCurve(to: p(display.minX + 8.6, display.midY), control1: p(display.minX + 4.3, display.midY - 3.6),
                      control2: p(display.minX + 6.5, display.midY + 3.6))
        ctx.stroke(wave, with: line(snapshot == nil ? 0.22 : 0.52), style: StrokeStyle(lineWidth: 1, lineCap: .round))
        var vents = Path()
        for row in 0..<2 {
            let y = box.minY + 15.5 + CGFloat(row) * 4
            vents.move(to: p(box.minX + 5, y)); vents.addLine(to: p(box.maxX - 5, y))
        }
        ctx.stroke(vents, with: line(0.16), style: StrokeStyle(lineWidth: 1, lineCap: .round))

        // Battery cabinet with a four-cell gauge.
        let cabinet = Self.cabinet
        let cap = CGRect(x: cabinet.midX - 5, y: cabinet.minY - 3, width: 10, height: 3)
        ctx.fill(Path(roundedRect: cap, cornerRadius: 1), with: line(0.16))
        let caseShape = Path(roundedRect: cabinet, cornerRadius: 4, style: .continuous)
        ctx.fill(caseShape, with: .linearGradient(Gradient(colors: [ink.opacity(0.11 * dim), ink.opacity(0.04 * dim)]),
                                                  startPoint: p(0, cabinet.minY), endPoint: p(0, cabinet.maxY)))
        ctx.stroke(caseShape, with: line(0.42), lineWidth: 1)

        let active = battery.presence
        let charging = battery.delivery(forward: true)
        let cellTint = lowBattery ? alertColor : batteryColor
        let cellHeight: CGFloat = 4.75, gap: CGFloat = 1.5
        let gaugeBottom = cabinet.maxY - 4.5
        for cell in 0..<4 {
            let top = gaugeBottom - CGFloat(cell + 1) * cellHeight - CGFloat(cell) * gap
            let rect = CGRect(x: cabinet.minX + 5, y: top, width: cabinet.width - 10, height: cellHeight)
            ctx.fill(Path(roundedRect: rect, cornerRadius: 1.2), with: .color(recess))
            guard let percent else { continue }
            let filled = clamp(percent / 25 - Double(cell))
            if charging > 0.02, filled < 0.98, cell == min(3, Int(percent / 25)) {
                // The cell being filled breathes while the battery charges.
                let pulse = 0.5 + 0.5 * sin(time * 2.6)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 1.2), with: .color(cellTint.opacity((0.08 + 0.22 * pulse) * charging)))
            }
            guard filled > 0.02 else { continue }
            let part = CGRect(x: rect.minX, y: rect.maxY - rect.height * filled, width: rect.width, height: rect.height * filled)
            let shape = Path(roundedRect: part, cornerRadius: min(1.2, part.height / 2))
            if lowBattery {
                ctx.fill(shape, with: .color(alertColor.opacity(0.92)))
            } else {
                ctx.fill(shape, with: .color(ink.opacity(0.40 - 0.12 * active)))
                if active > 0.01 { ctx.fill(shape, with: .color(batteryColor.opacity(0.62 * active))) }
            }
        }
    }

    private func drawEnergy(_ ctx: inout GraphicsContext) {
        var comets: [Comet] = []
        var sinks: [(route: Route, color: Color, alpha: Double)] = []

        if solar.presence > 0.01 {
            // Sunlight falling on the array: more beams as the sun climbs, none until it stands clear above the roof.
            // Their rhythm is fixed, so they need no crossfade; power shows in how many there are and how long.
            let sun = sunCenter
            let beams = solar.presence * smooth((Self.array.minY - 6 - sun.y) / 16)
            if beams > 0.02 {
                let aim = atan2(Self.array.minY - sun.y, Self.array.midX - sun.x)
                let order = [2, 0, 4, 1, 3]
                let stagger = [0.0, 0.37, 0.71, 0.18, 0.55]
                let steady = Train(pace: Pace(watts: 0), forward: true, weight: 1, reveal: 1, clear: 0)
                for stream in 0..<5 {
                    let weight = clamp(solar.level * 7 - Double(order[stream]) * 0.9) * beams
                    guard weight > 0.02 else { continue }
                    let target = p(Self.array.minX + 5 + CGFloat(stream) * 11, Self.array.minY + 0.5)
                    let angle = aim - Double(stream - 2) * 0.19
                    let start = p(sun.x + cos(angle) * 21, sun.y + sin(angle) * 21)
                    comets += trail(steady, on: Route([start, target]), color: solarColor, glow: 0, strength: weight * (dark ? 0.50 : 0.72),
                                    offset: stagger[stream], rate: 0.9, gap: 46, body: 18 + 12 * solar.level, width: 1.1, whole: true)
                }
            }
        }
        for train in solar.trains { comets += trail(train, on: Self.solarWire, color: solarColor) }
        sinks.append((Self.solarWire, solarColor, solar.delivery()))

        // No `gridPresent` test: when the grid drops out, the last of its energy drains away along the broken wire.
        for train in grid.trains { comets += trail(train, on: Self.serviceDrop, color: gridColor) }
        sinks.append((Self.serviceDrop, gridColor, grid.delivery()))

        let batteryTint = lowBattery ? alertColor : batteryColor
        for train in battery.trains { comets += trail(train, on: train.forward ? Self.batteryWire : Self.batteryReturn, color: batteryTint) }
        sinks.append((Self.batteryWire, batteryTint, battery.delivery(forward: true)))
        sinks.append((Self.batteryReturn, batteryTint, battery.delivery(forward: false)))

        // Each pulse splits where the nearer window's drop leaves the run, so both windows are fed together.
        for train in load.trains {
            comets += trail(train, on: Self.houseCircuits[0], color: loadColor, glow: dark ? 0.55 : 0)
            comets += trail(train, on: Self.houseCircuits[1], color: loadColor, glow: dark ? 0.55 : 0, skip: Double(Self.branch))
        }
        for circuit in Self.houseCircuits { sinks.append((circuit, loadColor, load.delivery())) }

        // The inverter's status lamp and the low-battery warning share the glow layer with the comets.
        let box = Self.inverter
        let lamp = p(box.maxX - 6.8, box.minY + 7.75)
        let breath = 0.72 + 0.28 * sin(time * 2.4)
        let warned = snapshot?.activeWarning != nil
        // The lamp crossfades from what was carrying the load to what carries it now.
        var lamps: [(color: Color, alpha: Double)] = []
        if warned {
            lamps.append((alertColor, breath))
        } else {
            if let before = sourceColor(for: previous), progress < 0.996 { lamps.append((before, 1 - progress)) }
            if let after = statusColor { lamps.append((after, progress)) }
        }

        ctx.drawLayer { glow in
            glow.addFilter(.blur(radius: 2.6))
            for comet in comets where comet.glow > 0 {
                let gain = (dark ? 0.6 : 0.34) * comet.glow
                glow.stroke(comet.path, with: .linearGradient(Gradient(colors: [comet.color.opacity(comet.tailAlpha * gain * 0.4), comet.color.opacity(comet.headAlpha * gain)]),
                                                              startPoint: comet.tail, endPoint: comet.head),
                            style: StrokeStyle(lineWidth: comet.width + 2.6, lineCap: .round, lineJoin: .round))
            }
            for item in lamps { glow.fill(dot(lamp, 3.4), with: .color(item.color.opacity(0.7 * item.alpha))) }
            if lowBattery, snapshot != nil {
                let cabinet = Self.cabinet
                glow.fill(Path(roundedRect: CGRect(x: cabinet.minX + 4, y: cabinet.maxY - 9, width: cabinet.width - 8, height: 6), cornerRadius: 2),
                          with: .color(alertColor.opacity((dark ? 0.55 : 0.40) * breath)))
            }
        }
        for comet in comets {
            let shading = Gradient(stops: [.init(color: comet.color.opacity(comet.tailAlpha), location: 0),
                                           .init(color: comet.color.opacity(comet.midAlpha), location: 0.55),
                                           .init(color: comet.color.opacity(comet.headAlpha), location: 1)])
            ctx.stroke(comet.path, with: .linearGradient(shading, startPoint: comet.tail, endPoint: comet.head),
                       style: StrokeStyle(lineWidth: comet.width, lineCap: .round, lineJoin: .round))
        }
        // A small arrowhead where each wire delivers, so direction reads even in a still frame.
        for sink in sinks where sink.alpha > 0.02 {
            let end = sink.route.length
            let tip = sink.route.point(at: end - 1.2), back = sink.route.point(at: end - 5.2)
            let angle = atan2(tip.y - back.y, tip.x - back.x)
            let arm: CGFloat = 3, spread = 0.66
            var head = Path()
            head.move(to: p(tip.x - cos(angle - spread) * arm, tip.y - sin(angle - spread) * arm))
            head.addLine(to: tip)
            head.addLine(to: p(tip.x - cos(angle + spread) * arm, tip.y - sin(angle + spread) * arm))
            ctx.stroke(head, with: .color(sink.color.opacity(0.82 * min(1, sink.alpha) * energy)), style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round))
        }
        ctx.fill(dot(lamp, 1.45), with: line(0.22))
        for item in lamps { ctx.fill(dot(lamp, 1.45), with: .color(item.color.opacity(0.95 * min(1, item.alpha * 1.15)))) }
    }

    /// Lamp on the inverter: the source carrying the load, or the alert colour while a warning is active.
    private var statusColor: Color? {
        guard let snapshot else { return nil }
        switch snapshot.mode {
        case .solar: return solarColor
        case .battery: return lowBattery ? alertColor : batteryColor
        case .grid: return gridColor
        case .standby, .unknown: return nil
        }
    }

    /// The same choice for a set of flows alone (the reading before this one).
    private func sourceColor(for flows: EnergyFlows) -> Color? {
        if flows.batteryW < -20 { return lowBattery ? alertColor : batteryColor }
        if flows.gridW > 1 { return gridColor }
        if flows.solarW > 20 { return solarColor }
        return nil
    }

    /// The comets of one steady stream on `route`: evenly spaced, emerging at its start and draining into its end.
    /// `skip` hides the first stretch of a route that shares it with another. `whole` holds a comet back until all of
    /// it is clear of the source (sunlight leaving the sun, as opposed to a pulse emerging from a box).
    private func trail(_ train: Train, on route: Route, color: Color, glow: Double = 1, strength: Double? = nil, skip: Double = 0,
                       offset: Double = 0, rate: Double? = nil, gap: Double? = nil, body: Double? = nil, width: CGFloat? = nil,
                       whole: Bool = false) -> [Comet] {
        let pace = train.pace
        let total = Double(route.length)
        let peak = (strength ?? pace.alpha) * train.weight * energy
        guard total > 4, peak > 0.01 else { return [] }
        let gap = gap ?? pace.gap, body = body ?? pace.body
        // A new flow reaches along its wire from the source; a dying one empties toward the sink.
        let span = total + body + 10
        let front = train.reveal * span, back = train.clear * span
        var head = HeroMath.fract((rate ?? pace.rate) * time + offset) * gap
        var out: [Comet] = []
        while head - body < total {
            defer { head += gap }
            let start = head - body
            let from = max(skip, start), to = min(total, head)
            guard to - from > 0.6 else { continue }
            let mask = clamp((front - head) / 10) * clamp((head - back) / 10 + 1) * (whole ? clamp(start / 8) : 1)
            guard mask > 0.02 else { continue }
            func level(_ d: Double) -> Double { peak * mask * pow(max(0, (d - start) / body), 1.5) }
            out.append(Comet(path: route.path(from: CGFloat(from), to: CGFloat(to)),
                             tail: route.point(at: CGFloat(from)), head: route.point(at: CGFloat(to)),
                             tailAlpha: level(from), midAlpha: level(from + (to - from) * 0.55), headAlpha: level(to),
                             color: color, width: width ?? pace.width, glow: glow))
        }
        return out
    }

    // MARK: Labels

    private func drawLabels(_ ctx: inout GraphicsContext) {
        guard let snapshot else {
            ctx.draw(Text("Waiting for data").font(.system(size: 10, weight: .medium)).foregroundStyle(ink.opacity(dark ? 0.55 : 0.62)),
                     at: p(Self.design.width / 2, 160))
            return
        }
        // A value the reading does not really hold is shown as a dash, never as a confident zero.
        let solarKnown = snapshot.pvPowerW.isFinite, loadKnown = snapshot.loadPowerW.isFinite, batteryKnown = snapshot.batteryPowerW.isFinite
        func watts(_ value: Double, known: Bool) -> String { known ? PowerFormat.watts(value) : "–" }
        caption(&ctx, x: Self.captionX.solar, name: "Solar", value: watts(flows.solarW, known: solarKnown), lit: flows.solarW >= 0.5)
        caption(&ctx, x: Self.captionX.home, name: "Home", value: watts(flows.loadW, known: loadKnown), lit: flows.loadW >= 0.5)
        let batteryName = flows.batteryW > 8 ? "Charging" : flows.batteryW < -8 ? "Discharging" : "Battery"
        caption(&ctx, x: Self.captionX.battery, name: batteryName, value: watts(flows.batteryW, known: batteryKnown), lit: abs(flows.batteryW) >= 0.5)
        if snapshot.gridPresent, flows.exportW > 15 {
            // Sent to the grid: the wire is not drawn backwards here, but the caption says what is happening.
            caption(&ctx, x: Self.captionX.grid, name: "Export", value: "↑ " + PowerFormat.watts(flows.exportW), lit: true)
        } else if snapshot.gridPresent {
            caption(&ctx, x: Self.captionX.grid, name: "Grid", value: watts(flows.gridW, known: solarKnown && loadKnown && batteryKnown), lit: flows.gridW >= 0.5)
        } else {
            caption(&ctx, x: Self.captionX.grid, name: "Grid", value: "Outage", lit: true, tint: alertColor)
        }
        if let percent {
            let tint = lowBattery ? alertColor : ink
            ctx.draw(Text("\(Int(percent.rounded()))%").font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(tint.opacity(lowBattery ? 1 : 0.86)),
                     at: p(Self.cabinet.maxX + 6, Self.cabinet.midY + 1), anchor: .leading)
        }
    }

    private func caption(_ ctx: inout GraphicsContext, x: CGFloat, name: String, value: String, lit: Bool, tint: Color? = nil) {
        // The light panel needs a little more ink for the same legibility.
        ctx.draw(Text(name).font(.system(size: 9, weight: .medium)).foregroundStyle(ink.opacity(dark ? 0.50 : 0.60)), at: p(x, 152.5))
        ctx.draw(Text(value).font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle((tint ?? ink).opacity(tint != nil ? 1 : lit ? 0.88 : dark ? 0.38 : 0.44)),
                 at: p(x, 166))
    }
}
