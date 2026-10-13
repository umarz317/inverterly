import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import InverterCore

/// The menu bar panel: header, the live card (hero, load, tiles) and two sections that open in place.
public struct InverterPanel: View {
    @ObservedObject private var store: AppStore
    #if os(macOS)
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    #endif

    public init(store: AppStore) {
        self.store = store
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // iOS puts the title in the navigation bar and the options in a Settings sheet.
            #if os(macOS)
            header
            #endif
            if let message = store.errorMessage, store.snapshot != nil {
                Banner(symbol: "exclamationmark.triangle", text: message, tint: .alertAccent)
            }
            if let snapshot = store.snapshot {
                if let warning = snapshot.activeWarning {
                    Banner(symbol: "bolt.trianglebadge.exclamationmark", text: "Inverter warning: \(warning)", tint: .alertAccent)
                }
                if snapshot.isStale() {
                    Banner(symbol: "clock.badge.exclamationmark", text: snapshot.staleText, tint: .solarAccent)
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
        #if os(macOS)
        .padding(14)
        .frame(width: 380)
        #else
        .padding(.horizontal, 16).padding(.vertical, 8)
        #endif
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Inverterly").font(.panel(13, weight: .semibold))
                Text(store.subtitle).font(.panel(11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button { Task { await store.refresh(force: true) } } label: {
                RefreshGlyph(spinning: store.busy)
            }
            .buttonStyle(IconButtonStyle())
            .help("Refresh now")
            .disabled(store.busy)

            Menu {
                if store.devices.count > 1 {
                    Picker(selection: Binding(
                        get: { store.devices.first(where: \.isSelected)?.id ?? "" },
                        set: { id in Task { await store.selectDevice(id) } })) {
                        ForEach(store.devices) { Text($0.name).tag($0.id) }
                    } label: { Label("Inverter", systemImage: "bolt.horizontal") }
                    Divider()
                }
                Picker(selection: $store.heroStyle) {
                    ForEach(HeroStyle.selectable) { Label($0.title, systemImage: $0.symbol).tag($0) }
                } label: { Label("Illustration", systemImage: "photo") }
                #if os(macOS)
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
                #endif
                Divider()
                if !store.signInRequired {
                    Button("Sign out", systemImage: "rectangle.portrait.and.arrow.right") { Task { await store.signOut() } }
                }
                #if os(macOS)
                Button("Quit Inverterly", systemImage: "xmark.rectangle") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
                #endif
            } label: {
                Image(systemName: "ellipsis").font(.panel(13, weight: .medium))
                    .frame(width: 26, height: 26).contentShape(Rectangle())
            }
            #if os(macOS)
            .menuStyle(.borderlessButton)
            #endif
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Options")
        }
    }

    // MARK: Card

    private func card(_ snapshot: EnergySnapshot) -> some View {
        Group {
            #if os(macOS)
            // One card on the Mac, the sections opening in place under the live reading.
            VStack(alignment: .leading, spacing: 0) {
                live(snapshot).padding(.bottom, 6)
                todaySection(snapshot)
                Divider().opacity(0.5)
                historySection
                Divider().opacity(0.5)
                detailsSection(snapshot)
            }
            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 4)
            .background(Color.panelCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            #else
            // A card each on the phone, with room between them.
            VStack(spacing: 16) {
                live(snapshot).padding(16).phoneCard()
                todaySection(snapshot).padding(.horizontal, 16).padding(.bottom, store.showToday ? 12 : 0).phoneCard()
                historySection.padding(.horizontal, 16).padding(.bottom, store.showHistory ? 12 : 0).phoneCard()
                detailsSection(snapshot).padding(.horizontal, 16).padding(.bottom, store.showDetails ? 12 : 0).phoneCard()
            }
            #endif
        }
        .animation(.snappy, value: snapshot.mode)
        .onChange(of: store.showToday) { _, open in if open { Task { await store.loadToday() } } }
        .onChange(of: store.showHistory) { _, open in if open { Task { await store.loadHistory() } } }
        .task {
            if store.showToday { await store.loadToday() }
            if store.showHistory { await store.loadHistory() }
        }
    }

    /// The mode, the hero, the load and the four tiles.
    private func live(_ snapshot: EnergySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.mode.label).font(.panel(13, weight: .semibold))
                        .contentTransition(.opacity)
                    Text(snapshot.statusLine).font(.panel(11)).foregroundStyle(.secondary)
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
            LoadGauge(fraction: snapshot.loadFraction, ratedW: snapshot.ratedPowerW)
                .padding(.top, 6).padding(.bottom, 12)

            tiles(snapshot)
        }
    }

    private func todaySection(_ snapshot: EnergySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionRow(title: "Today", trailing: todaySummary(snapshot), open: $store.showToday)
            if store.showToday {
                TodaySection(store: store).padding(.bottom, 8).transition(.opacity)
            }
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionRow(title: "History", trailing: historySummary, open: $store.showHistory)
            if store.showHistory {
                HistorySection(store: store).padding(.bottom, 8).transition(.opacity)
            }
        }
    }

    private func detailsSection(_ snapshot: EnergySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionRow(title: "Details", trailing: nil, open: $store.showDetails)
            if store.showDetails {
                DetailsSection(snapshot: snapshot).padding(.bottom, 4).transition(.opacity)
            }
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

    private func loadReadout(_ snapshot: EnergySnapshot) -> some View {
        let parts = PowerFormat.split(snapshot.loadPowerW)
        return HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(parts.number)
                .font(.panel(34, weight: .light)).monospacedDigit()
                .contentTransition(.numericText(value: snapshot.loadPowerW))
            Text(parts.unit).font(.panel(14, weight: .medium)).foregroundStyle(.secondary)
            Text("load").font(.panel(11)).foregroundStyle(.faint).padding(.leading, 2)
            Spacer(minLength: 8)
            Text("\(Int((snapshot.loadFraction * 100).rounded()))% of capacity")
                .font(.panel(11)).monospacedDigit().foregroundStyle(.secondary)
                .contentTransition(.numericText(value: snapshot.loadFraction))
        }
        .animation(.snappy, value: snapshot.loadPowerW)
    }

    private func tiles(_ snapshot: EnergySnapshot) -> some View {
        let battery = snapshot.batteryPowerW
        return HStack(spacing: PanelScale.scaled(6)) {
            StatTile(symbol: MenuBarMetric.solarSymbol(snapshot), caption: "Solar",
                     value: PowerFormat.watts(snapshot.pvPowerW),
                     detail: snapshot.pvVoltage.map { String(format: "%.0f V", $0) } ?? "–",
                     quiet: snapshot.pvPowerW < 1)
            StatTile(symbol: MenuBarMetric.batterySymbol(snapshot.batteryPercent), caption: "Battery",
                     value: snapshot.batteryPercent.map { "\(Int($0.rounded()))%" } ?? "–",
                     detail: abs(battery) > 30 ? "\(battery > 0 ? "+" : "−")\(PowerFormat.watts(battery))"
                         : (snapshot.batteryVoltage.map { String(format: "%.1f V", $0) } ?? "–"),
                     quiet: false)
            StatTile(symbol: MenuBarMetric.gridSymbol(snapshot), caption: "Grid",
                     value: snapshot.gridPresent ? (snapshot.gridPowerW > 0 ? PowerFormat.watts(snapshot.gridPowerW) : "Standby") : "Outage",
                     detail: snapshot.gridPresent ? String(format: "%.0f V", snapshot.gridVoltage ?? 0) : "No supply",
                     quiet: snapshot.gridPowerW < 1, alert: !snapshot.gridPresent)
            StatTile(symbol: "house", caption: "Output",
                     value: snapshot.outputVoltage.map { String(format: "%.0f V", $0) } ?? "–",
                     detail: snapshot.outputHz.map { String(format: "%.1f Hz", $0) } ?? "–",
                     quiet: false)
        }
    }
}

public extension AppStore {
    /// The inverter, its rating and when it last reported, for under the app's name.
    var subtitle: String {
        guard let snapshot else { return errorMessage == nil ? "Connecting…" : "Not connected" }
        var parts: [String] = []
        if let name = selectedDeviceName { parts.append(name) }
        if let rated = snapshot.ratedPowerW, rated > 0 {
            parts.append("\(PowerFormat.kilowatts(rated)) inverter")
        }
        if let time = snapshot.deviceTime ?? Optional(snapshot.fetchedAt) {
            parts.append("Updated \(time.formatted(date: .omitted, time: .shortened))")
        }
        return parts.joined(separator: " · ")
    }
}

extension EnergySnapshot {
    /// The battery and the grid in a few words: "Battery 78%, charging · grid available".
    var statusLine: String {
        var parts: [String] = []
        if let percent = batteryPercent {
            let verb = batteryPowerW > 30 ? "charging" : batteryPowerW < -30 ? "discharging" : "idle"
            parts.append("Battery \(Int(percent.rounded()))%, \(verb)")
        }
        parts.append(gridPresent ? "grid available" : "grid outage")
        return parts.joined(separator: " · ")
    }

    /// The load as a share of the inverter's rating, 0...1.
    var loadFraction: Double {
        if let rated = ratedPowerW, rated > 0 { return min(1, max(0, loadPowerW / rated)) }
        return min(1, max(0, (loadPercent ?? 0) / 100))
    }

    var staleText: String {
        guard let time = deviceTime else { return "The logger has stopped reporting." }
        return "The logger last reported \(time.formatted(.relative(presentation: .named))). Numbers may be old."
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

struct TodaySection: View {
    @ObservedObject var store: AppStore
    var chartHeight = PanelScale.scaled(96)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if let curve = store.today, !curve.points.isEmpty {
                    TodayChart(curve: curve)
                } else if store.todayLoading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Loading today's readings…").font(.panel(11)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    Text(store.todayError ?? "No readings for today yet.")
                        .font(.panel(11)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .frame(height: chartHeight)

            if let curve = store.today, !curve.points.isEmpty {
                let totals = curve.totals()
                HistorySummary(title: "So far today", solar: totals.solarKWh, grid: totals.gridKWh, load: totals.loadKWh)
            }
        }
    }
}

struct HistorySection: View {
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
                    .font(.panel(11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                HistorySummary(title: store.historyTab == .days ? "This month" : "Last \(rows.count) months",
                               solar: rows.reduce(0) { $0 + $1.solar }, grid: rows.reduce(0) { $0 + $1.grid },
                               load: rows.reduce(0) { $0 + $1.load })
                VStack(spacing: 0) {
                    HistoryHeader()
                    let scale = listed.map { $0.solar + $0.grid }.max() ?? 0
                    let list = LazyVStack(spacing: 0) {
                        ForEach(listed) { HistoryRow(row: $0, scale: scale).transition(.opacity.combined(with: .move(edge: .top))) }
                    }
                    .animation(.smooth, value: listed.map(\.id))
                    #if os(macOS)
                    ScrollView {
                        list.padding(.bottom, 10)
                    }
                    .frame(height: 176)
                    // Fade the last row instead of cutting it in half, so it reads as scrollable.
                    .mask(LinearGradient(stops: [.init(color: .black, location: 0.88), .init(color: .clear, location: 1)],
                                         startPoint: .top, endPoint: .bottom))
                    #else
                    // The whole screen scrolls on iOS, so the rows are laid out in full.
                    list
                    #endif
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
            .font(.panel(10)).foregroundStyle(.faint)
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

    /// Parses the "2026-10" and "2026-10-13" keys, which are Gregorian whatever the Mac is set to.
    private static let keyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static func date(_ text: String, _ format: String) -> Date? {
        keyFormatter.dateFormat = format
        return keyFormatter.date(from: text)
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
                Text(PowerFormat.kWhNumber(value))
            }
        }
    }
}

/// The period's totals, and how much of the energy came from the sun.
struct HistorySummary: View {
    let title: String
    let solar: Double
    let grid: Double
    let load: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.panel(11)).foregroundStyle(.secondary)
                Spacer()
                CountingKWh(value: solar, percentOf: solar + grid)
                    .font(.panel(11, weight: .medium)).monospacedDigit()
            }
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                stat("Solar", solar, .solarMark)
                stat("Grid", grid, .gridMark)
                stat("Load", load, nil)
            }
            ShareBar(solar: solar, grid: grid, scale: solar + grid).frame(height: 4)
        }
        .padding(.vertical, 2)
    }

    /// A total in ink, its series named by the dot beside the caption (none for load).
    private func stat(_ caption: String, _ value: Double, _ mark: Color?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                if let mark { Circle().fill(mark).frame(width: PanelScale.scaled(6), height: PanelScale.scaled(6)) }
                Text(caption).font(.panel(10)).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                CountingKWh(value: value).font(.panel(17, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("kWh").font(.panel(10)).foregroundStyle(.faint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension Color {
    /// Solar and grid in the bars, chart and legends. Checked as a pair for colour-blind separation and
    /// 3:1 contrast against the card in both modes; numbers stay in ink, the colour marks which is which.
    #if os(macOS)
    static let solarMark = adaptive(dark: NSColor(hex: 0xD4780A), light: NSColor(hex: 0xD4780A))
    static let gridMark = adaptive(dark: NSColor(hex: 0x6A7EE8), light: NSColor(hex: 0x5A6BDB))

    private static func adaptive(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }
    #else
    // On the phone, the system palette: solar is the one colour, the grid a neutral grey as the
    // "other" source, so the screen reads like Apple's own charts.
    static let solarMark = Color(uiColor: .systemOrange)
    static let gridMark = Color(uiColor: .systemGray)
    #endif
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
            HStack(spacing: 2) {
                if solar > 0 { Capsule().fill(Color.solarMark).frame(width: max(2, solar * unit)) }
                if grid > 0 { Capsule().fill(Color.gridMark).frame(width: max(2, grid * unit)) }
                Spacer(minLength: 0)
            }
            .background(Capsule().fill(.primary.opacity(0.07)))
        }
        .animation(.easeOut(duration: 0.6), value: [solar, grid, scale])
        .onAppear { withAnimation(.easeOut(duration: 0.9)) { grown = true } }
    }
}

private enum HistoryColumns {
    static let label = PanelScale.scaled(70)
    static let number = PanelScale.scaled(42)
}

private struct HistoryHeader: View {
    var body: some View {
        HStack(spacing: 8) {
            Spacer().frame(width: HistoryColumns.label)
            Spacer(minLength: 0)
            ColumnTitle(text: "Solar", mark: .solarMark)
            ColumnTitle(text: "Grid", mark: .gridMark)
            Text("Load").frame(width: HistoryColumns.number, alignment: .trailing)
        }
        .font(.panel(10, weight: .medium)).foregroundStyle(.secondary)
        .padding(.bottom, 2)
    }
}

/// A history column's name with its series dot.
private struct ColumnTitle: View {
    let text: String
    let mark: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(mark).frame(width: PanelScale.scaled(5), height: PanelScale.scaled(5))
            Text(text)
        }
        .frame(width: HistoryColumns.number, alignment: .trailing)
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
        .font(.panel(11)).monospacedDigit()
        .foregroundStyle(row.live ? .secondary : .primary)
        .padding(.vertical, PanelScale.scaled(4.5))
        .help(row.live ? "So far today" : "")
    }
}

struct DetailsSection: View {
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
            Text(title).font(.panel(11)).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(values.compactMap { $0 }.joined(separator: "  ·  "))
                .font(.panel(11, weight: .medium)).monospacedDigit()
        }
    }
}
