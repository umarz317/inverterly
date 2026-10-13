#if os(iOS)
import SwiftUI
import Charts
import InverterCore

/// This month day by day, or month by month: the energy mix, a bar for each period to drag across,
/// and the list.
struct HistoryScreen: View {
    @ObservedObject var store: AppStore
    /// The day or month picked by dragging across the chart.
    @State private var selection: Date?

    var body: some View {
        VStack(spacing: 20) {
            Picker("Period", selection: $store.historyTab) {
                ForEach(HistoryTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            let periods = self.periods
            if periods.isEmpty {
                placeholder
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(summaryTitle(periods)).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                    MixSummary(totals: (periods.reduce(0) { $0 + $1.solar }, periods.reduce(0) { $0 + $1.grid },
                                        periods.reduce(0) { $0 + $1.load }))
                }
                PhoneCard { PeriodChart(periods: periods, unit: unit, selection: $selection) }
                PeriodList(periods: periods)
                footer
            }
        }
        .onChange(of: store.historyTab) { _, _ in selection = nil }
        .task { await store.loadHistory() }
    }

    private var unit: Calendar.Component { store.historyTab == .days ? .day : .month }

    private var periods: [Period] {
        switch store.historyTab {
        case .days:
            return store.currentMonthDays.compactMap { day in
                Period.date(day.day, "yyyy-MM-dd").map {
                    Period(id: day.day, date: $0, label: Period.dayLabel($0), solar: day.solarKWh, grid: day.gridKWh,
                           load: day.loadKWh, live: !day.complete)
                }
            }
        case .months:
            return store.months.compactMap { month in
                Period.date(month.month, "yyyy-MM").map {
                    Period(id: month.month, date: $0, label: $0.formatted(.dateTime.month(.wide).year()),
                           solar: month.solarKWh, grid: month.gridKWh, load: month.loadKWh, live: false)
                }
            }
        }
    }

    private func summaryTitle(_ periods: [Period]) -> String {
        switch store.historyTab {
        case .days: "This month"
        case .months: periods.count == 1 ? "This month" : "Last \(periods.count) months"
        }
    }

    @ViewBuilder private var placeholder: some View {
        VStack(spacing: 12) {
            if store.historyLoading {
                ProgressView()
                Text("Reading history…")
            } else {
                Image(systemName: "calendar").font(.largeTitle).foregroundStyle(.tertiary)
                Text(store.historyError ?? "No history yet.").multilineTextAlignment(.center)
            }
        }
        .font(.subheadline).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56).padding(.horizontal, 24)
        .phoneCard()
    }

    /// Only while reading or after a failure.
    @ViewBuilder private var footer: some View {
        if store.historyLoading || store.historyError != nil {
            HStack(spacing: 6) {
                if store.historyLoading {
                    ProgressView().controlSize(.small)
                    Text("Updating…")
                } else if let error = store.historyError {
                    Text(error)
                }
            }
            .font(.footnote).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
        }
    }
}

/// One day or month of totals.
struct Period: Identifiable, Equatable {
    let id: String
    let date: Date
    let label: String
    let solar: Double
    let grid: Double
    let load: Double
    /// Today, still adding up.
    let live: Bool

    /// Parses the "2026-10" and "2026-10-13" keys, which are Gregorian whatever the phone is set to.
    static func date(_ text: String, _ format: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter.date(from: text)
    }

    static func dayLabel(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.abbreviated).day())
    }
}

/// Solar stacked under grid for each period; dragging reads one out, otherwise the latest shows.
private struct PeriodChart: View {
    let periods: [Period]
    let unit: Calendar.Component
    @Binding var selection: Date?

    private var shown: Period? {
        guard let selection else { return periods.first }
        return periods.first { Calendar.current.isDate($0.date, equalTo: selection, toGranularity: unit) } ?? periods.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let shown {
                VStack(alignment: .leading, spacing: 8) {
                    Text(shown.live ? shown.label + " · so far" : shown.label)
                        .font(.footnote.weight(.medium)).foregroundStyle(.secondary)
                    HStack(spacing: 0) {
                        value("Solar", shown.solar, .solarMark)
                        value("Grid", shown.grid, .gridMark)
                        value("Load", shown.load, nil)
                    }
                }
            }
            Chart(periods) { period in
                BarMark(x: .value("Period", period.date, unit: unit), y: .value("kWh", period.solar))
                    .foregroundStyle(by: .value("Source", "Solar"))
                    .cornerRadius(3)
                    .opacity(dimmed(period) ? 0.35 : 1)
                BarMark(x: .value("Period", period.date, unit: unit), y: .value("kWh", period.grid))
                    .foregroundStyle(by: .value("Source", "Grid"))
                    .cornerRadius(3)
                    .opacity(dimmed(period) ? 0.35 : 1)
            }
            .chartForegroundStyleScale(["Solar": Color.solarMark, "Grid": Color.gridMark])
            .chartLegend(.hidden)
            .chartXAxis {
                if unit == .day {
                    AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                        AxisValueLabel(format: .dateTime.day(), centered: true)
                    }
                } else {
                    AxisMarks(values: .stride(by: .month)) { _ in
                        AxisValueLabel(format: .dateTime.month(.narrow), centered: true)
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.18))
                    AxisValueLabel { if let kWh = value.as(Double.self) { Text(kWh.formatted(.number.precision(.fractionLength(0)))) } }
                }
            }
            .chartXSelection(value: $selection)
            .frame(height: 200)
            .accessibilityLabel("Bar chart of solar and grid energy for each \(unit == .day ? "day" : "month"), in kilowatt hours")
        }
        .animation(.snappy, value: periods)
    }

    private func dimmed(_ period: Period) -> Bool {
        guard selection != nil, let shown else { return false }
        return period.id != shown.id
    }

    private func value(_ name: String, _ kWh: Double, _ mark: Color?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Circle().fill(mark ?? .clear)
                    .overlay { if mark == nil { Circle().stroke(.secondary, lineWidth: 1.5) } }
                    .frame(width: 8, height: 8)
                Text(name).font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(PowerFormat.kWhNumber(kWh)).font(.headline).monospacedDigit()
                Text("kWh").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Every period, newest first, with its three totals.
private struct PeriodList: View {
    let periods: [Period]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                column("Solar", .solarMark)
                column("Grid", .gridMark)
                column("Load", nil)
            }
            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            .padding(.bottom, 6)

            ForEach(Array(periods.enumerated()), id: \.element.id) { index, period in
                if index > 0 { Divider() }
                row(period)
            }
        }
        .padding(16)
        .phoneCard()
    }

    private func column(_ name: String, _ mark: Color?) -> some View {
        HStack(spacing: 4) {
            if let mark { Circle().fill(mark).frame(width: 6, height: 6) }
            Text(name)
        }
        .frame(width: 58, alignment: .trailing)
    }

    private func row(_ period: Period) -> some View {
        HStack(spacing: 8) {
            Text(period.label).font(.body).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            number(period.solar)
            number(period.grid)
            number(period.load).fontWeight(.semibold)
        }
        .foregroundStyle(period.live ? .secondary : .primary)
        .padding(.vertical, 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(period.label)\(period.live ? ", so far" : ""): solar \(PowerFormat.kWh(period.solar)), grid \(PowerFormat.kWh(period.grid)), load \(PowerFormat.kWh(period.load))")
    }

    private func number(_ kWh: Double) -> some View {
        Text(PowerFormat.kWhNumber(kWh)).font(.body).monospacedDigit()
            .frame(width: 58, alignment: .trailing)
    }
}
#endif
