import AppKit
import TablesEngine

/// Sheets laid out together on one page, each a table where the canvas
/// puts it, as a Numbers sheet holds its tables.
///
/// The table being worked on is the grid itself, carried to its place on
/// the page; the others are drawn around it, read-only, until one is
/// clicked. A table is picked up to be moved by its name, by the round
/// grip outside its top-left corner, or by the edge just outside its
/// cells: all of them on the page, never on a cell, so clicking and
/// dragging cells is left to the grid. It snaps into line with the tables
/// around it as it comes close, with guides to show it.
@MainActor
final class CanvasView: NSView {
    weak var document: WorkbookDocument?
    weak var grid: GridView?
    /// Builds the menu for a right-click on a table's name.
    var tableMenu: ((Worksheet.ID) -> NSMenu?)?

    private struct Placed {
        var sheet: Worksheet
        var metrics: SheetMetrics
        var frame: CGRect
        var name: String?
    }

    /// The tables as last laid out, in the canvas's order.
    private var placed: [Placed] = []
    /// The table being dragged: where the drag started, and how far it has
    /// come once kept on the page and snapped into line.
    private var drag: (id: Worksheet.ID, start: CGPoint, offset: CGSize)?
    /// The lines showing what the dragged table is lined up with, drawn
    /// over everything, the grid included.
    private let guideView = CanvasGuideView()
    private var activeID: Worksheet.ID?
    private var pointerArea: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    private var zoom: Double { document?.state.zoom ?? 1 }
    private var nameHeight: CGFloat { SheetCanvas.nameHeight * zoom }

    // MARK: - Layout

    /// Lays the canvas out afresh, the grid carried to the active table's
    /// place, and keeps the page at least as large as `visible`.
    func refresh(_ canvas: SheetCanvas, visible: CGSize) {
        guard let document, let grid else { return }
        let zoom = self.zoom
        let active = document.activeSheet.id
        activeID = active
        placed = document.workbook.sheets(on: canvas).compactMap { sheet in
            guard let table = canvas.table(for: sheet.id) else { return nil }
            let metrics = sheet.id == active ? document.state.metrics : SheetMetrics(sheet: sheet, zoom: zoom)
            var frame = CGRect(x: table.x * zoom, y: table.y * zoom, width: metrics.totalWidth, height: metrics.totalHeight)
            if let drag, drag.id == sheet.id { frame = frame.offsetBy(dx: drag.offset.width, dy: drag.offset.height) }
            return Placed(sheet: sheet, metrics: metrics, frame: frame,
                          name: table.showsName ? document.workbook.tableName(of: sheet.id) : nil)
        }
        fit(visible: visible)
        if grid.superview !== self { addSubview(grid) }
        if guideView.superview !== self || subviews.last !== guideView {
            addSubview(guideView, positioned: .above, relativeTo: nil)
        }
        if let frame = placed.first(where: { $0.sheet.id == active })?.frame, grid.frame.origin != frame.origin {
            grid.setFrameOrigin(frame.origin)
        }
        needsDisplay = true
    }

    /// Grows the page to hold every table with room to spare, and to fill
    /// the window.
    func fit(visible: CGSize) {
        let margin = SheetCanvas.margin * zoom
        let right = placed.map(\.frame.maxX).max() ?? 0
        let bottom = placed.map(\.frame.maxY).max() ?? 0
        let size = NSSize(width: max(visible.width, right + margin), height: max(visible.height, bottom + margin * 2))
        if frame.size != size { setFrameSize(size) }
        guideView.frame = bounds
    }

    /// Where the active table sits on the page.
    var activeFrame: CGRect? { placed.first { $0.sheet.id == activeID }?.frame }

    /// The round grip outside the active table's top-left corner.
    private func gripRect(of table: Placed) -> CGRect {
        CGRect(x: table.frame.minX - 24, y: table.frame.minY - 24, width: 20, height: 20)
    }

    private var showsGrip: Bool { document?.state.allowsLayingOutTables == true }

    private func nameRect(of table: Placed) -> CGRect {
        CGRect(x: table.frame.minX, y: table.frame.minY - nameHeight, width: max(table.frame.width, 120), height: nameHeight)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        let lines = CellRenderer.gridLineColor(for: effectiveAppearance)
        for table in placed {
            if table.sheet.id != activeID, table.frame.intersects(dirtyRect) {
                context.saveGState()
                context.translateBy(x: table.frame.minX, y: table.frame.minY)
                let area = dirtyRect.offsetBy(dx: -table.frame.minX, dy: -table.frame.minY)
                    .intersection(CGRect(origin: .zero, size: table.frame.size))
                context.clip(to: area)
                CellRenderer(sheet: table.sheet, metrics: table.metrics, appearance: effectiveAppearance)
                    .draw(in: area, context: context, gridLineColor: lines)
                context.restoreGState()
            }
            // An edge round every table, so one without gridlines still reads as one.
            NSColor.separatorColor.setStroke()
            NSBezierPath(rect: table.frame.insetBy(dx: -0.5, dy: -0.5)).stroke()
            if let name = table.name {
                drawName(name, in: nameRect(of: table), isActive: table.sheet.id == activeID)
            }
            if table.sheet.id == activeID, showsGrip { drawGrip(in: gripRect(of: table)) }
        }
    }

    /// The grip: the move arrows on a disc of the accent colour, as a
    /// handle for carrying something about reads anywhere on the Mac.
    private func drawGrip(in rect: CGRect) {
        NSColor.controlAccentColor.setFill()
        NSBezierPath(ovalIn: rect).fill()
        let configuration = NSImage.SymbolConfiguration(pointSize: 10, weight: .bold)
            .applying(.init(paletteColors: [.white]))
        guard let arrows = NSImage(systemSymbolName: "arrow.up.and.down.and.arrow.left.and.right",
                                   accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return }
        let size = arrows.size
        arrows.draw(in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                               width: size.width, height: size.height),
                    from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    private func drawName(_ name: String, in rect: CGRect, isActive: Bool) {
        let font = NSFont.systemFont(ofSize: max(9, 14 * zoom), weight: .semibold)
        let text = NSAttributedString(string: name, attributes: [
            .font: font, .foregroundColor: isActive ? NSColor.labelColor : NSColor.secondaryLabelColor,
        ])
        let size = text.size()
        text.draw(with: CGRect(x: rect.minX, y: rect.maxY - size.height - 4 * zoom, width: rect.width, height: size.height),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    // MARK: - Events

    private func table(at point: CGPoint) -> Placed? {
        placed.last { $0.frame.contains(point) }
    }

    private func tableName(at point: CGPoint) -> Placed? {
        placed.last { $0.name != nil && nameRect(of: $0).contains(point) }
    }

    /// The table a drag starting here would pick up: by its name, by the
    /// active table's grip, or by the edge just outside its cells.
    private func grabbable(at point: CGPoint) -> Placed? {
        if let table = tableName(at: point) { return table }
        if showsGrip, let active = placed.first(where: { $0.sheet.id == activeID }),
           gripRect(of: active).insetBy(dx: -4, dy: -4).contains(point) { return active }
        return placed.last { $0.frame.insetBy(dx: -5, dy: -5).contains(point) && !$0.frame.contains(point) }
    }

    override func mouseDown(with event: NSEvent) {
        guard let document else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let table = grabbable(at: point) {
            if table.sheet.id != activeID { document.selectSheet(table.sheet.id) }
            if document.state.allowsLayingOutTables {
                drag = (table.sheet.id, point, .zero)
                NSCursor.closedHand.set()
            }
            return
        }
        guard let table = table(at: point) else { return }
        // Another table: it becomes the one worked on, with the cell clicked selected.
        let local = CGPoint(x: point.x - table.frame.minX, y: point.y - table.frame.minY)
        let address = CellAddress(row: table.metrics.row(atY: local.y), column: table.metrics.column(atX: local.x))
        document.selectSheet(table.sheet.id)
        let sheet = document.activeSheet
        document.state.select(sheet.mergedRange(containing: address)?.normalized.start ?? address, in: sheet)
        document.notify()
        if let grid { window?.makeFirstResponder(grid) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard var drag, let document, let canvas = document.workbook.canvas(containing: drag.id),
              let table = canvas.table(for: drag.id), let moving = placed.first(where: { $0.sheet.id == drag.id })
        else { return }
        let point = convert(event.locationInWindow, from: nil)
        // Measured from where the table was, so the page and the tables
        // round it decide where it lands, however far the pointer goes.
        let zoom = self.zoom
        let resting = CGRect(x: table.x * zoom, y: table.y * zoom, width: moving.frame.width, height: moving.frame.height)
        let proposed = resting.offsetBy(dx: point.x - drag.start.x, dy: point.y - drag.start.y)
        let others = placed.filter { $0.sheet.id != drag.id }.map(\.frame)
        let snapped = CanvasSnapping.snap(proposed, among: others, minimum: CanvasSnapping.minimumOrigin(zoom: zoom))
        drag.offset = CGSize(width: snapped.origin.x - resting.minX, height: snapped.origin.y - resting.minY)
        self.drag = drag
        guideView.guides = snapped.guides
        refresh(canvas, visible: enclosingScrollView?.contentSize ?? bounds.size)
        autoscroll(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard let drag, let document else { return }
        self.drag = nil
        guideView.guides = []
        NSCursor.openHand.set()
        guard drag.offset != .zero, let table = document.workbook.canvas(containing: drag.id)?.table(for: drag.id) else {
            return document.notify()
        }
        let zoom = self.zoom
        let state = document.state
        document.edit {
            state.moveTable(drag.id, toX: (table.x + drag.offset.width / zoom).rounded(),
                            y: (table.y + drag.offset.height / zoom).rounded(), in: &$0)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let table = tableName(at: point) ?? table(at: point) else { return nil }
        if table.sheet.id != activeID { document?.selectSheet(table.sheet.id) }
        return tableMenu?(table.sheet.id)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerArea { removeTrackingArea(pointerArea) }
        let area = NSTrackingArea(rect: .zero, options: [.cursorUpdate, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        pointerArea = area
    }

    override func cursorUpdate(with event: NSEvent) { updatePointer(for: event) }
    override func mouseMoved(with event: NSEvent) { updatePointer(for: event) }

    private func updatePointer(for event: NSEvent) {
        guard drag == nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        // The grid sets its own.
        if let grid, grid.frame.contains(point) { return }
        let movable = document?.state.allowsLayingOutTables == true && grabbable(at: point) != nil
        (movable ? NSCursor.openHand : NSCursor.arrow).set()
    }
}

/// The guides a dragged table shows while it is lined up with another:
/// over everything on the canvas, and never in the way of a click.
@MainActor
private final class CanvasGuideView: NSView {
    var guides: [CanvasSnapping.Guide] = [] {
        didSet { if guides != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard !guides.isEmpty else { return }
        NSColor.systemYellow.setFill()
        for guide in guides {
            let line = guide.axis == .vertical
                ? CGRect(x: guide.position - 0.5, y: guide.start, width: 1, height: guide.end - guide.start)
                : CGRect(x: guide.start, y: guide.position - 0.5, width: guide.end - guide.start, height: 1)
            line.fill()
        }
    }
}
