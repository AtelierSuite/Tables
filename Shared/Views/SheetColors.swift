import SwiftUI

/// The colours the grid and the charts on it are drawn in.
extension Color {
    /// The paper behind the grid.
    static let sheetBackground: Color = {
        #if canImport(UIKit)
        return Color(uiColor: .systemBackground)
        #else
        return Color(nsColor: .textBackgroundColor)
        #endif
    }()

    /// The surface the paper sits on, past the last row and column.
    static let sheetCanvas: Color = {
        #if canImport(UIKit)
        return Color(uiColor: .secondarySystemBackground)
        #else
        return Color(nsColor: .underPageBackgroundColor)
        #endif
    }()

    /// The hairline between cells.
    ///
    /// Not one opacity of `primary` for both appearances: a hairline is thin
    /// enough that the eye needs far more contrast from it in the dark, where
    /// 12% white over black all but disappears, than the same figure gives
    /// over white paper.
    static let gridLine: Color = {
        #if canImport(UIKit)
        return Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 1, alpha: 0.32)
                : UIColor(white: 0, alpha: 0.14)
        })
        #else
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(white: 1, alpha: 0.32)
                : NSColor(white: 0, alpha: 0.14)
        })
        #endif
    }()

    static let headerBackground = Color.primary.opacity(0.05)
}
