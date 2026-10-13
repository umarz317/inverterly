import SwiftUI
import AppKit
import InverterCore

/// The menu bar panel: header, the live card (hero, load, tiles) and two sections that open in place.
public struct InverterPanel: View {
    @ObservedObject private var store: AppStore
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    public init(store: AppStore) {
        self.store = store
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let message = store.errorMessage, store.snapshot != nil {
                Banner(symbol: "exclamationmark.triangle", text: message, tint: .alertAccent)
            }
            if let snapshot = store.snapshot {
                if let warning = snapshot.activeWarning {
                    Banner(symbol: "bolt.trianglebadge.exclamationmark", text: "Inverter warning: \(warning)", tint: .alertAccent)
                }
                if snapshot.isStale() {
                    Banner(symbol: "clock.badge.exclamationmark", text: staleText(snapshot), tint: .solarAccent)
                }
                card(snapshot)
            } else if store.signInRequired {
                SignInView(store: store)
            } else if let message = store.errorMessage {
                FailedView(message: message) { Task { await store.refresh(force: true) } }
            } else {
                ReadingView()
            }
        }
        .padding(14)
        .frame(width: 380)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text("InverterBar").font(.system(size: 13, weight: .semibold))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button { Task { await store.refresh(force: true) } } label: {
                RefreshGlyph(spinning: store.busy)
            }
            .buttonStyle(IconButtonStyle())
            .help("Refresh now")
            .disabled(store.busy)

            Menu {
                    Picker(selection: $store.heroStyle) {
                        ForEach(HeroStyle.selectable) { Label($0.title, systemImage: $0.symbol).tag($0) }
                    } label: { Label("Illustration", systemImage: "photo") }
                    Picker(selection: $store.metric) {
                        ForEach(MenuBarMetric.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                    } label: { Label("Menu bar shows", systemImage: "menubar.rectangle") }
                    Toggle(isOn: $store.animateIcon) { Label("Animate menu bar icon", systemImage: "sparkles") }
                    if LaunchAtLogin.isAvailable {
                        Toggle(isOn: Binding(
                            get: { launchAtLogin },
                            set: { LaunchAtLogin.set($0); launchAtLogin = LaunchAtLogin.isEnabled })) {
                            Label("Open at login", systemImage: "power")
                        }
                    }
                    Divider()
                    if !store.signInRequired {
                        Button("Sign out", systemImage: "rectangle.portrait.and.arrow.right") { Task { await store.signOut() } }
                    }
                    Button("Quit InverterBar", systemImage: "xmark.rectangle") { NSApplication.shared.terminate(nil) }
                        .keyboardShortcut("q")
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 13, weight: .medium))
                        .frame(width: 26, height: 26).contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Options")
        }
    }

    private var subtitle: String {
        guard let snapshot = store.snapshot else { return store.errorMessage == nil ? "Connecting…" : "Not connected" }
        var parts: [String] = []
        if let rated = snapshot.ratedPowerW, rated > 0 {
            parts.append("\(PowerFormat.kilowatts(rated)) inverter")
        }
        if let time = snapshot.deviceTime ?? Optional(snapshot.fetchedAt) {
            parts.append("Updated \(time.formatted(date: .omitted, time: .shortened))")
        }
        return parts.joined(separator: " · ")
    }

    private func staleText(_ snapshot: EnergySnapshot) -> String {
        guard let time = snapshot.deviceTime else { return "The logger has stopped reporting." }
        return "The logger last reported \(time.formatted(.relative(presentation: .named))). Numbers may be old."
    }

    // MARK: Card

    private func card(_ snapshot: EnergySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.mode.label).font(.system(size: 13, weight: .semibold))
                        .contentTransition(.opacity)
                    Text(statusLine(snapshot)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                BatteryRing(percent: snapshot.batteryPercent, powerW: snapshot.batteryPowerW)
            }
            .padding(.bottom, 4)

            hero(snapshot)
                .frame(height: store.heroStyle.height)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 6)

            loadReadout(snapshot)
            LoadGauge(fraction: loadFraction(snapshot), ratedW: snapshot.ratedPowerW)
                .padding(.top, 6).padding(.bottom, 12)

            tiles(snapshot).padding(.bottom, 6)

            SectionRow(title: "Today", trailing: snapshot.todayKWh.map { PowerFormat.kWh($0) + " solar" }, open: $store.showToday)
            if store.showToday {
                TodaySection(store: store, snapshot: snapshot).padding(.bottom, 8).transition(.opacity)
            }
            Divider().opacity(0.5)
            SectionRow(title: "Details", trailing: nil, open: $store.showDetails)
            if store.showDetails {
                DetailsSection(snapshot: snapshot).padding(.bottom, 4).transition(.opacity)
            }
        }
        .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 4)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .animation(.snappy, value: snapshot.mode)
        .onChange(of: store.showToday) { _, open in if open { Task { await store.loadToday() } } }
        .task { if store.showToday { await store.loadToday() } }
    }

    @ViewBuilder
    private func hero(_ snapshot: EnergySnapshot) -> some View {
        HeroHost(snapshot: snapshot, active: store.panelOpen) { frame, now in
            store.heroStyle.view(frame: frame, now: now)
        }
    }

    private func statusLine(_ snapshot: EnergySnapshot) -> String {
        var parts: [String] = []
        if let percent = snapshot.batteryPercent {
            let power = snapshot.batteryPowerW
            let verb = power > 30 ? "charging" : power < -30 ? "discharging" : "idle"
            parts.append("Battery \(Int(percent.rounded()))%, \(verb)")
        }
        parts.append(snapshot.gridPresent ? "grid available" : "grid outage")
        return parts.joined(separator: " · ")
    }

    private func loadFraction(_ snapshot: EnergySnapshot) -> Double {
        if let rated = snapshot.ratedPowerW, rated > 0 { return min(1, max(0, snapshot.loadPowerW / rated)) }
        return min(1, max(0, (snapshot.loadPercent ?? 0) / 100))
    }

    private func loadReadout(_ snapshot: EnergySnapshot) -> some View {
        let parts = PowerFormat.split(snapshot.loadPowerW)
        return HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(parts.number)
                .font(.system(size: 34, weight: .light)).monospacedDigit()
                .contentTransition(.numericText(value: snapshot.loadPowerW))
            Text(parts.unit).font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
            Text("load").font(.system(size: 11)).foregroundStyle(.tertiary).padding(.leading, 2)
            Spacer(minLength: 8)
            Text("\(Int((loadFraction(snapshot) * 100).rounded()))% of capacity")
                .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                .contentTransition(.numericText(value: loadFraction(snapshot)))
        }
        .animation(.snappy, value: snapshot.loadPowerW)
    }

    private func tiles(_ snapshot: EnergySnapshot) -> some View {
        let battery = snapshot.batteryPowerW
        return HStack(spacing: 6) {
            StatTile(symbol: snapshot.pvPowerW > 20 ? "sun.max" : "moon", caption: "Solar",
                     value: PowerFormat.watts(snapshot.pvPowerW),
                     detail: snapshot.pvVoltage.map { String(format: "%.0f V", $0) } ?? "–",
                     quiet: snapshot.pvPowerW < 1)
            StatTile(symbol: batterySymbol(snapshot.batteryPercent), caption: "Battery",
                     value: snapshot.batteryPercent.map { "\(Int($0.rounded()))%" } ?? "–",
                     detail: abs(battery) > 30 ? "\(battery > 0 ? "+" : "−")\(PowerFormat.watts(battery))"
                         : (snapshot.batteryVoltage.map { String(format: "%.1f V", $0) } ?? "–"),
                     quiet: false)
            StatTile(symbol: snapshot.gridPresent ? "powerplug" : "bolt.slash", caption: "Grid",
                     value: snapshot.gridPresent ? (snapshot.gridPowerW > 0 ? PowerFormat.watts(snapshot.gridPowerW) : "Standby") : "Outage",
                     detail: snapshot.gridPresent ? String(format: "%.0f V", snapshot.gridVoltage ?? 0) : "No supply",
                     quiet: snapshot.gridPowerW < 1, alert: !snapshot.gridPresent)
            StatTile(symbol: "house", caption: "Output",
                     value: snapshot.outputVoltage.map { String(format: "%.0f V", $0) } ?? "–",
                     detail: snapshot.outputHz.map { String(format: "%.1f Hz", $0) } ?? "–",
                     quiet: false)
        }
    }

    private func batterySymbol(_ percent: Double?) -> String {
        guard let percent else { return "battery.0percent" }
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

public extension PowerFormat {
    /// "6 kW", "3.5 kW" for a rating.
    static func kilowatts(_ watts: Double) -> String {
        let kw = watts / 1000
        return kw == kw.rounded() ? "\(Int(kw)) kW" : String(format: "%.1f kW", kw)
    }
}

// MARK: - Sections

private struct TodaySection: View {
    @ObservedObject var store: AppStore
    let snapshot: EnergySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if let curve = store.today, !curve.points.isEmpty {
                    TodayChart(curve: curve)
                } else if store.todayLoading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Loading today's readings…").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    Text(store.todayError ?? "No readings for today yet.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .frame(height: 96)

            HStack(spacing: 6) {
                EnergyStat(caption: "Today", value: snapshot.todayKWh)
                EnergyStat(caption: "Month", value: snapshot.monthKWh)
                EnergyStat(caption: "Year", value: snapshot.yearKWh)
                EnergyStat(caption: "Lifetime", value: snapshot.totalKWh)
            }
        }
    }
}

private struct EnergyStat: View {
    let caption: String
    let value: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(caption).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(text).font(.system(size: 12, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var text: String {
        guard let value else { return "–" }
        if value >= 1000 { return String(format: "%.2f MWh", value / 1000) }
        return PowerFormat.kWh(value)
    }
}

private struct DetailsSection: View {
    let snapshot: EnergySnapshot

    var body: some View {
        VStack(spacing: 5) {
            row("Solar input", [PowerFormat.watts(snapshot.pvPowerW), snapshot.pvVoltage.map { String(format: "%.1f V", $0) }])
            row("Battery", [snapshot.batteryVoltage.map { String(format: "%.1f V", $0) }, batteryCurrent])
            row("Grid input", snapshot.gridPresent
                ? [snapshot.gridVoltage.map { String(format: "%.1f V", $0) }, snapshot.gridHz.map { String(format: "%.1f Hz", $0) }]
                : ["No supply"])
            row("Output", [snapshot.outputVoltage.map { String(format: "%.1f V", $0) }, snapshot.outputHz.map { String(format: "%.1f Hz", $0) }])
            row("Load", [PowerFormat.watts(snapshot.loadPowerW), snapshot.loadApparentVA.map { "\(Int($0.rounded())) VA" }])
            if snapshot.gridPowerW > 0 {
                row("Grid draw (estimated)", [PowerFormat.watts(snapshot.gridPowerW)])
            }
            if let type = snapshot.machineType { row("Type", [type]) }
            if let online = snapshot.collectorOnline { row("Logger", [online ? "Online" : "Offline"]) }
            if let time = snapshot.deviceTime {
                row("Last report", [time.formatted(date: .abbreviated, time: .shortened)])
            }
        }
    }

    private var batteryCurrent: String? {
        if snapshot.batteryChargeA > 0.4 { return String(format: "+%.0f A", snapshot.batteryChargeA) }
        if snapshot.batteryDischargeA > 0.4 { return String(format: "−%.0f A", snapshot.batteryDischargeA) }
        return "0 A"
    }

    private func row(_ title: String, _ values: [String?]) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(values.compactMap { $0 }.joined(separator: "  ·  "))
                .font(.system(size: 11, weight: .medium)).monospacedDigit()
        }
    }
}
