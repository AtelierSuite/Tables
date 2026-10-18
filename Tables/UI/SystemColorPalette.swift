import SwiftUI
import TablesEngine

/// The Human Interface Guidelines system colours, offered as swatches.
///
/// Formatting a spreadsheet from a colour wheel produces documents that look
/// improvised; picking from the platform palette produces ones that look like
/// they belong on the platform. The wheel is still there for anything else.
///
/// The values are the HIG light-appearance sRGB definitions rather than the
/// live dynamic colours: a stored cell colour has to mean one fixed thing in
/// the file, and `AdaptiveColor` is what adjusts it for a dark viewer.
enum SystemColorPalette {
    struct Swatch: Identifiable, Hashable {
        /// Stable across releases — the UI tests and any saved preference key off it.
        let id: String
        /// String catalog key for the colour's name, spoken by VoiceOver.
        let labelKey: String
        /// OOXML "AARRGGBB", which is how `CellStyle` stores colour.
        let argbHex: String

        var color: Color { Color(argbHex: argbHex) ?? .primary }

        var label: String { String(localized: String.LocalizationValue(labelKey)) }
    }

    /// The accent colours, for text and for emphatic fills.
    static let accents: [Swatch] = [
        Swatch(id: "red", labelKey: "Color.Red", argbHex: "FFFF3B30"),
        Swatch(id: "orange", labelKey: "Color.Orange", argbHex: "FFFF9500"),
        Swatch(id: "yellow", labelKey: "Color.Yellow", argbHex: "FFFFCC00"),
        Swatch(id: "green", labelKey: "Color.Green", argbHex: "FF34C759"),
        Swatch(id: "mint", labelKey: "Color.Mint", argbHex: "FF00C7BE"),
        Swatch(id: "teal", labelKey: "Color.Teal", argbHex: "FF30B0C7"),
        Swatch(id: "cyan", labelKey: "Color.Cyan", argbHex: "FF32ADE6"),
        Swatch(id: "blue", labelKey: "Color.Blue", argbHex: "FF007AFF"),
        Swatch(id: "indigo", labelKey: "Color.Indigo", argbHex: "FF5856D6"),
        Swatch(id: "purple", labelKey: "Color.Purple", argbHex: "FFAF52DE"),
        Swatch(id: "pink", labelKey: "Color.Pink", argbHex: "FFFF2D55"),
        Swatch(id: "brown", labelKey: "Color.Brown", argbHex: "FFA2845E"),
    ]

    /// The greys, which is what most sheet furniture actually wants — header
    /// bands, banding, rules — plus plain black and white.
    static let neutrals: [Swatch] = [
        Swatch(id: "black", labelKey: "Color.Black", argbHex: "FF000000"),
        Swatch(id: "gray", labelKey: "Color.Grey", argbHex: "FF8E8E93"),
        Swatch(id: "gray2", labelKey: "Color.Grey2", argbHex: "FFAEAEB2"),
        Swatch(id: "gray3", labelKey: "Color.Grey3", argbHex: "FFC7C7CC"),
        Swatch(id: "gray4", labelKey: "Color.Grey4", argbHex: "FFD1D1D6"),
        Swatch(id: "gray5", labelKey: "Color.Grey5", argbHex: "FFE5E5EA"),
        Swatch(id: "gray6", labelKey: "Color.Grey6", argbHex: "FFF2F2F7"),
        Swatch(id: "white", labelKey: "Color.White", argbHex: "FFFFFFFF"),
    ]

    static let all: [Swatch] = accents + neutrals

    static func swatch(id: String) -> Swatch? {
        all.first { $0.id == id }
    }
}

/// A horizontal carousel of system colour swatches, led by the system colour
/// picker. `role` distinguishes the text and fill rows so each swatch has its
/// own identifier.
///
/// The carousel runs edge to edge — the row's own insets are removed so the
/// swatches scroll out under the card's rounded corners rather than stopping
/// short of them — and carries its own inner padding so the first and last
/// swatch still line up with the rest of the form at rest.
struct SystemColorSwatches: View {
    enum Role: String {
        case text = "textColor"
        case fill = "fillColor"
        case border = "borderColor"

        /// Accessibility wording is built per role rather than by pasting a role
        /// noun onto a phrase: the two halves do not compose in every language.
        var moreColoursLabel: LocalizedStringKey {
            switch self {
            case .text: return "ColorSwatches.More.Text.Accessibility"
            case .fill: return "ColorSwatches.More.Fill.Accessibility"
            case .border: return "ColorSwatches.More.Border.Accessibility"
            }
        }

        var noColourLabel: LocalizedStringKey {
            switch self {
            case .text: return "ColorSwatches.None.Text.Accessibility"
            case .fill: return "ColorSwatches.None.Fill.Accessibility"
            case .border: return "ColorSwatches.None.Border.Accessibility"
            }
        }

        func swatchLabel(_ colorName: String) -> String {
            switch self {
            case .text:
                return String(
                    format: String(localized: "ColorSwatches.Swatch.Text.Accessibility"), colorName
                )
            case .fill:
                return String(
                    format: String(localized: "ColorSwatches.Swatch.Fill.Accessibility"), colorName
                )
            case .border:
                return String(
                    format: String(localized: "ColorSwatches.Swatch.Border.Accessibility"), colorName
                )
            }
        }
    }

    let role: Role
    /// The colour currently applied, so the matching swatch can show as chosen.
    let selectedHex: String?
    /// Drives the escape-hatch colour picker that leads the carousel.
    @Binding var customColor: Color
    let onSelect: (SystemColorPalette.Swatch) -> Void
    /// Clears the colour. The carousel shows a struck-through swatch for it, so
    /// "no colour" is a choice among the colours rather than a separate button.
    let onClear: () -> Void

    /// Matches the system colour picker's own swatch, so the carousel reads as
    /// one row of equals rather than a picker followed by larger circles.
    private let swatchSize: CGFloat = 28

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                // The system palette is the escape hatch, not the first offer —
                // but it stays reachable without scrolling.
                ColorPicker("ColorSwatches.MoreColours", selection: $customColor, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: swatchSize, height: swatchSize)
                    .padding(3)
                    .accessibilityIdentifier("\(role.rawValue).more")
                    .accessibilityLabel(role.moreColoursLabel)

                Divider().frame(height: swatchSize)

                clearSwatch

                ForEach(SystemColorPalette.all) { swatch in
                    let isSelected = selectedHex?.caseInsensitiveCompare(swatch.argbHex) == .orderedSame
                    Button {
                        onSelect(swatch)
                    } label: {
                        Circle()
                            .fill(swatch.color)
                            .frame(width: swatchSize, height: swatchSize)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                            .overlay {
                                if isSelected {
                                    Circle().strokeBorder(Color.accentColor, lineWidth: 3).padding(-3)
                                }
                            }
                            .padding(3)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("\(role.rawValue).\(swatch.id)")
                    .accessibilityLabel(role.swatchLabel(swatch.label))
                    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
        .listRowInsets(EdgeInsets())
        .accessibilityIdentifier("\(role.rawValue).swatches")
    }

    /// The "no colour" swatch: an empty ring with a rule through it, the way a
    /// colour well shows an absent colour everywhere else on the platform.
    private var clearSwatch: some View {
        let isSelected = selectedHex == nil
        return Button(action: onClear) {
            Circle()
                .strokeBorder(Color.secondary.opacity(0.55), lineWidth: 1.5)
                .overlay {
                    // 45°, corner to corner of the circle's inscribed square.
                    Path { path in
                        let inset = swatchSize / 2 * (1 - 1 / sqrt(2))
                        path.move(to: CGPoint(x: inset, y: swatchSize - inset))
                        path.addLine(to: CGPoint(x: swatchSize - inset, y: inset))
                    }
                    .stroke(Color.red.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                }
                .frame(width: swatchSize, height: swatchSize)
                .overlay {
                    if isSelected {
                        Circle().strokeBorder(Color.accentColor, lineWidth: 3).padding(-3)
                    }
                }
                .padding(3)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("\(role.rawValue).none")
        .accessibilityLabel(role.noColourLabel)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
