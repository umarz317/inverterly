#if os(iOS)
import SwiftUI

/// Solar, grid and load as an icon in the series colour, used wherever a number needs naming:
/// the sun is orange, the grid's plug blue, the house (load) in the text colour. The charts keep
/// their own orange and grey; only the icons carry the extra colour.
enum EnergySource {
    case solar, grid, load, export

    var symbol: String {
        switch self {
        case .solar: "sun.max.fill"
        case .grid: "powerplug.fill"
        case .load: "house.fill"
        case .export: "arrow.up.right.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .solar: .solarMark
        case .grid: .blue
        case .load: .primary
        case .export: .green
        }
    }

    var name: String {
        switch self {
        case .solar: "Solar"
        case .grid: "Grid"
        case .load: "Load"
        case .export: "Export"
        }
    }
}

struct SourceIcon: View {
    let source: EnergySource
    var size: CGFloat = 14

    var body: some View {
        Image(systemName: source.symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(source.tint)
            .frame(width: size + 4)
            .accessibilityHidden(true)
    }
}
#endif
