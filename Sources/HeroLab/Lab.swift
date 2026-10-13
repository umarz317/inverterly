import SwiftUI
import AppKit
import InverterCore
import InverterUI

/// Renders heroes to PNG contact sheets.
///
///   swift run HeroLab <style> <out-dir> [scenario-id ...]
///
/// One sheet per colour scheme: a row per scenario, and across each row the same scenario at
/// several moments after the reading changed, so both the ramp and the steady motion are visible.
@main
struct Lab {
    static let times: [Double] = [0.12, 0.55, 1.3, 2.05, 2.8]
    static let heroWidth: CGFloat = 348

    @MainActor
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.count >= 2, args[0] == "panel" { renderPanels(Array(args.dropFirst())); return }
        if args.count >= 2, args[0] == "icon" { renderIcons(outDir: args[1]); return }
        guard args.count >= 2, let style = HeroStyle(rawValue: args[0]) else {
            print("usage: HeroLab <\(HeroStyle.allCases.map(\.rawValue).joined(separator: "|"))> <out-dir> [scenario-id ...]")
            exit(2)
        }
        let outDir = URL(fileURLWithPath: args[1], isDirectory: true)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let wanted = Set(args.dropFirst(2))
        let scenarios = HeroScenario.all.filter { wanted.isEmpty || wanted.contains($0.id) }

        for scheme in [ColorScheme.dark, .light] {
            let sheet = Sheet(style: style, scenarios: scenarios, scheme: scheme)
            let renderer = ImageRenderer(content: sheet)
            renderer.scale = 2
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                print("render failed for \(scheme)"); exit(1)
            }
            let url = outDir.appendingPathComponent("\(style.rawValue)-\(scheme == .dark ? "dark" : "light").png")
            do { try png.write(to: url); print("wrote \(url.path)") } catch { print("write failed: \(error)"); exit(1) }
        }
    }

    @MainActor
    static func write<V: View>(_ view: V, to url: URL) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            print("render failed: \(url.lastPathComponent)"); exit(1)
        }
        do { try png.write(to: url); print("wrote \(url.path)") } catch { print("write failed: \(error)"); exit(1) }
    }

    /// swift run HeroLab panel <out-dir> [style] [scenario-id ...]
    /// The whole panel for each scenario, collapsed and with both sections open, dark and light.
    @MainActor
    static func renderPanels(_ args: [String]) {
        let outDir = URL(fileURLWithPath: args[0], isDirectory: true)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        var rest = Array(args.dropFirst())
        var style = HeroStyle.preferred
        if let first = rest.first, let named = HeroStyle(rawValue: first) { style = named; rest.removeFirst() }
        let wanted = Set(rest)
        let scenarios = HeroScenario.all.filter { wanted.isEmpty ? ["sunny", "evening", "outage", "offline"].contains($0.id) : wanted.contains($0.id) }
        let day = DemoProvider.sampleDay(until: Calendar.current.startOfDay(for: HeroScenario.reference).addingTimeInterval(17.3 * 3600))

        for scheme in [ColorScheme.dark, .light] {
            let backdrop = scheme == .dark ? Color(red: 0.10, green: 0.14, blue: 0.19) : Color(red: 0.90, green: 0.92, blue: 0.94)
            let sheet = HStack(alignment: .top, spacing: 16) {
                ForEach(scenarios) { scenario in
                    ForEach([false, true], id: \.self) { open in
                        if !open || scenario.snapshot != nil {
                            panel(scenario, style: style, open: open, day: day)
                                .background(backdrop.opacity(0.001))
                                .background(scheme == .dark ? Color(red: 0.13, green: 0.17, blue: 0.23) : Color(red: 0.96, green: 0.97, blue: 0.98),
                                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                    }
                }
            }
            .padding(20)
            .background(backdrop)
            .environment(\.colorScheme, scheme)
            write(sheet, to: outDir.appendingPathComponent("panel-\(style.rawValue)-\(scheme == .dark ? "dark" : "light").png"))
        }
    }

    @MainActor
    static func panel(_ scenario: HeroScenario, style: HeroStyle, open: Bool, day: DayCurve) -> some View {
        let store = AppStore(preview: scenario.snapshot, today: open ? day : nil,
                             error: scenario.snapshot == nil && scenario.id == "offline" ? nil : nil)
        store.heroStyle = style
        store.showToday = open
        store.showDetails = open
        return InverterPanel(store: store, fixedHero: (scenario.frame(), HeroScenario.reference.addingTimeInterval(2.05)))
    }

    /// swift run HeroLab icon <out-dir>: the menu bar glyph in every state, enlarged.
    @MainActor
    static func renderIcons(outDir: String) {
        let dir = URL(fileURLWithPath: outDir, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let rows: [(String, Double?, MenuBarIcon.Activity, Bool)] = [
            ("sun, charging 40%", 0.40, .charging, true), ("night, discharging 86%", 0.86, .discharging, false),
            ("sun, idle 100%", 1.0, .idle, true), ("night, low 12%", 0.12, .discharging, false), ("no data", nil, .unknown, false),
        ]
        let sheet = VStack(alignment: .leading, spacing: 10) {
            ForEach(rows, id: \.0) { row in
                HStack(spacing: 14) {
                    Text(row.0).font(.system(size: 11)).frame(width: 140, alignment: .leading)
                    ForEach(0..<MenuBarIcon.phases, id: \.self) { phase in
                        Image(nsImage: MenuBarIcon.image(level: row.1, activity: row.2, solar: row.3, phase: phase))
                            .renderingMode(.template).interpolation(.high).resizable()
                            .frame(width: 69, height: 51)
                        Image(nsImage: MenuBarIcon.image(level: row.1, activity: row.2, solar: row.3, phase: phase))
                            .renderingMode(.template)
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .padding(20)
        .background(Color(red: 0.12, green: 0.16, blue: 0.22))
        .environment(\.colorScheme, .dark)
        write(sheet, to: dir.appendingPathComponent("icon.png"))
    }

    struct Sheet: View {
        let style: HeroStyle
        let scenarios: [HeroScenario]
        let scheme: ColorScheme

        var body: some View {
            let panel = scheme == .dark ? Color(red: 0.11, green: 0.15, blue: 0.20) : Color(red: 0.91, green: 0.93, blue: 0.95)
            VStack(alignment: .leading, spacing: 14) {
                ForEach(scenarios) { scenario in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(scenario.id) · \(scenario.title)")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            ForEach(Lab.times, id: \.self) { t in
                                VStack(spacing: 2) {
                                    style.view(frame: scenario.frame(), now: HeroScenario.reference.addingTimeInterval(t))
                                        .frame(width: Lab.heroWidth, height: style.height)
                                        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                                    Text(String(format: "t = %.2f s", t)).font(.system(size: 9)).foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
            }
            .padding(16)
            .background(panel)
            .environment(\.colorScheme, scheme)
        }
    }
}
