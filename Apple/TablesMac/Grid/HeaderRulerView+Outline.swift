import AppKit
import TablesEngine

/// The outline gutter along a header's outer edge: a bracket beside each
/// group of rows or columns, one lane per level, and on the group's summary
/// line a button that collapses or expands it.
extension HeaderRulerView {
    /// How wide one level's lane is, and the button in it.
    static let outlineLane: CGFloat = 14
    private static let outlineButton: CGFloat = 11

    static func outlineThickness(for outline: LineOutline) -> CGFloat {
        let levels = outline.maximumLevel
        return levels == 0 ? 0 : CGFloat(levels) * outlineLane + 4
    }

    var outlineAxis: OutlineAxis { isColumns ? .column : .row }

    /// The span of a line along the ruler, where it shows now.
    private func span(of line: Int) -> CGRect? {
        guard line >= 0, line < lineCount, length(of: line) > 0 else { return nil }
        return rulerRect(start: start(of: line), length: length(of: line), frozen: line < frozenCount)
    }

    /// Where along the gutter's depth a level's lane is centred.
    private func laneCenter(_ level: Int) -> CGFloat {
        2 + (CGFloat(level) - 0.5) * Self.outlineLane
    }

    /// The button for a group, if its summary line is in view.
    func outlineButtonRect(for group: LineOutline.Group) -> CGRect? {
        guard let summary = span(of: group.summary) else { return nil }
        let size = Self.outlineButton
        let lane = laneCenter(group.level)
        return isColumns
            ? CGRect(x: summary.midX - size / 2, y: lane - size / 2, width: size, height: size)
            : CGRect(x: lane - size / 2, y: summary.midY - size / 2, width: size, height: size)
    }

    func drawOutline(of sheet: Worksheet) {
        let outline = sheet.outline(outlineAxis)
        let color = NSColor.secondaryLabelColor
        let gutter = isColumns
            ? CGRect(x: 0, y: 0, width: bounds.width, height: outlineThickness)
            : CGRect(x: 0, y: 0, width: outlineThickness, height: bounds.height)
        NSColor.labelColor.withAlphaComponent(0.03).setFill()
        gutter.fill()
        CellRenderer.gridLineColor(for: effectiveAppearance).setFill()
        (isColumns
            ? CGRect(x: 0, y: outlineThickness - 1, width: bounds.width, height: 1)
            : CGRect(x: outlineThickness - 1, y: 0, width: 1, height: bounds.height)).fill()

        for group in outline.groups() {
            let collapsed = sheet.isCollapsed(group, axis: outlineAxis)
            let button = outlineButtonRect(for: group)
            if !collapsed {
                // The bracket: a line beside the group's lines, ending in a
                // tick towards the summary.
                let shown = group.lines.compactMap { span(of: $0) }
                if let first = shown.first, let last = shown.last {
                    let lane = laneCenter(group.level)
                    color.setFill()
                    if isColumns {
                        let start = outline.summaryAfter ? first.minX + 2 : (button?.maxX ?? first.minX + 2)
                        let end = outline.summaryAfter ? (button?.minX ?? last.maxX - 2) : last.maxX - 2
                        CGRect(x: start, y: lane - 0.5, width: max(0, end - start), height: 1).fill()
                        let tick = outline.summaryAfter ? first.minX + 2 : last.maxX - 3
                        CGRect(x: tick, y: lane - 0.5, width: 1, height: 5).fill()
                    } else {
                        let start = outline.summaryAfter ? first.minY + 2 : (button?.maxY ?? first.minY + 2)
                        let end = outline.summaryAfter ? (button?.minY ?? last.maxY - 2) : last.maxY - 2
                        CGRect(x: lane - 0.5, y: start, width: 1, height: max(0, end - start)).fill()
                        let tick = outline.summaryAfter ? first.minY + 2 : last.maxY - 3
                        CGRect(x: lane - 0.5, y: tick, width: 5, height: 1).fill()
                    }
                }
            }
            guard let button else { continue }
            NSColor.controlBackgroundColor.setFill()
            button.fill()
            color.setStroke()
            let frame = NSBezierPath(rect: button.insetBy(dx: 0.5, dy: 0.5))
            frame.lineWidth = 1
            frame.stroke()
            color.setFill()
            CGRect(x: button.minX + 2.5, y: button.midY - 0.5, width: button.width - 5, height: 1).fill()
            if collapsed {
                CGRect(x: button.midX - 0.5, y: button.minY + 2.5, width: 1, height: button.height - 5).fill()
            }
        }
    }

    /// Collapses or expands the group under a click in the gutter: its
    /// button, or anywhere along its bracket. False when the click was not
    /// in the gutter, so the ruler handles it as usual.
    func handleOutlineClick(at point: NSPoint) -> Bool {
        guard let document else { return false }
        let depth = isColumns ? point.y : point.x
        guard depth < outlineThickness else { return false }
        let line = line(at: gridPosition(of: point))
        let groups = document.activeSheet.outline(outlineAxis).groups()
        let hit = groups.first { outlineButtonRect(for: $0)?.insetBy(dx: -3, dy: -3).contains(point) == true }
            ?? groups.first { group in
                abs(depth - laneCenter(group.level)) <= Self.outlineLane / 2
                    && group.lines.contains(line) && !document.activeSheet.isCollapsed(group, axis: outlineAxis)
            }
        if let hit {
            let state = document.state
            document.edit { state.toggleOutlineGroup(hit, axis: outlineAxis, in: &$0) }
        }
        // A click elsewhere in the gutter does nothing, rather than select.
        return true
    }
}
