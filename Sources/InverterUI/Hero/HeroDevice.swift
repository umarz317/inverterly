import SwiftUI
import InverterCore

/// "Device": the wall-mounted hybrid inverter is the subject. Solar and grid feed it from the left,
/// the home and the battery hang off its right side. Its display lights up while it is working and
/// its output runs to the house; each conduit carries wisps only while power flows in it.
///
/// A pure function of `(frame, now)`: every moving thing is positioned from the reference clock at a
/// constant rate, so nothing jumps when a new reading arrives or while a flow eases. Speed follows
/// power by cross-fading between wisp populations of fixed, increasing speeds, never by changing a
/// wisp's own rate; how much power shows as how many wisps there are and how long they are.
/// Read-only: it draws the snapshot and touches nothing else.
struct HeroDevice: View {
    let frame: HeroFrame
    let now: Date
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Canvas { canvas, size in
            // Drawn at design size and centred. Given less room it shrinks to fit rather than clip; it never grows.
            let fit = min(1, size.width / DeviceGeo.size.width, size.height / DeviceGeo.size.height)
            guard fit > 0, fit.isFinite else { return }
            let state = DeviceState(frame: frame, now: now, dark: colorScheme == .dark, environment: canvas.environment)
            canvas.translateBy(x: (size.width - DeviceGeo.size.width * fit) / 2, y: (size.height - DeviceGeo.size.height * fit) / 2)
            canvas.scaleBy(x: fit, y: fit)
            DevicePainter(s: state).draw(&canvas)
        } symbols: {
            ForEach(DeviceGeo.glyphs, id: \.mode) { glyph in
                Image(systemName: glyph.symbol)
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .tag(glyph.mode.rawValue)
            }
        }
    }
}

// MARK: - Layout

/// Fixed geometry in design points. The drawing is 348 by 172 and is centred in whatever it is given.
private enum DeviceGeo {
    static let size = CGSize(width: 348, height: 172)

    static let body = CGRect(x: 132, y: 18, width: 84, height: 124)
    static let lcd = CGRect(x: 141, y: 30, width: 66, height: 20)
    static let seamY: CGFloat = 94

    /// The two rows everything hangs on: solar and home above, grid and battery below.
    static let rowTop: CGFloat = 48
    static let rowBottom: CGFloat = 112
    static let left: CGFloat = 46
    static let right: CGFloat = 302
    static let labelTop: CGFloat = 75
    static let labelBottom: CGFloat = 145
    static let captionY: CGFloat = 158

    static let sun = CGPoint(x: 24, y: 35)
    static let battery = CGRect(x: 279, y: 98, width: 46, height: 28)
    static let window = CGRect(x: 298, y: 44, width: 8, height: 8)

    static let solarFrom = CGPoint(x: 79, y: rowTop), solarTo = CGPoint(x: 128, y: rowTop)
    static let gridFrom = CGPoint(x: 62, y: rowBottom), gridTo = CGPoint(x: 128, y: rowBottom)
    static let batteryNear = CGPoint(x: 220, y: rowBottom), batteryFar = CGPoint(x: 276, y: rowBottom)
    static let outputFrom = CGPoint(x: 224, y: rowTop), outputTo = CGPoint(x: 286, y: rowTop)

    /// Mode glyphs for the display. An unknown mode shows the load alone.
    static let glyphs: [(mode: InverterMode, symbol: String)] = [
        (.solar, "sun.max.fill"), (.battery, "battery.75percent"), (.grid, "bolt.fill"), (.standby, "moon.fill"),
    ]
}

// MARK: - Colour

private struct DeviceTone {
    var r: Double, g: Double, b: Double

    func color(_ alpha: Double = 1) -> Color { Color(red: r, green: g, blue: b).opacity(alpha) }

    /// The HeroKit accents are tuned for a dark panel. On a light one the same hue is deepened and
    /// saturated so a thin moving stroke still reads.
    static func accent(_ color: Color, dark: Bool, in environment: EnvironmentValues) -> DeviceTone {
        let c = color.resolve(in: environment)
        let r = Double(c.red), g = Double(c.green), b = Double(c.blue)
        guard !dark else { return DeviceTone(r: r, g: g, b: b) }
        let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
        func deepen(_ v: Double) -> Double { min(1, max(0, (v - luma) * 1.35 + luma * 0.60)) }
        return DeviceTone(r: deepen(r), g: deepen(g), b: deepen(b))
    }
}

// MARK: - State for one frame

private struct DeviceState {
    let snapshot: EnergySnapshot?
    /// The flows this reading replaced, as the frame has them.
    let previous: EnergyFlows
    let live: Bool
    let dark: Bool
    let time: Double

    // Eased magnitudes, watts. `gridW` already dies away with `gridFade` in an outage.
    let solarW: Double, gridW: Double, chargeW: Double, dischargeW: Double, loadW: Double
    /// 0…1 presence of each flow. A flow that was already running stays at 1 while its power eases; a new
    /// one builds with the 1.1 s ramp and a dying one fades with it, so nothing appears at full strength.
    let solarOn: Double, gridOn: Double, chargeOn: Double, dischargeOn: Double, loadLevel: Double
    /// 0…1 display backlight, following the ramp.
    let lcdLevel: Double
    /// How brightly the home's window is lit: on with the load, brighter with more of it.
    let windowLevel: Double
    /// 0…1 grid lost. The flow dies over the first half of the ramp (`gridFade`), then the line parts (`gridBreak`).
    let outage: Double, gridFade: Double, gridBreak: Double
    /// How brightly the sun is lit: a trickle of PV lights it faintly, a strong array fully.
    let shine: Double
    /// 0…1 once the logger's last report is older than 15 minutes; the motion is held back.
    let stale: Double
    /// 1 while anything flows, easing to 0 once nothing does. With nothing flowing the host stops the
    /// clock, so the alert pulses settle to a steady glow instead of freezing wherever they happened to be.
    let motion: Double

    let percent: Double?
    let low: Bool
    /// Static ink is drawn at this strength: full with data, held back while waiting for it.
    let strength: Double

    let solar: DeviceTone, battery: DeviceTone, grid: DeviceTone, alert: DeviceTone
    /// The output's colour: the sources carrying the load right now, mixed in proportion.
    let output: DeviceTone

    init(frame: HeroFrame, now: Date, dark: Bool, environment: EnvironmentValues) {
        let flows = frame.flows(at: now)
        let progress = frame.progress(at: now)
        let previous = frame.previous, target = frame.target
        func any(_ f: EnergyFlows) -> Bool { f.solarW > 1 || f.gridW > 1 || abs(f.batteryW) > 1 || f.loadW > 1 }
        func presence(_ eased: Double, _ was: Double, _ willBe: Double) -> Double {
            let gate = min(1, max(0, eased / 30))            // the last few watts never pop in or out
            if was > 1, willBe > 1 { return gate }
            let end = willBe > 1 ? willBe : was
            return end > 1 ? gate * min(1, max(0, eased / end)) : 0
        }

        snapshot = frame.snapshot
        self.previous = previous
        live = frame.snapshot != nil
        self.dark = dark
        time = now.timeIntervalSinceReferenceDate

        if let snapshot = frame.snapshot, !snapshot.gridPresent {
            let lost = previous.gridW > 1 ? progress : 1
            outage = lost
            gridFade = 1 - min(1, lost / 0.45)
            gridBreak = min(1, max(0, (lost - 0.45) / 0.55))
        } else {
            outage = 0; gridFade = 1; gridBreak = 0
        }

        let gridFlow = flows.gridW * gridFade
        solarW = flows.solarW; gridW = gridFlow; loadW = flows.loadW
        chargeW = flows.batteryChargeW; dischargeW = flows.batteryDischargeW

        solarOn = presence(flows.solarW, previous.solarW, target.solarW)
        gridOn = presence(flows.gridW, previous.gridW, target.gridW) * gridFade
        chargeOn = presence(flows.batteryChargeW, previous.batteryChargeW, target.batteryChargeW)
        dischargeOn = presence(flows.batteryDischargeW, previous.batteryDischargeW, target.batteryDischargeW)
        let load = presence(flows.loadW, previous.loadW, target.loadW)
        loadLevel = load

        motion = any(target) ? 1 : any(previous) ? 1 - progress : 0

        // The display dims rather than lights fully when the inverter is only ticking over in standby.
        let lit: Double = !any(target) ? 0 : frame.snapshot?.mode == .standby ? 0.5 : 1
        lcdLevel = (any(previous) ? 1 : 0) * (1 - progress) + lit * progress
        windowLevel = load * (0.45 + 0.55 * HeroMath.intensity(flows.loadW))
        shine = solarOn * (0.3 + 0.7 * HeroMath.intensity(flows.solarW))
        if let reported = frame.snapshot?.deviceTime {
            stale = min(1, max(0, (now.timeIntervalSince(reported) - 15 * 60) / 20))
        } else {
            stale = 0
        }

        // A percent that is missing or not a number draws no level at all rather than an empty, alarming pack.
        percent = frame.snapshot?.batteryPercent.flatMap { $0.isFinite ? min(100, max(0, $0)) : nil }
        low = (percent ?? 100) < 20
        strength = frame.snapshot == nil ? (any(previous) ? 1 - 0.4 * progress : 0.6) : 1

        let solarTone = DeviceTone.accent(.solarAccent, dark: dark, in: environment)
        let batteryTone = DeviceTone.accent(.batteryAccent, dark: dark, in: environment)
        let gridTone = DeviceTone.accent(.gridAccent, dark: dark, in: environment)
        solar = solarTone; battery = batteryTone; grid = gridTone
        alert = DeviceTone.accent(.alertAccent, dark: dark, in: environment)
        // Load with no source accounted for (rounding in the feed): draw it in plain ink.
        let neutral = dark ? DeviceTone(r: 0.90, g: 0.93, b: 0.97) : DeviceTone(r: 0.24, g: 0.27, b: 0.32)

        let sources = [(flows.solarW, solarTone), (flows.batteryDischargeW, batteryTone), (gridFlow, gridTone)]
        let total = sources.reduce(0) { $0 + $1.0 }
        output = total > 1
            ? DeviceTone(r: sources.reduce(0) { $0 + $1.1.r * $1.0 } / total,
                         g: sources.reduce(0) { $0 + $1.1.g * $1.0 } / total,
                         b: sources.reduce(0) { $0 + $1.1.b * $1.0 } / total)
            : neutral
    }

    /// 0…1 "how much", spread evenly over the range this inverter works in: about 0.14 at 100 W, 0.45 at
    /// 1 kW and 0.77 at 3 kW. `HeroMath.intensity` sets the speed; it is too compressed to count wisps by,
    /// since 800 W and 2.6 kW would then look alike.
    static func amount(_ watts: Double) -> Double { watts > 1 ? min(1, (watts / 5000).squareRoot()) : 0 }

    static func fade(_ x: Double, _ from: Double, _ to: Double) -> Double { min(1, max(0, (x - from) / (to - from))) }
}

// MARK: - Drawing

private struct DevicePainter {
    let s: DeviceState
    private var ink: Color { .primary }

    func draw(_ c: inout GraphicsContext) {
        glows(&c)
        conduits(&c)
        inverter(&c)
        solar(&c)
        pylon(&c)
        house(&c)
        battery(&c)
        energy(&c)
        labels(&c)
    }

    // MARK: Glows (one blurred layer)

    private func glows(_ c: inout GraphicsContext) {
        let sunOn = s.shine, chargeOn = s.chargeOn
        guard sunOn > 0.01 || s.loadLevel > 0.01 || (s.dark && s.lcdLevel > 0.01) || chargeOn > 0.01 else { return }
        let mid = s.output
        c.drawLayer { glow in
            glow.addFilter(.blur(radius: 6))
            if sunOn > 0.01 {
                let breathe = 0.85 + 0.15 * sin(s.time * 1.3)
                let r: CGFloat = 10
                glow.fill(Path(ellipseIn: CGRect(x: DeviceGeo.sun.x - r, y: DeviceGeo.sun.y - r, width: r * 2, height: r * 2)),
                          with: .color(s.solar.color(0.5 * sunOn * breathe)))
            }
            if s.dark, s.lcdLevel > 0.01 {
                // Backlight spill. On a light panel the display reads as a recess, so there is none.
                glow.fill(Path(roundedRect: DeviceGeo.lcd.insetBy(dx: 3, dy: 2), cornerRadius: 5, style: .continuous),
                          with: .color(ink.opacity(0.22 * s.lcdLevel)))
            }
            if s.loadLevel > 0.01 {
                // The lit window the output arrives at.
                glow.fill(Path(roundedRect: DeviceGeo.window.insetBy(dx: -2, dy: -2), cornerRadius: 3),
                          with: .color(mid.color(0.55 * s.windowLevel)))
            }
            if chargeOn > 0.01, let percent = s.percent {
                let inner = DeviceGeo.battery.insetBy(dx: 3, dy: 3)
                let edge = inner.minX + inner.width * percent / 100
                glow.fill(Path(ellipseIn: CGRect(x: edge - 5, y: inner.minY, width: 10, height: inner.height)),
                          with: .color(s.battery.color(0.45 * chargeOn * (0.7 + 0.3 * sin(s.time * 2.2)))))
            }
        }
    }

    // MARK: Conduits

    private func conduits(_ c: inout GraphicsContext) {
        let k = s.strength
        func track(_ a: CGPoint, _ b: CGPoint, active: Double) {
            var path = Path()
            path.move(to: a); path.addLine(to: b)
            c.stroke(path, with: .color(ink.opacity((0.15 + 0.12 * active) * k)), style: StrokeStyle(lineWidth: 1, lineCap: .round))
        }
        track(DeviceGeo.solarFrom, DeviceGeo.solarTo, active: s.solarOn)
        track(DeviceGeo.batteryNear, DeviceGeo.batteryFar, active: max(s.chargeOn, s.dischargeOn))

        // Grid feed. In an outage the line parts in the middle and a small cross marks the break.
        let a = DeviceGeo.gridFrom, b = DeviceGeo.gridTo
        if s.gridBreak > 0.01 {
            let mid = (a.x + b.x) / 2, gap = 9 * s.gridBreak
            var path = Path()
            path.move(to: a); path.addLine(to: CGPoint(x: mid - gap, y: a.y))
            path.move(to: CGPoint(x: mid + gap, y: a.y)); path.addLine(to: b)
            c.stroke(path, with: .color(ink.opacity(0.15 - 0.04 * s.gridBreak)),
                     style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [2.5, 3]))
            var cross = Path()
            cross.move(to: CGPoint(x: mid - 3, y: a.y - 3)); cross.addLine(to: CGPoint(x: mid + 3, y: a.y + 3))
            cross.move(to: CGPoint(x: mid + 3, y: a.y - 3)); cross.addLine(to: CGPoint(x: mid - 3, y: a.y + 3))
            c.stroke(cross, with: .color(s.alert.color(0.85 * s.gridBreak)), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
        } else {
            track(a, b, active: s.gridOn)
        }

        track(DeviceGeo.outputFrom, DeviceGeo.outputTo, active: s.loadLevel)
    }

    // MARK: Inverter

    private func inverter(_ c: inout GraphicsContext) {
        let k = s.strength
        let body = DeviceGeo.body
        let shell = Path(roundedRect: body, cornerRadius: 10, style: .continuous)
        let seamY = DeviceGeo.seamY

        // Cable glands where the conduits meet the case.
        for y in [DeviceGeo.rowTop, DeviceGeo.rowBottom] {
            let gland = Path(roundedRect: CGRect(x: body.minX - 4, y: y - 4.5, width: 6, height: 9), cornerRadius: 2, style: .continuous)
            c.fill(gland, with: .color(ink.opacity(0.10 * k)))
            c.stroke(gland, with: .color(ink.opacity(0.22 * k)), lineWidth: 1)
        }
        let rightGland = Path(roundedRect: CGRect(x: body.maxX - 2, y: DeviceGeo.rowBottom - 4.5, width: 6, height: 9), cornerRadius: 2, style: .continuous)
        c.fill(rightGland, with: .color(ink.opacity(0.10 * k)))
        c.stroke(rightGland, with: .color(ink.opacity(0.22 * k)), lineWidth: 1)

        // Output vent on the right flank: the counterpart of a louver. It darkens and shows its vanes when the load is on.
        let vent = CGRect(x: body.maxX - 2, y: DeviceGeo.rowTop - 11, width: 8, height: 22)
        let ventPath = Path(roundedRect: vent, cornerRadius: 2.5, style: .continuous)
        c.fill(ventPath, with: .color(ink.opacity(0.10 * k)))
        c.fill(ventPath, with: .color(.black.opacity((s.dark ? 0.4 : 0.09) * s.loadLevel)))
        c.stroke(ventPath, with: .color(ink.opacity((0.22 + (s.dark ? 0.26 : 0.18) * s.loadLevel) * k)), lineWidth: 1)
        var vanes = Path()
        for step in 0..<4 {
            let y = vent.minY + 4 + CGFloat(step) * 4.7
            vanes.move(to: CGPoint(x: vent.minX + 3.5, y: y)); vanes.addLine(to: CGPoint(x: vent.maxX - 1.5, y: y))
        }
        c.stroke(vanes, with: .color(ink.opacity((0.12 + 0.3 * s.loadLevel) * k)), style: StrokeStyle(lineWidth: 1, lineCap: .round))

        // Case: vertical shading, a darker lower panel below the seam, a soft diagonal gloss.
        c.fill(shell, with: .linearGradient(Gradient(colors: [ink.opacity(0.13 * k), ink.opacity(0.05 * k)]),
                                            startPoint: CGPoint(x: body.midX, y: body.minY), endPoint: CGPoint(x: body.midX, y: body.maxY)))
        c.drawLayer { layer in
            layer.clip(to: shell)
            layer.fill(Path(CGRect(x: body.minX, y: seamY, width: body.width, height: body.maxY - seamY)),
                       with: .color(.black.opacity(s.dark ? 0.14 : 0.045)))
            var gloss = Path()
            gloss.move(to: CGPoint(x: body.minX + 8, y: body.minY))
            gloss.addLine(to: CGPoint(x: body.minX + 34, y: body.minY))
            gloss.addLine(to: CGPoint(x: body.minX + 12, y: seamY))
            gloss.addLine(to: CGPoint(x: body.minX - 14, y: seamY))
            gloss.closeSubpath()
            layer.fill(gloss, with: .linearGradient(Gradient(colors: [ink.opacity(0), ink.opacity(0.07 * k), ink.opacity(0)]),
                                                    startPoint: CGPoint(x: body.minX + 8, y: body.minY),
                                                    endPoint: CGPoint(x: body.minX + 32, y: body.minY + 7)))
            var seam = Path()
            seam.move(to: CGPoint(x: body.minX, y: seamY)); seam.addLine(to: CGPoint(x: body.maxX, y: seamY))
            layer.stroke(seam, with: .color(ink.opacity(0.11 * k)), lineWidth: 1)
        }
        c.stroke(shell, with: .color(ink.opacity((0.24 + 0.2 * s.lcdLevel) * k)), lineWidth: 1)
        var highlight = Path()
        highlight.move(to: CGPoint(x: body.minX + 10, y: body.minY + 1.5))
        highlight.addLine(to: CGPoint(x: body.maxX - 10, y: body.minY + 1.5))
        c.stroke(highlight, with: .color(ink.opacity(0.14 * k)), style: StrokeStyle(lineWidth: 1, lineCap: .round))

        // Cooling fins in the lower panel.
        var fins = Path()
        for step in 0..<6 {
            let y = seamY + 11 + CGFloat(step) * 5.2
            fins.move(to: CGPoint(x: body.minX + 16, y: y)); fins.addLine(to: CGPoint(x: body.maxX - 16, y: y))
        }
        c.stroke(fins, with: .color(ink.opacity(0.14 * k)), style: StrokeStyle(lineWidth: 1, lineCap: .round))

        // Display: dark when idle, lit with the mode glyph and the load while working.
        let lcd = DeviceGeo.lcd
        let recess = Color.black.opacity(s.dark ? 0.42 : 0.16)
        c.fill(Path(roundedRect: lcd, cornerRadius: 5, style: .continuous), with: .color(recess.opacity(0.6 + 0.4 * s.lcdLevel)))
        if let snapshot = s.snapshot, s.lcdLevel > 0.01 {
            var lit = c
            lit.opacity = 0.92 * s.lcdLevel
            if let glyph = c.resolveSymbol(id: snapshot.mode.rawValue) {
                lit.draw(glyph, at: CGPoint(x: lcd.minX + 11, y: lcd.midY))
            }
            lit.draw(Text(PowerFormat.watts(snapshot.flows.loadW))
                        .font(.system(size: 9.5, weight: .semibold).monospacedDigit()).foregroundStyle(ink),
                     at: CGPoint(x: lcd.maxX - 6, y: lcd.midY), anchor: .trailing)
        }

        // Status lamps: power, charging, fault.
        let lampY = lcd.maxY + 9
        func lamp(_ index: Int, _ tone: DeviceTone, _ on: Double) {
            let x = lcd.minX + 3 + CGFloat(index) * 7
            c.fill(Path(ellipseIn: CGRect(x: x - 1.5, y: lampY - 1.5, width: 3, height: 3)), with: .color(ink.opacity(0.16 * k)))
            guard on > 0.01 else { return }
            c.fill(Path(ellipseIn: CGRect(x: x - 3.2, y: lampY - 3.2, width: 6.4, height: 6.4)), with: .color(tone.color(0.22 * on)))
            c.fill(Path(ellipseIn: CGRect(x: x - 1.6, y: lampY - 1.6, width: 3.2, height: 3.2)), with: .color(tone.color(0.95 * on)))
        }
        // Keypad: three quiet buttons opposite the lamps.
        var keys = Path()
        for step in 0..<3 {
            keys.addEllipse(in: CGRect(x: lcd.maxX - 7.4 - CGFloat(step) * 8.5, y: lampY - 2.4, width: 4.8, height: 4.8))
        }
        c.stroke(keys, with: .color(ink.opacity(0.17 * k)), lineWidth: 1)

        // The fault lamp is for what needs attention: a warning from the inverter or a low battery.
        // Losing the grid alone is routine and is shown at the grid feed instead.
        let warned = !(s.snapshot?.activeWarning ?? "").isEmpty
        let fault = s.live && (warned || s.low)
        lamp(0, s.battery, s.live ? 1 : 0)
        lamp(1, s.battery, s.chargeOn * (0.65 + 0.35 * sin(s.time * 2.2)))
        lamp(2, s.alert, fault ? 1 - 0.3 * s.motion * (1 - sin(s.time * 3.4)) : 0)
    }

    // MARK: Solar

    private func solar(_ c: inout GraphicsContext) {
        let k = s.strength, on = s.solarOn, shine = s.shine
        let sun = DeviceGeo.sun

        var panel = Path()
        panel.move(to: CGPoint(x: 42, y: 38)); panel.addLine(to: CGPoint(x: 78, y: 38))
        panel.addLine(to: CGPoint(x: 72, y: 60)); panel.addLine(to: CGPoint(x: 36, y: 60))
        panel.closeSubpath()
        c.fill(panel, with: .color(ink.opacity(0.06 * k)))
        var cells = Path()
        cells.move(to: CGPoint(x: 39, y: 49)); cells.addLine(to: CGPoint(x: 75, y: 49))
        cells.move(to: CGPoint(x: 54, y: 38)); cells.addLine(to: CGPoint(x: 48, y: 60))
        cells.move(to: CGPoint(x: 66, y: 38)); cells.addLine(to: CGPoint(x: 60, y: 60))
        c.stroke(cells, with: .color(ink.opacity((0.13 + 0.07 * on) * k)), lineWidth: 1)
        c.stroke(panel, with: .color(ink.opacity((0.26 + 0.24 * on) * k)), style: StrokeStyle(lineWidth: 1, lineJoin: .round))

        // Sun: a quiet ring when there is no PV, a lit disc with slowly turning rays when there is.
        let disc = Path(ellipseIn: CGRect(x: sun.x - 4.5, y: sun.y - 4.5, width: 9, height: 9))
        var rays = Path()
        let turn = on > 0.01 ? s.time * 0.22 : 0
        for step in 0..<8 {
            let angle = Double(step) / 8 * 2 * .pi + turn
            let inner = 7.2, outer = 9.2 + 1.6 * shine
            rays.move(to: CGPoint(x: sun.x + CGFloat(cos(angle) * inner), y: sun.y + CGFloat(sin(angle) * inner)))
            rays.addLine(to: CGPoint(x: sun.x + CGFloat(cos(angle) * outer), y: sun.y + CGFloat(sin(angle) * outer)))
        }
        if shine < 0.99 {
            // No PV: a crescent moon, like the Solar tile.
            c.drawLayer { moon in
                let r: CGFloat = 5.5
                moon.fill(Path(ellipseIn: CGRect(x: sun.x - r, y: sun.y - r, width: r * 2, height: r * 2)),
                          with: .color(ink.opacity(0.42 * k * (1 - shine))))
                moon.blendMode = .destinationOut
                moon.fill(Path(ellipseIn: CGRect(x: sun.x - r + 3.4, y: sun.y - r - 2.2, width: r * 2, height: r * 2)), with: .color(.black))
            }
        }
        if shine > 0.01 {
            c.fill(disc, with: .color(s.solar.color(0.95 * shine)))
            c.stroke(rays, with: .color(s.solar.color(0.85 * shine)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
        }
    }

    // MARK: Grid

    private func pylon(_ c: inout GraphicsContext) {
        let k = s.strength
        let x = DeviceGeo.left, top = DeviceGeo.rowBottom - 18, base = DeviceGeo.rowBottom + 18
        var tower = Path()
        tower.move(to: CGPoint(x: x - 8, y: base)); tower.addLine(to: CGPoint(x: x - 2.5, y: top + 5))
        tower.addLine(to: CGPoint(x: x, y: top)); tower.addLine(to: CGPoint(x: x + 2.5, y: top + 5))
        tower.addLine(to: CGPoint(x: x + 8, y: base))
        // Cross-arms with insulators.
        tower.move(to: CGPoint(x: x - 9, y: top + 7)); tower.addLine(to: CGPoint(x: x + 9, y: top + 7))
        tower.move(to: CGPoint(x: x - 11.5, y: top + 16)); tower.addLine(to: CGPoint(x: x + 11.5, y: top + 16))
        for (dx, y) in [(-9.0, top + 7), (9.0, top + 7), (-11.5, top + 16), (11.5, top + 16)] {
            tower.move(to: CGPoint(x: x + CGFloat(dx), y: y)); tower.addLine(to: CGPoint(x: x + CGFloat(dx), y: y + 2.6))
        }
        // Bracing.
        tower.move(to: CGPoint(x: x - 4.7, y: top + 16)); tower.addLine(to: CGPoint(x: x + 6.3, y: top + 26))
        tower.move(to: CGPoint(x: x + 4.7, y: top + 16)); tower.addLine(to: CGPoint(x: x - 6.3, y: top + 26))
        let alpha = (0.30 + 0.24 * s.gridOn) * (1 - 0.5 * s.outage) * k
        c.stroke(tower, with: .color(ink.opacity(alpha)), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
    }

    // MARK: Home

    private func house(_ c: inout GraphicsContext) {
        let k = s.strength, on = s.loadLevel
        let x = DeviceGeo.right
        var walls = Path()
        walls.move(to: CGPoint(x: x - 12.5, y: 37.5)); walls.addLine(to: CGPoint(x: x - 12.5, y: 60))
        walls.addLine(to: CGPoint(x: x + 12.5, y: 60)); walls.addLine(to: CGPoint(x: x + 12.5, y: 37.5))
        var roof = Path()
        roof.move(to: CGPoint(x: x - 17.5, y: 41)); roof.addLine(to: CGPoint(x: x, y: 26.5)); roof.addLine(to: CGPoint(x: x + 17.5, y: 41))
        var fill = walls
        fill.addLine(to: CGPoint(x: x, y: 27)); fill.closeSubpath()
        c.fill(fill, with: .color(ink.opacity(0.05 * k)))
        let style = StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round)
        c.stroke(walls, with: .color(ink.opacity((0.26 + 0.22 * on) * k)), style: style)
        c.stroke(roof, with: .color(ink.opacity((0.30 + 0.24 * on) * k)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))

        let window = Path(roundedRect: DeviceGeo.window, cornerRadius: 1.8, style: .continuous)
        let lit = s.windowLevel
        if lit > 0.01 {
            let mid = s.output
            c.fill(window, with: .color(mid.color(0.85 * lit)))
        }
        c.stroke(window, with: .color(ink.opacity(0.24 * k * (1 - lit))), lineWidth: 1)
    }

    // MARK: Battery

    private func battery(_ c: inout GraphicsContext) {
        let k = s.strength
        let body = DeviceGeo.battery
        let active = max(s.chargeOn, s.dischargeOn)
        let shell = Path(roundedRect: body, cornerRadius: 7.5, style: .continuous)
        c.fill(shell, with: .color(ink.opacity(0.05 * k)))

        if let percent = s.percent {
            let inner = body.insetBy(dx: 3, dy: 3)
            let width = max(5, inner.width * percent / 100)
            let level = Path(roundedRect: CGRect(x: inner.minX, y: inner.minY, width: width, height: inner.height), cornerRadius: 4.6, style: .continuous)
            if s.low {
                c.fill(level, with: .color(s.alert.color(0.9)))
            } else {
                c.fill(level, with: .color(ink.opacity(0.17 + 0.07 * active)))
            }
        }
        let pulse = s.low ? 1 - 0.25 * s.motion * (1 - sin(s.time * 3.4)) : 0
        if s.low {
            c.stroke(shell, with: .color(s.alert.color(0.75 * pulse)), lineWidth: 1)
        } else {
            c.stroke(shell, with: .color(ink.opacity((0.28 + 0.22 * active) * k)), lineWidth: 1)
        }
        let cap = Path(roundedRect: CGRect(x: body.maxX + 1.5, y: body.midY - 5, width: 2.5, height: 10), cornerRadius: 1.2)
        c.fill(cap, with: .color(ink.opacity(0.3 * k)))

        if let percent = s.percent {
            let text = Text("\(Int(percent.rounded()))%").font(.system(size: 10, weight: .semibold).monospacedDigit())
            c.draw(text.foregroundStyle(s.low ? s.alert.color(1) : ink.opacity(0.88)), at: CGPoint(x: body.midX, y: body.midY))
        }
    }

    // MARK: Moving energy (one lightly blurred layer)

    /// Points per second, slowest to fastest. Neighbouring tiers are close, so the cross-fade between them is quiet.
    private static let speeds: [Double] = [13, 19, 27, 38, 52]
    /// Where each extra wisp joins the cycle, so that two are evenly spaced, and so are four.
    private static let order: [Double] = [0, 0.5, 0.25, 0.75]

    /// Comet-shaped wisps travelling along `point(0…1)`. More power means faster, longer and more of them:
    /// the first is always there, and each further one joins at its own `appear` amount.
    private func wisps(_ c: inout GraphicsContext, watts: Double, on: Double, tone: DeviceTone, seed: Int, run: CGFloat,
                       length: ClosedRange<CGFloat>, appear: [Double], jitter: Double, segments: Int, width: CGFloat, dot: Bool,
                       point: (Double) -> CGPoint) {
        guard on > 0.01 else { return }
        let intensity = HeroMath.intensity(watts), amount = DeviceState.amount(watts)
        // The cycle is sized for the longest wisp, so a wisp's rate never depends on its present length.
        let reach = Double(length.upperBound / run)
        let span = Double((length.lowerBound + (length.upperBound - length.lowerBound) * CGFloat(amount)) / run)
        let pace = 0.85 + 0.3 * HeroMath.hash(seed * 13 + 5)  // each run keeps its own steady pace
        let calm = 1 - 0.5 * s.stale
        for tier in 0..<Self.speeds.count {
            let weight = max(0, 1 - abs(intensity * Double(Self.speeds.count - 1) - Double(tier)))
            guard weight > 0.02 else { continue }
            let rate = Self.speeds[tier] * pace / Double(run) / (1 + reach)
            let share = pow(weight, 0.7)                     // two half-strength populations should not look dimmer than one
            for slot in 0..<appear.count {
                let density = slot == 0 ? 1 : DeviceState.fade(amount, appear[slot], appear[slot] + 0.15)
                guard density > 0.02 else { continue }
                let offset = Self.order[slot % Self.order.count] + HeroMath.hash(seed * 31 + tier * 7 + slot) * jitter
                    + HeroMath.hash(seed * 17 + tier)
                let phase = HeroMath.fract(s.time * rate + offset)
                let head = phase * (1 + reach), tail = head - span
                let h = min(1, head), t = max(0, tail)
                guard h - t > 0.01 else { continue }
                let alpha = on * share * density * (0.68 + 0.32 * amount) * calm
                var path = Path()
                path.move(to: point(t))
                for step in 1...segments { path.addLine(to: point(t + (h - t) * Double(step) / Double(segments))) }
                c.stroke(path, with: .linearGradient(Gradient(colors: [tone.color(0), tone.color(alpha * 0.5), tone.color(alpha)]),
                                                     startPoint: point(tail), endPoint: point(head)),
                         style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
                if dot, head < 1 {
                    let p = point(head), r = width * 0.95
                    c.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .color(tone.color(alpha)))
                }
            }
        }
    }

    private func energy(_ c: inout GraphicsContext) {
        func along(_ a: CGPoint, _ b: CGPoint) -> (Double) -> CGPoint {
            { p in CGPoint(x: a.x + (b.x - a.x) * CGFloat(p), y: a.y + (b.y - a.y) * CGFloat(p)) }
        }
        // A conduit carries one wisp for a trickle and four from about 3 kW.
        func conduit(_ e: inout GraphicsContext, watts: Double, on: Double, tone: DeviceTone, seed: Int, from: CGPoint, to: CGPoint) {
            wisps(&e, watts: watts, on: on, tone: tone, seed: seed, run: abs(to.x - from.x), length: 11...20,
                  appear: [0, 0.15, 0.40, 0.65], jitter: 0.12, segments: 1, width: 1.8, dot: true, point: along(from, to))
        }
        c.drawLayer { e in
            e.addFilter(.blur(radius: 0.5))
            conduit(&e, watts: s.solarW, on: s.solarOn, tone: s.solar, seed: 1, from: DeviceGeo.solarFrom, to: DeviceGeo.solarTo)
            conduit(&e, watts: s.gridW, on: s.gridOn, tone: s.grid, seed: 2, from: DeviceGeo.gridFrom, to: DeviceGeo.gridTo)
            conduit(&e, watts: s.chargeW, on: s.chargeOn, tone: s.battery, seed: 3, from: DeviceGeo.batteryNear, to: DeviceGeo.batteryFar)
            conduit(&e, watts: s.dischargeW, on: s.dischargeOn, tone: s.battery, seed: 4, from: DeviceGeo.batteryFar, to: DeviceGeo.batteryNear)
            conduit(&e, watts: s.loadW, on: s.loadLevel, tone: s.output, seed: 5, from: DeviceGeo.outputFrom, to: DeviceGeo.outputTo)
        }

        // Arrowheads at the receiving end, so direction reads in a still frame too.
        func chevron(tip: CGPoint, right: Bool, alpha: Double) {
            guard alpha > 0.01 else { return }
            let d: CGFloat = right ? -1 : 1
            var path = Path()
            path.move(to: CGPoint(x: tip.x + d * 2.8, y: tip.y - 2.8)); path.addLine(to: tip)
            path.addLine(to: CGPoint(x: tip.x + d * 2.8, y: tip.y + 2.8))
            c.stroke(path, with: .color(ink.opacity(0.5 * alpha)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
        }
        chevron(tip: CGPoint(x: DeviceGeo.solarTo.x - 3, y: DeviceGeo.rowTop), right: true, alpha: s.solarOn)
        chevron(tip: CGPoint(x: DeviceGeo.gridTo.x - 3, y: DeviceGeo.rowBottom), right: true, alpha: s.gridOn)
        chevron(tip: CGPoint(x: DeviceGeo.batteryFar.x - 2, y: DeviceGeo.rowBottom), right: true, alpha: s.chargeOn)
        chevron(tip: CGPoint(x: DeviceGeo.batteryNear.x + 4, y: DeviceGeo.rowBottom), right: false, alpha: s.dischargeOn)
        chevron(tip: CGPoint(x: DeviceGeo.outputTo.x - 2, y: DeviceGeo.rowTop), right: true, alpha: s.loadLevel)
    }

    // MARK: Labels

    private func labels(_ c: inout GraphicsContext) {
        func value(_ string: String, x: CGFloat, y: CGFloat, alpha: Double = 1) {
            c.draw(Text(string).font(.system(size: 10.5, weight: .semibold).monospacedDigit()).foregroundStyle(ink.opacity(0.9 * alpha)),
                   at: CGPoint(x: x, y: y))
        }
        func quiet(_ string: String, x: CGFloat, y: CGFloat) {
            c.draw(Text(string).font(.system(size: 9.5, weight: .medium).monospacedDigit()).foregroundStyle(ink.opacity(s.dark ? 0.46 : 0.52)),
                   at: CGPoint(x: x, y: y))
        }
        let centre = DeviceGeo.body.midX
        guard let snapshot = s.snapshot else {
            c.draw(Text("Waiting for data").font(.system(size: 10, weight: .medium)).foregroundStyle(ink.opacity(0.46)),
                   at: CGPoint(x: centre, y: DeviceGeo.captionY))
            return
        }
        // Labels state the reading as it arrived while the motion eases toward it, and a figure brightens
        // as its flow builds. The two exceptions are the changes of kind below, where the new figure would
        // contradict what is still being drawn.
        let flows = snapshot.flows
        func rise(_ on: Double) -> Double { 0.4 + 0.6 * on }

        if flows.solarW > 1 { value(PowerFormat.watts(flows.solarW), x: DeviceGeo.left, y: DeviceGeo.labelTop, alpha: rise(s.solarOn)) }
        else { quiet("0 W", x: DeviceGeo.left, y: DeviceGeo.labelTop) }

        if flows.loadW > 1 { value(PowerFormat.watts(flows.loadW), x: DeviceGeo.right, y: DeviceGeo.labelTop, alpha: rise(s.loadLevel)) }
        else { quiet("0 W", x: DeviceGeo.right, y: DeviceGeo.labelTop) }

        if !snapshot.gridPresent {
            if s.previous.gridW > 1, s.gridFade > 0.01 {
                // The feed is still dying away: its last figure fades with it before the line parts.
                value(PowerFormat.watts(s.previous.gridW), x: DeviceGeo.left, y: DeviceGeo.labelBottom, alpha: s.gridFade)
            } else {
                // A state, not an alarm: outages are routine here. The warning caption and the battery carry the red.
                let alpha = s.previous.gridW > 1 ? min(1, s.gridBreak * 2.5) : 1
                c.draw(Text("No grid").font(.system(size: 10, weight: .semibold)).foregroundStyle(ink.opacity(0.66 * alpha)),
                       at: CGPoint(x: DeviceGeo.left, y: DeviceGeo.labelBottom))
            }
        } else if flows.gridW > 1 {
            value(PowerFormat.watts(flows.gridW), x: DeviceGeo.left, y: DeviceGeo.labelBottom, alpha: rise(s.gridOn))
        } else if let volts = snapshot.gridVoltage, volts.isFinite {
            quiet("\(Int(volts.rounded())) V", x: DeviceGeo.left, y: DeviceGeo.labelBottom)
        } else {
            quiet("0 W", x: DeviceGeo.left, y: DeviceGeo.labelBottom)
        }

        if abs(flows.batteryW) > 1 {
            var shown = flows.batteryW, alpha = rise(max(s.chargeOn, s.dischargeOn))
            let was = s.previous.batteryW
            if abs(was) > 1, (was > 0) != (shown > 0) {
                // Direction is reversing: keep the old figure while the old flow is still drawn, swap as it crosses zero.
                let eased = s.chargeW - s.dischargeW
                if (eased > 0) != (shown > 0) { shown = was }
                alpha = min(1, abs(eased) / min(450, abs(shown)))   // about a quarter of a second around the crossing
            }
            value((shown > 0 ? "+" : "\u{2212}") + PowerFormat.watts(shown), x: DeviceGeo.right, y: DeviceGeo.labelBottom, alpha: alpha)
        } else if snapshot.batteryDischargeA > 0.4 {
            // Current without a battery voltage gives no watts to show; say which way it is going instead.
            quiet("Discharging", x: DeviceGeo.right, y: DeviceGeo.labelBottom)
        } else if snapshot.batteryChargeA > 0.4 {
            quiet("Charging", x: DeviceGeo.right, y: DeviceGeo.labelBottom)
        } else {
            quiet((s.percent ?? 0) >= 99.5 ? "Full" : "Idle", x: DeviceGeo.right, y: DeviceGeo.labelBottom)
        }

        if let warning = snapshot.activeWarning, !warning.isEmpty {
            let short = warning.count > 28 ? String(warning.prefix(27)) + "\u{2026}" : warning
            c.draw(Text(short).font(.system(size: 10, weight: .semibold)).foregroundStyle(s.alert.color(1)),
                   at: CGPoint(x: centre, y: DeviceGeo.captionY))
        } else if s.stale > 0.01, let reported = snapshot.deviceTime {
            let minutes = Int(s.time - reported.timeIntervalSinceReferenceDate) / 60
            let age = minutes < 90 ? "\(minutes) min" : minutes < 48 * 60 ? "\(minutes / 60) h" : "\(minutes / 1440) d"
            c.draw(Text("Last report \(age) ago").font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(ink.opacity(0.46 * s.stale)),
                   at: CGPoint(x: centre, y: DeviceGeo.captionY))
        }
    }
}
