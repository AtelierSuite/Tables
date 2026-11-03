import AppKit
import SwiftUI
import TablesEngine

/// Draws a sheet's cells into the current graphics context: fills, the
/// hairlines between cells, text, borders, merged regions and comment marks.
///
/// Shared by the grid on screen and by printing, so a printed sheet looks
/// like the one in the window. Works in sheet coordinates at the metrics'
/// zoom, in a flipped context.
@MainActor
struct CellRenderer {
    let sheet: Worksheet
    let metrics: SheetMetrics
    /// The appearance colours are adapted for, already corrected for a sheet
    /// whose author made it dark.
    let scheme: ColorScheme
    var drawsGridlines = true
    /// The part of the sheet on show, when that stops short of all of it, as
    /// a printout or preview of the cells in use does. Borders on its edges
    /// are kept inside it.
    var shownArea: CGRect?

    init(sheet: Worksheet, metrics: SheetMetrics, appearance: NSAppearance, drawsGridlines: Bool = true) {
        self.sheet = sheet
        self.metrics = metrics
        let viewer: ColorScheme = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
        scheme = sheet.colorScheme(for: viewer)
        self.drawsGridlines = drawsGridlines
    }

    /// What the cells without a fill of their own show through to: the
    /// sheet's background colour, or the system's paper.
    var paper: NSColor {
        sheet.backgroundColorHex == nil ? .textBackgroundColor
            : AdaptiveColor.resolve(hex: sheet.backgroundColorHex, for: scheme, isText: false).map { NSColor($0) }
                ?? .textBackgroundColor
    }

    static func gridLineColor(for appearance: NSAppearance) -> NSColor {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.32)
            : NSColor(white: 0, alpha: 0.14)
    }

    /// Draws every cell that meets `rect`.
    func draw(in rect: CGRect, context: CGContext, gridLineColor: NSColor) {
        let rows = metrics.rows(in: Double(rect.minY)...Double(max(rect.minY, rect.maxY)), overscan: 0)
        let columns = metrics.columns(in: Double(rect.minX)...Double(max(rect.minX, rect.maxX)), overscan: 0)
        guard !rows.isEmpty, !columns.isEmpty else { return }

        let window = CellRange(
            start: CellAddress(row: rows.lowerBound, column: columns.lowerBound),
            end: CellAddress(row: rows.upperBound - 1, column: columns.upperBound - 1)
        )
        // Borders are centred on the gridlines, so the cells just outside
        // `rect` reach into it with theirs.
        let borderRows = metrics.rowsBordering(rows)
        let borderColumns = metrics.columnsBordering(columns)
        let reach = CellRange(
            start: CellAddress(row: borderRows.lowerBound, column: borderColumns.lowerBound),
            end: CellAddress(row: borderRows.upperBound - 1, column: borderColumns.upperBound - 1)
        )
        let nearby = sheet.mergedRanges.map(\.normalized).filter { $0.intersects(reach) }
        let merges = nearby.filter { $0.intersects(window) }
        var covered = Set<CellAddress>()
        for merge in nearby {
            for row in max(merge.start.row, borderRows.lowerBound)...min(merge.end.row, borderRows.upperBound - 1) {
                for column in max(merge.start.column, borderColumns.lowerBound)...min(merge.end.column, borderColumns.upperBound - 1) {
                    covered.insert(CellAddress(row: row, column: column))
                }
            }
        }

        // The cells with something to show, and how far each one's text runs.
        var painted: [(address: CellAddress, cell: Cell, overflow: CGRect?)] = []
        var openEdges = Set<CellAddress>()
        for row in rows where !sheet.hiddenRows.contains(row) {
            for column in columns where !sheet.hiddenColumns.contains(column) {
                let address = CellAddress(row: row, column: column)
                guard !covered.contains(address), let cell = sheet.cells[address], !cell.isEmptyEntirely else { continue }
                painted.append((address, cell, overflow(of: address, edges: &openEdges)))
            }
            painted += spills(into: row, columns: columns, edges: &openEdges)
        }

        if drawsGridlines {
            context.setStrokeColor(gridLineColor.cgColor)
            context.setLineWidth(1)
            for row in rows where !sheet.hiddenRows.contains(row) {
                for column in columns where !sheet.hiddenColumns.contains(column) {
                    let address = CellAddress(row: row, column: column)
                    guard !covered.contains(address) else { continue }
                    strokeHairlines(of: metrics.frame(for: address), openEdge: openEdges.contains(address), in: context)
                }
            }
        }
        // In passes, so text running over a neighbour lands on top of that
        // neighbour's fill, and borders on top of the text.
        let own = painted.filter { columns.contains($0.address.column) }
        for entry in own {
            fill(entry.cell, in: metrics.frame(for: entry.address), context: context, gridLineColor: gridLineColor,
                 openEdge: openEdges.contains(entry.address))
        }
        for entry in painted {
            drawText(of: entry.cell, in: metrics.frame(for: entry.address), overflow: entry.overflow, context: context)
        }
        // After the cells, so a merge covers the hairlines of those beneath it.
        for merge in merges {
            let frame = metrics.frame(for: merge)
            let cell = sheet[merge.start]
            context.saveGState()
            paper.setFill()
            context.fill(frame)
            if let fill = cell.style.fillColor(for: scheme) {
                context.setFillColor(NSColor(fill).cgColor)
                context.fill(frame)
            }
            // The merge's own trailing and bottom gridlines, filled or not,
            // since the background above covered the ones beneath it.
            if drawsGridlines {
                context.setStrokeColor(gridLineColor.cgColor)
                context.setLineWidth(1)
                strokeHairlines(of: frame, openEdge: false, in: context)
            }
            context.restoreGState()
            drawText(of: cell, in: frame, overflow: nil, context: context)
        }
        // Last, so no fill covers the half of a border that falls in the
        // neighbouring cell. The cells around `rect` draw only as far as it:
        // the rest of their borders is drawn with them.
        context.saveGState()
        context.clip(to: rect)
        for row in borderRows where !sheet.hiddenRows.contains(row) {
            for column in borderColumns where !sheet.hiddenColumns.contains(column) {
                let address = CellAddress(row: row, column: column)
                guard !covered.contains(address), let cell = sheet.cells[address] else { continue }
                drawBorders(cell.style, in: metrics.frame(for: address), context: context)
            }
        }
        for merge in nearby {
            drawBorders(sheet[merge.start].style, in: metrics.frame(for: merge), context: context)
        }
        context.restoreGState()
        drawCommentMarks(rows: rows, columns: columns, context: context)
    }

    // MARK: - Overflow

    /// How far a cell's text spills, noting the cell edges it runs across
    /// so their gridlines can make way for it.
    private func overflow(of address: CellAddress, edges: inout Set<CellAddress>) -> CGRect? {
        guard let span = sheet.overflowSpan(of: address) else { return nil }
        for column in span.lowerBound..<span.upperBound {
            edges.insert(CellAddress(row: address.row, column: column))
        }
        return metrics.frame(for: CellRange(
            start: CellAddress(row: address.row, column: span.lowerBound),
            end: CellAddress(row: address.row, column: span.upperBound)
        ))
    }

    /// Text that starts in a cell outside `columns` and runs into them. Only
    /// the nearest filled cell on either side can: anything further away is
    /// stopped by it.
    private func spills(
        into row: Int, columns: Range<Int>, edges: inout Set<CellAddress>
    ) -> [(address: CellAddress, cell: Cell, overflow: CGRect?)] {
        let reach = 24
        let before = stride(from: columns.lowerBound - 1, through: max(0, columns.lowerBound - reach), by: -1)
        let after = stride(from: columns.upperBound, to: min(sheet.columnCount, columns.upperBound + reach), by: 1)
        var found: [(address: CellAddress, cell: Cell, overflow: CGRect?)] = []
        for candidates in [Array(before), Array(after)] {
            for column in candidates {
                let address = CellAddress(row: row, column: column)
                guard let cell = sheet.cells[address], !cell.isBlank else { continue }
                if let span = sheet.overflowSpan(of: address, reach: reach),
                   span.overlaps(columns.lowerBound...(columns.upperBound - 1)) {
                    found.append((address, cell, overflow(of: address, edges: &edges)))
                }
                break
            }
        }
        return found
    }

    // MARK: - Fills and lines

    /// The trailing and bottom separators of one cell, held a half-width
    /// inside it.
    private func strokeHairlines(of rect: CGRect, openEdge: Bool, in context: CGContext) {
        let inset = 0.5
        context.beginPath()
        if openEdge {
            context.move(to: CGPoint(x: rect.maxX, y: rect.maxY - inset))
        } else {
            context.move(to: CGPoint(x: rect.maxX - inset, y: rect.minY))
            context.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.maxY - inset))
        }
        context.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - inset))
        context.strokePath()
    }

    private func fill(_ cell: Cell, in frame: CGRect, context: CGContext, gridLineColor: NSColor, openEdge: Bool) {
        guard frame.width > 0, frame.height > 0, let fill = cell.style.fillColor(for: scheme) else { return }
        context.setFillColor(NSColor(fill).cgColor)
        context.fill(frame)
        if drawsGridlines {
            context.setStrokeColor(gridLineColor.cgColor)
            context.setLineWidth(1)
            strokeHairlines(of: frame, openEdge: openEdge, in: context)
        }
    }

    // MARK: - Text

    /// The font a cell's text is drawn in, at the grid's zoom.
    static func font(for style: CellStyle, zoom: Double) -> NSFont {
        let size = style.fontSize * zoom
        var traits: NSFontDescriptor.SymbolicTraits = []
        if style.isBold { traits.insert(.bold) }
        if style.isItalic { traits.insert(.italic) }
        let base = NSFont.systemFont(ofSize: size)
        guard !traits.isEmpty else { return base }
        return NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(traits), size: size) ?? base
    }

    /// `overflow` is the stretch of the row the text may run across. The
    /// text is still aligned to its own cell, but measured and clipped
    /// against the larger stretch.
    /// A Numbers checkbox: an empty box, or a filled one with a tick.
    private func drawCheckbox(_ isOn: Bool, in box: CGRect, color: NSColor) {
        guard box.width > 0 else { return }
        let zoom = metrics.zoom
        let shape = NSBezierPath(roundedRect: box, xRadius: 2.5 * zoom, yRadius: 2.5 * zoom)
        guard isOn else {
            color.withAlphaComponent(0.6).setStroke()
            shape.lineWidth = max(1, zoom)
            shape.stroke()
            return
        }
        NSColor.controlAccentColor.setFill()
        shape.fill()
        let tick = NSBezierPath()
        let points = CellStyle.checkmark(in: box)
        tick.move(to: points[0])
        points.dropFirst().forEach { tick.line(to: $0) }
        tick.lineWidth = max(1.5, 1.8 * zoom)
        tick.lineCapStyle = .round
        tick.lineJoinStyle = .round
        NSColor.white.setStroke()
        tick.stroke()
    }

    private func drawText(of cell: Cell, in frame: CGRect, overflow: CGRect?, context: CGContext) {
        let style = cell.style
        if style.showsCheckbox, case .boolean(let isOn) = cell.value {
            let color = style.textColor(for: scheme).map { NSColor($0) } ?? .labelColor
            return drawCheckbox(isOn, in: style.checkboxFrame(in: frame, zoom: metrics.zoom), color: color)
        }
        var string = CellFormatter.displayText(for: cell)
        guard !string.isEmpty, frame.width > 0, frame.height > 0 else { return }
        if style.isTextStacked { string = string.map(String.init).joined(separator: "\n") }
        let zoom = metrics.zoom

        let horizontal = style.horizontalAlignment == .automatic
            ? CellFormatter.naturalAlignment(for: cell.value)
            : style.horizontalAlignment
        // An error takes the cell's own text colour when it has one, like
        // Excel; red is only the default.
        let color: NSColor = style.textColor(for: scheme).map { NSColor($0) }
            ?? (cell.value.errorValue != nil ? .systemRed : .labelColor)

        var attributes: [NSAttributedString.Key: Any] = [
            .font: Self.font(for: style, zoom: zoom), .foregroundColor: color,
        ]
        if style.isUnderlined { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if style.isStruckThrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }

        // The same padding the in-cell editor has, so opening it does not
        // shift the text.
        var box = frame.insetBy(dx: 6 * zoom, dy: 2 * zoom)
        let indent = style.indentPoints * zoom
        if indent > 0 {
            if horizontal != .trailing { box.origin.x += indent }
            box.size.width -= indent
        }
        guard box.width > 0, box.height > 0 else { return }

        // Excel never wraps a number or cuts one short: one too wide for its
        // cell shows as a row of #s.
        let isNumber: Bool
        if case .number = cell.value { isNumber = true } else { isNumber = false }
        let wraps = (style.wrapsText && !isNumber) || style.isTextStacked
        var room = box.width
        if let overflow, !wraps {
            let reach = overflow.insetBy(dx: 6 * zoom, dy: 0)
            switch horizontal {
            case .trailing: room = box.maxX - reach.minX
            case .center: room = 2 * min(box.midX - reach.minX, reach.maxX - box.midX)
            default: room = reach.maxX - box.minX
            }
            room = max(room, box.width)
        }

        var text = NSAttributedString(string: string, attributes: attributes)
        var measured = text.boundingRect(
            with: CGSize(width: wraps ? box.width : Self.unbounded, height: Self.unbounded),
            options: [.usesLineFragmentOrigin]
        ).size
        // A number a hair too wide may take some of the cell's padding before
        // it gives way to #s.
        if isNumber, !wraps, measured.width > room, measured.width <= frame.width - 2 * zoom {
            let spare = (frame.width - 2 * zoom - box.width) / 2
            box = box.insetBy(dx: -spare, dy: 0)
            room = box.width
        }
        if !wraps, measured.width > room {
            let shortened = isNumber ? hashes(filling: room, attributes: attributes)
                : elided(string, to: room, attributes: attributes)
            text = NSAttributedString(string: shortened, attributes: attributes)
            measured = text.size()
        }

        // Wrapped text is laid out across the whole box, its paragraph style
        // doing the horizontal alignment, so the box itself must not move.
        let size = CGSize(width: wraps ? box.width : min(measured.width, room), height: measured.height)
        // Turned text is aligned by the box it covers once turned, so a
        // vertical label sits on the cell's bottom rather than hanging out of it.
        let angle = style.rotationDegrees * .pi / 180
        let extent = CGSize(
            width: abs(size.width * cos(angle)) + abs(size.height * sin(angle)),
            height: abs(size.width * sin(angle)) + abs(size.height * cos(angle))
        )
        let midX: Double
        switch horizontal {
        case .trailing: midX = box.maxX - extent.width / 2
        case .center: midX = box.midX
        default: midX = box.minX + extent.width / 2
        }
        let midY: Double
        switch style.verticalAlignment {
        case .top: midY = box.minY + extent.height / 2
        case .middle: midY = box.midY
        case .bottom: midY = box.maxY - extent.height / 2
        }
        let target = CGRect(
            x: midX - size.width / 2, y: midY - size.height / 2, width: size.width, height: size.height
        )

        context.saveGState()
        context.clip(to: overflow.map { $0.union(frame) } ?? frame)
        if style.rotationDegrees != 0 {
            context.translateBy(x: target.midX, y: target.midY)
            context.rotate(by: -style.rotationDegrees * .pi / 180)
            context.translateBy(x: -target.midX, y: -target.midY)
        }
        if wraps {
            let paragraph = NSMutableParagraphStyle()
            switch horizontal {
            case .trailing: paragraph.alignment = .right
            case .center: paragraph.alignment = .center
            default: paragraph.alignment = .left
            }
            let wrapped = NSMutableAttributedString(attributedString: text)
            wrapped.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: wrapped.length))
            wrapped.draw(with: target, options: [.usesLineFragmentOrigin])
        } else {
            text.draw(at: target.origin)
        }
        context.restoreGState()
    }

    /// Stands in for an unconstrained axis when measuring.
    private static let unbounded: Double = 100_000

    /// The longest prefix that fits in `width`, with an ellipsis.
    private func elided(_ string: String, to width: Double, attributes: [NSAttributedString.Key: Any]) -> String {
        let characters = Array(string)
        var low = 0
        var high = characters.count - 1
        var best = "…"
        while low <= high {
            let middle = (low + high) / 2
            let candidate = String(characters[0..<middle]) + "…"
            if NSAttributedString(string: candidate, attributes: attributes).size().width <= width {
                best = candidate
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return best
    }

    /// As many #s as fit in `width`, which is what Excel shows for a number
    /// its cell is too narrow for.
    private func hashes(filling width: Double, attributes: [NSAttributedString.Key: Any]) -> String {
        let one = NSAttributedString(string: "#", attributes: attributes).size().width
        guard one > 0 else { return "" }
        return String(repeating: "#", count: max(Int(width / one), 1))
    }

    // MARK: - Borders

    private func drawBorders(_ style: CellStyle, in frame: CGRect, context: CGContext) {
        guard !style.borderSides.isEmpty || style.diagonalBorder != nil else { return }
        let zoom = metrics.zoom
        for edge in BorderEdge.allCases {
            guard let side = style.borderSides[edge] else { continue }
            stroke(side.lineStyle, colorHex: side.colorHex, context: context) { offset in
                let (start, end) = metrics.borderSegment(
                    edge, of: frame, lineWidth: side.lineStyle.lineWidth * zoom, offset: offset, shown: shownArea
                )
                return [start, end]
            }
        }
        if let diagonal = style.diagonalBorder, diagonal.isVisible {
            stroke(diagonal.lineStyle, colorHex: diagonal.colorHex, context: context) { offset in
                var points: [CGPoint] = []
                if diagonal.goesDown {
                    points += [CGPoint(x: frame.minX, y: frame.minY + offset), CGPoint(x: frame.maxX, y: frame.maxY + offset)]
                }
                if diagonal.goesUp {
                    points += [CGPoint(x: frame.minX, y: frame.maxY + offset), CGPoint(x: frame.maxX, y: frame.minY + offset)]
                }
                return points
            }
        }
    }

    /// Strokes a line style along `segments`, drawing a double rule as two
    /// offset passes.
    private func stroke(
        _ lineStyle: BorderLineStyle, colorHex: String?, context: CGContext, segments: (Double) -> [CGPoint]
    ) {
        let zoom = metrics.zoom
        let color = AdaptiveColor.resolve(hex: colorHex, for: scheme, isText: true).map { NSColor($0) }
            ?? Self.automaticBorderColor
        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(lineStyle.lineWidth * zoom)
        context.setLineDash(phase: 0, lengths: lineStyle.dashPattern.map { CGFloat($0 * zoom) })
        let offsets: [Double] = lineStyle.doubleLineGap.map { [-$0 * zoom / 2, $0 * zoom / 2] } ?? [0]
        for offset in offsets {
            context.strokeLineSegments(between: segments(offset))
        }
        context.restoreGState()
    }

    /// Excel's automatic border colour: black on paper, and the label colour
    /// on screen so it follows dark mode.
    private static var automaticBorderColor: NSColor {
        NSGraphicsContext.current?.isDrawingToScreen == false ? .black : .labelColor
    }

    // MARK: - Comments

    /// Notes are marked red and conversations purple, as Excel marks them;
    /// a resolved conversation fades to grey.
    private func drawCommentMarks(rows: Range<Int>, columns: Range<Int>, context: CGContext) {
        for (address, comment) in sheet.comments
        where rows.contains(address.row) && columns.contains(address.column)
            && !sheet.hiddenRows.contains(address.row) && !sheet.hiddenColumns.contains(address.column) {
            let merge = sheet.mergedRange(containing: address)?.normalized
            if let merge, merge.start != address { continue }
            let frame = merge.map { metrics.frame(for: $0) } ?? metrics.frame(for: address)
            let size = min(8 * metrics.zoom, frame.width / 2, frame.height / 2)
            guard size > 0 else { continue }
            let color: NSColor
            switch (comment.kind, comment.isResolved) {
            case (.note, _): color = NSColor(red: 0.86, green: 0.15, blue: 0.15, alpha: 1)
            case (.thread, false): color = NSColor(red: 0.44, green: 0.19, blue: 0.63, alpha: 1)
            case (.thread, true): color = .systemGray
            }
            context.setFillColor(color.cgColor)
            context.beginPath()
            context.move(to: CGPoint(x: frame.maxX - size, y: frame.minY))
            context.addLine(to: CGPoint(x: frame.maxX, y: frame.minY))
            context.addLine(to: CGPoint(x: frame.maxX, y: frame.minY + size))
            context.closePath()
            context.fillPath()
        }
    }
}
