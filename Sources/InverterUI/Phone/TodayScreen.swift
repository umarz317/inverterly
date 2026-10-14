#if os(iOS)
import SwiftUI
import Charts
import InverterCore

/// Today: where the energy came from so far, the day's power curve to drag through, the peaks, and
/// the battery through the day.
struct TodayScreen: View {
    @ObservedObject var store: AppStore
    /// The instant picked by dragging across either chart; nil shows the latest reading.
    @State private var selection: Date?

    var body: some View {
        VStack(spacing: 20) {
            if let curve = store.today, !curve.points.isEmpty {
                MixSummary(totals: curve.totals())
                PhoneCard { PowerChart(curve: curve, selection: $selection) }
                if curve.points.contains(where: { $0.batteryPercent != nil }) {
                    PhoneCard { BatteryChart(curve: curve, selection: $selection) }
                }
            } else {
                placeholder
            }
        }
        .task { await store.loadToday() }
    }

    @ViewBuilder private var placeholder: some View {
        VStack(spacing: 12) {
            if store.todayLoading {
                ProgressView()
                Text("Loading today's readings…")
            } else {
                Image(systemName: "chart.xyaxis.line").font(.largeTitle).foregroundStyle(.tertiary)
                Text(store.todayError ?? "No readings for today yet.")
                    .multilineTextAlignment(.center)
            }
        }
        .font(.subheadline).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56).padding(.horizontal, 24)
        .phoneCard()
    }
}

// MARK: - Energy mix

/// A period's share of solar as one large figure and a bar, with the totals under it, and the
/// energy sent to the grid when there was any.
struct MixSummary: View {
    let totals: (solarKWh: Double, gridKWh: Double, loadKWh: Double, exportKWh: Double)

    /// What went to the grid was made by the panels but did not serve the house, so it is left out of the share.
    private var usedSolar: Double { max(0, totals.solarKWh - totals.exportKWh) }
    private var supplied: Double { usedSolar + totals.gridKWh }
    private var solarShare: Double { supplied > 0 ? usedSolar / supplied : 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(Int((solarShare * 100).rounded()))%")
                    .font(.system(size: 40, weight: .semibold, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText())
                Text("from solar").font(.title3).foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                let width = proxy.size.width
                HStack(spacing: 2) {
                    if usedSolar > 0 { Capsule().fill(Color.solarMark).frame(width: max(4, (width - 2) * solarShare)) }
                    if totals.gridKWh > 0 { Capsule().fill(Color.gridMark) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }
            .frame(height: 6)
            HStack(spacing: 0) {
                total(.solar, totals.solarKWh)
                total(.grid, totals.gridKWh)
                total(.load, totals.loadKWh)
                if totals.exportKWh > 0 { total(.export, totals.exportKWh) }
            }
        }
        .padding(16)
        .phoneCard()
        .animation(.smooth, value: solarShare)
        .accessibilityElement(children: .combine)
    }

    private func total(_ source: EnergySource, _ kWh: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                SourceIcon(source: source, size: 12)
                Text(source.name).font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(PowerFormat.kWhNumber(kWh)).font(.headline).monospacedDigit()
                    .contentTransition(.numericText())
                Text("kWh").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Power chart

/// Solar as a filled curve, grid and load as lines, midnight to midnight. Dragging across it reads
/// out that moment; otherwise the readout shows the latest point.
private struct PowerChart: View {
    let curve: DayCurve
    @Binding var selection: Date?

    private var shown: DayCurvePoint? { curve.point(near: selection) ?? curve.points.last }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            readout
            Chart {
                ForEach(curve.points) { point in
                    AreaMark(x: .value("Time", point.time), y: .value("Solar", point.pvW / 1000))
                        .foregroundStyle(LinearGradient(colors: [Color.solarMark.opacity(0.28), Color.solarMark.opacity(0.02)],
                                                        startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", point.time), y: .value("kW", point.pvW / 1000), series: .value("Series", "Solar"))
                        .foregroundStyle(Color.solarMark)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineJoin: .round))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", point.time), y: .value("kW", point.gridW / 1000), series: .value("Series", "Grid"))
                        .foregroundStyle(Color.gridMark)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineJoin: .round))
                    LineMark(x: .value("Time", point.time), y: .value("kW", point.loadW / 1000), series: .value("Series", "Load"))
                        .foregroundStyle(Color.primary.opacity(0.8))
                        .lineStyle(StrokeStyle(lineWidth: 2, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
                if let point = shown {
                    RuleMark(x: .value("Time", point.time))
                        .foregroundStyle(Color.secondary.opacity(selection == nil ? 0.25 : 0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: selection == nil ? [3, 3] : []))
                    marker(point.time, point.pvW, .solarMark)
                    marker(point.time, point.gridW, .gridMark)
                    marker(point.time, point.loadW, .primary)
                }
            }
            .chartXScale(domain: curve.dayStart...curve.dayEnd)
            .chartXAxis { hourAxis(curve) }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.18))
                    AxisValueLabel {
                        if let kW = value.as(Double.self) { Text(kW == 0 ? "0" : "\(kW.formatted(.number.precision(.fractionLength(0...1)))) kW") }
                    }
                }
            }
            .chartLegend(.hidden)
            .chartXSelection(value: $selection)
            .frame(height: 240)
            .accessibilityLabel("Chart of today's solar, grid and load power")
        }
    }

    /// The moment shown and each series' power at it; the coloured marks double as the legend.
    private var readout: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(shown.map { selection == nil ? "Latest · " + $0.time.formatted(date: .omitted, time: .shortened)
                                              : $0.time.formatted(date: .omitted, time: .shortened) } ?? "")
                .font(.footnote.weight(.medium)).foregroundStyle(.secondary).monospacedDigit()
            HStack(spacing: 0) {
                value(.solar, shown?.pvW)
                value(.grid, shown?.gridW)
                value(.load, shown?.loadW)
            }
        }
        .animation(nil, value: selection)
    }

    private func value(_ source: EnergySource, _ watts: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                SourceIcon(source: source, size: 12)
                Text(source.name).font(.caption).foregroundStyle(.secondary)
            }
            Text(watts.map(PowerFormat.watts) ?? "–").font(.headline).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func marker(_ time: Date, _ watts: Double, _ color: Color) -> some ChartContent {
        PointMark(x: .value("Time", time), y: .value("kW", watts / 1000))
            .symbolSize(48)
            .foregroundStyle(color)
    }
}

/// The battery's charge through the day, sharing the power chart's selected moment.
private struct BatteryChart: View {
    let curve: DayCurve
    @Binding var selection: Date?

    private var points: [DayCurvePoint] { curve.points.filter { $0.batteryPercent != nil } }
    private var shown: DayCurvePoint? {
        (selection.flatMap { time in points.min { abs($0.time.timeIntervalSince(time)) < abs($1.time.timeIntervalSince(time)) } }) ?? points.last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let percent = shown?.batteryPercent {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Battery").font(.footnote.weight(.medium)).foregroundStyle(.secondary)
                    Text("\(Int(percent.rounded()))%").font(.headline).monospacedDigit()
                    Text(selection == nil ? "now" : "at " + (shown?.time.formatted(date: .omitted, time: .shortened) ?? ""))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Chart {
                ForEach(points) { point in
                    AreaMark(x: .value("Time", point.time), y: .value("Charge", point.batteryPercent ?? 0))
                        .foregroundStyle(LinearGradient(colors: [Color.green.opacity(0.22), Color.green.opacity(0.02)],
                                                        startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", point.time), y: .value("Charge", point.batteryPercent ?? 0))
                        .foregroundStyle(Color.green)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.monotone)
                }
                if let point = shown, let percent = point.batteryPercent {
                    RuleMark(x: .value("Time", point.time))
                        .foregroundStyle(Color.secondary.opacity(selection == nil ? 0.25 : 0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: selection == nil ? [3, 3] : []))
                    PointMark(x: .value("Time", point.time), y: .value("Charge", percent))
                        .symbolSize(48).foregroundStyle(Color.green)
                }
            }
            .chartXScale(domain: curve.dayStart...curve.dayEnd)
            .chartYScale(domain: 0...100)
            .chartXAxis { hourAxis(curve) }
            .chartYAxis {
                AxisMarks(position: .trailing, values: [0, 50, 100]) { value in
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.18))
                    AxisValueLabel { if let v = value.as(Int.self) { Text("\(v)%") } }
                }
            }
            .chartXSelection(value: $selection)
            .frame(height: 120)
            .accessibilityLabel("Chart of the battery's charge through the day")
        }
    }
}

/// Midnight, 6 am, noon, 6 pm and midnight.
private func hourAxis(_ curve: DayCurve) -> some AxisContent {
    AxisMarks(values: stride(from: 0, through: 24, by: 6).map { curve.dayStart.addingTimeInterval(Double($0) * 3600) }) { value in
        AxisGridLine().foregroundStyle(Color.secondary.opacity(0.12))
        AxisValueLabel(format: .dateTime.hour(), centered: false)
    }
}

private extension DayCurve {
    /// The reading closest to `time`, or nil without one.
    func point(near time: Date?) -> DayCurvePoint? {
        guard let time else { return nil }
        return points.min { abs($0.time.timeIntervalSince(time)) < abs($1.time.timeIntervalSince(time)) }
    }
}
#endif
