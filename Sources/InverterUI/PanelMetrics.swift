import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// The panel's sizes are set in macOS points. On iOS the same scale steps up so the 13 pt macOS
/// body reads as the 17 pt iOS body, and follows the text size chosen in Settings.
enum PanelScale {
    static func scaled(_ size: CGFloat) -> CGFloat {
        #if os(iOS)
        UIFontMetrics.default.scaledValue(for: size * 17 / 13)
        #else
        size
        #endif
    }

    /// Opacity of the chart's axis labels: a touch darker on the phone, read at arm's length in daylight.
    #if os(iOS)
    static let axisInk = 0.6
    #else
    static let axisInk = 0.4
    #endif
}

extension ShapeStyle where Self == HierarchicalShapeStyle {
    /// The quietest text: tertiary on the Mac's glass, secondary on the phone, where tertiary is too faint to read.
    static var faint: HierarchicalShapeStyle {
        #if os(iOS)
        .secondary
        #else
        .tertiary
        #endif
    }
}

extension Font {
    /// The system font at a panel size (see `PanelScale`).
    static func panel(_ size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: PanelScale.scaled(size), weight: weight, design: design)
    }
}

extension Color {
    /// Behind a card: a faint wash on the macOS glass panel, the grouped card colour on iOS.
    static var panelCard: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemGroupedBackground)
        #else
        Color.primary.opacity(0.035)
        #endif
    }
}

#if os(iOS)
extension View {
    /// A grouped card on the phone's grey background.
    func phoneCard() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.panelCard, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
#endif

#if os(macOS)
extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
#endif
