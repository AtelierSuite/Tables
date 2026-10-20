import SwiftUI
import TablesEngine

/// One cell as the canvas needs it: where it goes and what it holds.
struct PaintedCell: Equatable, Sendable {
    var address: CellAddress
    var frame: CGRect
    var cell: Cell
    /// Where the text may run past the cell, across empty neighbours.
    var overflow: CGRect?
    /// A cell outside the tile whose text runs into it: only its text is
    /// drawn here, its own tile draws the rest.
    var textOnly = false

    init(address: CellAddress, frame: CGRect, cell: Cell) {
        self.address = address
        self.frame = frame
        self.cell = cell
    }
}

/// A merged region, drawn from its top-left cell across the whole range.
struct PaintedMerge: Equatable, Sendable {
    var range: CellRange
    var frame: CGRect
    var cell: Cell
    /// Set on the one tile holding the region's top-left corner. A merge wider
    /// than a tile is drawn by every tile it crosses, but it is still one cell,
    /// so only one of them reports it to accessibility.
    var ownsElement: Bool
}

/// Everything a tile draws, gathered by the grid before the tile is built.
///
/// Only cells with something to show are listed: a sheet is mostly empty, and
/// the blank ones need nothing but their hairlines, which the tile can derive
/// from its own line ranges.
struct TileContents: Equatable, Sendable {
    var cells: [PaintedCell] = []
    var merges: [PaintedMerge] = []
    var covered: Set<CellAddress> = []
    /// Cells whose trailing edge spilled text runs across, which draw no
    /// gridline there — Excel's text reads as one run, not as boxes.
    var overflowEdges: Set<CellAddress> = []
    /// The corner markers of commented cells.
    var comments: [CommentMark] = []
}

/// The small triangle in the top-right corner of a commented cell.
struct CommentMark: Equatable, Sendable {
    var address: CellAddress
    var frame: CGRect
    var kind: CellComment.Kind
    var isResolved: Bool
}

/// A rectangular block of the grid, drawn as a single `Canvas`.
///
/// A screenful is several hundred cells, and a view apiece — each with its own
/// text layout, clip layer, tap gesture and context-menu interaction — is a
/// hundredfold rebuild on every scroll frame. Drawing them costs one display
/// list, and `Equatable` means scrolling past a tile whose cells have not
/// changed costs nothing at all.
///
/// That reuse is why tiles are cut on fixed line boundaries rather than from the
/// viewport: a tile keeps its identity and its contents as the sheet scrolls
/// under it, so there is something for SwiftUI to skip.
struct GridTileView: View, Equatable {
    let rows: Range<Int>
    let columns: Range<Int>
    /// The tile's top-left corner in content coordinates.
    let origin: CGPoint
    let size: CGSize
    let hiddenRows: Set<Int>
    let hiddenColumns: Set<Int>
    let contents: TileContents
    let metrics: SheetMetrics
    let scheme: ColorScheme

    nonisolated static func == (lhs: GridTileView, rhs: GridTileView) -> Bool {
        lhs.rows == rhs.rows && lhs.columns == rhs.columns
            && lhs.origin == rhs.origin && lhs.size == rhs.size
            && lhs.scheme == rhs.scheme
            && lhs.hiddenRows == rhs.hiddenRows && lhs.hiddenColumns == rhs.hiddenColumns
            && lhs.metrics == rhs.metrics
            && lhs.contents == rhs.contents
    }

    var body: some View {
        // Worked out once and shared by the drawing and the accessibility pass,
        // both of which have to leave out the cells a merge draws over.
        let covered = contents.covered

        return ZStack(alignment: .topLeading) {
            Canvas(rendersAsynchronously: false) { context, _ in
                CellPainter.paint(
                    contents: contents,
                    rows: rows, columns: columns,
                    hiddenRows: hiddenRows, hiddenColumns: hiddenColumns,
                    covered: covered,
                    metrics: metrics, origin: origin, scheme: scheme,
                    into: &context
                )
            }
            .frame(width: size.width, height: size.height)

            accessibilityCells(covered: covered)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .offset(x: origin.x, y: origin.y)
    }

    // MARK: - Accessibility

    /// The cells as VoiceOver sees them.
    ///
    /// A canvas is one opaque element, so a real view per cell still has to
    /// carry the reference and the value. These are invisible and hold no
    /// gestures — a tap on one falls through to the grid's own — and they are
    /// rebuilt only when the tile around them is.
    private func accessibilityCells(covered: Set<CellAddress>) -> some View {
        let painted = Dictionary(
            contents.cells.map { ($0.address, $0.cell) }, uniquingKeysWith: { first, _ in first }
        )
        let commented = Set(contents.comments.map(\.address))

        return ZStack(alignment: .topLeading) {
            ForEach(rows, id: \.self) { row in
                if !hiddenRows.contains(row) {
                    ForEach(columns, id: \.self) { column in
                        let address = CellAddress(row: row, column: column)
                        if !hiddenColumns.contains(column), !covered.contains(address) {
                            element(
                                in: metrics.frame(for: address),
                                at: address,
                                cell: painted[address] ?? Cell(),
                                hasComment: commented.contains(address)
                            )
                        }
                    }
                }
            }
            ForEach(contents.merges.filter(\.ownsElement), id: \.range) { merge in
                element(in: merge.frame, at: merge.range.start, cell: merge.cell,
                        hasComment: commented.contains(merge.range.start))
            }
        }
    }

    private func element(in frame: CGRect, at address: CellAddress, cell: Cell, hasComment: Bool) -> some View {
        Color.clear
            .frame(width: frame.width, height: frame.height)
            .offset(x: frame.minX - origin.x, y: frame.minY - origin.y)
            // One leaf element per cell, so VoiceOver reads "B4, 2180.5" as a
            // unit instead of losing the cell inside the scroll view's contents.
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("cell.\(address.a1)")
            .accessibilityLabel(hasComment
                ? String(format: Self.commentedLabelFormat, Self.description(of: cell, at: address))
                : Self.description(of: cell, at: address))
            .accessibilityAddTraits(.isButton)
            .accessibilityRespondsToUserInteraction(true)
    }

    /// The two cell labels, looked up once rather than per cell: a bundle
    /// lookup apiece is a few hundred of them for a string that never changes.
    private static let emptyCellLabelFormat = String(localized: "Grid.Cell.Accessibility.Empty")
    private static let cellLabelFormat = String(localized: "Grid.Cell.Accessibility.Value")
    private static let commentedLabelFormat = String(localized: "Grid.Cell.Accessibility.Commented")

    /// "B4, 2180.5" — the reference followed by whatever the cell shows.
    private static func description(of cell: Cell, at address: CellAddress) -> String {
        let text = CellFormatter.displayText(for: cell)
        guard !text.isEmpty else {
            return String(format: emptyCellLabelFormat, address.a1)
        }
        return String(format: cellLabelFormat, address.a1, text)
    }
}

/// Draws cells into a `GraphicsContext`.
///
/// Everything here works in content coordinates and takes only value types, so
/// it stays out of the main actor and out of the view graph entirely.
enum CellPainter {
    static func paint(
        contents: TileContents,
        rows: Range<Int>, columns: Range<Int>,
        hiddenRows: Set<Int>, hiddenColumns: Set<Int>,
        covered: Set<CellAddress>,
        metrics: SheetMetrics, origin: CGPoint, scheme: ColorScheme,
        into context: inout GraphicsContext
    ) {
        context.translateBy(x: -origin.x, y: -origin.y)

        let painted = Set(contents.cells.map(\.address))
        let edges = contents.overflowEdges
        paintBlankHairlines(
            rows: rows, columns: columns,
            hiddenRows: hiddenRows, hiddenColumns: hiddenColumns,
            skipping: covered.union(painted), openEdges: edges, metrics: metrics, into: &context
        )
        // In passes, so text spilling over a neighbour lands on top of that
        // neighbour's fill, and borders on top of the text.
        let own = contents.cells.filter { !$0.textOnly }
        for cell in own {
            paintBackground(cell.cell, in: cell.frame, openEdge: edges.contains(cell.address), into: &context, scheme: scheme)
        }
        for cell in contents.cells {
            paintText(cell.cell, in: cell.frame, overflow: cell.overflow, zoom: metrics.zoom, scheme: scheme, into: &context)
        }
        for cell in own {
            paintBorders(cell.cell.style, in: cell.frame, zoom: metrics.zoom, scheme: scheme, into: &context)
        }
        // Last, so a merge covers the hairlines of the cells beneath it.
        for merge in contents.merges {
            paint(merge.cell, in: merge.frame, zoom: metrics.zoom, scheme: scheme, into: &context)
        }
        for mark in contents.comments {
            paintCommentMark(mark, zoom: metrics.zoom, into: &context)
        }
    }

    /// Notes are marked red and conversations purple, as Excel marks them;
    /// a resolved conversation fades to grey.
    private static func paintCommentMark(_ mark: CommentMark, zoom: Double, into context: inout GraphicsContext) {
        let size = min(10 * zoom, mark.frame.width / 2, mark.frame.height / 2)
        guard size > 0 else { return }
        var triangle = Path()
        triangle.move(to: CGPoint(x: mark.frame.maxX - size, y: mark.frame.minY))
        triangle.addLine(to: CGPoint(x: mark.frame.maxX, y: mark.frame.minY))
        triangle.addLine(to: CGPoint(x: mark.frame.maxX, y: mark.frame.minY + size))
        triangle.closeSubpath()
        let color: Color
        switch (mark.kind, mark.isResolved) {
        case (.note, _): color = Color(red: 0.86, green: 0.15, blue: 0.15)
        case (.thread, false): color = Color(red: 0.44, green: 0.19, blue: 0.63)
        case (.thread, true): color = .gray
        }
        context.fill(triangle, with: .color(color))
    }

    /// The separators of every cell with nothing else to draw, as one stroke.
    ///
    /// Most of a sheet is blank, and a path per empty cell is the bulk of the
    /// work in a tile if each is stroked on its own.
    private static func paintBlankHairlines(
        rows: Range<Int>, columns: Range<Int>,
        hiddenRows: Set<Int>, hiddenColumns: Set<Int>,
        skipping: Set<CellAddress>,
        openEdges: Set<CellAddress>,
        metrics: SheetMetrics,
        into context: inout GraphicsContext
    ) {
        var path = Path()
        for row in rows where !hiddenRows.contains(row) {
            for column in columns where !hiddenColumns.contains(column) {
                let address = CellAddress(row: row, column: column)
                guard !skipping.contains(address) else { continue }
                addHairlines(of: metrics.frame(for: address), openEdge: openEdges.contains(address), to: &path)
            }
        }
        guard !path.isEmpty else { return }
        context.stroke(path, with: .color(.gridLine), lineWidth: hairlineWidth)
    }

    private static let hairlineWidth: Double = 1

    /// The trailing and bottom separators of one cell.
    ///
    /// Both sit a half-width inside the cell rather than straddling its edge, so
    /// that a line on a tile boundary is drawn whole by the tile that owns it
    /// instead of half by each of two.
    private static func addHairlines(of rect: CGRect, openEdge: Bool = false, to path: inout Path) {
        let inset = hairlineWidth / 2
        if openEdge {
            path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - inset))
        } else {
            path.move(to: CGPoint(x: rect.maxX - inset, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.maxY - inset))
        }
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - inset))
    }

    /// A whole cell in one go, for merges, which nothing spills across.
    private static func paint(
        _ cell: Cell, in frame: CGRect, zoom: Double, scheme: ColorScheme,
        into context: inout GraphicsContext
    ) {
        guard frame.width > 0, frame.height > 0 else { return }
        paintBackground(cell, in: frame, openEdge: false, into: &context, scheme: scheme)
        paintText(cell, in: frame, overflow: nil, zoom: zoom, scheme: scheme, into: &context)
        paintBorders(cell.style, in: frame, zoom: zoom, scheme: scheme, into: &context)
    }

    private static func paintBackground(
        _ cell: Cell, in frame: CGRect, openEdge: Bool, into context: inout GraphicsContext, scheme: ColorScheme
    ) {
        guard frame.width > 0, frame.height > 0 else { return }
        if let fill = cell.style.fillColor(for: scheme) {
            context.fill(Path(frame), with: .color(fill))
        }
        var hairlines = Path()
        addHairlines(of: frame, openEdge: openEdge, to: &hairlines)
        context.stroke(hairlines, with: .color(.gridLine), lineWidth: hairlineWidth)
    }

    // MARK: - Text

    /// `overflow` is the stretch of the row the text may run across. The
    /// text is still aligned to its own cell — Excel's centred title stays
    /// centred on its cell however far it spills — but it is measured, cut
    /// short and clipped against the larger stretch.
    private static func paintText(
        _ cell: Cell, in frame: CGRect, overflow: CGRect?, zoom: Double, scheme: ColorScheme,
        into context: inout GraphicsContext
    ) {
        let style = cell.style
        var string = CellFormatter.displayText(for: cell)
        guard !string.isEmpty else { return }
        // Stacked text is drawn as one glyph per line rather than by rotating
        // the run, which is what Excel's `textRotation="255"` looks like.
        if style.isTextStacked { string = string.map(String.init).joined(separator: "\n") }

        let horizontal = style.horizontalAlignment == .automatic
            ? CellFormatter.naturalAlignment(for: cell.value)
            : style.horizontalAlignment
        let color: Color = cell.value.errorValue != nil
            ? .red
            : (style.textColor(for: scheme) ?? .primary)

        let make: (String) -> Text = { text in
            var run = Text(verbatim: text)
                .font(style.font(zoom: zoom))
                .foregroundStyle(color)
            if style.isUnderlined { run = run.underline() }
            if style.isStruckThrough { run = run.strikethrough() }
            return run
        }

        // The box the glyphs get. The in-cell editor pads to match, so opening
        // it does not shift the text the cell was already showing.
        var box = frame.insetBy(dx: 6 * zoom, dy: 2 * zoom)
        // Indent pads the edge the text is aligned to, matching Excel.
        let indent = style.indentPoints * zoom
        if indent > 0 {
            if horizontal != .trailing { box.origin.x += indent }
            box.size.width -= indent
        }
        guard box.width > 0, box.height > 0 else { return }

        // Excel never wraps a number or cuts one short: one too wide for its
        // cell shows as a row of #s, so a figure is never misread.
        let isNumber: Bool
        if case .number = cell.value { isNumber = true } else { isNumber = false }
        let wraps = (style.wrapsText && !isNumber) || style.isTextStacked
        // The width the text has, out to the far edge of its overflow.
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
        var resolved = context.resolve(make(string))
        var measured = resolved.measure(in: CGSize(
            width: wraps ? box.width : unbounded, height: unbounded
        ))
        if !wraps, measured.width > room {
            let shortened = isNumber
                ? hashes(filling: room, make: make, in: context)
                : elided(string, to: room, make: make, in: context)
            resolved = context.resolve(make(shortened))
            measured = resolved.measure(in: CGSize(width: unbounded, height: unbounded))
        }

        let width = min(measured.width, room)
        let x: Double
        switch horizontal {
        case .trailing: x = box.maxX - width
        case .center: x = box.midX - width / 2
        default: x = box.minX
        }
        let y: Double
        switch style.verticalAlignment {
        case .top: y = box.minY
        case .middle: y = box.midY - measured.height / 2
        case .bottom: y = box.maxY - measured.height
        }
        let target = CGRect(x: x, y: y, width: width, height: measured.height)

        context.drawLayer { layer in
            // A font taller than the row, a rotated run, or wrapped text with
            // more lines than fit all draw outside the cell otherwise — over the
            // neighbours, which reads as corrupt rather than as clipped.
            layer.clip(to: Path(overflow.map { $0.union(frame) } ?? frame))
            if style.rotationDegrees != 0 {
                // Rotation turns the glyphs, not the box they are aligned in,
                // which is how Excel places a rotated run: the box is laid out
                // upright and spun about its own centre afterwards.
                layer.translateBy(x: target.midX, y: target.midY)
                layer.rotate(by: .degrees(-style.rotationDegrees))
                layer.translateBy(x: -target.midX, y: -target.midY)
            }
            layer.draw(resolved, in: target)
        }
    }

    /// Stands in for an unconstrained axis when measuring. A finite number
    /// rather than `.infinity`, which text layout will happily multiply.
    private static let unbounded: Double = 100_000

    /// The longest prefix that fits in `width`, with an ellipsis.
    ///
    /// Text laid out by hand does not truncate itself, and a run simply clipped
    /// at the cell edge reads as a shorter value rather than as a longer one cut
    /// off. Binary search keeps this to a handful of measurements, and only for
    /// the cells that actually overflow.
    private static func elided(
        _ string: String, to width: Double, make: (String) -> Text, in context: GraphicsContext
    ) -> String {
        let characters = Array(string)
        var low = 0
        var high = characters.count - 1
        var best = "…"
        while low <= high {
            let middle = (low + high) / 2
            let candidate = String(characters[0..<middle]) + "…"
            let size = context.resolve(make(candidate))
                .measure(in: CGSize(width: unbounded, height: unbounded))
            if size.width <= width {
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
    private static func hashes(filling width: Double, make: (String) -> Text, in context: GraphicsContext) -> String {
        let one = context.resolve(make("#")).measure(in: CGSize(width: unbounded, height: unbounded)).width
        guard one > 0 else { return "" }
        return String(repeating: "#", count: max(Int(width / one), 1))
    }

    // MARK: - Borders

    private static func paintBorders(
        _ style: CellStyle, in frame: CGRect, zoom: Double, scheme: ColorScheme,
        into context: inout GraphicsContext
    ) {
        guard !style.borderSides.isEmpty || style.diagonalBorder != nil else { return }

        // Each edge gets its own stroke because line width, dash pattern and
        // colour all vary per edge in OOXML.
        for edge in BorderEdge.allCases {
            guard let side = style.borderSides[edge] else { continue }
            stroke(side.lineStyle, colorHex: side.colorHex, zoom: zoom, scheme: scheme, into: &context) {
                edgePath(edge, in: frame, width: side.lineStyle.lineWidth * zoom, offset: $0)
            }
        }
        if let diagonal = style.diagonalBorder, diagonal.isVisible {
            stroke(diagonal.lineStyle, colorHex: diagonal.colorHex, zoom: zoom, scheme: scheme, into: &context) {
                diagonalPath(diagonal, in: frame, offset: $0)
            }
        }
    }

    /// Strokes a line style, drawing a double rule as two offset passes.
    private static func stroke(
        _ lineStyle: BorderLineStyle, colorHex: String?, zoom: Double, scheme: ColorScheme,
        into context: inout GraphicsContext, path: (Double) -> Path
    ) {
        let paint = AdaptiveColor.resolve(hex: colorHex, for: scheme, isText: true) ?? .secondary
        let style = StrokeStyle(
            lineWidth: lineStyle.lineWidth * zoom,
            dash: lineStyle.dashPattern.map { CGFloat($0 * zoom) }
        )
        let offsets: [Double] = lineStyle.doubleLineGap.map { [-$0 * zoom / 2, $0 * zoom / 2] } ?? [0]
        for offset in offsets {
            context.stroke(path(offset), with: .color(paint), style: style)
        }
    }

    /// One edge of the cell rectangle.
    ///
    /// The stroke is held a half-width inside the rectangle so that it lands
    /// entirely within the cell — and so within one tile — and `offset` nudges a
    /// double rule's two passes further in from there.
    private static func edgePath(
        _ edge: BorderEdge, in rect: CGRect, width: Double, offset: Double
    ) -> Path {
        let inward = width / 2 + offset + abs(offset)
        let outward = -width / 2 + offset - abs(offset)
        return Path { path in
            switch edge {
            case .top:
                path.move(to: CGPoint(x: rect.minX, y: rect.minY + inward))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + inward))
            case .bottom:
                path.move(to: CGPoint(x: rect.minX, y: rect.maxY + outward))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY + outward))
            case .leading:
                path.move(to: CGPoint(x: rect.minX + inward, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.minX + inward, y: rect.maxY))
            case .trailing:
                path.move(to: CGPoint(x: rect.maxX + outward, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.maxX + outward, y: rect.maxY))
            }
        }
    }

    private static func diagonalPath(_ diagonal: DiagonalBorder, in rect: CGRect, offset: Double) -> Path {
        Path { path in
            if diagonal.goesDown {
                path.move(to: CGPoint(x: rect.minX, y: rect.minY + offset))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY + offset))
            }
            if diagonal.goesUp {
                path.move(to: CGPoint(x: rect.minX, y: rect.maxY + offset))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + offset))
            }
        }
    }
}
