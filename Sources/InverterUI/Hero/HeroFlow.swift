import SwiftUI
import InverterCore

/// "Flow": an energy-flow map in quiet monochrome glass. Sun and grid sit on the left, home and
/// battery on the right, a small inverter hub in the middle, joined by hairline conduits.
/// Comets travel each conduit from source to sink: more power means more comets, moving faster.
/// The battery ring's arc is its state of charge and its conduit reverses with the sign of the
/// battery power. Comets leaving the hub carry the colour of the source that feeds them.
///
/// When a reading changes, the numbers count in watts while everything drawn eases in visual
/// level, so a new flow builds up over the whole ramp instead of appearing at once. A flow that
/// starts from nothing also travels: one pulse leaves its source and crosses to the hub, the hub
/// wakes, and pulses leave it for the sinks, which light as they land. The regular comets appear
/// in each pulse's wake.
///
/// A pure function of `(frame, now)`: no state, no timers. Read-only, like everything else here.
struct HeroFlow: View {
    let frame: HeroFrame
    let now: Date
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Canvas { canvas, size in draw(&canvas, size: size) }
    }

    // MARK: Layout

    private enum Metric {
        static let ring: CGFloat = 20           // node radius
        static let reach: CGFloat = 116         // node centre to hub centre, across
        static let rise: CGFloat = 45           // node centre to hub centre, up or down
        static let hub = CGSize(width: 34, height: 42)
        static let port: CGFloat = 8            // conduit ports sit this far above and below the hub's middle
        static let labels: CGFloat = 30         // value and caption beneath a node
        static let edge: CGFloat = 6            // labels keep this far from the canvas edge
        static let slots = 4                    // most comets on one conduit
    }

    /// A conduit: an S-curve from a node's rim to a hub port, walkable at constant speed.
    private struct Track {
        let p0, p1, p2, p3: CGPoint
        private let lengths: [Double]
        private static let steps = 16

        init(from node: CGPoint, to port: CGPoint) {
            let pull = (port.x - node.x) * 0.52
            p0 = node
            p1 = CGPoint(x: node.x + pull, y: node.y)
            p2 = CGPoint(x: port.x - pull, y: port.y)
            p3 = port
            var sums: [Double] = [0]
            sums.reserveCapacity(Self.steps + 1)
            var last = node, run = 0.0
            for i in 1...Self.steps {
                let p = Self.bezier(p0, p1, p2, p3, Double(i) / Double(Self.steps))
                run += Double(hypot(p.x - last.x, p.y - last.y))
                sums.append(run)
                last = p
            }
            lengths = sums
        }

        private static func bezier(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint, _ t: Double) -> CGPoint {
            let u = 1 - t
            let wa = u * u * u, wb = 3 * u * u * t, wc = 3 * u * t * t, wd = t * t * t
            return CGPoint(x: wa * a.x + wb * b.x + wc * c.x + wd * d.x, y: wa * a.y + wb * b.y + wc * c.y + wd * d.y)
        }

        /// Point at a fraction of the arc length: 0 at the node, 1 at the hub.
        func at(_ s: Double) -> CGPoint {
            let want = min(1, max(0, s)) * lengths[Self.steps]
            var i = 1
            while i < Self.steps && lengths[i] < want { i += 1 }
            let a = lengths[i - 1], b = lengths[i]
            let local = b > a ? (want - a) / (b - a) : 0
            return Self.bezier(p0, p1, p2, p3, (Double(i - 1) + local) / Double(Self.steps))
        }

        var path: Path {
            var path = Path()
            path.move(to: p0)
            path.addCurve(to: p3, control1: p1, control2: p2)
            return path
        }
    }

    // MARK: Colour

    /// A colour as plain sRGB numbers, so two can be mixed (SwiftUI's own `mix` needs macOS 15).
    private struct Shade {
        var r, g, b, a: Double

        func color(_ opacity: Double = 1) -> Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a * opacity) }

        func mixed(_ other: Shade, _ t: Double) -> Shade {
            Shade(r: r + (other.r - r) * t, g: g + (other.g - g) * t, b: b + (other.b - b) * t, a: a + (other.a - a) * t)
        }
    }

    private struct Tone {
        var base: Shade     // comet bodies and glows
        var hot: Shade      // comet heads
        var text: Color     // the few words set in an accent

        func mixed(_ other: Tone, _ t: Double) -> Tone {
            Tone(base: base.mixed(other.base, t), hot: hot.mixed(other.hot, t), text: t < 0.5 ? text : other.text)
        }
    }

    /// The kit's accents, tuned per scheme: lifted toward white for the heads on dark glass,
    /// deepened on light glass where the pastel originals would wash out.
    private struct Tones {
        let solar, battery, grid, alert, ink: Tone

        init(environment: EnvironmentValues, dark: Bool) {
            func tone(_ color: Color) -> Tone {
                let c = color.resolve(in: environment)
                let r = Double(c.red), g = Double(c.green), b = Double(c.blue)
                func shade(_ f: (Double) -> Double) -> Shade { Shade(r: f(r), g: f(g), b: f(b), a: 1) }
                if dark {
                    return Tone(base: shade { $0 }, hot: shade { $0 + (1 - $0) * 0.5 }, text: shade { $0 + (1 - $0) * 0.16 }.color())
                }
                let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
                func deepen(_ gain: Double) -> Shade { shade { min(1, max(0, (lum + ($0 - lum) * 1.6) * gain)) } }
                return Tone(base: deepen(0.76), hot: deepen(0.64), text: deepen(0.6).color())
            }
            solar = tone(.solarAccent)
            battery = tone(.batteryAccent)
            grid = tone(.gridAccent)
            alert = tone(.alertAccent)
            // A flow whose source the feed does not show is drawn in plain ink, held back on light glass.
            let p = Color.primary.resolve(in: environment)
            let plain = Shade(r: Double(p.red), g: Double(p.green), b: Double(p.blue), a: Double(p.opacity))
            ink = Tone(base: Shade(r: plain.r, g: plain.g, b: plain.b, a: plain.a * (dark ? 0.8 : 0.5)),
                       hot: Shade(r: plain.r, g: plain.g, b: plain.b, a: plain.a * (dark ? 1 : 0.72)), text: Color.primary)
        }
    }

    // MARK: Motion

    /// One comet, ready to draw: a tapered body that is thin and faint at the tail, full at the head.
    private struct Comet {
        var spine: Path         // centre line, stroked wide and blurred for the bloom
        var body: Path          // tapered outline, filled
        var tail: CGPoint
        var head: CGPoint
        var tone: Tone
        var tailAlpha: Double
        var headAlpha: Double
        var dotAlpha: Double
        var width: CGFloat      // across the head
    }

    private static func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    private static func finite(_ x: Double) -> Double { x.isFinite ? x : 0 }

    /// A reading with anything unusable (NaN, infinity, a negative source) zeroed, so one bad number
    /// from the feed can neither reach a label nor poison the drawing.
    private static func clean(_ f: EnergyFlows) -> EnergyFlows {
        EnergyFlows(solarW: max(0, finite(f.solarW)), gridW: max(0, finite(f.gridW)),
                    batteryW: finite(f.batteryW), loadW: max(0, finite(f.loadW)), exportW: max(0, finite(f.exportW)))
    }

    /// `HeroMath.intensity` with a soft start, so a few stray watts draw a faint comet, not one at its 0.12 floor.
    private static func level(_ watts: Double) -> Double {
        HeroMath.intensity(watts) * smooth(1, 25, watts)
    }

    /// 0 for an idle element, 1 as soon as its level reaches the floor a real flow has.
    private static func presence(_ level: Double) -> Double {
        min(1, max(0, level) / 0.12)
    }

    /// Conduit lengths per second.
    private static func rate(_ watts: Double) -> Double {
        0.15 + 0.5 * pow(HeroMath.intensity(watts), 1.7)
    }

    /// How far the comets on a conduit have travelled, in cycles. Settled, it is simply `rate * clock`,
    /// so it needs no memory. When a reading changes the rate, the speed eases from the old rate to
    /// the new one across the ramp (this is the exact integral of that), and the leftover phase
    /// difference between the two clocks is slipped in gently over a slightly longer window. Comets
    /// therefore never jump: they pick up or lose speed and carry on.
    private func travel(from old: Double, to new: Double) -> Double {
        let r0 = Self.rate(old), r1 = Self.rate(new)
        let clock = now.timeIntervalSinceReferenceDate
        let since = now.timeIntervalSince(frame.changedAt)
        let ramp = HeroFrame.ramp, window = HeroFrame.ramp * 2.5
        guard since >= 0, since < window, r0 != r1 else { return r1 * clock }
        let changed = frame.changedAt.timeIntervalSinceReferenceDate
        let x = min(1, since / ramp)
        let eased = x < 0.5 ? (2.0 / 3.0) * x * x * x : (x - 0.5) + (2.0 / 3.0) * pow(1 - x, 3)
        let covered = r0 * since + (r1 - r0) * (ramp * eased + max(0, since - ramp))
        var slip = HeroMath.fract((r1 - r0) * (changed + ramp / 2))
        // Prefer catching up to falling back, and never fall back enough to run a comet backwards.
        let allowance = min(0.5, 0.8 * min(r0, r1) * window / 1.5)
        if slip > 1 - allowance { slip -= 1 }
        return r0 * changed + covered + slip * Self.smooth(0, window, since)
    }

    private static let slotOffsets: [Double] = [0, 0.5, 0.25, 0.75]
    private static let slotGates: [Double] = [0, 0.45, 0.68, 0.86]     // roughly 0, 300 W, 1 kW, 2.5 kW

    /// - Parameters:
    ///   - strength: the conduit's visual level right now, 0…1.
    ///   - settled: the level it is heading for once the ramp ends.
    ///   - front: how far along the direction of travel a flow that is starting from nothing has
    ///     reached, 0…1. A single leading comet rides the front; the regular comets light up
    ///     behind it as it passes. 1 for an established flow.
    private func addComets(_ comets: inout [Comet], on track: Track, towardHub: Bool, strength: Double, settled: Double,
                           front: Double, travel: Double, vigor: Double, tone: (Int) -> Tone) {
        guard vigor > 0, front > 0 else { return }
        let samples = 8
        var points = [CGPoint](repeating: .zero, count: samples + 1)
        var edge = [CGPoint](repeating: .zero, count: samples + 1)

        // Builds one comet whose head is `head` along the direction of travel (it may overhang either end).
        func emit(head: Double, length: Double, width: CGFloat, alpha: Double, tone: Tone) {
            // The comet enters at the source, crosses, and is swallowed by the sink: clip it to the conduit.
            let tail = head - length
            let lo = max(tail, 0), hi = min(head, 1)
            guard hi - lo > 0.015, alpha > 0.008 else { return }
            for step in 0...samples {
                let s = lo + (hi - lo) * Double(step) / Double(samples)
                points[step] = track.at(towardHub ? s : 1 - s)
            }
            var spine = Path(), body = Path()
            spine.move(to: points[0])
            for step in 0...samples {
                let a = points[max(0, step - 1)], b = points[min(samples, step + 1)]
                let run = max(0.001, hypot(b.x - a.x, b.y - a.y))
                let nx = -(b.y - a.y) / run, ny = (b.x - a.x) / run
                let along = (lo + (hi - lo) * Double(step) / Double(samples) - tail) / length
                let half = width / 2 * CGFloat(0.1 + 0.9 * pow(along, 0.85))
                let p = points[step]
                edge[step] = CGPoint(x: p.x - nx * half, y: p.y - ny * half)
                let near = CGPoint(x: p.x + nx * half, y: p.y + ny * half)
                if step == 0 { body.move(to: near) } else { body.addLine(to: near); spine.addLine(to: p) }
            }
            for step in stride(from: samples, through: 0, by: -1) { body.addLine(to: edge[step]) }
            body.closeSubpath()
            comets.append(Comet(spine: spine, body: body, tail: points[0], head: points[samples], tone: tone,
                                tailAlpha: alpha * pow((lo - tail) / length, 1.2),
                                headAlpha: alpha * pow((hi - tail) / length, 1.2),
                                dotAlpha: alpha * (1 - Self.smooth(0.95, 1.0, head)) * Self.smooth(0, 0.05, head),
                                width: width))
        }
        // Brightness: fades in up to the floor, and a trickle stays dimmer than a real flow.
        func brightness(_ level: Double) -> Double {
            Self.presence(level) * (0.55 + 0.45 * Self.smooth(0.1, 0.5, level)) * vigor
        }

        // The leader: the first pulse of a new flow, from its source end to its sink end and out.
        // It brightens as it goes, so nothing new is at full strength in the first moments of a ramp.
        var cleared = 1.0       // how far the leader's tail has got; regular comets appear behind it
        if front < 1, settled > 0.004 {
            let length = 0.26 + 0.07 * settled
            let head = front * (1 + length)
            cleared = head - length
            emit(head: head, length: length, width: CGFloat(2.3 + 0.9 * settled),
                 alpha: brightness(settled) * Self.smooth(0, 0.45, front), tone: tone(0))
        }

        guard strength > 0.004 else { return }
        let glow = brightness(strength)
        for slot in 0..<Metric.slots {
            let gate = slot == 0 ? 1 : Self.smooth(Self.slotGates[slot] - 0.07, Self.slotGates[slot] + 0.07, strength)
            guard gate > 0.01 else { continue }
            // A comet that is only partly earned is smaller as well as fainter, so it reads as a small one, not a ghost.
            let length = (0.26 + 0.07 * strength) * (0.6 + 0.4 * gate)
            let width = CGFloat((2.3 + 0.9 * strength) * (0.75 + 0.25 * gate))
            let cycle = HeroMath.fract(travel + Self.slotOffsets[slot] + (HeroMath.hash(slot * 7 + 3) - 0.5) * 0.05)
            let head = cycle * (1 + length)
            let centre = min(1, max(0, head - length / 2))
            let reveal = front >= 1 ? 1 : Self.smooth(centre - 0.1, centre, cleared)
            emit(head: head, length: length, width: width, alpha: glow * gate * reveal, tone: tone(slot))
        }
    }

    // MARK: Drawing

    private func draw(_ canvas: inout GraphicsContext, size: CGSize) {
        let dark = colorScheme == .dark
        let ink = Color.primary
        let time = now.timeIntervalSinceReferenceDate
        let snap = frame.snapshot
        let live = snap != nil
        let tones = Tones(environment: canvas.environment, dark: dark)
        let stale = snap?.isStale(now: now) ?? false
        let vigor: Double = stale ? 0.45 : 1

        // Geometry: four nodes on the corners of a rectangle, the hub at its centre.
        let radius = Metric.ring
        let mid = size.width / 2
        let reach = min(Metric.reach, mid - radius - 22)
        let block = 2 * (Metric.rise + radius) + Metric.labels
        let hubC = CGPoint(x: mid, y: (size.height - block) / 2 + radius + Metric.rise)
        let sunC = CGPoint(x: mid - reach, y: hubC.y - Metric.rise)
        let gridC = CGPoint(x: mid - reach, y: hubC.y + Metric.rise)
        let homeC = CGPoint(x: mid + reach, y: hubC.y - Metric.rise)
        let battC = CGPoint(x: mid + reach, y: hubC.y + Metric.rise)
        let hub = CGRect(x: hubC.x - Metric.hub.width / 2, y: hubC.y - Metric.hub.height / 2,
                         width: Metric.hub.width, height: Metric.hub.height)
        let sunTrack = Track(from: CGPoint(x: sunC.x + radius, y: sunC.y), to: CGPoint(x: hub.minX, y: hubC.y - Metric.port))
        let gridTrack = Track(from: CGPoint(x: gridC.x + radius, y: gridC.y), to: CGPoint(x: hub.minX, y: hubC.y + Metric.port))
        let homeTrack = Track(from: CGPoint(x: homeC.x - radius, y: homeC.y), to: CGPoint(x: hub.maxX, y: hubC.y - Metric.port))
        let battTrack = Track(from: CGPoint(x: battC.x - radius, y: battC.y), to: CGPoint(x: hub.maxX, y: hubC.y + Metric.port))

        // Facts. The labels count in watts, exactly as `frame.flows(at:)` would have them.
        let progress = frame.progress(at: now)
        let since = max(0, now.timeIntervalSince(frame.changedAt))      // seconds since the reading changed
        let before = Self.clean(frame.previous), after = Self.clean(frame.target)
        let flows = before.mix(after, progress)
        let solarW = flows.solarW, gridW = flows.gridW, loadW = flows.loadW, battW = flows.batteryW
        let percent = snap?.batteryPercent.flatMap { $0.isFinite ? min(100, max(0, $0)) : nil }
        let low = (percent ?? 100) < 20
        // An outage is a grid voltage that is reported and too low. A voltage the feed left out proves nothing.
        let outage = (snap?.gridVoltage).map { $0.isFinite && !(snap?.gridPresent ?? true) } ?? false
        let battTone = low ? tones.alert : tones.battery

        // What is drawn eases in visual level, not in watts: intensity is logarithmic, so a flow
        // rising from nothing would otherwise reach half its final strength in the first tenth of the ramp.
        func eased(_ a: Double, _ b: Double) -> Double { a + (b - a) * progress }
        let solarWas = Self.level(before.solarW), gridWas = Self.level(before.gridW), homeWas = Self.level(before.loadW)
        // How far the outage look has set in. It follows the ramp only when the grid was carrying power a moment ago.
        let cut = outage ? (gridWas > 0.004 ? progress : 1) : 0
        let solarLevel = eased(solarWas, Self.level(after.solarW))
        let importLevel = eased(gridWas, Self.level(after.gridW)) * (1 - cut)   // a dead line empties ahead of its label
        // Power sent to the grid runs the same conduit the other way, so the line carries whichever is larger.
        let exportWas = Self.level(before.exportW)
        let exportLevel = eased(exportWas, Self.level(after.exportW))
        let exporting = exportLevel > importLevel
        let gridLevel = max(importLevel, exportLevel)
        let homeFlow = eased(homeWas, Self.level(after.loadW))

        // The battery is signed. Without a battery voltage the feed gives current but no watts: then the
        // direction is still known, and is drawn at the faintest real level rather than left out.
        let amps = snap.map { Self.finite($0.batteryChargeA) - Self.finite($0.batteryDischargeA) } ?? 0
        let blind = !((snap?.batteryVoltage ?? 0) > 0) && abs(amps) > 0.4
        func signed(_ watts: Double) -> Double {
            let level = Self.level(abs(watts))
            return level > 0.004 ? (watts < 0 ? -level : level) : 0     // too faint to draw counts as no flow
        }
        let battTo = blind ? (amps > 0 ? 0.14 : -0.14) : signed(after.batteryW)
        // Blind, the previous flows cannot say what the battery was doing, so it only builds up from a standing start.
        let battFrom = blind && before != .zero ? battTo : signed(before.batteryW)
        var battFlow: Double, charging: Bool
        var battStart = 0.0, battWas = abs(battFrom)        // when a new battery flow starts building, and from what
        if battFrom * battTo < 0 {
            // Swapping direction: the old flow dies away to the moment the watts cross zero (so the
            // caption turns at the same instant), then the new one builds from nothing.
            let crossing = blind ? abs(battFrom) / (abs(battFrom) + abs(battTo))
                                 : abs(before.batteryW) / (abs(before.batteryW) + abs(after.batteryW))
            if progress < crossing {
                battFlow = abs(battFrom) * (1 - progress / crossing)
                charging = battFrom > 0
            } else {
                // The moment of the crossing in seconds: `HeroFrame.progress` run backwards.
                battStart = (crossing < 0.5 ? (crossing / 2).squareRoot() : 1 - ((1 - crossing) / 2).squareRoot()) * HeroFrame.ramp
                battFlow = abs(battTo) * (progress - crossing) / (1 - crossing)
                charging = battTo > 0
                battWas = 0
            }
        } else {
            battFlow = eased(abs(battFrom), abs(battTo))
            charging = (battTo != 0 ? battTo : battFrom) > 0
        }

        // A flow that starts from nothing sends one pulse ahead, source end to sink end, at one steady pace.
        // If the hub was dark as well, the sinks wait for the sources' pulse to land on it before theirs leave.
        let pulseTime = 0.6 * HeroFrame.ramp                // seconds for a pulse to run its conduit and leave
        let hubWasLive = max(solarWas, gridWas, battFrom < 0 ? -battFrom : 0) > 0.004
        let sinkStart = hubWasLive ? 0 : 0.46 * HeroFrame.ramp
        func front(from start: Double, was: Double) -> Double {
            was > 0.004 ? 1 : min(1, max(0, (since - start) / pulseTime))
        }
        func arrival(_ front: Double) -> Double { Self.smooth(0.55, 1, front) }     // the pulse lands at about 0.76
        let sunFront = front(from: 0, was: solarWas)
        let gridFront = front(from: 0, was: max(gridWas, exportWas))
        let homeFront = front(from: sinkStart, was: homeWas)
        let battFront = front(from: charging ? max(battStart, sinkStart) : battStart, was: battWas)
        // A sink lights when its first comet lands.
        let homeLevel = homeFlow * arrival(homeFront)
        let battLevel = battFlow * (charging ? arrival(battFront) : 1)

        let solarOn = Self.presence(solarLevel), gridOn = Self.presence(gridLevel)
        let homeOn = Self.presence(homeLevel), battOn = Self.presence(battLevel)

        // Comets leaving the hub wear the colour of what feeds them, in proportion. Settled, each comet has
        // one clean colour. When the mix changes, each crosses from its old colour to its new one over the ramp.
        func sources(_ flows: EnergyFlows) -> [(tone: Tone, watts: Double, battery: Bool)] {
            [(tones.solar, flows.solarW, false), (tones.grid, flows.gridW, false), (battTone, flows.batteryDischargeW, true)]
                .sorted { $0.watts > $1.watts }
        }
        let fedBefore = sources(before), fedAfter = sources(after)
        func pick(_ feeds: [(tone: Tone, watts: Double, battery: Bool)], _ slot: Int, battery: Bool) -> Tone? {
            let usable = feeds.filter { battery || !$0.battery }
            let total = usable.reduce(0) { $0 + $1.watts }
            guard total > 1 else { return nil }
            let want = (Self.slotOffsets[slot] + 0.125) * total
            var run = 0.0
            for item in usable {
                run += item.watts
                if want < run { return item.tone }
            }
            return usable[0].tone
        }
        func feed(_ slot: Int, battery: Bool) -> Tone {
            switch (pick(fedBefore, slot, battery: battery), pick(fedAfter, slot, battery: battery)) {
            case let (was?, will?): return was.mixed(will, progress)
            case let (was?, nil): return was
            case let (nil, will?): return will
            default: return tones.ink
            }
        }

        var comets: [Comet] = []
        comets.reserveCapacity((Metric.slots + 1) * 4)
        addComets(&comets, on: sunTrack, towardHub: true, strength: solarLevel, settled: Self.level(after.solarW), front: sunFront,
                  travel: travel(from: before.solarW, to: after.solarW), vigor: vigor) { _ in tones.solar }
        // Imported power flows in from the grid in the grid's colour; exported power leaves the hub in the colour of what feeds it.
        addComets(&comets, on: gridTrack, towardHub: !exporting, strength: gridLevel,
                  settled: max(Self.level(after.gridW), Self.level(after.exportW)), front: gridFront,
                  travel: travel(from: max(before.gridW, before.exportW), to: max(after.gridW, after.exportW)) + 0.37,
                  vigor: vigor) { slot in exporting ? feed(slot, battery: true) : tones.grid }
        addComets(&comets, on: battTrack, towardHub: !charging, strength: battFlow, settled: abs(battTo), front: battFront,
                  travel: travel(from: abs(before.batteryW), to: abs(after.batteryW)) + 0.61, vigor: vigor) { slot in
            charging ? feed(slot, battery: false) : battTone
        }
        addComets(&comets, on: homeTrack, towardHub: false, strength: homeFlow, settled: Self.level(after.loadW), front: homeFront,
                  travel: travel(from: before.loadW, to: after.loadW) + 0.83, vigor: vigor) { slot in
            feed(slot, battery: true)
        }

        // 1. Halos: a soft pool of light behind whatever is working.
        let pulse = 0.5 + 0.5 * sin(time * 2.4)
        let glowGain = (dark ? 1.0 : 0.75) * vigor
        canvas.drawLayer { glow in
            glow.addFilter(.blur(radius: 9))
            func halo(_ c: CGPoint, _ color: Color, _ alpha: Double) {
                guard alpha > 0.004 else { return }
                glow.fill(Path(ellipseIn: Self.circle(c, radius - 3)), with: .color(color.opacity(alpha * glowGain)))
            }
            halo(sunC, tones.solar.base.color(), 0.34 * solarLevel)
            halo(gridC, tones.grid.base.color(), 0.32 * gridLevel)
            halo(homeC, ink, 0.12 * homeLevel)
            if low && live {
                halo(battC, tones.alert.base.color(), 0.20 + 0.16 * pulse * min(1, battOn + 0.3))
            } else {
                halo(battC, tones.battery.base.color(), 0.30 * battLevel)
            }
        }

        // 2. Conduits: always there as hairlines, a little brighter while they carry power.
        func conduit(_ track: Track, _ on: Double, broken: Double = 0) {
            let alpha = live ? 0.13 + 0.17 * on : 0.09
            if broken < 1 {
                canvas.stroke(track.path, with: .color(ink.opacity(alpha * (1 - broken))), style: StrokeStyle(lineWidth: 1, lineCap: .round))
            }
            if broken > 0 {
                canvas.stroke(track.path, with: .color(ink.opacity(alpha * broken)), style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [1.5, 4.5]))
            }
        }
        conduit(sunTrack, solarOn)
        conduit(gridTrack, gridOn, broken: cut)
        conduit(homeTrack, homeOn)
        conduit(battTrack, battOn)

        // 3. Comets: a blurred bloom underneath, then the crisp tapered body and its head.
        if !comets.isEmpty {
            canvas.drawLayer { bloom in
                bloom.addFilter(.blur(radius: 2.8))
                for comet in comets {
                    let peak = comet.headAlpha * (dark ? 0.5 : 0.36)
                    bloom.stroke(comet.spine, with: .linearGradient(
                        Gradient(colors: [comet.tone.base.color(0), comet.tone.base.color(peak)]),
                        startPoint: comet.tail, endPoint: comet.head),
                        style: StrokeStyle(lineWidth: comet.width + 2.4, lineCap: .round, lineJoin: .round))
                }
            }
            for comet in comets {
                canvas.fill(comet.body, with: .linearGradient(
                    Gradient(colors: [comet.tone.base.color(comet.tailAlpha * 0.8), comet.tone.base.color(comet.headAlpha)]),
                    startPoint: comet.tail, endPoint: comet.head))
                if comet.dotAlpha > 0.02 {
                    canvas.fill(Path(ellipseIn: Self.circle(comet.head, comet.width / 2 + 0.35)),
                                with: .color(comet.tone.hot.color(comet.dotAlpha)))
                }
            }
        }

        // 4. Nodes.
        func disc(_ c: CGPoint, _ on: Double, dashed: Double = 0) {
            let shape = Path(ellipseIn: Self.circle(c, radius))
            let top = live ? 0.09 : 0.05, bottom = live ? 0.03 : 0.02
            canvas.fill(shape, with: .linearGradient(Gradient(colors: [ink.opacity(top), ink.opacity(bottom)]),
                                                     startPoint: CGPoint(x: c.x, y: c.y - radius), endPoint: CGPoint(x: c.x, y: c.y + radius)))
            let alpha = live ? 0.17 + 0.23 * on : 0.12
            if dashed < 1 { canvas.stroke(shape, with: .color(ink.opacity(alpha * (1 - dashed))), lineWidth: 1) }
            if dashed > 0 {
                canvas.stroke(shape, with: .color(ink.opacity(alpha * dashed)), style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [2, 3.5]))
            }
        }
        func glyphAlpha(_ on: Double) -> Double { live ? 0.36 + 0.54 * on : 0.22 }

        disc(sunC, solarOn)
        drawSun(&canvas, at: sunC, alpha: glyphAlpha(solarOn), on: solarOn, level: solarLevel, time: time, tone: tones.solar)

        disc(gridC, gridOn, dashed: cut)
        drawPylon(&canvas, at: gridC, alpha: glyphAlpha(gridOn) + (0.26 - glyphAlpha(gridOn)) * cut, cut: cut)

        disc(homeC, homeOn)
        drawHouse(&canvas, at: homeC, alpha: glyphAlpha(homeOn), lit: homeLevel)

        disc(battC, battOn)
        if let percent {
            let fraction = percent / 100
            var arc = Path()
            if fraction > 0.995 {
                arc.addEllipse(in: Self.circle(battC, radius))
            } else {
                arc.addArc(center: battC, radius: radius, startAngle: .degrees(-90),
                           endAngle: .degrees(-90 + 360 * max(0.012, fraction)), clockwise: false)
            }
            let arcColor = low ? tones.alert.text : ink.opacity((0.42 + 0.3 * battOn) * (dark ? 1 : 0.85))
            canvas.stroke(arc, with: .color(arcColor), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
        }
        drawBattery(&canvas, at: battC, alpha: glyphAlpha(max(battOn, percent == nil ? 0 : 0.35)),
                    fraction: percent.map { $0 / 100 }, low: low, tone: tones.alert)

        // 5. Hub. It wakes when power reaches it, from a source or (if the feed shows none) for the load.
        let through = max(solarLevel * arrival(sunFront), importLevel * arrival(gridFront),
                          charging ? 0 : battFlow * arrival(battFront), homeLevel)
        drawHub(&canvas, rect: hub, activity: live ? through * vigor : 0, live: live, time: time, dark: dark,
                ports: [(sunTrack.p3, solarOn), (gridTrack.p3, gridOn), (homeTrack.p3, homeOn), (battTrack.p3, battOn)])

        // 6. Labels. Quiet text needs a little more ink on light glass to hold the same contrast.
        let lift = dark ? 1.0 : 1.22
        func value(_ string: String, _ alpha: Double, _ color: Color = .primary) -> Text {
            Text(string).font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(color.opacity(min(1, alpha * lift)))
        }
        func caption(_ string: String, _ alpha: Double) -> Text {
            Text(string).font(.system(size: 9.5, weight: .medium)).foregroundStyle(ink.opacity(min(1, alpha * lift)))
        }
        func reading(_ string: String, _ on: Double, fade: Double = 1) -> Text {
            live ? value(string, (0.38 + 0.54 * on * (stale ? 0.6 : 1)) * fade) : value("--", 0.24)
        }
        func valuePoint(_ c: CGPoint) -> CGPoint { CGPoint(x: c.x, y: c.y + radius + 11.5) }
        func captionPoint(_ c: CGPoint) -> CGPoint { CGPoint(x: c.x, y: c.y + radius + 24) }
        func label(_ c: CGPoint, _ top: Text, _ bottom: Text) {
            canvas.draw(top, at: valuePoint(c), anchor: .center)
            canvas.draw(bottom, at: captionPoint(c), anchor: .center)
        }
        let quiet = live ? 0.42 : 0.3

        label(sunC, reading(PowerFormat.watts(solarW), solarOn), caption("Solar", quiet + 0.12 * solarOn))
        label(homeC, reading(PowerFormat.watts(loadW), homeOn), caption("Home", quiet + 0.12 * homeOn))

        // Grid: its watts, or "Outage" once the line is gone. The two never overlap: one leaves, then the other arrives.
        let leaving = 1 - Self.smooth(0, 0.5, cut), arriving = Self.smooth(0.5, 1, cut)
        // While power is being sent to the grid, the label is the export, with an arrow out.
        let sending = flows.exportW > 15
        let gridText = sending ? "↑ " + PowerFormat.watts(flows.exportW) : PowerFormat.watts(gridW)
        if leaving > 0.01 { canvas.draw(reading(gridText, gridOn, fade: leaving), at: valuePoint(gridC), anchor: .center) }
        if arriving > 0.01 { canvas.draw(value("Outage", arriving, tones.alert.text), at: valuePoint(gridC), anchor: .center) }
        canvas.draw(caption(sending ? "Export" : "Grid", quiet + 0.12 * gridOn), at: captionPoint(gridC), anchor: .center)

        // Battery: watts (or amps when that is all the feed gives), then charge and what it is doing.
        let filling = blind ? amps > 0 : battW > 15, draining = blind ? amps < 0 : battW < -15
        let state: String?
        if filling { state = "Charging" }
        else if low { state = "Low" }
        else if draining { state = "Discharging" }
        else if let percent { state = percent >= 99.5 ? "Full" : "Idle" }
        else { state = nil }
        let battReading = blind ? "\(Int(min(999, abs(amps)).rounded())) A" : PowerFormat.watts(battW)
        canvas.draw(reading(battReading, blind ? 1 : battOn), at: valuePoint(battC), anchor: .center)
        var battCaption: Text
        if let percent {
            var figure = AttributedString("\(Int(percent.rounded()))%")
            figure.font = .system(size: 9.5, weight: .semibold).monospacedDigit()
            figure.foregroundColor = low ? tones.alert.text : ink.opacity(0.9)
            var rest = AttributedString("  \(state ?? "")")
            rest.font = .system(size: 9.5, weight: .medium)
            rest.foregroundColor = low ? tones.alert.text.opacity(0.85) : ink.opacity(min(1, (quiet + 0.12 * battOn) * lift))
            battCaption = Text(figure + rest)
        } else {
            battCaption = caption(live ? state ?? "Battery" : "Battery", quiet + 0.12 * battOn)
        }
        // The widest label on the map: keep it centred under its node unless that would push it off the canvas.
        let resolved = canvas.resolve(battCaption)
        let half = resolved.measure(in: CGSize(width: 400, height: 40)).width / 2
        let battX = max(half + Metric.edge, min(battC.x, size.width - Metric.edge - half))
        canvas.draw(resolved, at: CGPoint(x: battX, y: captionPoint(battC).y), anchor: .center)

        // Status under the hub: what is carrying the load, then anything that needs attention.
        // Each line is cut to the room between the two lower conduits at its own height.
        func room(at y: CGFloat) -> CGFloat {
            var half = mid - Metric.edge
            for step in 0...12 {
                let point = gridTrack.at(Double(step) / 12)
                if abs(point.y - y) < 8 { half = min(half, mid - point.x - 6) }
            }
            return max(24, half * 2)
        }
        func fitted(_ string: String, width: CGFloat, _ style: (String) -> Text) -> GraphicsContext.ResolvedText {
            var kept = string
            var resolved = canvas.resolve(style(kept))
            var measured = resolved.measure(in: CGSize(width: 2000, height: 40)).width
            var tries = 0
            while measured > width, kept.count > 4, tries < 3 {
                // Cut in proportion, back to a whole word where that still leaves most of the line.
                var shorter = String(kept.prefix(max(4, Int(Double(kept.count) * Double(width / measured)) - 1)))
                if let space = shorter.lastIndex(of: " "), shorter.distance(from: shorter.startIndex, to: space) > shorter.count / 2 {
                    shorter = String(shorter[..<space])
                }
                kept = shorter
                resolved = canvas.resolve(style(kept + "\u{2026}"))
                measured = resolved.measure(in: CGSize(width: 2000, height: 40)).width
                tries += 1
            }
            return resolved
        }
        var status: [(String, (String) -> Text)] = []
        if let snap {
            if stale, let seen = snap.deviceTime {
                let minutes = max(1, Int(min(1e9, now.timeIntervalSince(seen) / 60)))
                let ago = minutes < 100 ? "\(minutes) min" : minutes < 48 * 60 ? "\(minutes / 60) h" : "\(minutes / 1440) d"
                status.append(("Updated \(ago) ago", { caption($0, 0.55) }))
            } else if snap.mode != .unknown {
                status.append((snap.mode.label, { caption($0, 0.55) }))
            }
            // One line, whatever the feed sends: no line breaks, and no more text than could ever fit.
            let warning = (snap.activeWarning ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !warning.isEmpty {
                status.append((String(warning.prefix(60)), { Text($0).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(tones.alert.text) }))
            }
        } else {
            status.append(("Waiting for data", { caption($0, 0.5) }))
        }
        for (row, line) in status.enumerated() {
            let y = hub.maxY + 12 + 13 * CGFloat(row)
            canvas.draw(fitted(line.0, width: room(at: y), line.1), at: CGPoint(x: hubC.x, y: y), anchor: .center)
        }
    }

    // MARK: Glyphs

    private static func circle(_ c: CGPoint, _ r: CGFloat) -> CGRect {
        CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
    }

    private static let line = StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round)

    private func drawSun(_ canvas: inout GraphicsContext, at c: CGPoint, alpha: Double, on: Double, level: Double, time: Double, tone: Tone) {
        let ink = Color.primary
        let core = Path(ellipseIn: Self.circle(c, 3.8))
        var rays = Path()
        for k in 0..<8 {
            let angle = Double(k) * .pi / 4
            let shimmer = sin(time * 1.9 + Double(k) * 2.4) * 0.9 * level
            let inner = 6.4, outer = 8.6 + 0.9 * level + shimmer
            rays.move(to: CGPoint(x: c.x + cos(angle) * inner, y: c.y + sin(angle) * inner))
            rays.addLine(to: CGPoint(x: c.x + cos(angle) * outer, y: c.y + sin(angle) * outer))
        }
        canvas.stroke(rays, with: .color(ink.opacity(alpha)), style: Self.line)
        // The core warms up as soon as the panels produce anything, and brightens with output.
        if on > 0.01 { canvas.fill(core, with: .color(tone.base.color(on * (0.45 + 0.5 * level)))) }
        canvas.stroke(core, with: .color(ink.opacity(alpha)), style: Self.line)
    }

    /// `cut` runs 0…1 as an outage sets in: the strike-through draws itself across the tower.
    private func drawPylon(_ canvas: inout GraphicsContext, at c: CGPoint, alpha: Double, cut: Double) {
        let ink = Color.primary
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: c.x + x, y: c.y + y) }
        var tower = Path()
        tower.move(to: p(-5.5, 9)); tower.addLine(to: p(-1.5, -9)); tower.addLine(to: p(1.5, -9)); tower.addLine(to: p(5.5, 9))
        tower.move(to: p(-7, -5)); tower.addLine(to: p(7, -5))
        tower.move(to: p(-8.5, -0.5)); tower.addLine(to: p(8.5, -0.5))
        tower.move(to: p(-7, -5)); tower.addLine(to: p(-7, -3.2))
        tower.move(to: p(7, -5)); tower.addLine(to: p(7, -3.2))
        tower.move(to: p(-8.5, -0.5)); tower.addLine(to: p(-8.5, 1.3))
        tower.move(to: p(8.5, -0.5)); tower.addLine(to: p(8.5, 1.3))
        tower.move(to: p(-3.4, -0.5)); tower.addLine(to: p(4.6, 5)); tower.addLine(to: p(-4.6, 5)); tower.addLine(to: p(3.4, -0.5))
        canvas.stroke(tower, with: .color(ink.opacity(alpha)), style: StrokeStyle(lineWidth: 1.15, lineCap: .round, lineJoin: .round))
        if cut > 0.02 {
            // No grid: the tower is struck through.
            let drawn = CGFloat(Self.smooth(0, 1, cut)) * 21
            var slash = Path()
            slash.move(to: p(-10.5, 10.5)); slash.addLine(to: p(-10.5 + drawn, 10.5 - drawn))
            canvas.stroke(slash, with: .color(ink.opacity(0.62 * Self.smooth(0, 0.2, cut))), style: Self.line)
        }
    }

    private func drawHouse(_ canvas: inout GraphicsContext, at c: CGPoint, alpha: Double, lit: Double) {
        let ink = Color.primary
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: c.x + x, y: c.y + y - 0.5) }
        var door = Path()
        door.move(to: p(-2.1, 7.8)); door.addLine(to: p(-2.1, 3.6))
        door.addQuadCurve(to: p(2.1, 3.6), control: p(0, 1.2))
        door.addLine(to: p(2.1, 7.8))
        if lit > 0.01 { canvas.fill(door, with: .color(ink.opacity(min(1, lit * 1.5) * 0.55))) }
        var house = Path()
        house.move(to: p(-8.8, -0.6)); house.addLine(to: p(0, -8.4)); house.addLine(to: p(8.8, -0.6))
        house.move(to: p(-6.3, -2.6)); house.addLine(to: p(-6.3, 7.8)); house.addLine(to: p(6.3, 7.8)); house.addLine(to: p(6.3, -2.6))
        canvas.stroke(house, with: .color(ink.opacity(alpha)), style: Self.line)
        canvas.stroke(door, with: .color(ink.opacity(alpha * 0.8)), style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round))
    }

    private func drawBattery(_ canvas: inout GraphicsContext, at c: CGPoint, alpha: Double, fraction: Double?, low: Bool, tone: Tone) {
        let ink = Color.primary
        let body = CGRect(x: c.x - 9, y: c.y - 5, width: 15.5, height: 10)
        canvas.stroke(Path(roundedRect: body, cornerRadius: 3, style: .continuous), with: .color(ink.opacity(alpha)), lineWidth: 1.3)
        let cap = CGRect(x: body.maxX + 1.3, y: c.y - 2, width: 1.7, height: 4)
        canvas.fill(Path(roundedRect: cap, cornerRadius: 0.8), with: .color(ink.opacity(alpha)))
        if let fraction {
            let well = body.insetBy(dx: 2.1, dy: 2.1)
            let fill = CGRect(x: well.minX, y: well.minY, width: max(1.6, well.width * fraction), height: well.height)
            let color = low ? tone.text : ink.opacity(alpha * 0.75)
            canvas.fill(Path(roundedRect: fill, cornerRadius: 1.1, style: .continuous), with: .color(color))
        }
    }

    private func drawHub(_ canvas: inout GraphicsContext, rect: CGRect, activity: Double, live: Bool,
                         time: Double, dark: Bool, ports: [(CGPoint, Double)]) {
        let ink = Color.primary
        let shell = Path(roundedRect: rect, cornerRadius: 9, style: .continuous)
        canvas.fill(shell, with: .linearGradient(Gradient(colors: [ink.opacity(live ? 0.12 : 0.07), ink.opacity(live ? 0.04 : 0.03)]),
                                                 startPoint: CGPoint(x: rect.midX, y: rect.minY), endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
        canvas.stroke(shell, with: .color(ink.opacity(live ? 0.22 + 0.2 * min(1, activity * 2) : 0.13)), lineWidth: 1)
        var highlight = Path()
        highlight.move(to: CGPoint(x: rect.minX + 9, y: rect.minY + 1.5))
        highlight.addLine(to: CGPoint(x: rect.maxX - 9, y: rect.minY + 1.5))
        canvas.stroke(highlight, with: .color(ink.opacity(live ? 0.14 : 0.07)), style: StrokeStyle(lineWidth: 1, lineCap: .round))

        // Display: a flat trace at rest, a sine wave while the inverter is making AC.
        let window = CGRect(x: rect.minX + 5, y: rect.minY + 5.5, width: rect.width - 10, height: 14)
        canvas.fill(Path(roundedRect: window, cornerRadius: 4, style: .continuous),
                    with: .color(Color.black.opacity(dark ? 0.34 : 0.10)))
        let swing = 3.8 * min(1, activity * 1.6)
        var wave = Path()
        let span = window.width - 7
        for step in 0...18 {
            let f = Double(step) / 18
            let envelope = sin(.pi * f)
            let y = window.midY + CGFloat(sin(f * 3.4 * .pi - time * 3.2) * swing * (0.35 + 0.65 * envelope))
            let point = CGPoint(x: window.minX + 3.5 + span * CGFloat(f), y: y)
            if step == 0 { wave.move(to: point) } else { wave.addLine(to: point) }
        }
        canvas.stroke(wave, with: .color(ink.opacity(live ? 0.4 + 0.5 * min(1, activity * 2) : 0.2)),
                      style: StrokeStyle(lineWidth: 1.15, lineCap: .round, lineJoin: .round))

        // Vents.
        var vents = Path()
        for row in 0..<3 {
            let y = rect.minY + 25.5 + CGFloat(row) * 4
            vents.move(to: CGPoint(x: rect.midX - 7, y: y)); vents.addLine(to: CGPoint(x: rect.midX + 7, y: y))
        }
        canvas.stroke(vents, with: .color(ink.opacity(live ? 0.17 : 0.1)), style: StrokeStyle(lineWidth: 1, lineCap: .round))

        // Ports where the conduits land.
        for (point, on) in ports {
            canvas.fill(Path(ellipseIn: Self.circle(point, 1.6)), with: .color(ink.opacity(live ? 0.3 + 0.34 * on : 0.18)))
        }
    }
}
