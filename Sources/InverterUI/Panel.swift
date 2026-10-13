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

            SectionRow(title: "Today", trailing: todaySummary(snapshot), open: $store.showToday)
            if store.showToday {
                TodaySection(store: store, snapshot: snapshot).padding(.bottom, 8).transition(.opacity)
            }
            Divider().opacity(0.5)
            SectionRow(title: "History", trailing: historySummary, open: $store.showHistory)
            if store.showHistory {
                HistorySection(store: store).padding(.bottom, 8).transition(.opacity)
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
        .onChange(of: store.showHistory) { _, open in if open { Task { await store.loadHistory() } } }
        .task {
            if store.showToday { await store.loadToday() }
            if store.showHistory { await store.loadHistory() }
        }
    }

    @ViewBuilder
    private func hero(_ snapshot: EnergySnapshot) -> some View {
        HeroHost(snapshot: snapshot, active: store.panelOpen) { frame, now in
            store.heroStyle.view(frame: frame, now: now)
        }
    }

    /// Today's solar, and the estimated grid draw once today's readings have been read.
    private func todaySummary(_ snapshot: EnergySnapshot) -> String? {
        guard let solar = snapshot.todayKWh else { return nil }
        guard let curve = store.today, !curve.points.isEmpty else { return PowerFormat.kWh(solar) + " solar" }
        return PowerFormat.kWh(solar) + " solar · " + PowerFormat.kWh(curve.totals().gridKWh) + " grid"
    }

    /// This month's solar so far, once the days have been read.
    private var historySummary: String? {
        let days = store.currentMonthDays
        guard !days.isEmpty else { return nil }
        return PowerFormat.kWh(days.reduce(0) { $0 + $1.solarKWh }) + " solar this month"
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

            if let curve = store.today, !curve.points.isEmpty {
                let totals = curve.totals()
                HistorySummary(title: "So far today", solar: totals.solarKWh, grid: totals.gridKWh, load: totals.loadKWh)
            }
        }
    }
}

private struct HistorySection: View {
    @ObservedObject var store: AppStore

    var body: some View {
        VStack(spacing: 10) {
            Picker("", selection: $store.historyTab) {
                ForEach(HistoryTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.small)

            let rows = self.rows
            // Today has its own section above, so its running total is only counted in the summary.
            let listed = rows.filter { !$0.live }
            if rows.isEmpty {
                Text(store.historyLoading ? "Reading history…" : store.historyError ?? "No history yet.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                HistorySummary(title: store.historyTab == .days ? "This month" : "Last \(rows.count) months",
                               solar: rows.reduce(0) { $0 + $1.solar }, grid: rows.reduce(0) { $0 + $1.grid },
                               load: rows.reduce(0) { $0 + $1.load })
                VStack(spacing: 0) {
                    HistoryHeader()
                    ScrollView {
                        let scale = listed.map { $0.solar + $0.grid }.max() ?? 0
                        LazyVStack(spacing: 0) {
                            ForEach(listed) { HistoryRow(row: $0, scale: scale).transition(.opacity.combined(with: .move(edge: .top))) }
                        }
                        .animation(.smooth, value: listed.map(\.id))
                        .padding(.bottom, 10)
                    }
                    .frame(height: 176)
                    // Fade the last row instead of cutting it in half, so it reads as scrollable.
                    .mask(LinearGradient(stops: [.init(color: .black, location: 0.88), .init(color: .clear, location: 1)],
                                         startPoint: .top, endPoint: .bottom))
                }
            }

            HStack(spacing: 6) {
                if store.historyLoading && !rows.isEmpty {
                    ProgressView().controlSize(.mini)
                    Text("Updating…")
                } else if let error = store.historyError, !rows.isEmpty {
                    Text(error)
                } else {
                    Text("All values in kWh. Grid is estimated from the logger's readings.")
                }
            }
            .font(.system(size: 10)).foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var rows: [HistoryRow.Data] {
        switch store.historyTab {
        case .days:
            return store.currentMonthDays.map {
                HistoryRow.Data(id: $0.day, label: Self.dayLabel($0.day), solar: $0.solarKWh, grid: $0.gridKWh,
                                load: $0.loadKWh, live: !$0.complete)
            }
        case .months:
            return store.months.map {
                HistoryRow.Data(id: $0.month, label: Self.monthLabel($0.month), solar: $0.solarKWh, grid: $0.gridKWh,
                                load: $0.loadKWh, live: false)
            }
        }
    }

    private static func date(_ text: String, _ format: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        return formatter.date(from: text)
    }

    private static func dayLabel(_ day: String) -> String {
        guard let date = date(day, "yyyy-MM-dd") else { return day }
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.abbreviated).day())
    }

    private static func monthLabel(_ month: String) -> String {
        date(month, "yyyy-MM")?.formatted(.dateTime.month(.abbreviated).year()) ?? month
    }
}

/// kWh with one decimal below 100 and none above, so columns stay narrow.
private func kWhText(_ value: Double) -> String {
    value >= 100 ? String(format: "%.0f", value) : String(format: "%.1f", value)
}

/// A kWh figure that counts up to its value when it appears, and on to each new value as history
/// is read in, rather than jumping.
private struct CountingKWh: View {
    let value: Double
    var percentOf: Double? = nil
    @State private var shown: Double = 0

    var body: some View {
        Counter(value: shown, percentOf: percentOf)
            .onAppear { withAnimation(.easeOut(duration: 0.9)) { shown = value } }
            .onChange(of: value) { _, new in withAnimation(.easeOut(duration: 0.6)) { shown = new } }
    }

    private struct Counter: View, Animatable {
        var value: Double
        let percentOf: Double?
        var animatableData: Double {
            get { value }
            set { value = newValue }
        }
        var body: some View {
            if let percentOf {
                Text("\(Int((percentOf > 0 ? value / percentOf * 100 : 0).rounded()))% from solar")
            } else {
                Text(kWhText(value))
            }
        }
    }
}

/// The period's totals, and how much of the energy came from the sun.
private struct HistorySummary: View {
    let title: String
    let solar: Double
    let grid: Double
    let load: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                CountingKWh(value: solar, percentOf: solar + grid)
                    .font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(Color.solarText)
            }
            // No box of its own: the panel is already glass, so colour carries the grouping instead.
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                stat("Solar", solar, .solarText)
                stat("Grid", grid, .gridText)
                stat("Load", load, .primary)
            }
            ShareBar(solar: solar, grid: grid, scale: solar + grid).frame(height: 4)
        }
        .padding(.vertical, 2)
    }

    private func stat(_ caption: String, _ value: Double, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(caption).font(.system(size: 10)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                CountingKWh(value: value).font(.system(size: 17, weight: .semibold, design: .rounded))
                    .monospacedDigit().foregroundStyle(tint)
                Text("kWh").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension Color {
    /// The solar and grid accents as text: the pastel accents in dark mode, deeper shades that stay
    /// readable on a light panel.
    static let solarText = adaptive(dark: NSColor(Color.solarAccent), light: NSColor(red: 0.74, green: 0.48, blue: 0.0, alpha: 1))
    static let gridText = adaptive(dark: NSColor(Color.gridAccent), light: NSColor(red: 0.13, green: 0.42, blue: 0.86, alpha: 1))

    private static func adaptive(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }
}

/// Solar then grid, side by side, each as long as its share of `scale`.
private struct ShareBar: View {
    let solar: Double
    let grid: Double
    let scale: Double
    @State private var grown = false

    var body: some View {
        GeometryReader { proxy in
            // Starts empty and grows with the numbers; later changes animate with them.
            let unit = scale > 0 && grown ? proxy.size.width / scale : 0
            HStack(spacing: 1) {
                if solar > 0 { Capsule().fill(Color.solarText).frame(width: max(2, solar * unit)) }
                if grid > 0 { Capsule().fill(Color.gridText).frame(width: max(2, grid * unit)) }
                Spacer(minLength: 0)
            }
            .background(Capsule().fill(.primary.opacity(0.07)))
        }
        .animation(.easeOut(duration: 0.6), value: [solar, grid, scale])
        .onAppear { withAnimation(.easeOut(duration: 0.9)) { grown = true } }
    }
}

private enum HistoryColumns {
    static let label: CGFloat = 70
    static let number: CGFloat = 42
}

private struct HistoryHeader: View {
    var body: some View {
        HStack(spacing: 8) {
            Spacer().frame(width: HistoryColumns.label)
            Spacer(minLength: 0)
            Text("Solar").foregroundStyle(Color.solarText).frame(width: HistoryColumns.number, alignment: .trailing)
            Text("Grid").foregroundStyle(Color.gridText).frame(width: HistoryColumns.number, alignment: .trailing)
            Text("Load").frame(width: HistoryColumns.number, alignment: .trailing)
        }
        .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
        .padding(.bottom, 2)
    }
}

private struct HistoryRow: View {
    struct Data: Identifiable {
        let id: String
        let label: String
        let solar: Double
        let grid: Double
        let load: Double
        /// A day still going: its numbers are a running total.
        let live: Bool
    }
    let row: Data
    let scale: Double

    var body: some View {
        HStack(spacing: 8) {
            Text(row.label).frame(width: HistoryColumns.label, alignment: .leading).lineLimit(1)
            ShareBar(solar: row.solar, grid: row.grid, scale: scale).frame(height: 4)
            CountingKWh(value: row.solar).frame(width: HistoryColumns.number, alignment: .trailing)
            CountingKWh(value: row.grid).frame(width: HistoryColumns.number, alignment: .trailing)
            CountingKWh(value: row.load).frame(width: HistoryColumns.number, alignment: .trailing)
                .fontWeight(.medium)
        }
        .font(.system(size: 11)).monospacedDigit()
        .foregroundStyle(row.live ? .secondary : .primary)
        .padding(.vertical, 4.5)
        .help(row.live ? "So far today" : "")
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
