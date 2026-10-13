import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import InverterCore
import InverterUI

/// Renders the demo video frame by frame from the app's own views.
///
///   swift run DemoVideo <lines.json> <out-dir> [--fps 30] [--only <seconds>]
///
/// `lines.json` comes from Tools/demo-video/narrate.py: one spoken line per shot with its
/// length, and each shot lasts as long as its line. The panel in the video is the real
/// `InverterPanel` and the real heroes, drawn at made-up readings; the desktop, menu bar and
/// pointer around it are drawn here. Nothing is captured from the screen.
/// Writes <out-dir>/frames/00000.png … and <out-dir>/timeline.json (where each line starts).
@main
struct DemoVideo {
    @MainActor
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count >= 2 else {
            print("usage: DemoVideo <lines.json> <out-dir> [--fps 30] [--only <seconds>]")
            exit(2)
        }
        func option(_ name: String) -> String? {
            arguments.firstIndex(of: name).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        }
        let lines = try JSONDecoder().decode([Line].self, from: Data(contentsOf: URL(fileURLWithPath: arguments[0])))
        let out = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let fps = Double(option("--fps") ?? "30") ?? 30
        let frames = out.appendingPathComponent("frames", isDirectory: true)
        try? FileManager.default.removeItem(at: frames)
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)

        let director = Director(lines: lines)
        let timeline = director.shots.map { ["id": $0.id, "start": $0.start, "speechAt": $0.start + Director.speechDelay, "length": $0.length] as [String: Any] }
        try JSONSerialization.data(withJSONObject: ["fps": fps, "duration": director.duration, "shots": timeline], options: [.prettyPrinted])
            .write(to: out.appendingPathComponent("timeline.json"))

        // `--only 12.5,20` renders just those moments, for checking a shot without a full render.
        if let only = option("--only") {
            for (index, t) in only.split(separator: ",").compactMap({ Double($0) }).enumerated() {
                try write(director.frame(at: t), to: frames.appendingPathComponent(String(format: "check-%02d-%05.2fs.png", index, t)))
            }
            print("wrote \(only) to \(frames.path)")
            return
        }

        let count = Int((director.duration * fps).rounded(.up))
        let started = Date()
        for index in 0..<count {
            try write(director.frame(at: Double(index) / fps), to: frames.appendingPathComponent(String(format: "%05d.png", index)))
            if index % 150 == 0 { print("frame \(index)/\(count)  \(Int(Date().timeIntervalSince(started)))s"); fflush(stdout) }
        }
        print("wrote \(count) frames, \(String(format: "%.1f", director.duration)) s, to \(frames.path)")
    }

    @MainActor
    static func write(_ view: some View, to url: URL) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        renderer.isOpaque = true
        guard let image = renderer.cgImage,
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}

struct Line: Decodable {
    let id: String
    let text: String
    let seconds: Double
}

struct Shot {
    let id: String
    let text: String
    let start: Double
    let length: Double
    var end: Double { start + length }
}

/// What the panel is showing.
struct PanelState: Hashable {
    var scenario: String
    var showToday = false
    var showDetails = false
    var style: HeroStyle = .device
}

struct Camera {
    var scale: CGFloat          // pixels per world point
    var centre: CGPoint         // world point at the middle of the viewport

    func mix(_ other: Camera, _ t: CGFloat) -> Camera {
        Camera(scale: scale + (other.scale - scale) * t,
               centre: CGPoint(x: centre.x + (other.centre.x - centre.x) * t, y: centre.y + (other.centre.y - centre.y) * t))
    }
}

@MainActor
final class Director {
    // Output: a 1080 x 1350 frame, the scene above and a subtitle band below.
    static let width: CGFloat = 1080
    static let sceneHeight: CGFloat = 1200
    static let bandHeight: CGFloat = 150
    // World (points): a slice of a desktop with a menu bar across the top.
    static let worldWidth: CGFloat = 540
    static let worldHeight: CGFloat = 960
    static let menuBarHeight: CGFloat = 26
    static let itemCentreX: CGFloat = 280
    static let panelWidth: CGFloat = 380
    static let panelX: CGFloat = 90
    static let panelY: CGFloat = 32
    static let speechDelay = 0.25

    let shots: [Shot]
    let duration: Double
    private var stores: [PanelState: AppStore] = [:]
    private var heights: [PanelState: CGFloat] = [:]
    private let scenarios: [String: EnergySnapshot]
    private let day: DayCurve
    private let stateChanges: [(time: Double, state: PanelState)]
    private let flowChanges: [(time: Double, scenario: String)]
    private let openTime: Double
    private let closeTime: Double

    init(lines: [Line]) {
        // Each shot lasts as long as its line, with a breath after it, and no less than the
        // picture needs.
        let minimum: [String: Double] = ["intro": 4.4, "icon": 4.6, "open": 2.8, "styles": 5.6, "end": 3.4, "today": 3.2, "details": 3.4]
        var start = 0.0
        var built: [Shot] = []
        for line in lines {
            let length = max(line.seconds + Self.speechDelay + 0.45, minimum[line.id] ?? 2.8)
            built.append(Shot(id: line.id, text: line.text, start: start, length: length))
            start += length
        }
        shots = built
        duration = start

        // Readings: the app's own demo scenarios, stamped with a believable time of day.
        func reading(_ scenario: HeroScenario, hour: Int, minute: Int) -> EnergySnapshot {
            var snapshot = scenario.snapshot ?? EnergySnapshot()
            snapshot.deviceTime = nil
            snapshot.fetchedAt = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
            return snapshot
        }
        scenarios = [
            "sunny": reading(.sunnyCharging, hour: 12, minute: 42),
            "evening": reading(.eveningBattery, hour: 18, minute: 21),
            "night": reading(.nightGrid, hour: 23, minute: 5),
            "outage": reading(.outageLowBattery, hour: 2, minute: 14),
        ]
        day = DemoProvider.sampleDay(until: Calendar.current.date(bySettingHour: 12, minute: 42, second: 0, of: Date()) ?? Date())

        func at(_ id: String, _ offset: Double) -> Double { (built.first { $0.id == id }?.start ?? 0) + offset }
        openTime = at("open", 1.55)
        closeTime = at("end", 0.35)
        flowChanges = [
            (openTime, "sunny"), (at("evening", 0.15), "evening"), (at("night", 0.15), "night"),
            (at("outage", 0.15), "outage"), (at("today", 0.10), "sunny"),
        ]
        stateChanges = [
            (openTime, PanelState(scenario: "sunny")),
            (at("evening", 0.15), PanelState(scenario: "evening")),
            (at("night", 0.15), PanelState(scenario: "night")),
            (at("outage", 0.15), PanelState(scenario: "outage")),
            (at("today", 0.10), PanelState(scenario: "sunny")),
            (at("today", 1.45), PanelState(scenario: "sunny", showToday: true)),
            (at("details", 1.25), PanelState(scenario: "sunny", showToday: true, showDetails: true)),
            (at("styles", 0.10), PanelState(scenario: "sunny")),
            (at("styles", 2.50), PanelState(scenario: "sunny", style: .flow)),
            (at("styles", 3.50), PanelState(scenario: "sunny", style: .scene)),
            (at("readonly", 0.20), PanelState(scenario: "sunny")),
        ]
    }

    // MARK: Timeline helpers

    private func shot(at t: Double) -> Shot { shots.last { $0.start <= t } ?? shots[0] }
    private func start(_ id: String) -> Double { shots.first { $0.id == id }?.start ?? 0 }

    private static func ease(_ x: Double) -> Double {
        let t = min(1, max(0, x))
        return t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
    }
    private static func easeOut(_ x: Double) -> Double { 1 - pow(1 - min(1, max(0, x)), 3) }

    private func store(for state: PanelState) -> AppStore {
        if let store = stores[state] { return store }
        let store = AppStore(preview: scenarios[state.scenario], today: day)
        store.heroStyle = state.style
        store.showToday = state.showToday
        store.showDetails = state.showDetails
        stores[state] = store
        return store
    }

    private func height(of state: PanelState) -> CGFloat {
        if let height = heights[state] { return height }
        let probe = NSHostingController(rootView: InverterPanel(store: store(for: state)).environment(\.colorScheme, .dark))
        let height = probe.sizeThatFits(in: CGSize(width: Self.panelWidth, height: 4000)).height.rounded(.up)
        heights[state] = height
        return height
    }

    private func targetHeightOrZero(_ state: PanelState?) -> CGFloat { state.map(height(of:)) ?? 0 }

    private func heroFrame(at t: Double) -> HeroFrame {
        guard let index = flowChanges.lastIndex(where: { $0.time <= t }) else { return HeroFrame(snapshot: nil) }
        let change = flowChanges[index]
        let previous = index > 0 ? (scenarios[flowChanges[index - 1].scenario]?.flows ?? .zero) : .zero
        return HeroFrame(snapshot: scenarios[change.scenario], previous: previous,
                         changedAt: HeroScenario.reference.addingTimeInterval(change.time))
    }

    // MARK: Camera

    private func camera(for id: String) -> Camera {
        let wide = Camera(scale: 2.0, centre: CGPoint(x: 270, y: 300))
        let hero = Camera(scale: 2.75, centre: CGPoint(x: Self.itemCentreX, y: Self.panelY + 204))
        let collapsed = height(of: PanelState(scenario: "sunny"))
        let withToday = height(of: PanelState(scenario: "sunny", showToday: true))
        let withBoth = height(of: PanelState(scenario: "sunny", showToday: true, showDetails: true))
        // When a section opens the view stays at the same size and follows the panel's bottom
        // edge down, the way you would scroll to see what just appeared.
        func following(_ panelHeight: CGFloat) -> Camera {
            Camera(scale: 2.0, centre: CGPoint(x: 270, y: max(300, Self.panelY + panelHeight + 14 - 300)))
        }
        _ = collapsed
        switch id {
        case "icon": return Camera(scale: 5.4, centre: CGPoint(x: Self.itemCentreX + 6, y: 0))
        case "sunny", "evening", "night", "styles": return hero
        case "outage": return Camera(scale: 2.75, centre: CGPoint(x: Self.itemCentreX, y: Self.panelY + 238))
        case "today": return following(withToday)
        case "details": return following(withBoth)
        default: return wide
        }
    }

    /// Keeps the view inside the world, so no shot ever shows past its edges.
    private func clamped(_ camera: Camera) -> Camera {
        let halfWidth = Self.width / 2 / camera.scale, halfHeight = Self.sceneHeight / 2 / camera.scale
        return Camera(scale: camera.scale, centre: CGPoint(
            x: min(max(camera.centre.x, halfWidth), Self.worldWidth - halfWidth),
            y: min(max(camera.centre.y, halfHeight), Self.worldHeight - halfHeight)))
    }

    private func camera(at t: Double) -> Camera {
        let current = shot(at: t)
        guard let index = shots.firstIndex(where: { $0.id == current.id }), index > 0 else { return clamped(camera(for: current.id)) }
        // The move to this shot's framing starts as the shot does and takes about a second.
        // The two section shots wait for the click that opens the section.
        let delay: Double = current.id == "today" ? 1.35 : current.id == "details" ? 1.15 : 0
        let progress = Self.ease((t - current.start - delay) / 1.0)
        return clamped(camera(for: shots[index - 1].id)).mix(clamped(camera(for: current.id)), progress)
    }

    // MARK: Pointer

    private struct PointerKey { let time: Double; let point: CGPoint; let visible: Bool }

    private var pointerKeys: [PointerKey] {
        let item = CGPoint(x: Self.itemCentreX - 4, y: 14)
        let collapsed = height(of: PanelState(scenario: "sunny"))
        let withToday = height(of: PanelState(scenario: "sunny", showToday: true))
        let todayRow = CGPoint(x: Self.panelX + 300, y: Self.panelY + collapsed - 68)
        let detailsRow = CGPoint(x: Self.panelX + 300, y: Self.panelY + withToday - 34)
        let aside = CGPoint(x: 500, y: 150)
        return [
            PointerKey(time: 0, point: CGPoint(x: 130, y: 470), visible: false),
            PointerKey(time: 0.5, point: CGPoint(x: 130, y: 470), visible: true),
            PointerKey(time: start("icon") - 0.2, point: CGPoint(x: 210, y: 380), visible: true),
            PointerKey(time: start("icon") + 0.2, point: CGPoint(x: 215, y: 372), visible: false),
            PointerKey(time: start("open") + 0.1, point: CGPoint(x: 240, y: 210), visible: true),
            PointerKey(time: start("open") + 1.25, point: item, visible: true),
            PointerKey(time: openTime + 0.5, point: item, visible: true),
            PointerKey(time: start("sunny") + 0.1, point: aside, visible: true),
            PointerKey(time: start("sunny") + 0.5, point: aside, visible: false),
            PointerKey(time: start("today") + 0.2, point: aside, visible: true),
            PointerKey(time: start("today") + 1.25, point: todayRow, visible: true),
            PointerKey(time: start("details") + 0.25, point: todayRow, visible: true),
            PointerKey(time: start("details") + 1.05, point: detailsRow, visible: true),
            PointerKey(time: start("styles") - 0.1, point: detailsRow, visible: true),
            PointerKey(time: start("styles") + 0.3, point: detailsRow, visible: false),
        ]
    }

    private var clickTimes: [Double] { [openTime - 0.08, start("today") + 1.38, start("details") + 1.18] }

    private func pointer(at t: Double) -> (point: CGPoint, opacity: Double) {
        let keys = pointerKeys
        guard let next = keys.firstIndex(where: { $0.time > t }), next > 0 else {
            return (keys.last?.point ?? .zero, (keys.last?.visible ?? false) ? 1 : 0)
        }
        let a = keys[next - 1], b = keys[next]
        let p = Self.ease((t - a.time) / max(0.001, b.time - a.time))
        let point = CGPoint(x: a.point.x + (b.point.x - a.point.x) * p, y: a.point.y + (b.point.y - a.point.y) * p)
        let opacity = (a.visible ? 1.0 : 0.0) + ((b.visible ? 1.0 : 0.0) - (a.visible ? 1.0 : 0.0)) * min(1, (t - a.time) / 0.25)
        return (point, opacity)
    }

    // MARK: One frame

    func frame(at t: Double) -> some View {
        let current = shot(at: t)
        let local = t - current.start
        let camera = camera(at: t)

        // Panel: the state now, and the one it is cross-fading from.
        let index = stateChanges.lastIndex { $0.time <= t }
        let state = index.map { stateChanges[$0].state }
        let changedAt = index.map { stateChanges[$0].time } ?? 0
        let before = index.flatMap { $0 > 0 ? stateChanges[$0 - 1].state : nil }
        let since = t - changedAt
        let grow = Self.easeOut(since / 0.36)
        // A section opening or closing leaves everything above it where it was, so the two
        // states can dissolve into each other. Any other change (a banner arriving, another
        // illustration) moves the layout, and a dissolve would show both at once, offset. Those
        // dip out and back in instead.
        let sameTop = before.map { $0.scenario == state?.scenario && $0.style == state?.style } ?? true
        let dips = !sameTop && before.map { height(of: $0) != targetHeightOrZero(state) || $0.style != state?.style } == true
        let outgoing = dips ? 1 - Self.ease(since / 0.13) : 1 - Self.ease(since / 0.28)
        let incoming = dips ? Self.ease((since - 0.11) / 0.20) : Self.ease(since / 0.28)
        let hero = heroFrame(at: t)
        let now = HeroScenario.reference.addingTimeInterval(t)

        let targetHeight = state.map(height(of:)) ?? 0
        let fromHeight = before.map(height(of:)) ?? targetHeight
        let panelHeight = fromHeight + (targetHeight - fromHeight) * grow
        let opening = Self.easeOut((t - openTime) / 0.2)
        let closing = Self.ease((t - closeTime) / 0.16)
        let panelOpacity = t < openTime ? 0 : opening * (1 - closing)
        let panelLift = (1 - opening) * -7

        // Menu bar item: follows the reading on show, and moves for a few seconds after each new one.
        let reading = t >= openTime ? scenarios[flowChanges.last { $0.time <= t }?.scenario ?? "sunny"] : scenarios["sunny"]
        let lastArrival = ([start("icon")] + flowChanges.map(\.time)).last { $0 <= t } ?? 0
        let phase = (t - lastArrival) < 4.5 ? Int((t - lastArrival) / 0.5) % 4 : 0

        let pointer = pointer(at: t)
        let click = clickTimes.last { $0 <= t }.map { t - $0 } ?? 9

        let titleIn = Self.ease((t - 0.35) / 0.5) * (1 - Self.ease((t - (shots[0].end - 0.55)) / 0.4))
        let endIn = Self.ease((t - (closeTime + 0.25)) / 0.5)
        let subtitle = min(Self.ease((local - 0.08) / 0.18), 1 - Self.ease((local - (current.length - 0.2)) / 0.18))

        return VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                // The world, seen through the camera.
                ZStack(alignment: .topLeading) {
                    Wallpaper()
                    MenuBar(reading: reading, phase: phase, pressed: panelOpacity > 0.5,
                            clock: (reading?.fetchedAt ?? Date()).addingTimeInterval(60))

                    if let state {
                        ZStack(alignment: .top) {
                            if let before, outgoing > 0 {
                                panel(before, hero: hero, now: now).opacity(outgoing)
                            }
                            panel(state, hero: hero, now: now).opacity(before == nil ? 1 : incoming)
                        }
                        .frame(width: Self.panelWidth, height: panelHeight, alignment: .top)
                        .clipped()
                        .background(PanelGlass())
                        .opacity(panelOpacity)
                        .offset(x: Self.panelX, y: Self.panelY + panelLift)
                    }

                    VStack(spacing: 8) {
                        Text("InverterBar").font(.system(size: 40, weight: .semibold))
                        Text("a solar inverter, in the Mac menu bar").font(.system(size: 15)).opacity(0.72)
                    }
                    .foregroundStyle(.white)
                    .frame(width: Self.worldWidth)
                    .offset(y: 220)
                    .opacity(titleIn)

                    VStack(spacing: 14) {
                        IconGlyph(level: 0.72, activity: .charging, solar: true, phase: Int(t / 0.5) % 4)
                            .frame(width: 23 * 5, height: 17 * 5)
                        Text("InverterBar").font(.system(size: 40, weight: .semibold))
                        Text("native macOS, read-only").font(.system(size: 15)).opacity(0.72)
                    }
                    .foregroundStyle(.white)
                    .frame(width: Self.worldWidth)
                    .offset(y: 170)
                    .opacity(endIn)

                    if click < 0.4 {
                        Circle().stroke(.white.opacity(0.75 * (1 - click / 0.4)), lineWidth: 1.5)
                            .frame(width: 8 + 34 * click / 0.4, height: 8 + 34 * click / 0.4)
                            .position(pointer.point)
                    }
                    Pointer()
                        .scaleEffect(click < 0.16 ? 0.9 : 1, anchor: .topLeading)
                        .offset(x: pointer.point.x, y: pointer.point.y)
                        .opacity(pointer.opacity)
                }
                .frame(width: Self.worldWidth, height: Self.worldHeight, alignment: .topLeading)
                .scaleEffect(camera.scale, anchor: .topLeading)
                .offset(x: Self.width / 2 - camera.centre.x * camera.scale,
                        y: Self.sceneHeight / 2 - camera.centre.y * camera.scale)
            }
            .frame(width: Self.width, height: Self.sceneHeight, alignment: .topLeading)
            .clipped()

            // Subtitle band under the scene.
            ZStack {
                Color(red: 0.035, green: 0.045, blue: 0.065)
                Text(current.text)
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.horizontal, 60)
                    .opacity(max(0, subtitle))
            }
            .frame(width: Self.width, height: Self.bandHeight)
        }
        .frame(width: Self.width, height: Self.sceneHeight + Self.bandHeight)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
    }

    private func panel(_ state: PanelState, hero: HeroFrame, now: Date) -> some View {
        InverterPanel(store: store(for: state), fixedHero: (hero, now))
            .frame(width: Self.panelWidth, alignment: .top)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Set dressing

/// An abstract dusk-blue wallpaper.
private struct Wallpaper: View {
    var body: some View {
        Canvas { canvas, size in
            let rect = CGRect(origin: .zero, size: size)
            canvas.fill(Path(rect), with: .linearGradient(
                Gradient(colors: [Color(red: 0.05, green: 0.09, blue: 0.20), Color(red: 0.07, green: 0.20, blue: 0.33), Color(red: 0.10, green: 0.30, blue: 0.38)]),
                startPoint: .zero, endPoint: CGPoint(x: size.width * 0.3, y: size.height)))
            canvas.drawLayer { layer in
                layer.addFilter(.blur(radius: 70))
                layer.fill(Path(ellipseIn: CGRect(x: -80, y: 250, width: 360, height: 300)), with: .color(Color(red: 0.16, green: 0.45, blue: 0.60).opacity(0.55)))
                layer.fill(Path(ellipseIn: CGRect(x: 300, y: 60, width: 340, height: 260)), with: .color(Color(red: 0.32, green: 0.24, blue: 0.56).opacity(0.45)))
                layer.fill(Path(ellipseIn: CGRect(x: 180, y: 560, width: 420, height: 340)), with: .color(Color(red: 0.95, green: 0.62, blue: 0.30).opacity(0.20)))
            }
        }
        .frame(width: Director.worldWidth, height: Director.worldHeight)
    }
}

/// A stand-in menu bar: generic items, and InverterBar's own drawn from the reading.
private struct MenuBar: View {
    let reading: EnergySnapshot?
    let phase: Int
    let pressed: Bool
    let clock: Date

    var body: some View {
        let power = reading?.batteryPowerW ?? 0
        let activity: MenuBarIcon.Activity = reading == nil ? .unknown : power > 30 ? .charging : power < -30 ? .discharging : .idle
        ZStack(alignment: .topLeading) {
            Rectangle().fill(.black.opacity(0.26)).frame(width: Director.worldWidth, height: Director.menuBarHeight)

            HStack(spacing: 14) {
                Text("Finder").font(.system(size: 13, weight: .semibold))
                ForEach(["File", "Edit", "View", "Go"], id: \.self) { Text($0).font(.system(size: 13)) }
            }
            .foregroundStyle(.white.opacity(0.92))
            .frame(height: Director.menuBarHeight)
            .offset(x: 16)

            // InverterBar's item.
            HStack(spacing: 4) {
                IconGlyph(level: (reading?.batteryPercent ?? 0) / 100, activity: activity,
                          solar: (reading?.pvPowerW ?? 0) > 20, phase: phase)
                    .frame(width: 23, height: 17)
                Text(reading?.batteryPercent.map { "\(Int($0.rounded()))%" } ?? "")
                    .font(.system(size: 13).monospacedDigit())
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(.white.opacity(pressed ? 0.20 : 0), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .frame(width: 80)
            .offset(x: Director.itemCentreX - 40, y: 2)

            HStack(spacing: 13) {
                Image(systemName: "wifi")
                Image(systemName: "switch.2")
                Text("Tue 13 Oct  " + clock.formatted(date: .omitted, time: .shortened)).font(.system(size: 13))
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white.opacity(0.92))
            .frame(width: 200, height: Director.menuBarHeight, alignment: .trailing)
            .offset(x: Director.worldWidth - 200 - 12)
        }
    }
}

/// The app's menu bar glyph as vector drawing, so it stays sharp when the camera is close.
/// Same geometry as `MenuBarIcon`, on a 23 x 17 point grid.
private struct IconGlyph: View {
    let level: Double
    let activity: MenuBarIcon.Activity
    let solar: Bool
    let phase: Int

    var body: some View {
        Canvas { canvas, size in
            let k = size.width / 23
            canvas.scaleBy(x: k, y: k)
            let ink = Color.white
            let known = activity != .unknown
            let step = Double(phase % 4) / 3

            let track = CGRect(x: 0.75, y: 9.75, width: 21.5, height: 6.5)
            canvas.stroke(Path(roundedRect: track, cornerRadius: 3.25), with: .color(ink.opacity(known ? 0.9 : 0.4)), lineWidth: 1.2)
            if known {
                let well = track.insetBy(dx: 1.9, dy: 1.9)
                let filled = max(1.4, well.width * min(1, max(0, level)))
                var inner = canvas
                inner.clip(to: Path(roundedRect: well, cornerRadius: 1.35))
                func bar(_ x: CGFloat, _ width: CGFloat, _ alpha: Double) {
                    guard width > 0.05 else { return }
                    inner.fill(Path(CGRect(x: well.minX + x, y: well.minY, width: width, height: well.height)), with: .color(ink.opacity(alpha)))
                }
                switch activity {
                case .charging:
                    bar(0, filled, 1)
                    bar(filled, (well.width - filled) * step, 0.4)
                case .discharging:
                    let tip = min(filled, 3.2)
                    bar(0, filled - tip, 1)
                    bar(filled - tip, tip, 1 - 0.65 * step)
                default:
                    bar(0, filled, 1)
                }
            }

            let centre = CGPoint(x: 11.5, y: 7.65)
            let alpha = !known ? 0.3 : solar ? 0.95 : 0.36
            var disc = Path()
            for index in 0...24 {
                let angle = Double(index) / 24 * .pi
                let point = CGPoint(x: centre.x + cos(angle) * 3.0, y: centre.y - sin(angle) * 3.0)
                if index == 0 { disc.move(to: point) } else { disc.addLine(to: point) }
            }
            disc.closeSubpath()
            canvas.fill(disc, with: .color(ink.opacity(alpha)))
            var rays = Path()
            for index in 0..<5 {
                let angle = Double(index) * .pi / 4
                let pulse = solar && known ? (index % 2 == phase % 2 ? 0.9 : 0) : 0
                rays.move(to: CGPoint(x: centre.x + cos(angle) * 4.6, y: centre.y - sin(angle) * 4.6))
                rays.addLine(to: CGPoint(x: centre.x + cos(angle) * (6.0 + pulse), y: centre.y - sin(angle) * (6.0 + pulse)))
            }
            canvas.stroke(rays, with: .color(ink.opacity(alpha)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
        }
    }
}

/// The dark translucent sheet behind the panel's content.
private struct PanelGlass: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color(red: 0.12, green: 0.14, blue: 0.18).opacity(0.95))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.10), lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 26, y: 14)
    }
}

/// An arrow pointer, tip at the view's top-left corner.
private struct Pointer: View {
    var body: some View {
        Canvas { canvas, _ in
            var arrow = Path()
            let points: [CGPoint] = [.zero, CGPoint(x: 0, y: 16.5), CGPoint(x: 4.3, y: 12.6), CGPoint(x: 7.2, y: 19),
                                     CGPoint(x: 9.6, y: 18), CGPoint(x: 6.8, y: 11.7), CGPoint(x: 12.4, y: 11.7)]
            arrow.addLines(points)
            arrow.closeSubpath()
            canvas.translateBy(x: 1.5, y: 1.5)
            canvas.drawLayer { shadow in
                shadow.addFilter(.blur(radius: 1.6))
                shadow.fill(arrow.offsetBy(dx: 0.6, dy: 1.2), with: .color(.black.opacity(0.4)))
            }
            canvas.fill(arrow, with: .color(.black))
            canvas.stroke(arrow, with: .color(.white), style: StrokeStyle(lineWidth: 1.3, lineJoin: .round))
        }
        .frame(width: 18, height: 24)
        .offset(x: -1.5, y: -1.5)
    }
}
