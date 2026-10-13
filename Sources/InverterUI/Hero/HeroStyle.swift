import SwiftUI
import InverterCore

/// The selectable hero illustrations. Each case maps to one pure view of `(HeroFrame, Date)`.
public enum HeroStyle: String, CaseIterable, Identifiable, Sendable {
    case device
    case flow
    case scene

    public var id: String { rawValue }

    /// The illustration a fresh install starts with.
    public static let preferred: HeroStyle = .device

    /// The styles offered in the options menu.
    public static var selectable: [HeroStyle] { allCases }

    public var title: String {
        switch self {
        case .device: "Inverter"
        case .flow: "Flow map"
        case .scene: "House"
        }
    }

    /// SF Symbol shown beside the title in the options menu.
    public var symbol: String {
        switch self {
        case .device: "bolt.batteryblock"
        case .flow: "point.3.connected.trianglepath.dotted"
        case .scene: "house"
        }
    }

    /// Height the hero wants inside the 380 pt panel.
    public var height: CGFloat {
        switch self {
        case .device: 172
        case .flow: 186
        case .scene: 180
        }
    }

    @ViewBuilder
    public func view(frame: HeroFrame, now: Date) -> some View {
        switch self {
        case .device: HeroDevice(frame: frame, now: now)
        case .flow: HeroFlow(frame: frame, now: now)
        case .scene: HeroScene(frame: frame, now: now)
        }
    }
}
