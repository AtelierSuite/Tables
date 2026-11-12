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
    /// The sheet's merges and comments, found without walking them.
    let lookup: SheetLookup
    var drawsGridlines = true
    /// The part of the sheet on show, when that stops short of all of it, as
    /// a printout or preview of the cells in use does. Borders on its edges
    /// are kept inside it.
    var shownArea: CGRect?

    /// `lookup` is one built from this version of `sheet`, kept from an
    /// earlier draw by a `SheetLookupCache`. Without one, it is built here,
    /// which is fine for a one-off but not for every draw of a scroll.
    init(
        sheet: Worksheet, metrics: SheetMetrics, appearance: NSAppearance, lookup: SheetLookup? = nil,
        drawsGridlines: Bool = true
    ) {
        self.sheet = sheet
        self.metrics = metrics
        let lookup = lookup ?? SheetLookup(sheet)
        self.lookup = lookup
        let viewer: ColorScheme = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
        scheme = lookup.colorScheme(for: viewer)
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
        let nearby = lookup.merges.ranges(intersecting: reach)
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
                guard !covered.contains(address) else { continue }
                let cell = sheet.displayedCell(at: address)
                guard !cell.isEmptyEntirely else { continue }
                painted.append((address, cell, overflow(of: address, edges: &openEdges)))
            }
            painted += spills(into: row, columns: columns, edges: &openEdges)
        }

        if drawsGridlines {
            context.setStrokeColor(gridLineColor.cgColor)
            context.setLineWidth(metrics.gridLineWidth)
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
            let cell = sheet.displayedCell(at: merge.start)
            context.saveGState()
            paper.setFill()
            context.fill(frame)
            paintFill(of: cell.style, in: frame, context: context)
            // The merge's own trailing and bottom gridlines, filled or not,
            // since the background above covered the ones beneath it.
            if drawsGridlines {
                context.setStrokeColor(gridLineColor.cgColor)
                context.setLineWidth(metrics.gridLineWidth)
                strokeHairlines(of: frame, openEdge: false, in: context)
            }
            context.restoreGState()
            drawText(of: cell, in: frame, overflow: nil, context: context)
        }
        // Last, so no fill covers the half of a border that falls in the
        // neighbouring cell. The cells around `rect` draw only as far as it:
        // the rest of their borders is drawn with them.
        // An edge two cells share is drawn once, by the one whose border wins.
        context.saveGState()
        context.clip(to: rect)
        let resolver = BorderResolver(sheet: sheet, metrics: metrics, near: reach)
        for row in borderRows where !sheet.hiddenRows.contains(row) {
            for column in borderColumns where !sheet.hiddenColumns.contains(column) {
                let address = CellAddress(row: row, column: column)
                guard !covered.contains(address), sheet.cells[address] != nil else { continue }
                drawBorders(of: CellRange(address), resolver: resolver, context: context)
            }
        }
        for merge in nearby {
            drawBorders(of: merge, resolver: resolver, context: context)
        }
        context.restoreGState()
        drawCommentMarks(rows: rows, columns: columns, context: context)
    }

    // MARK: - Overflow

    /// How far a cell's text may spill, noting the cell edges it actually
    /// runs across so their gridlines can make way for it.
    private func overflow(of address: CellAddress, edges: inout Set<CellAddress>) -> CGRect? {
        guard let span = sheet.overflowSpan(of: address, lookup: lookup) else { return nil }
        let cell = sheet.displayedCell(at: address)
        let style = cell.style
        let zoom = metrics.zoom
        let width = NSAttributedString(
            string: CellFormatter.displayText(for: cell),
            attributes: [.font: Self.font(for: style, zoom: zoom)]
        ).size().width
        if let reach = Worksheet.overflowReach(
            of: address.column, within: span, textWidth: width,
            alignment: CellFormatter.alignment(for: cell), padding: 6 * zoom, indent: style.indentPoints * zoom,
            columnWidth: { metrics.frame(for: CellAddress(row: address.row, column: $0)).width }
        ) {
            for column in reach.lowerBound..<reach.upperBound {
                edges.insert(CellAddress(row: address.row, column: column))
            }
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
                let cell = sheet.displayedCell(at: address)
                guard !cell.isBlank else { continue }
                if let span = sheet.overflowSpan(of: address, reach: reach, lookup: lookup),
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
        context.beginPath()
        for (start, end) in metrics.gridLines(of: rect, openEdge: openEdge) {
            context.move(to: start)
            context.addLine(to: end)
        }
        context.strokePath()
    }

    private func fill(_ cell: Cell, in frame: CGRect, context: CGContext, gridLineColor: NSColor, openEdge: Bool) {
        guard frame.width > 0, frame.height > 0, cell.style.hasFill else { return }
        paintFill(of: cell.style, in: frame, context: context)
        if drawsGridlines {
            context.setStrokeColor(gridLineColor.cgColor)
            context.setLineWidth(metrics.gridLineWidth)
            strokeHairlines(of: frame, openEdge: openEdge, in: context)
        }
    }

    /// A cell's fill: its colour, then any pattern over it, or its gradient.
    private func paintFill(of style: CellStyle, in frame: CGRect, context: CGContext) {
        guard frame.width > 0, frame.height > 0 else { return }
        if let gradient = style.fillGradient(for: scheme) {
            paintGradient(gradient, in: frame, context: context)
            return
        }
        if let fill = style.fillColor(for: scheme) {
            context.setFillColor(NSColor(fill).cgColor)
            context.fill(frame)
        }
        if let pattern = style.fillPattern, let ink = style.fillPatternColor(for: scheme) {
            paintPattern(pattern.type, ink: NSColor(ink).cgColor, in: frame, context: context)
        }
    }

    /// Tiles the pattern across the frame from the sheet's origin, so the
    /// cells of a patterned range join up. The context is in points on
    /// screen at any zoom, so a bit stays a point however far in it goes.
    private func paintPattern(_ type: FillPatternType, ink: CGColor, in frame: CGRect, context: CGContext) {
        // Sheet coordinates run down the screen however the view or layer
        // gets them to, so a bitmap always lands upside down: the tile is
        // laid out to suit. The backing scale makes a bit whole device pixels.
        let scale = max(1, Int(hypot(context.ctm.c, context.ctm.d).rounded()))
        guard let image = Self.patternTile(type, ink: ink, scale: scale, flipped: true) else { return }
        let side = FillPattern.bitSize * Double(FillPattern.tileBits)
        context.saveGState()
        context.clip(to: frame)
        context.interpolationQuality = .none
        var y = (frame.minY / side).rounded(.down) * side
        while y < frame.maxY {
            var x = (frame.minX / side).rounded(.down) * side
            while x < frame.maxX {
                context.draw(image, in: CGRect(x: x, y: y, width: side, height: side))
                x += side
            }
            y += side
        }
        context.restoreGState()
    }

    private struct PatternTileKey: Hashable {
        var type: FillPatternType
        var ink: String
        var scale: Int
        var flipped: Bool
    }

    private static var patternTiles: [PatternTileKey: CGImage] = [:]

    private static func patternTile(_ type: FillPatternType, ink: CGColor, scale: Int, flipped: Bool) -> CGImage? {
        let key = PatternTileKey(
            type: type, ink: (ink.components ?? []).map { String(format: "%.3f", $0) }.joined(separator: ","),
            scale: scale, flipped: flipped
        )
        if let cached = patternTiles[key] { return cached }
        let image = type.tileImage(ink: ink, scale: scale, flipped: flipped)
        if patternTiles.count > 256 { patternTiles.removeAll() }
        patternTiles[key] = image
        return image
    }

    private func paintGradient(_ gradient: FillGradient, in frame: CGRect, context: CGContext) {
        context.saveGState()
        context.clip(to: frame)
        if case .path = gradient.kind {
            // A ring a point apart on screen is too close to see a step in.
            for band in gradient.pathBands(in: frame, step: 1) {
                context.setFillColor(Self.cgColor(band.colorHex))
                context.fill(band.rect)
            }
        } else {
            let colors = gradient.stops.map { Self.cgColor($0.colorHex ?? FillGradient.automaticColorHex) }
            let locations = gradient.stops.map { CGFloat($0.position) }
            if let space = CGColorSpace(name: CGColorSpace.sRGB),
               let shading = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations) {
                let ends = gradient.linearEndpoints(in: frame)
                context.drawLinearGradient(
                    shading, start: ends.start, end: ends.end,
                    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
                )
            }
        }
        context.restoreGState()
    }

    private static func cgColor(_ hex: String) -> CGColor {
        Color(argbHex: hex).map { NSColor($0).cgColor } ?? NSColor.white.cgColor
    }

    // MARK: - Text

    /// The font a cell's text is drawn in, at the grid's zoom: its own family
    /// when it has one and it is installed, otherwise the system font.
    static func font(for style: CellStyle, zoom: Double) -> NSFont {
        style.platformFont(zoom: zoom)
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
        // The characters a format's `_x` reserves are laid out but not drawn.
        var string = CellFormatter.layoutText(for: cell)
        guard !string.isEmpty, frame.width > 0, frame.height > 0 else { return }
        if style.isTextStacked {
            string = TextFitting.stacked(CellFormatter.displayText(for: cell))
        }
        let zoom = metrics.zoom

        let horizontal = CellFormatter.alignment(for: cell)
        // An error takes the cell's own text colour when it has one, like
        // Excel; red is only the default.
        let color: NSColor = cell.textColor(for: scheme).map { NSColor($0) }
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

        var text = Self.attributed(string, attributes: attributes)
        var measured = text.boundingRect(
            with: CGSize(width: wraps ? box.width : Self.unbounded, height: Self.unbounded),
            options: [.usesLineFragmentOrigin]
        ).size
        // Turned text runs along its turned box rather than across the cell.
        let turned = style.rotationDegrees != 0
        if turned, !wraps {
            room = TextFitting.runLength(of: style, in: box.size, lineHeight: measured.height)
        }
        // A number a hair too wide may take some of the cell's padding before
        // it gives way to #s.
        if isNumber, !wraps, !turned, measured.width > room, measured.width <= frame.width - 2 * zoom {
            let spare = (frame.width - 2 * zoom - box.width) / 2
            box = box.insetBy(dx: -spare, dy: 0)
            room = box.width
        }
        if isNumber, !wraps, measured.width > room {
            // A General number is rounded to fit before it gives way to #s.
            let fitted = CellFormatter.fittedGeneralText(for: cell) { candidate in
                NSAttributedString(string: candidate, attributes: attributes).size().width <= room
            }
            text = Self.attributed(fitted ?? hashes(filling: room, attributes: attributes), attributes: attributes)
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

        // A format's fill spreads the text across the cell: an accounting
        // format's symbol at the left edge, the amount at the right.
        if !wraps, style.rotationDegrees == 0, measured.width <= box.width,
           let parts = CellFormatter.filledText(for: cell, reservingWidth: true) {
            let leading = Self.attributed(parts.leading, attributes: attributes)
            let trailing = Self.attributed(parts.trailing, attributes: attributes)
            let trailingWidth = trailing.size().width
            context.saveGState()
            context.clip(to: frame)
            leading.draw(at: CGPoint(x: box.minX, y: target.minY))
            trailing.draw(at: CGPoint(x: box.maxX - trailingWidth, y: target.minY))
            context.restoreGState()
            return
        }

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
            // Text longer than its room runs on and is clipped at the edge.
            text.draw(at: TextFitting.clippedLine(target, length: measured.width, alignment: horizontal).origin)
        }
        context.restoreGState()
    }

    /// Stands in for an unconstrained axis when measuring.
    private static let unbounded: Double = 100_000

    /// `string` from `CellFormatter.layoutText` set in `attributes`, with
    /// the characters its format reserves the width of left clear.
    private static func attributed(_ string: String, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        guard string.contains(CellFormatter.reserveMark) else {
            return NSAttributedString(string: string, attributes: attributes)
        }
        let result = NSMutableAttributedString()
        for part in CellFormatter.reservedRuns(in: string) {
            var partAttributes = attributes
            if part.isReserved { partAttributes[.foregroundColor] = NSColor.clear }
            result.append(NSAttributedString(string: part.text, attributes: partAttributes))
        }
        return result
    }

    /// As many #s as fit in `width`, which is what Excel shows for a number
    /// its cell is too narrow for.
    private func hashes(filling width: Double, attributes: [NSAttributedString.Key: Any]) -> String {
        let one = NSAttributedString(string: "#", attributes: attributes).size().width
        guard one > 0 else { return "" }
        return String(repeating: "#", count: max(Int(width / one), 1))
    }

    // MARK: - Borders

    /// The borders of a cell or merge: the stretches of its edges its border
    /// wins against the neighbour's, and its diagonal.
    private func drawBorders(of region: CellRange, resolver: BorderResolver, context: CGContext) {
        for border in resolver.drawnBorders(of: region) {
            let side = border.side
            let frame = metrics.frame(for: border.range)
            stroke(side.lineStyle, colorHex: side.colorHex, context: context) { offset in
                let (start, end) = metrics.borderSegment(
                    border.edge, of: frame, lineWidth: metrics.lineWidth(of: side.lineStyle), offset: offset, shown: shownArea
                )
                return [start, end]
            }
        }
        if let diagonal = sheet.cells[region.start]?.style.diagonalBorder, diagonal.isVisible {
            let frame = metrics.frame(for: region)
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
        context.setLineWidth(metrics.lineWidth(of: lineStyle))
        context.setLineDash(phase: 0, lengths: lineStyle.dashPattern.map { CGFloat($0 * zoom) })
        for offset in metrics.passOffsets(of: lineStyle) {
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
        for (_, comment, range) in sheet.commentMarks(rows: rows, columns: columns, lookup: lookup) {
            let frame = metrics.frame(for: range)
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
