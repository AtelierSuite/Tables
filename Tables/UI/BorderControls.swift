import SwiftUI
import TablesEngine

/// Which part of the border box a control is acting on.
enum BorderTarget: Hashable, Sendable {
    case edge(BorderEdge)
    case diagonalUp
    case diagonalDown
}

/// A straight rule in a border line style — its dashes, its weight, and both
/// strokes of a double rule.
///
/// The grid paints borders into a canvas rather than as views, so the controls
/// cannot show the real thing; this is the same geometry expressed as a shape,
/// which is what lets a swatch look like what it is going to draw.
struct BorderRule: Shape {
    let lineStyle: BorderLineStyle
    var isVertical = false
    /// Multiplies the stored weight. Swatches draw at 1; the box picker thickens
    /// its rules a little so a hairline still reads at a glance.
    var weight: Double = 1

    func path(in rect: CGRect) -> Path {
        Path { path in
            let offsets: [Double] = lineStyle.doubleLineGap.map { [-$0 / 2, $0 / 2] } ?? [0]
            for offset in offsets {
                if isVertical {
                    path.move(to: CGPoint(x: rect.midX + offset, y: rect.minY))
                    path.addLine(to: CGPoint(x: rect.midX + offset, y: rect.maxY))
                } else {
                    path.move(to: CGPoint(x: rect.minX, y: rect.midY + offset))
                    path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY + offset))
                }
            }
        }
    }

    var strokeStyle: StrokeStyle {
        StrokeStyle(
            lineWidth: lineStyle.lineWidth * weight,
            dash: lineStyle.dashPattern.map { CGFloat($0) }
        )
    }
}

/// One rule, drawn.
private struct Rule: View {
    let lineStyle: BorderLineStyle
    let color: Color
    var isVertical = false
    var weight: Double = 1

    var body: some View {
        let rule = BorderRule(lineStyle: lineStyle, isVertical: isVertical, weight: weight)
        rule.stroke(color, style: rule.strokeStyle)
    }
}

/// The cell drawn as a diagram, with a tap target on each of its sides.
///
/// Drawn rather than built from SF Symbols so that each side can show the
/// weight, dash and colour it is actually carrying.
struct BorderBoxPicker: View {
    let style: CellStyle
    let onToggle: (BorderTarget) -> Void

    @Environment(\.colorScheme) private var colorScheme

    /// The cell face.
    private let side: Double = 112
    /// How far a side's tap target reaches outside the box, and inside it. Most
    /// of the target sits outside, so aiming at an edge never means aiming into
    /// the middle, where the diagonals live.
    private let outward: Double = 24
    private let inward: Double = 10

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.primary.opacity(0.04))
                .frame(width: side, height: side)

            diagonals

            ForEach(BorderEdge.allCases, id: \.self) { edge in
                edgeButton(edge)
            }
        }
        .frame(width: side + outward * 2, height: side + outward * 2)
        .accessibilityElement(children: .contain)
    }

    // MARK: - Edges

    private func edgeButton(_ edge: BorderEdge) -> some View {
        let isVertical = edge == .leading || edge == .trailing
        let drawn = style.borderSides[edge]
        let thickness = outward + inward

        return Button { onToggle(.edge(edge)) } label: {
            ZStack {
                Color.clear
                if let drawn {
                    Rule(
                        lineStyle: drawn.lineStyle,
                        color: color(of: drawn.colorHex),
                        isVertical: isVertical,
                        weight: 1.6
                    )
                    .frame(width: isVertical ? 6 : side, height: isVertical ? side : 6)
                } else {
                    // Something faint to aim at: an edge you cannot see is an
                    // edge you cannot guess is tappable.
                    Capsule()
                        .fill(Color.secondary.opacity(0.28))
                        .frame(width: isVertical ? 1.5 : side, height: isVertical ? side : 1.5)
                }
            }
            .frame(
                width: isVertical ? thickness : side,
                height: isVertical ? side : thickness
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .offset(
            x: isVertical ? (edge == .leading ? -side / 2 : side / 2) : 0,
            y: isVertical ? 0 : (edge == .top ? -side / 2 : side / 2)
        )
        .accessibilityIdentifier("border.\(edge.rawValue)")
        .accessibilityLabel(BorderScope(edge).label)
        .accessibilityAddTraits(drawn != nil ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Diagonals

    /// The two diagonal rules, as a pair of buttons in the middle of the box —
    /// where the lines they draw actually cross, and clear of the edge targets.
    private var diagonals: some View {
        HStack(spacing: 8) {
            diagonalButton(.diagonalDown, isOn: style.diagonalBorder?.goesDown ?? false)
            diagonalButton(.diagonalUp, isOn: style.diagonalBorder?.goesUp ?? false)
        }
    }

    private func diagonalButton(_ target: BorderTarget, isOn: Bool) -> some View {
        let goesUp = target == .diagonalUp
        let diagonal = style.diagonalBorder
        let tint = isOn ? color(of: diagonal?.colorHex) : Color.secondary.opacity(0.4)
        let label: LocalizedStringKey = goesUp
            ? "Format.Border.DiagonalUp" : "Format.Border.DiagonalDown"

        return Button { onToggle(target) } label: {
            let rule = BorderRule(lineStyle: diagonal?.lineStyle ?? .thin, weight: isOn ? 1.6 : 1)
            Path { path in
                path.move(to: CGPoint(x: 6, y: goesUp ? 34 : 6))
                path.addLine(to: CGPoint(x: 34, y: goesUp ? 6 : 34))
            }
            .stroke(tint, style: rule.strokeStyle)
            .frame(width: 40, height: 40)
            .background(
                isOn ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04),
                in: .rect(cornerRadius: 8, style: .continuous)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(goesUp ? "border.diagonalUp" : "border.diagonalDown")
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }

    /// A stored colour as the grid would draw it, so the diagram and the sheet
    /// agree in both appearances.
    private func color(of hex: String?) -> Color {
        AdaptiveColor.resolve(hex: hex, for: colorScheme, isText: true) ?? .primary
    }
}

/// Picks which sides the line style and colour below it apply to.
struct BorderScopePicker: View {
    @Binding var scope: BorderScope

    var body: some View {
        HStack(spacing: 4) {
            ForEach(BorderScope.allCases) { option in
                let isSelected = option == scope
                Button { scope = option } label: {
                    BorderScopeGlyph(scope: option, isSelected: isSelected)
                        .frame(width: 26, height: 26)
                        .padding(6)
                        .background(
                            isSelected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05),
                            in: .rect(cornerRadius: 8, style: .continuous)
                        )
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(option.label)
                .accessibilityIdentifier("borderScope.\(option.rawValue)")
                .accessibilityLabel(option.label)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
    }
}

/// A small square standing in for a cell, with the scope's sides drawn heavy.
private struct BorderScopeGlyph: View {
    let scope: BorderScope
    let isSelected: Bool

    var body: some View {
        GeometryReader { proxy in
            let box = CGRect(origin: .zero, size: proxy.size).insetBy(dx: 2, dy: 2)
            ZStack {
                Rectangle().path(in: box)
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                highlight(in: box)
                    .stroke(
                        isSelected ? Color.accentColor : Color.primary,
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                    )
            }
        }
    }

    private func highlight(in box: CGRect) -> Path {
        Path { path in
            switch scope {
            case .all:
                path.addRect(box)
            case .diagonal:
                path.move(to: CGPoint(x: box.minX, y: box.minY))
                path.addLine(to: CGPoint(x: box.maxX, y: box.maxY))
                path.move(to: CGPoint(x: box.minX, y: box.maxY))
                path.addLine(to: CGPoint(x: box.maxX, y: box.minY))
            case .top:
                path.move(to: CGPoint(x: box.minX, y: box.minY))
                path.addLine(to: CGPoint(x: box.maxX, y: box.minY))
            case .bottom:
                path.move(to: CGPoint(x: box.minX, y: box.maxY))
                path.addLine(to: CGPoint(x: box.maxX, y: box.maxY))
            case .leading:
                path.move(to: CGPoint(x: box.minX, y: box.minY))
                path.addLine(to: CGPoint(x: box.minX, y: box.maxY))
            case .trailing:
                path.move(to: CGPoint(x: box.maxX, y: box.minY))
                path.addLine(to: CGPoint(x: box.maxX, y: box.maxY))
            }
        }
    }
}

/// The line styles as a carousel of drawn rules.
///
/// A menu of thirteen names — "Medium Dash Dot Dot" — asks the reader to picture
/// each one. Showing the stroke asks nothing.
struct BorderLineStylePicker: View {
    let selection: BorderLineStyle?
    let onSelect: (BorderLineStyle) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(BorderLineStyle.allCases, id: \.self) { option in
                    let isSelected = option == selection
                    Button { onSelect(option) } label: {
                        // Full contrast whatever colour the border is set to:
                        // what is picked here is the dash and the weight, and a
                        // pale swatch would hide both.
                        Rule(lineStyle: option, color: .primary)
                            .padding(.horizontal, 12)
                            .frame(width: 70, height: 32)
                            .background(
                                isSelected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05),
                                in: .capsule
                            )
                            .overlay {
                                if isSelected {
                                    Capsule().strokeBorder(Color.accentColor, lineWidth: 2)
                                }
                            }
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .help(option.label)
                    .accessibilityIdentifier("borderLineStyle.\(option.rawValue)")
                    .accessibilityLabel(option.label)
                    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .scrollIndicators(.hidden)
    }
}

/// A caption for one of the edge-to-edge carousels, which have no room for a
/// label of their own.
struct CarouselCaption: View {
    let key: LocalizedStringKey

    var body: some View {
        Text(key)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
