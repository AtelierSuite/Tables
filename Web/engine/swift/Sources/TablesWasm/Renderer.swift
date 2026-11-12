import Foundation
import TablesEngine

/// Decides what a part of a sheet looks like, as the Mac's `CellRenderer` does,
/// and hands the page an ordered list of drawing operations for a canvas. The
/// only thing left to the page is measuring text, since the browser owns the
/// fonts: eliding text that doesn't fit, and showing #s for a number too wide.
///
/// Works in sheet coordinates at 100%; the page scales for zoom. Given the
/// device pixels a sheet point comes to at that zoom, edges and lines are
/// snapped to them, as on the Mac.
struct Renderer {
    let sheet: Worksheet
    let metrics: SheetMetrics
    /// The appearance colours are adapted for, corrected for a sheet whose author made it dark.
    let scheme: ColorScheme

    init(sheet: Worksheet, viewer: ColorScheme, pixelScale: Double? = nil) {
        self.sheet = sheet
        metrics = SheetMetrics(sheet: sheet, pixelScale: pixelScale)
        scheme = sheet.colorScheme(for: viewer)
    }

    private var operations: [[String: Any]] = []

    /// The colour cells without a fill of their own show through to, or nil for the page's paper.
    var paper: String? {
        sheet.backgroundColorHex == nil ? nil
            : AdaptiveColor.resolve(hex: sheet.backgroundColorHex, for: scheme, isText: false)?.argbHex
    }

    mutating func render(_ rect: CGRect) -> [[String: Any]] {
        operations = []
        let rows = metrics.rows(in: Double(rect.minY)...Double(max(rect.minY, rect.maxY)), overscan: 0)
        let columns = metrics.columns(in: Double(rect.minX)...Double(max(rect.minX, rect.maxX)), overscan: 0)
        guard !rows.isEmpty, !columns.isEmpty else { return [] }

        let window = CellRange(
            start: CellAddress(row: rows.lowerBound, column: columns.lowerBound),
            end: CellAddress(row: rows.upperBound - 1, column: columns.upperBound - 1)
        )
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

        var painted: [(address: CellAddress, cell: Cell, overflow: CGRect?)] = []
        var openEdges = Set<CellAddress>()
        for row in rows where !sheet.hiddenRows.contains(row) {
            for column in columns where !sheet.hiddenColumns.contains(column) {
                let address = CellAddress(row: row, column: column)
                guard !covered.contains(address) else { continue }
                let cell = sheet.displayedCell(at: address)
                guard !cell.isEmptyEntirely else { continue }
                painted.append((address, cell, overflow(of: address, edges: &openEdges)))
            }
            painted += spills(into: row, columns: columns, edges: &openEdges)
        }

        // Gridlines, as one batch: each cell's trailing and bottom hairline.
        var hairlines: [Double] = []
        for row in rows where !sheet.hiddenRows.contains(row) {
            for column in columns where !sheet.hiddenColumns.contains(column) {
                let address = CellAddress(row: row, column: column)
                guard !covered.contains(address) else { continue }
                appendHairlines(of: metrics.frame(for: address), openEdge: openEdges.contains(address), to: &hairlines)
            }
        }
        if !hairlines.isEmpty { operations.append(["k": "grid", "p": hairlines, "w": metrics.gridLineWidth]) }

        let own = painted.filter { columns.contains($0.address.column) }
        for entry in own {
            fill(entry.cell, in: metrics.frame(for: entry.address), openEdge: openEdges.contains(entry.address))
        }
        for entry in painted {
            text(of: entry.cell, in: metrics.frame(for: entry.address), overflow: entry.overflow)
        }
        for merge in merges {
            let frame = metrics.frame(for: merge)
            let cell = sheet.displayedCell(at: merge.start)
            operations.append(["k": "paper", "r": frameArray(frame)])
            paintFill(of: cell.style, in: frame)
            var lines: [Double] = []
            appendHairlines(of: frame, openEdge: false, to: &lines)
            operations.append(["k": "grid", "p": lines, "w": metrics.gridLineWidth])
            text(of: cell, in: frame, overflow: nil)
        }

        // An edge two cells share is drawn once, by the one whose border wins.
        let shown = CGRect(x: metrics.snapped(rect.minX), y: metrics.snapped(rect.minY),
                           width: metrics.snapped(rect.maxX) - metrics.snapped(rect.minX),
                           height: metrics.snapped(rect.maxY) - metrics.snapped(rect.minY))
        operations.append(["k": "clip", "r": frameArray(shown)])
        let resolver = BorderResolver(sheet: sheet, metrics: metrics, near: reach)
        for row in borderRows where !sheet.hiddenRows.contains(row) {
            for column in borderColumns where !sheet.hiddenColumns.contains(column) {
                let address = CellAddress(row: row, column: column)
                guard !covered.contains(address), sheet.cells[address] != nil else { continue }
                borders(of: CellRange(address), resolver: resolver)
            }
        }
        for merge in nearby {
            borders(of: merge, resolver: resolver)
        }
        operations.append(["k": "unclip"])
        commentMarks(rows: rows, columns: columns)
        return operations
    }

    private func frameArray(_ frame: CGRect) -> [Double] {
        [Double(frame.minX), Double(frame.minY), Double(frame.width), Double(frame.height)]
    }

    // MARK: - Overflow

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
                let cell = sheet.displayedCell(at: address)
                guard !cell.isBlank else { continue }
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

    /// The trailing and bottom separators of one cell, held a half-width inside
    /// it, as line segments (x1, y1, x2, y2). Text running on into the next
    /// cell leaves out the trailing one.
    private func appendHairlines(of frame: CGRect, openEdge: Bool, to points: inout [Double]) {
        for (start, end) in metrics.gridLines(of: frame, openEdge: openEdge) {
            points += [Double(start.x), Double(start.y), Double(end.x), Double(end.y)]
        }
    }

    private mutating func fill(_ cell: Cell, in frame: CGRect, openEdge: Bool) {
        guard frame.width > 0, frame.height > 0, cell.style.hasFill else { return }
        paintFill(of: cell.style, in: frame)
        var lines: [Double] = []
        appendHairlines(of: frame, openEdge: openEdge, to: &lines)
        operations.append(["k": "grid", "p": lines, "w": metrics.gridLineWidth])
    }

    /// A cell's fill: its colour, then any pattern over it, or its gradient.
    ///
    /// A pattern goes to the page as its bits, which it tiles from the sheet's
    /// origin a screen point to a bit whatever the zoom, as the Mac does.
    private mutating func paintFill(of style: CellStyle, in frame: CGRect) {
        guard frame.width > 0, frame.height > 0 else { return }
        if let gradient = style.fillGradient(for: scheme) {
            if case .path = gradient.kind {
                // Half a point apart, so the rings still blend at 200%.
                for band in gradient.pathBands(in: frame, step: 0.5) {
                    operations.append(["k": "fill", "r": frameArray(band.rect), "c": band.colorHex])
                }
            } else {
                let ends = gradient.linearEndpoints(in: frame)
                operations.append([
                    "k": "lgrad", "r": frameArray(frame),
                    "p": [Double(ends.start.x), Double(ends.start.y), Double(ends.end.x), Double(ends.end.y)],
                    "s": gradient.stops.map { [$0.position, $0.colorHex ?? FillGradient.automaticColorHex] as [Any] },
                ])
            }
            return
        }
        if let fill = style.fillColor(for: scheme)?.argbHex {
            operations.append(["k": "fill", "r": frameArray(frame), "c": fill])
        }
        if let pattern = style.fillPattern, let ink = style.fillPatternColor(for: scheme)?.argbHex {
            operations.append([
                "k": "pattern", "r": frameArray(frame), "c": ink,
                "b": pattern.type.rows.map { Int($0) },
            ])
        }
    }

    // MARK: - Text

    private mutating func text(of cell: Cell, in frame: CGRect, overflow: CGRect?) {
        let style = cell.style
        let textColor = cell.textColor(for: scheme)?.argbHex
        if style.showsCheckbox, case .boolean(let isOn) = cell.value {
            let box = style.checkboxFrame(in: frame, zoom: 1)
            guard box.width > 0 else { return }
            var operation: [String: Any] = ["k": "check", "r": frameArray(box), "on": isOn,
                                            "m": CellStyle.checkmark(in: box).flatMap { [Double($0.x), Double($0.y)] }]
            if let textColor { operation["c"] = textColor }
            operations.append(operation)
            return
        }
        var string = CellFormatter.displayText(for: cell)
        guard !string.isEmpty, frame.width > 0, frame.height > 0 else { return }
        if style.isTextStacked {
            string = TextFitting.stacked(string)
        } else {
            // Led by the mark that sets the cell's reading order, if it has one.
            string = CellFormatter.directed(string, for: cell)
        }

        let horizontal = CellFormatter.alignment(for: cell)
        let isNumber: Bool
        if case .number = cell.value { isNumber = true } else { isNumber = false }

        var operation: [String: Any] = [
            "k": "text", "r": frameArray(frame), "t": string, "fs": style.fontSize,
            "h": horizontal == .trailing ? "r" : horizontal == .center ? "c" : "l",
            "v": style.verticalAlignment == .top ? "t" : style.verticalAlignment == .bottom ? "b" : "m",
        ]
        if let family = style.displayFontName { operation["ff"] = family }
        if style.isBold { operation["b"] = true }
        if style.isItalic { operation["i"] = true }
        if style.isUnderlined { operation["u"] = true }
        if style.isStruckThrough { operation["s"] = true }
        if let textColor { operation["c"] = textColor } else if cell.value.errorValue != nil { operation["err"] = true }
        if isNumber { operation["num"] = true }
        if (style.wrapsText && !isNumber) || style.isTextStacked { operation["wrap"] = true }
        if style.isTextStacked { operation["stk"] = true }
        // Read right to left, so the canvas sets it that way and its
        // ellipsis lands on the left.
        if TextFitting.baseDirection(of: string) == .rightToLeft { operation["rtl"] = true }
        if style.rotationDegrees != 0 { operation["rot"] = style.rotationDegrees }
        if style.indentPoints > 0 { operation["ind"] = style.indentPoints }
        if let overflow { operation["ov"] = frameArray(overflow) }
        if let parts = CellFormatter.filledText(for: cell) { operation["parts"] = [parts.leading, parts.trailing] }
        operations.append(operation)
    }

    // MARK: - Borders

    /// The borders of a cell or merge: the stretches of its edges its border
    /// wins against the neighbour's, and its diagonal.
    private mutating func borders(of region: CellRange, resolver: BorderResolver) {
        let metrics = self.metrics
        for border in resolver.drawnBorders(of: region) {
            let frame = metrics.frame(for: border.range)
            stroke(border.side.lineStyle, colorHex: border.side.colorHex) { offset in
                let (start, end) = metrics.borderSegment(
                    border.edge, of: frame, lineWidth: metrics.lineWidth(of: border.side.lineStyle), offset: offset
                )
                return [start, end]
            }
        }
        if let diagonal = sheet.cells[region.start]?.style.diagonalBorder, diagonal.isVisible {
            let frame = metrics.frame(for: region)
            stroke(diagonal.lineStyle, colorHex: diagonal.colorHex) { offset in
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

    /// One line style along `segments`, as pairs of points; a double rule is two offset passes.
    private mutating func stroke(_ lineStyle: BorderLineStyle, colorHex: String?, segments: (Double) -> [CGPoint]) {
        var points: [Double] = []
        for offset in metrics.passOffsets(of: lineStyle) {
            for point in segments(offset) { points += [Double(point.x), Double(point.y)] }
        }
        var operation: [String: Any] = ["k": "line", "p": points, "w": metrics.lineWidth(of: lineStyle)]
        if !lineStyle.dashPattern.isEmpty { operation["d"] = lineStyle.dashPattern }
        if let color = AdaptiveColor.resolve(hex: colorHex, for: scheme, isText: true)?.argbHex { operation["c"] = color }
        operations.append(operation)
    }

    // MARK: - Comments

    /// Notes are marked red and conversations purple, as Excel marks them; a resolved conversation fades to grey.
    private mutating func commentMarks(rows: Range<Int>, columns: Range<Int>) {
        for (address, comment) in sheet.comments
        where rows.contains(address.row) && columns.contains(address.column)
            && !sheet.hiddenRows.contains(address.row) && !sheet.hiddenColumns.contains(address.column) {
            let merge = sheet.mergedRange(containing: address)?.normalized
            if let merge, merge.start != address { continue }
            let frame = merge.map { metrics.frame(for: $0) } ?? metrics.frame(for: address)
            let size = min(8, frame.width / 2, frame.height / 2)
            guard size > 0 else { continue }
            let color: String
            switch (comment.kind, comment.isResolved) {
            case (.note, _): color = "FFDB2626"
            case (.thread, false): color = "FF7030A1"
            case (.thread, true): color = "FF8E8E93"
            }
            operations.append([
                "k": "tri", "c": color,
                "p": [Double(frame.maxX - size), Double(frame.minY), Double(frame.maxX), Double(frame.minY),
                      Double(frame.maxX), Double(frame.minY + size)],
            ])
        }
    }
}
