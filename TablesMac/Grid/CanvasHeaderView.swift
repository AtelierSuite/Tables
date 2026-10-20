import AppKit
import TablesEngine

/// The column letters above and row numbers beside the table being worked
/// on on a canvas, as the grid's rulers are for a sheet of its own: click
/// or drag along them to select whole columns and rows, drag a line between
/// two to resize it, double-click one to fit a column to its contents.
///
/// It lies over the table and the bars round it, letting clicks on the
/// cells through to the grid, and the corner where the bars meet through
/// to the canvas, where it is the handle the table is moved by.
@MainActor
final class CanvasHeaderView: NSView {
    weak var document: WorkbookDocument?
    /// The table it is the headers of.
    let sheetID: Worksheet.ID
    /// Builds the menu for a right-click on a column's or row's header.
    var lineMenu: ((_ isColumn: Bool) -> NSMenu?)?

    private enum Drag {
        case selecting(isColumn: Bool, anchor: Int)
        case resizing(isColumn: Bool, line: Int, start: CGFloat, original: Double)
    }
    private var drag: Drag?
    private var pointerArea: NSTrackingArea?

    private static let grabDistance: CGFloat = 3

    init(sheetID: Worksheet.ID) {
        self.sheetID = sheetID
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    private var metrics: SheetMetrics { document?.state.metrics ?? SheetMetrics() }
    private var columnBarHeight: CGFloat { CanvasChrome.columnHeaderHeight }
    private var rowBarWidth: CGFloat {
        CanvasChrome.rowHeaderWidth(rowCount: document?.workbook[sheetID]?.rowCount ?? 1)
    }

    /// Lays the bars round a table's cells, given where they are on the page.
    func place(around cells: CGRect) {
        let frame = CGRect(x: cells.minX - rowBarWidth, y: cells.minY - columnBarHeight,
                           width: cells.width + rowBarWidth, height: cells.height + columnBarHeight)
        if self.frame != frame { self.frame = frame }
        needsDisplay = true
    }

    private var columnBar: CGRect {
        CGRect(x: rowBarWidth, y: 0, width: max(0, bounds.width - rowBarWidth), height: columnBarHeight)
    }

    private var rowBar: CGRect {
        CGRect(x: 0, y: columnBarHeight, width: rowBarWidth, height: max(0, bounds.height - columnBarHeight))
    }

    /// Only the bars take clicks: the cells are the grid's, the corner the canvas's.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0.5, let superview else { return nil }
        let local = convert(point, from: superview)
        return columnBar.contains(local) || rowBar.contains(local) ? self : nil
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let document else { return }
        let state = document.state
        let sheet = document.activeSheet
        guard sheet.id == sheetID else { return }
        let separator = CellRenderer.gridLineColor(for: effectiveAppearance)
        let selected = state.selectedRanges.map(\.normalized)
        let font = NSFont.systemFont(ofSize: 10)

        for (bar, isColumns) in [(columnBar, true), (rowBar, false)] where bar.intersects(dirtyRect) {
            NSColor.windowBackgroundColor.setFill()
            bar.fill()
            NSColor.labelColor.withAlphaComponent(0.05).setFill()
            bar.fill()
            let spansAll = isColumns ? state.selectionSpansEntireColumns(in: sheet) : state.selectionSpansEntireRows(in: sheet)
            let visible = dirtyRect.intersection(bar)
            let lines = isColumns
                ? metrics.columns(in: Double(visible.minX - bar.minX)...Double(max(visible.minX, visible.maxX) - bar.minX), overscan: 1)
                : metrics.rows(in: Double(visible.minY - bar.minY)...Double(max(visible.minY, visible.maxY) - bar.minY), overscan: 1)
            for line in lines {
                let length = isColumns ? metrics.width(ofColumn: line) : metrics.height(ofRow: line)
                guard length > 0 else { continue }
                let rect = isColumns
                    ? CGRect(x: bar.minX + metrics.x(ofColumn: line), y: bar.minY, width: length, height: bar.height)
                    : CGRect(x: bar.minX, y: bar.minY + metrics.y(ofRow: line), width: bar.width, height: length)
                let isSelected = selected.contains { isColumns ? $0.columnRange.contains(line) : $0.rowRange.contains(line) }
                if isSelected {
                    NSColor.controlAccentColor.withAlphaComponent(spansAll ? 0.35 : 0.18).setFill()
                    rect.fill()
                }
                let text = NSAttributedString(string: isColumns ? CellAddress.columnName(line) : String(line + 1), attributes: [
                    .font: isSelected ? NSFont.boldSystemFont(ofSize: 10) : font,
                    .foregroundColor: isSelected ? NSColor.labelColor : NSColor.secondaryLabelColor,
                ])
                let size = text.size()
                text.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
                separator.setFill()
                if isColumns {
                    CGRect(x: rect.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill()
                } else {
                    CGRect(x: rect.minX, y: rect.maxY - 1, width: rect.width, height: 1).fill()
                }
            }
        }
        separator.setFill()
        CGRect(x: columnBar.minX, y: columnBar.maxY - 1, width: columnBar.width, height: 1).fill()
        CGRect(x: rowBar.maxX - 1, y: rowBar.minY, width: 1, height: rowBar.height).fill()
        drawCorner(CGRect(x: 0, y: 0, width: rowBarWidth, height: columnBarHeight), movable: state.allowsLayingOutTables)
    }

    /// Where the bars meet: the handle the table is moved by, and a click
    /// selects all of it.
    private func drawCorner(_ rect: CGRect, movable: Bool) {
        let shape = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        (movable ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.12)).setFill()
        shape.fill()
        guard movable else { return }
        let configuration = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
            .applying(.init(paletteColors: [.white]))
        guard let arrows = NSImage(systemSymbolName: "arrow.up.and.down.and.arrow.left.and.right",
                                   accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return }
        let size = arrows.size
        arrows.draw(in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                               width: size.width, height: size.height),
                    from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    // MARK: - Mouse

    /// Which bar a point is on, and how far along it, in the table's own
    /// coordinates.
    private func position(of point: CGPoint) -> (isColumn: Bool, along: CGFloat)? {
        if columnBar.contains(point) { return (true, point.x - columnBar.minX) }
        if rowBar.contains(point) { return (false, point.y - rowBar.minY) }
        return nil
    }

    private func line(at along: CGFloat, isColumn: Bool) -> Int {
        isColumn ? metrics.column(atX: Double(max(0, along))) : metrics.row(atY: Double(max(0, along)))
    }

    /// The line whose trailing edge is under the pointer, if any.
    private func boundary(near along: CGFloat, isColumn: Bool) -> Int? {
        let line = line(at: along, isColumn: isColumn)
        let start = isColumn ? metrics.x(ofColumn: line) : metrics.y(ofRow: line)
        let length = isColumn ? metrics.width(ofColumn: line) : metrics.height(ofRow: line)
        if abs(CGFloat(start + length) - along) <= Self.grabDistance { return line }
        if line > 0, abs(CGFloat(start) - along) <= Self.grabDistance { return line - 1 }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let document, let (isColumn, along) = position(of: convert(event.locationInWindow, from: nil)) else { return }
        let state = document.state
        if state.editingAddress != nil {
            document.edit { state.commitEditing(in: &$0, then: nil) }
        }
        state.selectChart(nil)
        state.selectDrawing(nil)
        let sheet = document.activeSheet
        if let boundary = boundary(near: along, isColumn: isColumn) {
            if event.clickCount == 2, isColumn {
                document.edit { state.fitColumn(boundary, in: &$0) }
                return
            }
            let original = isColumn ? sheet.width(ofColumn: boundary) : sheet.height(ofRow: boundary)
            drag = .resizing(isColumn: isColumn, line: boundary, start: along, original: original)
            return
        }
        let line = line(at: along, isColumn: isColumn)
        var anchor = line
        if event.modifierFlags.contains(.shift) { anchor = isColumn ? state.anchor.column : state.anchor.row }
        select(from: anchor, to: line, isColumn: isColumn, in: sheet, state: state)
        drag = .selecting(isColumn: isColumn, anchor: anchor)
        document.notify()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let document, let drag else { return }
        let state = document.state
        let point = convert(event.locationInWindow, from: nil)
        switch drag {
        case .selecting(let isColumn, let anchor):
            let along = isColumn ? point.x - columnBar.minX : point.y - rowBar.minY
            select(from: anchor, to: line(at: along, isColumn: isColumn), isColumn: isColumn,
                   in: document.activeSheet, state: state)
            document.notify()
            superview?.autoscroll(with: event)
        case .resizing(let isColumn, let line, let start, let original):
            let along = isColumn ? point.x - columnBar.minX : point.y - rowBar.minY
            let size = max(isColumn ? Worksheet.minimumColumnWidth : Worksheet.minimumRowHeight,
                           original + Double(along - start) / state.zoom)
            document.edit {
                if isColumn { state.resizeColumn(line, to: size, in: &$0) } else { state.resizeRow(line, to: size, in: &$0) }
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        drag = nil
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let document, let (isColumn, along) = position(of: convert(event.locationInWindow, from: nil)) else { return nil }
        let state = document.state
        let sheet = document.activeSheet
        let line = line(at: along, isColumn: isColumn)
        let isInSelection = state.selectedRanges.contains {
            isColumn ? $0.normalized.columnRange.contains(line) : $0.normalized.rowRange.contains(line)
        }
        let isWhole = isColumn ? state.selectionSpansEntireColumns(in: sheet) : state.selectionSpansEntireRows(in: sheet)
        if !(isInSelection && isWhole) {
            select(from: line, to: line, isColumn: isColumn, in: sheet, state: state)
            document.notify()
        }
        return lineMenu?(isColumn)
    }

    private func select(from anchor: Int, to line: Int, isColumn: Bool, in sheet: Worksheet, state: EditorState) {
        let range = min(anchor, line)...max(anchor, line)
        if isColumn {
            state.selectEntireColumns(range, in: sheet)
            state.anchor = CellAddress(row: 0, column: anchor)
        } else {
            state.selectEntireRows(range, in: sheet)
            state.anchor = CellAddress(row: anchor, column: 0)
        }
    }

    // MARK: - Pointer

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
        guard drag == nil, let (isColumn, along) = position(of: convert(event.locationInWindow, from: nil)) else { return }
        if boundary(near: along, isColumn: isColumn) != nil {
            (isColumn ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
        } else {
            NSCursor.arrow.set()
        }
    }
}
