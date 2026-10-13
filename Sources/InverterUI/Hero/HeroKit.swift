import SwiftUI
import InverterCore

/// Everything a hero needs to draw one frame. A hero is a pure function of `(HeroFrame, Date)`:
/// no timers and no state of its own, so the lab can render any moment exactly.
public struct HeroFrame: Equatable {
    public var snapshot: EnergySnapshot?
    /// Flows before the latest reading arrived, and the moment it arrived. Heroes ease from
    /// `previous` to the snapshot's flows over `ramp` seconds so a flow builds up or dies away
    /// instead of popping.
    public var previous: EnergyFlows
    public var changedAt: Date

    public static let ramp: TimeInterval = 1.1

    public init(snapshot: EnergySnapshot?, previous: EnergyFlows = .zero, changedAt: Date = .distantPast) {
        self.snapshot = snapshot; self.previous = previous; self.changedAt = changedAt
    }

    public var target: EnergyFlows { snapshot?.flows ?? .zero }

    /// 0 at the moment of change, 1 once the ramp has finished (ease in-out).
    public func progress(at now: Date) -> Double {
        let raw = min(1, max(0, now.timeIntervalSince(changedAt) / Self.ramp))
        return raw < 0.5 ? 2 * raw * raw : 1 - pow(-2 * raw + 2, 2) / 2
    }

    /// The flows to draw right now.
    public func flows(at now: Date) -> EnergyFlows { previous.mix(target, progress(at: now)) }

    public func isTransitioning(at now: Date) -> Bool { now.timeIntervalSince(changedAt) < Self.ramp + 0.1 }
}

/// Drives a hero: remembers the previous flows, restarts the ramp when a new reading changes them,
/// and ticks the animation clock only while something is moving and the panel is on screen.
public struct HeroHost<Content: View>: View {
    private let snapshot: EnergySnapshot?
    private let active: Bool
    private let content: (HeroFrame, Date) -> Content
    @State private var frame = HeroFrame(snapshot: nil)
    @State private var transitioning = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `active` is false while the panel is closed. The hosting view outlives the closed window
    /// and a timeline in it would keep drawing at display rate, so it has to be told to stop.
    public init(snapshot: EnergySnapshot?, active: Bool = true, @ViewBuilder content: @escaping (HeroFrame, Date) -> Content) {
        self.snapshot = snapshot; self.active = active; self.content = content
    }

    public var body: some View {
        let moving = (frame.snapshot?.flows ?? .zero) != .zero
        // Capped at 60 frames a second: a 120 Hz display would otherwise double the work for no visible gain.
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion || !active || (!moving && !transitioning))) { context in
            // With Reduce Motion the hero is drawn settled at one fixed instant.
            content(frame, reduceMotion ? frame.changedAt.addingTimeInterval(HeroFrame.ramp + 1) : context.date)
        }
        .onAppear { adopt(snapshot) }
        .onChange(of: snapshot) { _, new in adopt(new) }
        // One task per ramp: a newer reading cancels the older task, so an old timer can never
        // switch the clock off in the middle of a newer ramp.
        .task(id: frame.changedAt) {
            guard transitioning else { return }
            try? await Task.sleep(for: .seconds(HeroFrame.ramp + 0.15))
            if !Task.isCancelled { transitioning = false }
        }
        .accessibilityHidden(true)
    }

    private func adopt(_ new: EnergySnapshot?) {
        let now = Date()
        let shown = frame.flows(at: now)
        let target = new?.flows ?? .zero
        if target != frame.target || frame.snapshot == nil {
            transitioning = true
            frame = HeroFrame(snapshot: new, previous: shown, changedAt: now)
        } else {
            frame.snapshot = new
        }
    }
}

/// Small drawing helpers shared by the heroes.
public enum HeroMath {
    /// 0…1 intensity for a power, compressed so 100 W is already visible and 6 kW is not a blur.
    public static func intensity(_ watts: Double, full: Double = 5000) -> Double {
        guard watts > 1 else { return 0 }
        return min(1, max(0.12, log10(1 + watts / 40) / log10(1 + full / 40)))
    }

    public static func fract(_ x: Double) -> Double { x - floor(x) }

    /// Stable pseudo-random 0…1 for an integer seed (no state, same every frame).
    public static func hash(_ seed: Int) -> Double { fract(sin(Double(seed) * 12.9898 + 4.1414) * 43758.5453) }
}

public extension Color {
    /// Restrained accents for the energy sources. Heroes stay mostly monochrome ink and use these sparingly.
    #if os(iOS)
    // The phone uses the system palette, matching its charts: orange sun, grey grid, green battery.
    static let solarAccent = Color(uiColor: .systemOrange)
    static let batteryAccent = Color(uiColor: .systemGreen)
    static let gridAccent = Color(uiColor: .systemGray)
    static let alertAccent = Color(uiColor: .systemRed)
    #else
    static let solarAccent = Color(red: 1.00, green: 0.78, blue: 0.36)
    static let batteryAccent = Color(red: 0.45, green: 0.86, blue: 0.62)
    static let gridAccent = Color(red: 0.50, green: 0.72, blue: 1.00)
    static let alertAccent = Color(red: 1.00, green: 0.50, blue: 0.42)
    #endif
}
