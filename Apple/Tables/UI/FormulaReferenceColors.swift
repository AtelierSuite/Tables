import SwiftUI
import TablesEngine

/// The colours a formula's references are told apart by, both where they are
/// outlined on the grid and where they are written in the formula.
enum FormulaReferenceColors {
    /// Dynamic system colours, so the outlines stay legible in either
    /// appearance. Cycled once a formula names more cells than there are.
    private static let palette: [UIColor] = [
        .systemBlue, .systemRed, .systemPurple, .systemGreen,
        .systemOrange, .systemTeal, .systemPink, .systemBrown,
    ]

    static func uiColor(at index: Int) -> UIColor {
        palette[index % palette.count]
    }

    static func color(at index: Int) -> Color {
        Color(uiColor: uiColor(at: index))
    }
}
