#if os(iOS)
import SwiftUI
import InverterCore

/// The live reading: what carries the load, the hero, the load and a tile each for solar, battery,
/// grid and output, then the details.
struct NowScreen: View {
    @ObservedObject var store: AppStore
    /// False while another tab is showing, so the hero stops drawing.
    let visible: Bool

    var body: some View {
        VStack(spacing: 20) {
            if let snapshot = store.snapshot {
                banners(snapshot)
                live(snapshot)
                readings(snapshot)
                details(snapshot)
            } else if let message = store.errorMessage {
                FailedView(message: message) { Task { await store.refresh(force: true) } }
            } else {
                PhoneReadingView()
            }
        }
    }

    @ViewBuilder
    private func banners(_ snapshot: EnergySnapshot) -> some View {
        if let message = store.errorMessage {
            Banner(symbol: "exclamationmark.triangle", text: message, tint: .alertAccent)
        }
        if let warning = snapshot.activeWarning {
            Banner(symbol: "bolt.trianglebadge.exclamationmark", text: "Inverter warning: \(warning)", tint: .alertAccent)
        }
        if snapshot.isStale() {
            Banner(symbol: "clock.badge.exclamationmark", text: snapshot.staleText, tint: .orange)
        }
    }

    /// What carries the load, the hero and the load itself.
    private func live(_ snapshot: EnergySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.mode.label).font(.title3.weight(.semibold))
                        .contentTransition(.opacity)
                    Text(snapshot.statusLine).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                BatteryRing(percent: snapshot.batteryPercent, powerW: snapshot.batteryPowerW)
            }

            HeroHost(snapshot: snapshot, active: store.panelOpen && visible) { frame, now in
                store.heroStyle.view(frame: frame, now: now)
            }
            .frame(height: store.heroStyle.height)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)

            let load = PowerFormat.split(snapshot.loadPowerW)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(load.number)
                    .font(.system(size: 48, weight: .light, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText(value: snapshot.loadPowerW))
                Text(load.unit + " load").font(.title3).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text("\(Int((snapshot.loadFraction * 100).rounded()))% of capacity")
                    .font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
            }
            .animation(.snappy, value: snapshot.loadPowerW)
        }
        .padding(16)
        .phoneCard()
        .animation(.snappy, value: snapshot.mode)
    }

    /// Solar, battery, grid and output in one card.
    private func readings(_ snapshot: EnergySnapshot) -> some View {
        let battery = snapshot.batteryPowerW
        return Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 20) {
            GridRow {
                Reading(symbol: MenuBarMetric.solarSymbol(snapshot), tint: .solarMark, caption: "Solar",
                        value: PowerFormat.watts(snapshot.pvPowerW),
                        detail: snapshot.pvVoltage.map { String(format: "%.0f V", $0) } ?? "–",
                        quiet: snapshot.pvPowerW < 1)
                Reading(symbol: MenuBarMetric.batterySymbol(snapshot.batteryPercent), tint: .green, caption: "Battery",
                        value: snapshot.batteryPercent.map { "\(Int($0.rounded()))%" } ?? "–",
                        detail: abs(battery) > 30 ? "\(battery > 0 ? "Charging" : "Discharging") \(PowerFormat.watts(abs(battery)))" : "Idle")
            }
            GridRow {
                Reading(symbol: MenuBarMetric.gridSymbol(snapshot), tint: snapshot.gridPresent ? .gridMark : .alertAccent, caption: "Grid",
                        value: snapshot.gridPresent ? (snapshot.gridPowerW > 0 ? PowerFormat.watts(snapshot.gridPowerW) : "Standby") : "Outage",
                        detail: snapshot.gridPresent ? String(format: "%.0f V", snapshot.gridVoltage ?? 0) : "No supply",
                        quiet: snapshot.gridPresent && snapshot.gridPowerW < 1)
                Reading(symbol: "house", tint: .secondary, caption: "Output",
                        value: snapshot.outputVoltage.map { String(format: "%.0f V", $0) } ?? "–",
                        detail: snapshot.outputHz.map { String(format: "%.1f Hz", $0) } ?? "–")
            }
        }
        .padding(16)
        .phoneCard()
    }

    /// The full list, folded away until asked for.
    private func details(_ snapshot: EnergySnapshot) -> some View {
        DisclosureGroup(isExpanded: $store.showDetails) {
            DetailsSection(snapshot: snapshot).padding(.top, 12)
        } label: {
            Text("Details").font(.subheadline.weight(.medium))
        }
        .tint(.secondary)
        .foregroundStyle(.primary)
        .padding(16)
        .phoneCard()
    }
}

/// Until the first reading: what is happening, a pulse along a row of dashes like power on a wire,
/// and the tiles' places held so the screen does not jump when the numbers land.
private struct PhoneReadingView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 18) {
                Image("Logo")
                    .resizable()
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                    .shadow(color: Color.solarMark.opacity(breathing ? 0.45 : 0.1), radius: breathing ? 18 : 6)
                    .scaleEffect(breathing ? 1.04 : 1)
                VStack(spacing: 6) {
                    Text("Reading your inverter").font(.title3.weight(.semibold))
                    Text("Getting the latest numbers from the inverter cloud. This takes a few seconds.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
                    let beat = timeline.date.timeIntervalSinceReferenceDate * 4.2
                    HStack(spacing: 6) {
                        ForEach(0..<5, id: \.self) { index in
                            Capsule().fill(Color.solarMark)
                                .frame(width: 16, height: 4)
                                .opacity(reduceMotion ? 0.4 : ReadingView.glow(of: index, at: beat))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24).padding(.vertical, 36)
            .phoneCard()

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(0..<4, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 10) {
                        Circle().frame(width: 30, height: 30)
                        RoundedRectangle(cornerRadius: 6).frame(width: 90, height: 22)
                        RoundedRectangle(cornerRadius: 4).frame(width: 60, height: 12)
                    }
                    .foregroundStyle(.quaternary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .phoneCard()
                }
            }
            .opacity(breathing ? 0.6 : 1)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { breathing = true }
        }
    }
}

/// One reading: a small tinted symbol and caption, the value, and a detail under it.
private struct Reading: View {
    let symbol: String
    let tint: Color
    let caption: String
    let value: String
    let detail: String
    var quiet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label {
                Text(caption)
            } icon: {
                Image(systemName: symbol).foregroundStyle(tint)
                    .contentTransition(.symbolEffect(.replace))
            }
            .font(.subheadline).foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.semibold)).monospacedDigit()
                .foregroundStyle(quiet ? .secondary : .primary)
                .lineLimit(1).minimumScaleFactor(0.7)
                .contentTransition(.numericText())
            Text(detail)
                .font(.footnote).monospacedDigit().foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.snappy, value: value)
        .accessibilityElement(children: .combine)
    }
}
#endif
