import SwiftUI
import InverterCore

// MARK: - Header pieces

/// The round hit target behind a header icon.
struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .frame(width: 26, height: 26)
            .modifier(PointerDisc(pressed: configuration.isPressed))
    }
}

/// A disc that fades in under the pointer and tightens while the button is held down.
private struct PointerDisc: ViewModifier {
    let pressed: Bool
    @State private var underPointer = false

    func body(content: Content) -> some View {
        content
            .background {
                Circle()
                    .fill(.primary.opacity(pressed ? 0.14 : underPointer ? 0.08 : 0))
                    .scaleEffect(pressed ? 0.88 : 1)
            }
            .contentShape(Circle())
            .onHover { underPointer = $0 }
            .animation(.easeOut(duration: 0.12), value: underPointer)
            .animation(.easeOut(duration: 0.12), value: pressed)
    }
}

/// The refresh arrow, turning while a fetch is in flight.
struct RefreshGlyph: View {
    let spinning: Bool
    @State private var turn = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: "arrow.clockwise")
            .rotationEffect(.degrees(turn))
            .opacity(spinning ? 0.55 : 1)
            .onChange(of: spinning) { _, now in
                guard !reduceMotion else { return }
                if now {
                    withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { turn = 360 }
                } else {
                    withAnimation(.easeOut(duration: 0.25)) { turn = 0 }
                }
            }
    }
}

struct Banner: View {
    let symbol: String
    let text: String
    let tint: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
            Text(text).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Empty states

/// Shown until the first reading arrives: a pulse runs along a row of dashes, the same
/// left-to-right motion the heroes use for power on a wire.
struct ReadingView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let dashes = 5

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "bolt.fill").font(.system(size: 20)).foregroundStyle(.secondary)
            TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduceMotion)) { timeline in
                let beat = timeline.date.timeIntervalSinceReferenceDate * 4.2
                HStack(spacing: 5) {
                    ForEach(0..<Self.dashes, id: \.self) { index in
                        Capsule()
                            .fill(.primary)
                            .frame(width: 13, height: 3)
                            .opacity(reduceMotion ? 0.3 : Self.glow(of: index, at: beat))
                    }
                }
            }
            Text("Reading your inverter…").font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    /// How bright one dash is while the pulse travels past it. The pulse runs two dashes beyond
    /// the row before it starts again, which reads as a short rest between passes.
    static func glow(of index: Int, at beat: Double) -> Double {
        let head = beat.truncatingRemainder(dividingBy: Double(dashes + 2)) - 1
        let distance = abs(head - Double(index))
        return 0.16 + 0.70 * max(0, 1 - distance / 1.6)
    }
}

/// Asks for the inverter cloud account and saves it to the account file.
struct SignInView: View {
    @ObservedObject var store: AppStore
    @State private var user = ""
    @State private var password = ""
    @State private var working = false

    private var ready: Bool { !user.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty && !working }

    var body: some View {
        VStack(spacing: 16) {
            logo
            VStack(spacing: 4) {
                Text("Sign in").font(.system(size: 17, weight: .semibold))
                Text("Use the same username and password as in your inverter's phone app.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 8) {
                field(TextField("Username", text: $user))
                field(SecureField("Password", text: $password).onSubmit(submit))
            }
            if let error = store.signInError {
                Text(error).font(.system(size: 11)).foregroundStyle(Color.alertAccent)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            Button(action: submit) {
                Text(working ? "Signing in…" : "Sign in").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(!ready)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 22).padding(.vertical, 26)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// The app icon when running from the built app; a sun glyph when there is none (swift run, lab renders).
    @ViewBuilder private var logo: some View {
        if let icon = NSImage(named: "AppIcon") {
            Image(nsImage: icon).resizable().frame(width: 64, height: 64)
                .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
        } else {
            Image(systemName: "sun.max.fill").font(.system(size: 30)).foregroundStyle(Color.solarAccent)
                .frame(width: 64, height: 64)
                .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
    }

    private func field(_ view: some View) -> some View {
        view.textFieldStyle(.roundedBorder).controlSize(.large).font(.system(size: 13))
    }

    private func submit() {
        guard ready else { return }
        working = true
        let account = (user.trimmingCharacters(in: .whitespaces), password)
        Task {
            await store.signIn(user: account.0, password: account.1)
            working = false
            password = ""
        }
    }
}

struct FailedView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "bolt.slash").font(.system(size: 22, weight: .light)).foregroundStyle(.secondary)
            Text("Can't read the inverter").font(.system(size: 13, weight: .semibold))
            Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Button("Try again", action: retry).controlSize(.small).padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18).padding(.vertical, 28)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Card pieces

/// State of charge as a ring, with an arrow for the direction the battery is moving.
struct BatteryRing: View {
    let percent: Double?
    let powerW: Double

    var body: some View {
        let fraction = min(1, max(0, (percent ?? 0) / 100))
        let low = (percent ?? 100) < 20
        ZStack {
            Circle().stroke(.primary.opacity(0.10), lineWidth: 2)
            Circle().trim(from: 0, to: fraction)
                .stroke(low ? AnyShapeStyle(Color.alertAccent) : AnyShapeStyle(.primary.opacity(0.85)),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: powerW > 30 ? "arrow.up" : powerW < -30 ? "arrow.down" : "minus")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(powerW > 30 ? AnyShapeStyle(Color.batteryAccent) : AnyShapeStyle(.primary.opacity(0.75)))
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: 30, height: 30)
        .animation(.snappy, value: fraction)
        .help(helpText)
        .accessibilityLabel(helpText)
    }

    private var helpText: String {
        let level = percent.map { "Battery \(Int($0.rounded()))%" } ?? "Battery level unknown"
        let state = powerW > 30 ? "charging at \(PowerFormat.watts(powerW))"
            : powerW < -30 ? "discharging at \(PowerFormat.watts(powerW))" : "idle"
        return "\(level), \(state)"
    }
}

/// Read-only gauge of the load against the inverter's rated output, ticked every 10%.
struct LoadGauge: View {
    let fraction: Double
    let ratedW: Double?

    var body: some View {
        VStack(spacing: 3) {
            GeometryReader { geometry in
                let width = geometry.size.width
                let x = width * min(1, max(0, fraction))
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.10)).frame(height: 3)
                    Capsule().fill(fraction > 0.9 ? AnyShapeStyle(Color.alertAccent) : AnyShapeStyle(.primary.opacity(0.8)))
                        .frame(width: max(3, x), height: 3)
                    ForEach(1..<10, id: \.self) { tick in
                        Rectangle().fill(.primary.opacity(0.18))
                            .frame(width: 1, height: 7)
                            .offset(x: width * Double(tick) / 10 - 0.5)
                    }
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(.primary)
                        .frame(width: 5, height: 13)
                        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                        .offset(x: min(width - 5, max(0, x - 2.5)))
                }
                .frame(height: 13)
                .animation(.snappy, value: fraction)
            }
            .frame(height: 13)
            HStack {
                Text("0").font(.system(size: 9)).foregroundStyle(.tertiary)
                Spacer()
                if let ratedW, ratedW > 0 {
                    Text(PowerFormat.kilowatts(ratedW)).font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Load \(Int((fraction * 100).rounded())) percent of capacity")
    }
}

struct StatTile: View {
    let symbol: String
    let caption: String
    let value: String
    let detail: String
    var quiet: Bool = false
    var alert: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(alert ? AnyShapeStyle(Color.alertAccent) : AnyShapeStyle(.secondary))
                .frame(height: 16, alignment: .leading)
                .contentTransition(.symbolEffect(.replace))
                .padding(.bottom, 7)
            Text(caption).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.75)
                .foregroundStyle(quiet ? .secondary : .primary)
                .contentTransition(.numericText())
            Text(detail).font(.system(size: 10)).monospacedDigit().foregroundStyle(.tertiary)
                .lineLimit(1).minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8).padding(.vertical, 8)
        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .animation(.snappy, value: value)
        .accessibilityElement(children: .combine)
    }
}

/// A row that opens a section in place, like a disclosure without the system chrome.
struct SectionRow: View {
    let title: String
    let trailing: String?
    @Binding var open: Bool

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(open ? 90 : 0))
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(open ? "expanded" : "collapsed")
    }
}
