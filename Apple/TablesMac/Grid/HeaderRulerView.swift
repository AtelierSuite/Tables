import AppKit
import TablesEngine

/// The column letters across the top of the grid, or the row numbers down its
/// side, as the scroll view's rulers — so they scroll with the sheet along
/// their own axis and stay put along the other.
///
/// A click selects the whole line, a drag selects several, and dragging a
/// boundary resizes the line before it. A double-click on a column boundary
/// fits the column to its contents.
@MainActor
final class HeaderRulerView: NSRulerView {
    weak var document: WorkbookDocument?
    /// Builds the menu for a right-click on a line.
    var lineMenu: ((_ isColumn: Bool, _ line: Int) -> NSMenu?)?

    private var isColumns: Bool { orientation == .horizontalRuler }

    private enum Drag {
        case selecting(anchor: Int)
        case resizing(line: Int, start: CGFloat, original: Double)
    }

    private var drag: Drag?
    /// Close enough to a boundary to grab it.
    private static let grabDistance: CGFloat = 4

    init(scrollView: NSScrollView, orientation: NSRulerView.Orientation) {
        super.init(scrollView: scrollView, orientation: orientation)
        reservedThicknessForMarkers = 0
        reservedThicknessForAccessoryView = 0
        ruleThickness = orientation == .horizontalRuler ? 22 : 44
        // Labels for lines scrolled half out of view would otherwise spill
        // over the formula bar.
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var requiredThickness: CGFloat { ruleThickness }

    /// Widens the row numbers to fit the sheet's longest one.
    func refresh() {
        guard let document else { return }
        if !isColumns {
            let digits = String(document.activeSheet.rowCount).count
            let wanted = max(36, CGFloat(digits) * 8 + 16)
            if ruleThickness != wanted { ruleThickness = wanted }
        }
        needsDisplay = true
    }

    // MARK: - Geometry

    private var metrics: SheetMetrics { document?.state.metrics ?? SheetMetrics() }

    /// The lines frozen in view along this ruler's axis, and how far they reach.
    private var frozenCount: Int {
        guard let sheet = document?.activeSheet else { return 0 }
        return isColumns ? sheet.frozenColumns : sheet.frozenRows
    }

    private var frozenLength: Double { frozenCount > 0 ? start(of: frozenCount) : 0 }

    /// Where the grid is scrolled to along this ruler's axis: the first
    /// point of the sheet past the other ruler, which lies over the clip view.
    private var scrolledOrigin: Double {
        guard let scrollView else { return 0 }
        let clip = scrollView.contentView.bounds
        let other = isColumns ? scrollView.verticalRulerView : scrollView.horizontalRulerView
        return Double(isColumns ? clip.minX : clip.minY) + Double(other?.requiredThickness ?? 0)
    }

    /// Converts from the ruler to the grid's coordinates along the ruler's
    /// axis: past the frozen lines the sheet scrolls, over them it stays put.
    private func gridPosition(of point: NSPoint) -> CGFloat {
        guard let client = clientView else { return 0 }
        let converted = client.convert(point, from: self)
        let position = isColumns ? converted.x : converted.y
        let unscrolled = Double(position) - scrolledOrigin
        return frozenLength > 0 && unscrolled < frozenLength ? CGFloat(unscrolled) : position
    }

    /// A span of the sheet along the ruler, in the ruler's coordinates: where
    /// it scrolls to, or for a frozen line, where it stays.
    private func rulerRect(start: Double, length: Double, frozen: Bool = false) -> CGRect {
        guard let client = clientView else { return .zero }
        let start = frozen ? start + scrolledOrigin : start
        let rect = isColumns
            ? CGRect(x: start, y: 0, width: length, height: 1)
            : CGRect(x: 0, y: start, width: 1, height: length)
        let converted = convert(rect, from: client)
        return isColumns
            ? CGRect(x: converted.minX, y: 0, width: converted.width, height: bounds.height)
            : CGRect(x: 0, y: converted.minY, width: bounds.width, height: converted.height)
    }

    private func start(of line: Int) -> Double { isColumns ? metrics.x(ofColumn: line) : metrics.y(ofRow: line) }
    private func length(of line: Int) -> Double { isColumns ? metrics.width(ofColumn: line) : metrics.height(ofRow: line) }
    private func line(at position: CGFloat) -> Int {
        isColumns ? metrics.column(atX: Double(max(0, position))) : metrics.row(atY: Double(max(0, position)))
    }

    private var lineCount: Int { isColumns ? metrics.columnCount : metrics.rowCount }

    /// The line whose trailing boundary is under the pointer, if any.
    private func boundary(near position: CGFloat) -> Int? {
        guard lineCount > 0 else { return nil }
        let line = line(at: position)
        let end = start(of: line) + length(of: line)
        if abs(CGFloat(end) - position) <= Self.grabDistance { return line }
        if line > 0, abs(CGFloat(start(of: line)) - position) <= Self.grabDistance {
            // The boundary before this line belongs to the visible line before.
            var previous = line - 1
            while previous > 0, length(of: previous) == 0 { previous -= 1 }
            return previous
        }
        return nil
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.labelColor.withAlphaComponent(0.04).setFill()
        bounds.fill()
        guard let document, let client = clientView else { return }
        let state = document.state
        let sheet = document.activeSheet
        let visible = convert(dirtyRect, to: client)
        let span = isColumns ? Double(visible.minX)...Double(max(visible.minX, visible.maxX))
            : Double(visible.minY)...Double(max(visible.minY, visible.maxY))
        let lines = isColumns ? metrics.columns(in: span, overscan: 1) : metrics.rows(in: span, overscan: 1)

        let selected = state.selectedRanges.map(\.normalized)
        let spansAll = isColumns ? state.selectionSpansEntireColumns(in: sheet) : state.selectionSpansEntireRows(in: sheet)
        let separator = CellRenderer.gridLineColor(for: effectiveAppearance)
        let font = NSFont.systemFont(ofSize: 11)

        func drawLine(_ line: Int, frozen: Bool) {
            let length = length(of: line)
            guard length > 0 else { return }
            let rect = rulerRect(start: start(of: line), length: length, frozen: frozen)
            let isSelected = selected.contains { isColumns ? $0.columnRange.contains(line) : $0.rowRange.contains(line) }
            if isSelected {
                NSColor.controlAccentColor.withAlphaComponent(spansAll ? 0.35 : 0.18).setFill()
                rect.fill()
            }
            let label = isColumns ? CellAddress.columnName(line) : String(line + 1)
            let text = NSAttributedString(string: label, attributes: [
                .font: isSelected ? NSFont.boldSystemFont(ofSize: 11) : font,
                .foregroundColor: isSelected ? NSColor.labelColor : NSColor.secondaryLabelColor,
            ])
            let size = text.size()
            text.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
            separator.setFill()
            if isColumns {
                CGRect(x: rect.maxX - 1, y: 0, width: 1, height: bounds.height).fill()
            } else {
                CGRect(x: 0, y: rect.maxY - 1, width: bounds.width, height: 1).fill()
            }
        }

        // The scrolling lines, kept out from under the frozen ones, which
        // are drawn over them where they stay.
        let frozenZone = frozenLength > 0 ? rulerRect(start: 0, length: frozenLength, frozen: true) : .zero
        NSGraphicsContext.saveGraphicsState()
        if frozenLength > 0 {
            let scrolling = isColumns
                ? CGRect(x: frozenZone.maxX, y: 0, width: max(0, bounds.maxX - frozenZone.maxX), height: bounds.height)
                : CGRect(x: 0, y: frozenZone.maxY, width: bounds.width, height: max(0, bounds.maxY - frozenZone.maxY))
            scrolling.clip()
        }
        for line in lines where line >= frozenCount { drawLine(line, frozen: false) }
        NSGraphicsContext.restoreGraphicsState()
        if frozenLength > 0 {
            for line in 0..<min(frozenCount, lineCount) { drawLine(line, frozen: true) }
            // Where the frozen lines end, as on the sheet.
            NSColor.separatorColor.withAlphaComponent(0.9).setFill()
            if isColumns {
                CGRect(x: frozenZone.maxX - 1, y: 0, width: 1, height: bounds.height).fill()
            } else {
                CGRect(x: 0, y: frozenZone.maxY - 1, width: bounds.width, height: 1).fill()
            }
        }
        separator.setFill()
        if isColumns {
            CGRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
        } else {
            CGRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()
        }
    }

    // MARK: - Mouse

    override func resetCursorRects() {
        guard document != nil, let client = clientView else { return }
        let span = isColumns ? Double(client.visibleRect.minX)...Double(client.visibleRect.maxX)
            : Double(client.visibleRect.minY)...Double(client.visibleRect.maxY)
        let lines = isColumns ? metrics.columns(in: span, overscan: 1) : metrics.rows(in: span, overscan: 1)
        let frozenEnd = frozenLength > 0 ? rulerRect(start: frozenLength, length: 0, frozen: true) : .zero
        func addGrab(for line: Int, frozen: Bool) {
            let end = rulerRect(start: start(of: line) + length(of: line), length: 0, frozen: frozen)
            if !frozen, frozenLength > 0, (isColumns ? end.minX : end.minY) < (isColumns ? frozenEnd.minX : frozenEnd.minY) {
                return
            }
            let grab = isColumns
                ? CGRect(x: end.minX - Self.grabDistance, y: 0, width: Self.grabDistance * 2, height: bounds.height)
                : CGRect(x: 0, y: end.minY - Self.grabDistance, width: bounds.width, height: Self.grabDistance * 2)
            addCursorRect(grab, cursor: isColumns ? .resizeLeftRight : .resizeUpDown)
        }
        for line in lines where line >= frozenCount { addGrab(for: line, frozen: false) }
        for line in 0..<min(frozenCount, lineCount) { addGrab(for: line, frozen: true) }
    }

    override func mouseDown(with event: NSEvent) {
        guard let document else { return }
        let state = document.state
        let position = gridPosition(of: convert(event.locationInWindow, from: nil))
        if state.editingAddress != nil {
            (clientView as? GridView)?.commitEditing(then: nil)
        }
        state.selectChart(nil)
        state.selectDrawing(nil)
        if let boundary = boundary(near: position) {
            if event.clickCount == 2, isColumns {
                document.edit { state.fitColumn(boundary, in: &$0) }
                return
            }
            let original = isColumns
                ? document.activeSheet.width(ofColumn: boundary) : document.activeSheet.height(ofRow: boundary)
            drag = .resizing(line: boundary, start: position, original: original)
            return
        }
        let line = line(at: position)
        let sheet = document.activeSheet
        var anchor = line
        if event.modifierFlags.contains(.shift) {
            anchor = isColumns ? state.anchor.column : state.anchor.row
        }
        select(from: anchor, to: line, in: sheet, state: state)
        window?.makeFirstResponder(clientView)
        drag = .selecting(anchor: anchor)
        document.notify()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let document, let drag else { return }
        let state = document.state
        let position = gridPosition(of: convert(event.locationInWindow, from: nil))
        switch drag {
        case .selecting(let anchor):
            clientView?.autoscroll(with: event)
            select(from: anchor, to: line(at: position), in: document.activeSheet, state: state)
            document.notify()
        case .resizing(let line, let start, let original):
            let size = max(isColumns ? Worksheet.minimumColumnWidth : Worksheet.minimumRowHeight,
                           original + Double(position - start) / state.zoom)
            document.edit {
                if isColumns {
                    state.resizeColumn(line, to: size, in: &$0)
                } else {
                    state.resizeRow(line, to: size, in: &$0)
                }
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        drag = nil
        window?.invalidateCursorRects(for: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let document else { return nil }
        let state = document.state
        let line = line(at: gridPosition(of: convert(event.locationInWindow, from: nil)))
        let sheet = document.activeSheet
        let isInSelection = state.selectedRanges.contains {
            isColumns ? $0.normalized.columnRange.contains(line) : $0.normalized.rowRange.contains(line)
        }
        let isWhole = isColumns ? state.selectionSpansEntireColumns(in: sheet) : state.selectionSpansEntireRows(in: sheet)
        if !(isInSelection && isWhole) {
            select(from: line, to: line, in: sheet, state: state)
            document.notify()
        }
        return lineMenu?(isColumns, line)
    }

    private func select(from anchor: Int, to line: Int, in sheet: Worksheet, state: EditorState) {
        let range = min(anchor, line)...max(anchor, line)
        if isColumns {
            state.selectEntireColumns(range, in: sheet)
            state.anchor = CellAddress(row: 0, column: anchor)
        } else {
            state.selectEntireRows(range, in: sheet)
            state.anchor = CellAddress(row: anchor, column: 0)
        }
    }

    // NSRulerView draws markers and a baseline of its own; there are none here.
    override func drawHashMarksAndLabels(in rect: NSRect) {}
}
