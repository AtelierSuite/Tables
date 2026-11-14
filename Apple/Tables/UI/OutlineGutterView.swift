import SwiftUI
import TablesEngine

/// The outline gutter beside the row numbers or above the column letters: a
/// bracket beside each group of lines, one lane per level, and on the
/// group's summary line a button that collapses or expands it.
struct OutlineGutterView: View {
    let axis: OutlineAxis
    let sheet: Worksheet
    let metrics: SheetMetrics
    /// How far the sheet is scrolled along the gutter's axis.
    let scrollOffset: Double
    let onToggle: (LineOutline.Group) -> Void

    /// How wide one level's lane is.
    static let lane: Double = 16
    private static let button: Double = 14

    /// How deep the gutter is for a sheet, zero when nothing is grouped on the axis.
    static func thickness(for outline: LineOutline) -> Double {
        let levels = outline.maximumLevel
        return levels == 0 ? 0 : Double(levels) * lane + 4
    }

    private var isRows: Bool { axis == .row }
    private var outline: LineOutline { sheet.outline(axis) }
    private var frozenCount: Int { isRows ? sheet.frozenRows : sheet.frozenColumns }
    private var lineCount: Int { isRows ? metrics.rowCount : metrics.columnCount }

    /// Where a line shows along the gutter, or nil while it is hidden.
    private func span(of line: Int) -> ClosedRange<Double>? {
        guard line >= 0, line < lineCount else { return nil }
        let length = isRows ? metrics.height(ofRow: line) : metrics.width(ofColumn: line)
        guard length > 0 else { return nil }
        let start = (isRows ? metrics.y(ofRow: line) : metrics.x(ofColumn: line))
            - (line < frozenCount ? 0 : scrollOffset)
        return start...(start + length)
    }

    private func laneCenter(_ level: Int) -> Double { 2 + (Double(level) - 0.5) * Self.lane }

    private func point(along: Double, depth: Double) -> CGPoint {
        isRows ? CGPoint(x: depth, y: along) : CGPoint(x: along, y: depth)
    }

    var body: some View {
        let groups = outline.groups()
        ZStack(alignment: .topLeading) {
            Color.headerBackground.background(.regularMaterial)
            Canvas { context, _ in
                for group in groups where !sheet.isCollapsed(group, axis: axis) {
                    let shown = group.lines.compactMap { span(of: $0) }
                    guard let first = shown.first, let last = shown.last else { continue }
                    let lane = laneCenter(group.level)
                    let summary = span(of: group.summary)
                    let start = outline.summaryAfter ? first.lowerBound + 3 : (summary.map { ($0.lowerBound + $0.upperBound) / 2 + Self.button / 2 } ?? first.lowerBound + 3)
                    let end = outline.summaryAfter ? (summary.map { ($0.lowerBound + $0.upperBound) / 2 - Self.button / 2 } ?? last.upperBound - 3) : last.upperBound - 3
                    let tick = outline.summaryAfter ? start : end
                    var path = Path()
                    path.move(to: point(along: start, depth: lane))
                    path.addLine(to: point(along: max(start, end), depth: lane))
                    path.move(to: point(along: tick, depth: lane))
                    path.addLine(to: point(along: tick, depth: lane + 5))
                    context.stroke(path, with: .color(.secondary), lineWidth: 1)
                }
            }
            ForEach(groups, id: \.self) { group in
                if let summary = span(of: group.summary) {
                    let collapsed = sheet.isCollapsed(group, axis: axis)
                    Button { onToggle(group) } label: {
                        Image(systemName: collapsed ? "plus" : "minus")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: Self.button, height: Self.button)
                            .background(Color(uiColor: .systemBackground))
                            .overlay { Rectangle().stroke(Color.secondary, lineWidth: 1) }
                            .frame(width: Self.lane, height: Self.lane)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(collapsed ? "Outline.Expand" : "Outline.Collapse")
                    .position(point(along: (summary.lowerBound + summary.upperBound) / 2, depth: laneCenter(group.level)))
                }
            }
        }
        .overlay(alignment: isRows ? .trailing : .bottom) {
            Rectangle().fill(Color.gridLine)
                .frame(width: isRows ? 1 : nil, height: isRows ? nil : 1)
        }
        .clipped()
    }
}
