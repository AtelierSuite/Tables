import SwiftUI
import TablesEngine

/// A shape from a sheet's drawing — a rectangle, oval, line, arrow or text
/// box — drawn with its fill, outline and text. Shared by the iPhone and iPad
/// grid, the Mac grid and the Mac printout.
///
/// Colours go through the same adaptation as cell fills and text, so a box
/// of black text stays readable on a dark sheet.
struct DrawingShapeView: View, Equatable {
    let shape: DrawingShape
    var zoom: Double = 1

    @Environment(\.colorScheme) private var colorScheme

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.shape == rhs.shape && lhs.zoom == rhs.zoom }

    /// DrawingML's default text insets: a tenth of an inch at the sides,
    /// a twentieth at the top and bottom.
    private static let horizontalInset = 7.2
    private static let verticalInset = 3.6

    var body: some View {
        ZStack {
            if shape.kind.isLine {
                line
            } else {
                area
                if !shape.text.isEmpty { text }
            }
        }
        .rotationEffect(.degrees(shape.rotation))
    }

    private var fill: Color {
        AdaptiveColor.resolve(hex: shape.fillHex, for: colorScheme, isText: false) ?? .clear
    }

    private var stroke: Color {
        AdaptiveColor.resolve(hex: shape.outlineHex, for: colorScheme, isText: true) ?? .clear
    }

    private var lineWidth: Double { max(0.5, shape.outlineWidth * zoom) }

    @ViewBuilder
    private var area: some View {
        switch shape.kind {
        case .ellipse:
            Ellipse().fill(fill).overlay {
                if shape.outlineHex != nil { Ellipse().strokeBorder(stroke, lineWidth: lineWidth) }
            }
        case .roundedRectangle:
            // Office's default corner: a sixth of the shorter side.
            GeometryReader { proxy in
                let radius = min(proxy.size.width, proxy.size.height) / 6
                RoundedRectangle(cornerRadius: radius).fill(fill).overlay {
                    if shape.outlineHex != nil {
                        RoundedRectangle(cornerRadius: radius).strokeBorder(stroke, lineWidth: lineWidth)
                    }
                }
            }
        default:
            Rectangle().fill(fill).overlay {
                if shape.outlineHex != nil { Rectangle().strokeBorder(stroke, lineWidth: lineWidth) }
            }
        }
    }

    private var line: some View {
        Canvas { context, size in
            guard shape.outlineHex != nil else { return }
            // Top-left to bottom-right, unless flipped.
            var start = CGPoint(x: 0, y: 0)
            var end = CGPoint(x: size.width, y: size.height)
            if shape.flipsHorizontally { swap(&start.x, &end.x) }
            if shape.flipsVertically { swap(&start.y, &end.y) }
            var path = Path()
            path.move(to: start)
            path.addLine(to: end)
            let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round)
            context.stroke(path, with: .color(stroke), style: style)
            if shape.hasArrowAtEnd { context.fill(arrowHead(at: end, from: start), with: .color(stroke)) }
            if shape.hasArrowAtStart { context.fill(arrowHead(at: start, from: end), with: .color(stroke)) }
        }
    }

    /// Office's medium triangle: three line widths long and wide, at least
    /// big enough to see.
    private func arrowHead(at tip: CGPoint, from tail: CGPoint) -> Path {
        let angle = atan2(tip.y - tail.y, tip.x - tail.x)
        let length = max(6 * zoom, lineWidth * 3)
        let spread = Double.pi / 7
        var path = Path()
        path.move(to: tip)
        path.addLine(to: CGPoint(x: tip.x - length * cos(angle - spread), y: tip.y - length * sin(angle - spread)))
        path.addLine(to: CGPoint(x: tip.x - length * cos(angle + spread), y: tip.y - length * sin(angle + spread)))
        path.closeSubpath()
        return path
    }

    private var text: some View {
        let horizontal: Alignment = switch shape.textAlignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
        let vertical: Alignment = switch shape.textAnchor {
        case .top: .top
        case .center: .center
        case .bottom: .bottom
        }
        let textAlignment: TextAlignment = switch shape.textAlignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
        let color = AdaptiveColor.resolveText(hex: shape.textHex, on: shape.fillHex, for: colorScheme) ?? .primary
        return Text(shape.text)
            .font(.system(size: shape.fontSize * zoom))
            .foregroundStyle(color)
            .multilineTextAlignment(textAlignment)
            .padding(.horizontal, Self.horizontalInset * zoom)
            .padding(.vertical, Self.verticalInset * zoom)
            .frame(maxWidth: .infinity, maxHeight: .infinity,
                   alignment: Alignment(horizontal: horizontal.horizontal, vertical: vertical.vertical))
            .clipped()
    }
}
