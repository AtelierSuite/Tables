import AppKit
import TablesEngine

/// Sheets laid out together on one page, each a table where the canvas
/// puts it, as a Numbers sheet holds its tables.
///
/// The table being worked on is the grid itself, carried to its place on
/// the page; the others are drawn around it, read-only, until one is
/// clicked. The table worked on has column letters and row numbers round
/// it, which fade in as it is picked, into room every table keeps for them
/// so nothing moves. A table is picked up to be moved by the corner where
/// its headers meet, or by the edge just outside its cells: both on the
/// page, never on a cell, so clicking and dragging cells is left to the
/// grid. It snaps into line with the tables around it as it comes close,
/// with guides to show it. A click on a table's name edits it in place.
@MainActor
final class CanvasView: NSView {
    weak var document: WorkbookDocument?
    weak var grid: GridView?
    /// Builds the menu for a right-click on a table's name.
    var tableMenu: ((Worksheet.ID) -> NSMenu?)?
    /// Builds the menu for a right-click on a column's or row's header.
    var lineMenu: ((_ isColumn: Bool) -> NSMenu?)?

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
    /// Whether the drag began on the corner of the headers, which selects
    /// the whole table when it is let go without moving.
    private var isDraggingFromCorner = false
    /// The active table's headers.
    private var headerView: CanvasHeaderView?
    /// The lines showing what the dragged table is lined up with, drawn
    /// over everything, the grid included.
    private let guideView = CanvasGuideView()
    private var activeID: Worksheet.ID?
    private var pointerArea: NSTrackingArea?
    /// The field a table's name is edited in, over where it is drawn.
    private var nameField: NSTextField?
    private var editingNameID: Worksheet.ID?

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
        showHeaders(for: active)
        placeNameField()
        needsDisplay = true
    }

    /// Puts the headers round the active table, fading the last table's
    /// out and the new one's in when another is picked.
    private func showHeaders(for active: Worksheet.ID) {
        guard let frame = activeFrame else { return }
        if let headerView, headerView.sheetID == active {
            headerView.place(around: frame)
            return
        }
        if let old = headerView {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = CanvasChrome.fadeDuration
                old.animator().alphaValue = 0
            }, completionHandler: { old.removeFromSuperview() })
        }
        let headers = CanvasHeaderView(sheetID: active)
        headers.document = document
        headers.lineMenu = { [weak self] isColumn in self?.lineMenu?(isColumn) }
        headers.alphaValue = 0
        addSubview(headers, positioned: .below, relativeTo: guideView)
        headers.place(around: frame)
        headerView = headers
        NSAnimationContext.runAnimationGroup { context in
            context.duration = CanvasChrome.fadeDuration
            headers.animator().alphaValue = 1
        }
    }

    /// Lets what a dragged table passes over show through its headers, and
    /// brings them back once it is let go.
    private func fadeHeaders(to opacity: CGFloat) {
        guard let headerView, headerView.alphaValue != opacity else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = CanvasChrome.fadeDuration
            headerView.animator().alphaValue = opacity
        }
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

    /// The corner where the active table's headers meet: its handle.
    private func cornerRect(of table: Placed) -> CGRect {
        let width = CanvasChrome.rowHeaderWidth(rowCount: table.sheet.rowCount)
        let height = CanvasChrome.columnHeaderHeight
        return CGRect(x: table.frame.minX - width, y: table.frame.minY - height, width: width, height: height)
    }

    /// A table's name, above the room kept for its column letters.
    private func nameRect(of table: Placed) -> CGRect {
        CGRect(x: table.frame.minX, y: table.frame.minY - CanvasChrome.nameReach(zoom: zoom),
               width: max(table.frame.width, 120), height: nameHeight)
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
            if let name = table.name, table.sheet.id != editingNameID {
                drawName(name, in: nameRect(of: table), isActive: table.sheet.id == activeID)
            }
        }
    }

    private var nameFont: NSFont { NSFont.systemFont(ofSize: max(9, 14 * zoom), weight: .semibold) }

    private func drawName(_ name: String, in rect: CGRect, isActive: Bool) {
        let font = nameFont
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

    /// Whether a point is on the corner of the active table's headers.
    private func isOnCorner(_ point: CGPoint) -> Bool {
        placed.first { $0.sheet.id == activeID }.map { cornerRect(of: $0).contains(point) } ?? false
    }

    /// The table a drag starting here would pick up: by the corner of the
    /// active table's headers, or by the edge just outside its cells.
    private func grabbable(at point: CGPoint) -> Placed? {
        if isOnCorner(point) { return placed.first { $0.sheet.id == activeID } }
        if tableName(at: point) != nil { return nil }
        return placed.last { $0.frame.insetBy(dx: -5, dy: -5).contains(point) && !$0.frame.contains(point) }
    }

    override func mouseDown(with event: NSEvent) {
        guard let document else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let table = tableName(at: point) {
            if table.sheet.id != activeID { document.selectSheet(table.sheet.id) }
            if document.state.allowsLayingOutTables { beginEditingName(of: table.sheet.id) }
            return
        }
        if let table = grabbable(at: point) {
            isDraggingFromCorner = isOnCorner(point)
            if table.sheet.id != activeID { document.selectSheet(table.sheet.id) }
            if document.state.allowsLayingOutTables {
                drag = (table.sheet.id, point, .zero)
                NSCursor.closedHand.set()
            } else if isDraggingFromCorner {
                selectWholeTable(in: document)
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
        let snapped = CanvasSnapping.snap(
            proposed, among: others, minimum: CanvasSnapping.minimumOrigin(zoom: zoom, rowCount: moving.sheet.rowCount))
        drag.offset = CGSize(width: snapped.origin.x - resting.minX, height: snapped.origin.y - resting.minY)
        self.drag = drag
        if drag.offset != .zero { fadeHeaders(to: CanvasChrome.draggingOpacity) }
        guideView.guides = snapped.guides
        refresh(canvas, visible: enclosingScrollView?.contentSize ?? bounds.size)
        autoscroll(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard let drag, let document else { return }
        self.drag = nil
        guideView.guides = []
        fadeHeaders(to: 1)
        NSCursor.openHand.set()
        guard drag.offset != .zero, let table = document.workbook.canvas(containing: drag.id)?.table(for: drag.id) else {
            // A click on the corner, rather than a drag, selects the table.
            if isDraggingFromCorner { return selectWholeTable(in: document) }
            return document.notify()
        }
        let zoom = self.zoom
        let state = document.state
        document.edit {
            state.moveTable(drag.id, toX: (table.x + drag.offset.width / zoom).rounded(),
                            y: (table.y + drag.offset.height / zoom).rounded(), in: &$0)
        }
    }

    private func selectWholeTable(in document: WorkbookDocument) {
        document.state.selectAll(in: document.activeSheet)
        document.notify()
        if let grid { window?.makeFirstResponder(grid) }
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
        let editable = document?.state.allowsLayingOutTables == true
        if editable, tableName(at: point) != nil { return NSCursor.iBeam.set() }
        (editable && grabbable(at: point) != nil ? NSCursor.openHand : NSCursor.arrow).set()
    }

    // MARK: - Naming

    /// Puts a field over a table's name to type a new one in, as a sheet's
    /// tab is renamed; the table must show its name.
    func beginEditingName(of id: Worksheet.ID) {
        guard let document, document.state.allowsLayingOutTables,
              placed.contains(where: { $0.sheet.id == id && $0.name != nil }) else { return }
        endEditingName(commit: true)
        let field = NSTextField(string: document.workbook.tableName(of: id))
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.focusRingType = .exterior
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = self
        editingNameID = id
        nameField = field
        addSubview(field, positioned: .below, relativeTo: guideView)
        placeNameField()
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        needsDisplay = true
    }

    /// Keeps the field over the name as the canvas is laid out afresh, and
    /// lets it go if its table has gone or no longer shows its name.
    private func placeNameField() {
        guard let field = nameField, let id = editingNameID else { return }
        guard let table = placed.first(where: { $0.sheet.id == id && $0.name != nil }) else {
            return endEditingName(commit: false)
        }
        field.font = nameFont
        let height = ceil(field.intrinsicContentSize.height)
        let rect = nameRect(of: table)
        let frame = CGRect(x: rect.minX - 2, y: rect.maxY - height - 3 * zoom, width: rect.width + 2, height: height)
        if field.frame != frame { field.frame = frame }
    }

    /// Puts the name typed in place, or leaves the old one.
    private func endEditingName(commit: Bool) {
        guard let field = nameField, let id = editingNameID else { return }
        nameField = nil
        editingNameID = nil
        let name = field.stringValue
        let hadFocus = field.currentEditor() != nil
        field.removeFromSuperview()
        needsDisplay = true
        if hadFocus, let grid { window?.makeFirstResponder(grid) }
        guard commit, let document, name != document.workbook.tableName(of: id) else { return }
        let state = document.state
        document.edit { state.renameTable(id, to: name, in: &$0) }
    }
}

extension CanvasView: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ notification: Notification) {
        endEditingName(commit: true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(cancelOperation(_:)) else { return false }
        endEditingName(commit: false)
        return true
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
