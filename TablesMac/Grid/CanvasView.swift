import AppKit
import TablesEngine

/// Sheets laid out together on one page, each a table where the canvas
/// puts it, as a Numbers sheet holds its tables.
///
/// The table being worked on is the grid itself, carried to its place on
/// the page; the others are drawn around it, read-only, until one is
/// clicked. A table's name above it is where it is picked up to be moved.
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
    /// The table whose name is being dragged: where the drag started, and
    /// how far it has come.
    private var drag: (id: Worksheet.ID, start: CGPoint, offset: CGSize)?
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
    }

    /// Where the active table sits on the page.
    var activeFrame: CGRect? { placed.first { $0.sheet.id == activeID }?.frame }

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
        }
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

    override func mouseDown(with event: NSEvent) {
        guard let document else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let table = tableName(at: point) {
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
        guard var drag, let document else { return }
        let point = convert(event.locationInWindow, from: nil)
        drag.offset = CGSize(width: point.x - drag.start.x, height: point.y - drag.start.y)
        self.drag = drag
        if let canvas = document.workbook.canvas(containing: drag.id) {
            refresh(canvas, visible: enclosingScrollView?.contentSize ?? bounds.size)
        }
        autoscroll(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard let drag, let document else { return }
        self.drag = nil
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
        let movable = document?.state.allowsLayingOutTables == true && tableName(at: point) != nil
        (movable ? NSCursor.openHand : NSCursor.arrow).set()
    }
}
