import AppKit
import TablesEngine

/// The sheet: cells, the selection drawn over them, the in-cell editor, and
/// the charts and pictures floating above.
///
/// Draws only what the dirty rectangle meets, straight from the worksheet,
/// so a hundred-thousand-row sheet scrolls as easily as a small one. Edits
/// go through the document, which owns the undo stack; the grid only reads.
@MainActor
final class GridView: NSView, NSTextFieldDelegate {
    weak var document: WorkbookDocument?
    /// Builds the menu for a right-click on a cell.
    var cellMenu: ((CellAddress) -> NSMenu?)?
    /// Hands the formula bar the keyboard, for an edit that started there.
    var formulaBarField: (() -> NSTextField?)?

    private var editor: CellEditorField?
    /// Whether the edit began by typing over the cell, when the arrow keys
    /// finish it and move on rather than moving the caret — as in Excel.
    private var isEnteringByTyping = false
    /// Set while the grid itself ends an edit, so losing focus is not
    /// mistaken for the user clicking away.
    private var isEndingEditing = false

    private enum Drag {
        case selecting
        case pointing(origin: CellAddress)
        /// Pulling the fill handle, toward the range it would fill.
        case filling(target: CellRange)
        /// Carrying the selection by its border: the grabbed cell's offset
        /// into it, and where its top-left would land.
        case moving(grab: CellAddress, destination: CellAddress)
    }

    private var drag: Drag?
    private var objectViews: [AnyHashable: FloatingObjectView] = [:]

    override var isFlipped: Bool { true }
    /// Not while a formula is being typed: a click then points at cells for
    /// the formula, and the editor has to keep the keyboard.
    override var acceptsFirstResponder: Bool { !(state?.isEnteringFormula ?? false) }
    override var isOpaque: Bool { true }

    private var state: EditorState? { document?.state }

    /// The frozen panes laid over the grid, corner first, which draw through
    /// it and hand it their clicks.
    var panes: [FrozenPaneView] = []

    /// The sheet coordinates under the pointer: through whichever frozen
    /// pane it is over, or else the grid's own.
    func sheetPoint(for event: NSEvent) -> NSPoint {
        for pane in panes where !pane.isHidden {
            let local = pane.convert(event.locationInWindow, from: nil)
            if pane.bounds.contains(local) { return local }
        }
        return convert(event.locationInWindow, from: nil)
    }

    /// Whether the pointer is over a frozen pane rather than the grid itself.
    private func isOverPane(_ event: NSEvent) -> Bool {
        panes.contains { !$0.isHidden && $0.bounds.contains($0.convert(event.locationInWindow, from: nil)) }
    }

    /// How far the frozen rows reach down, and the frozen columns across.
    var frozenExtent: CGSize {
        guard let document else { return .zero }
        let sheet = document.activeSheet
        let metrics = document.state.metrics
        return CGSize(
            width: sheet.frozenColumns > 0 ? metrics.x(ofColumn: sheet.frozenColumns) : 0,
            height: sheet.frozenRows > 0 ? metrics.y(ofRow: sheet.frozenRows) : 0)
    }

    // MARK: - Updating

    /// Brings the grid up to date with the document.
    func refresh() {
        guard let document else { return }
        let metrics = document.state.metrics
        let size = NSSize(width: max(1, metrics.totalWidth), height: max(1, metrics.totalHeight))
        if frame.size != size { setFrameSize(size) }
        syncEditor(in: document)
        syncObjects(in: document)
        needsDisplay = true
        for pane in panes { pane.needsDisplay = true }
        if let target = document.state.scrollTarget {
            document.state.scrollTarget = nil
            reveal(target, in: document)
        }
    }

    /// Scrolls a cell into view, clear of the frozen panes: a frozen cell is
    /// always in view along the frozen axis, and any other has to land
    /// below and beside them rather than underneath.
    private func reveal(_ address: CellAddress, in document: WorkbookDocument) {
        let sheet = document.activeSheet
        var frame = document.state.metrics.frame(for: address).insetBy(dx: -4, dy: -4)
        let frozen = frozenExtent
        let visible = visibleRect
        if address.row < sheet.frozenRows {
            // Already in view: ask for somewhere that is, so nothing moves.
            frame.origin.y = visible.midY
            frame.size.height = 1
        } else if frame.minY < visible.minY + frozen.height {
            frame.origin.y -= frozen.height
            frame.size.height += frozen.height
        }
        if address.column < sheet.frozenColumns {
            frame.origin.x = visible.midX
            frame.size.width = 1
        } else if frame.minX < visible.minX + frozen.width {
            frame.origin.x -= frozen.width
            frame.size.width += frozen.width
        }
        scrollToVisible(frame)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        drawSheet(dirtyRect, in: context)
    }

    /// Draws a part of the sheet, given in its own coordinates: for the grid,
    /// and for the frozen panes, which show parts of it in place.
    func drawSheet(_ dirtyRect: NSRect, in context: CGContext) {
        guard let document else { return }
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        let renderer = CellRenderer(
            sheet: document.activeSheet, metrics: document.state.metrics, appearance: effectiveAppearance
        )
        renderer.draw(in: dirtyRect, context: context, gridLineColor: CellRenderer.gridLineColor(for: effectiveAppearance))
        drawReferences(in: document, context: context)
        drawSelection(in: document, context: context)
        drawDragPreview(in: document, context: context)
    }

    /// The ring the selection is outlined with, in the grid's coordinates.
    private func selectionRing(in document: WorkbookDocument) -> NSRect {
        let sheet = document.activeSheet
        return document.state.metrics.frame(for: sheet.expandedToMerges(document.state.selection)).insetBy(dx: 1, dy: 1)
    }

    /// Whether the selection can be filled or carried: one range, with no
    /// edit, chart or picture in the way.
    private func offersSelectionHandles(in document: WorkbookDocument) -> Bool {
        let state = document.state
        return !state.hasMultipleSelections && state.editingAddress == nil
            && state.selectedChartID == nil && state.selectedDrawingID == nil
            && !document.macroRunner.isRunning
    }

    /// The fill handle: the small square at the selection's bottom-right corner.
    private func fillHandleRect(in document: WorkbookDocument) -> NSRect {
        let ring = selectionRing(in: document)
        let size: CGFloat = 7
        return NSRect(x: ring.maxX - size / 2, y: ring.maxY - size / 2, width: size, height: size)
    }

    /// The strips along the selection's edges that pick it up to move it.
    private func borderRects(in document: WorkbookDocument) -> [NSRect] {
        let ring = selectionRing(in: document)
        let reach: CGFloat = 3
        return [
            NSRect(x: ring.minX - reach, y: ring.minY - reach, width: ring.width + reach * 2, height: reach * 2),
            NSRect(x: ring.minX - reach, y: ring.maxY - reach, width: ring.width + reach * 2, height: reach * 2),
            NSRect(x: ring.minX - reach, y: ring.minY - reach, width: reach * 2, height: ring.height + reach * 2),
            NSRect(x: ring.maxX - reach, y: ring.minY - reach, width: reach * 2, height: ring.height + reach * 2),
        ]
    }

    /// Where a fill or a move would land, outlined while it is dragged.
    private func drawDragPreview(in document: WorkbookDocument, context: CGContext) {
        let metrics = document.state.metrics
        let frame: NSRect
        switch drag {
        case .filling(let target):
            frame = metrics.frame(for: target.normalized)
        case .moving(_, let destination):
            let box = document.state.selection.normalized
            frame = metrics.frame(for: CellRange(
                start: destination,
                end: CellAddress(
                    row: destination.row + box.end.row - box.start.row,
                    column: destination.column + box.end.column - box.start.column)))
        default:
            return
        }
        context.saveGState()
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(2)
        context.setLineDash(phase: 0, lengths: [4, 3])
        context.stroke(frame.insetBy(dx: 1, dy: 1))
        context.restoreGState()
    }

    /// Tints the selected ranges, leaving the active cell clear, and rings
    /// the range keyboard entry works from.
    private func drawSelection(in document: WorkbookDocument, context: CGContext) {
        let state = document.state
        let sheet = document.activeSheet
        let metrics = state.metrics
        let accent = NSColor.controlAccentColor
        let active = metrics.frame(for: sheet.mergedRange(containing: state.anchor) ?? CellRange(state.anchor))

        context.saveGState()
        context.setFillColor(accent.withAlphaComponent(0.14).cgColor)
        for range in state.selectedRanges {
            let frame = metrics.frame(for: sheet.expandedToMerges(range))
            context.addRect(frame)
            if frame.contains(active) { context.addRect(active) }
            context.fillPath(using: .evenOdd)
        }
        let ring = metrics.frame(for: sheet.expandedToMerges(state.selection)).insetBy(dx: 1, dy: 1)
        context.setStrokeColor(accent.cgColor)
        context.setLineWidth(2)
        context.stroke(ring)
        if state.selection.normalized.isSingleCell == false {
            context.setLineWidth(1)
            context.stroke(active.insetBy(dx: 2, dy: 2))
        }
        if offersSelectionHandles(in: document) {
            let handle = fillHandleRect(in: document)
            context.setFillColor(accent.cgColor)
            context.fill(handle)
            context.setStrokeColor(NSColor.textBackgroundColor.cgColor)
            context.setLineWidth(1)
            context.stroke(handle.insetBy(dx: -0.5, dy: -0.5))
        }
        context.restoreGState()
    }

    /// While a formula is being typed, the cells it names, outlined in the
    /// colours the formula is written in.
    private func drawReferences(in document: WorkbookDocument, context: CGContext) {
        let state = document.state
        guard state.isEnteringFormula else { return }
        let sheet = document.activeSheet
        context.saveGState()
        context.setLineWidth(2)
        for reference in FormulaReferenceScanner.references(in: state.editingText) {
            if let name = reference.sheetName, name.caseInsensitiveCompare(sheet.name) != .orderedSame { continue }
            let frame = state.metrics.frame(for: reference.cells.normalized).insetBy(dx: 1, dy: 1)
            let color = ReferenceColors.color(at: reference.colorIndex)
            context.setFillColor(color.withAlphaComponent(0.1).cgColor)
            context.fill(frame)
            context.setStrokeColor(color.cgColor)
            context.stroke(frame)
        }
        context.restoreGState()
    }

    // MARK: - Hit testing

    /// The cell under a point, as the merge it falls in where there is one.
    private func address(at point: NSPoint, in document: WorkbookDocument) -> CellAddress {
        let metrics = document.state.metrics
        let address = rawAddress(at: point, metrics: metrics)
        return document.activeSheet.mergedRange(containing: address)?.normalized.start ?? address
    }

    private func rawAddress(at point: NSPoint, metrics: SheetMetrics) -> CellAddress {
        CellAddress(row: metrics.row(atY: max(0, point.y)), column: metrics.column(atX: max(0, point.x)))
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        guard let document else { return }
        let state = document.state
        let point = sheetPoint(for: event)
        let sheet = document.activeSheet
        let address = address(at: point, in: document)

        // Typing a formula, a click points at the cells it should name.
        if state.editingAddress != nil, state.isEnteringFormula {
            let raw = rawAddress(at: point, metrics: state.metrics)
            drag = .pointing(origin: raw)
            state.insertReference(sheet.expandedToMerges(CellRange(raw)), in: document.workbook)
            showEditedText(in: document)
            return
        }
        if state.editingAddress != nil { commitEditing(then: nil) }
        if state.selectedChartID != nil || state.selectedDrawingID != nil {
            state.selectChart(nil)
            state.selectDrawing(nil)
        }
        window?.makeFirstResponder(self)

        if event.clickCount == 1, event.modifierFlags.isDisjoint(with: [.shift, .command]),
           offersSelectionHandles(in: document) {
            if fillHandleRect(in: document).insetBy(dx: -3, dy: -3).contains(point) {
                drag = .filling(target: state.selection.normalized)
                return
            }
            if borderRects(in: document).contains(where: { $0.contains(point) }) {
                let box = state.selection.normalized
                let grabbed = rawAddress(at: point, metrics: state.metrics)
                let grab = CellAddress(
                    row: min(max(grabbed.row, box.start.row), box.end.row) - box.start.row,
                    column: min(max(grabbed.column, box.start.column), box.end.column) - box.start.column)
                drag = .moving(grab: grab, destination: box.start)
                NSCursor.closedHand.push()
                return
            }
        }

        if event.clickCount == 2 {
            beginEditing(at: address, seed: nil)
            return
        }
        if event.modifierFlags.contains(.shift) {
            state.select(address, extending: true, in: sheet)
        } else if event.modifierFlags.contains(.command) {
            state.addRange(startingAt: address, in: sheet)
        } else {
            state.select(address, in: sheet)
        }
        drag = .selecting
        document.notify()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let document, let drag else { return }
        autoscroll(with: event)
        let state = document.state
        let point = sheetPoint(for: event)
        let raw = rawAddress(at: point, metrics: state.metrics)
        switch drag {
        case .selecting:
            state.select(raw, extending: true, in: document.activeSheet)
            document.notify()
        case .pointing(let origin):
            state.insertReference(CellRange(start: origin, end: raw), in: document.workbook)
            showEditedText(in: document)
        case .filling:
            let target = AutoFill.target(extending: state.selection, toward: raw)
            self.drag = .filling(target: target)
            needsDisplay = true
        case .moving(let grab, _):
            let box = state.selection.normalized
            let sheet = document.activeSheet
            let height = box.end.row - box.start.row
            let width = box.end.column - box.start.column
            let destination = CellAddress(
                row: min(max(0, raw.row - grab.row), max(0, sheet.rowCount - 1 - height)),
                column: min(max(0, raw.column - grab.column), max(0, sheet.columnCount - 1 - width)))
            self.drag = .moving(grab: grab, destination: destination)
            updateMoveCursor(copying: event.modifierFlags.contains(.option))
            needsDisplay = true
        }
    }

    /// Holding Option while carrying the selection copies it instead, and
    /// the pointer says so.
    private func updateMoveCursor(copying: Bool) {
        let cursor: NSCursor = copying ? .dragCopy : .closedHand
        if NSCursor.current != cursor { cursor.set() }
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        if case .moving = drag { updateMoveCursor(copying: event.modifierFlags.contains(.option)) }
    }

    override func mouseUp(with event: NSEvent) {
        let finished = drag
        drag = nil
        guard let document else { return }
        let state = document.state
        switch finished {
        case .pointing:
            state.finishReferenceInsertion()
        case .filling(let target):
            if target.normalized != state.selection.normalized {
                document.edit { state.fillSelection(to: target, in: &$0) }
            }
            document.notify()
        case .moving(_, let destination):
            NSCursor.pop()
            if destination != state.selection.normalized.start {
                let copying = event.modifierFlags.contains(.option)
                document.edit { state.moveSelection(to: destination, copying: copying, in: &$0) }
            }
            document.notify()
        default:
            break
        }
        if let event = NSApp.currentEvent { updatePointer(for: event) }
    }

    // MARK: - Pointer

    private var pointerArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerArea { removeTrackingArea(pointerArea) }
        let area = NSTrackingArea(
            rect: .zero, options: [.cursorUpdate, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        pointerArea = area
    }

    override func cursorUpdate(with event: NSEvent) { updatePointer(for: event) }
    override func mouseMoved(with event: NSEvent) { updatePointer(for: event) }

    /// The fill handle's crosshair and an open hand along the selection's
    /// border; an arrow everywhere else. Charts and pictures keep their own.
    private func updatePointer(for event: NSEvent) {
        guard drag == nil, let document else { return }
        let point = sheetPoint(for: event)
        if !isOverPane(event), let hit = superview.flatMap({ hitTest($0.convert(event.locationInWindow, from: nil)) }),
           hit !== self {
            if let object = hit as? FloatingObjectView {
                object.cursor(atWindowPoint: event.locationInWindow).set()
            } else if !(hit is NSTextView || hit is NSTextField) {
                NSCursor.arrow.set()
            }
            return
        }
        if offersSelectionHandles(in: document) {
            if fillHandleRect(in: document).insetBy(dx: -3, dy: -3).contains(point) {
                NSCursor.crosshair.set()
                return
            }
            if borderRects(in: document).contains(where: { $0.contains(point) }) {
                NSCursor.openHand.set()
                return
            }
        }
        NSCursor.arrow.set()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let document else { return nil }
        let state = document.state
        let point = sheetPoint(for: event)
        let address = address(at: point, in: document)
        if state.editingAddress != nil { commitEditing(then: nil) }
        state.selectChart(nil)
        state.selectDrawing(nil)
        if !state.isSelected(address) {
            state.select(address, in: document.activeSheet)
            document.notify()
        }
        return cellMenu?(address)
    }

    override func magnify(with event: NSEvent) {
        guard let controller = window?.windowController as? WorkbookWindowController else { return }
        controller.workbookViewController.setZoom(
            (document?.state.zoom ?? 1) * (1 + event.magnification), around: convert(event.locationInWindow, from: nil)
        )
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        guard let document else { return super.keyDown(with: event) }
        // While a macro runs, the sheet is the macro's.
        guard !document.macroRunner.isRunning else { return }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // F2 edits the cell in place, as it does in Excel.
        if event.keyCode == 120 {
            beginEditing(at: document.state.selectedAddress, seed: nil)
            return
        }
        if modifiers.isDisjoint(with: [.command, .control]), let characters = event.characters,
           let scalar = characters.unicodeScalars.first, Self.startsEntry(scalar),
           document.state.selectedChartID == nil, document.state.selectedDrawingID == nil {
            // Typing over a cell starts an edit, and the keystroke goes to the
            // editor so an input method sees it from the first key.
            beginEditing(at: document.state.selectedAddress, seed: "")
            isEnteringByTyping = true
            editor?.currentEditor()?.keyDown(with: event)
            return
        }
        interpretKeyEvents([event])
    }

    /// Whether a keystroke is text, rather than a movement or function key.
    private static func startsEntry(_ scalar: Unicode.Scalar) -> Bool {
        // Function keys arrive in the private use area.
        if (0xF700...0xF8FF).contains(scalar.value) { return false }
        return !CharacterSet.controlCharacters.contains(scalar)
    }

    private func move(_ direction: EditorState.MoveDirection, extending: Bool = false) {
        guard let document else { return }
        document.state.move(direction, extending: extending, in: document.activeSheet)
        document.notify()
    }

    override func moveUp(_ sender: Any?) { move(.up) }
    override func moveDown(_ sender: Any?) { move(.down) }
    override func moveLeft(_ sender: Any?) { move(.left) }
    override func moveRight(_ sender: Any?) { move(.right) }
    override func moveUpAndModifySelection(_ sender: Any?) { move(.up, extending: true) }
    override func moveDownAndModifySelection(_ sender: Any?) { move(.down, extending: true) }
    override func moveLeftAndModifySelection(_ sender: Any?) { move(.left, extending: true) }
    override func moveRightAndModifySelection(_ sender: Any?) { move(.right, extending: true) }

    override func insertNewline(_ sender: Any?) {
        move(NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? .up : .down)
    }

    override func insertTab(_ sender: Any?) { move(.right) }
    override func insertBacktab(_ sender: Any?) { move(.left) }

    /// Option-Return edits the cell without replacing what is in it.
    override func insertNewlineIgnoringFieldEditor(_ sender: Any?) {
        guard let document else { return }
        beginEditing(at: document.state.selectedAddress, seed: nil)
    }

    override func deleteBackward(_ sender: Any?) { clearSelection() }
    override func deleteForward(_ sender: Any?) { clearSelection() }

    /// Delete removes the chart or picture picked out, or else empties the
    /// selected cells.
    private func clearSelection() {
        guard let document else { return }
        let state = document.state
        if state.selectedChartID != nil {
            document.edit { state.deleteSelectedChart(in: &$0) }
        } else if state.selectedDrawingID != nil {
            document.edit { state.deleteSelectedDrawing(in: &$0) }
        } else {
            document.edit { state.clearContents(in: &$0) }
        }
    }

    override func cancelOperation(_ sender: Any?) {
        guard let document else { return }
        document.state.selectChart(nil)
        document.state.selectDrawing(nil)
        document.notify()
    }

    private func jump(rows: Int? = nil, columns: Int? = nil, extending: Bool) {
        guard let document else { return }
        let state = document.state
        let sheet = document.activeSheet
        let origin = extending ? state.selection.end : state.selectedAddress
        let target = CellAddress(
            row: rows.map { min(max(0, $0), sheet.rowCount - 1) } ?? origin.row,
            column: columns.map { min(max(0, $0), sheet.columnCount - 1) } ?? origin.column
        )
        state.select(target, extending: extending, in: sheet)
        state.scrollTarget = target
        document.notify()
    }

    override func moveToBeginningOfDocument(_ sender: Any?) { jump(rows: 0, extending: false) }
    override func moveToEndOfDocument(_ sender: Any?) { jump(rows: .max, extending: false) }
    override func moveToLeftEndOfLine(_ sender: Any?) { jump(columns: 0, extending: false) }
    override func moveToRightEndOfLine(_ sender: Any?) { jump(columns: .max, extending: false) }
    override func moveToBeginningOfDocumentAndModifySelection(_ sender: Any?) { jump(rows: 0, extending: true) }
    override func moveToEndOfDocumentAndModifySelection(_ sender: Any?) { jump(rows: .max, extending: true) }
    override func moveToLeftEndOfLineAndModifySelection(_ sender: Any?) { jump(columns: 0, extending: true) }
    override func moveToRightEndOfLineAndModifySelection(_ sender: Any?) { jump(columns: .max, extending: true) }

    override func scrollToBeginningOfDocument(_ sender: Any?) { jump(rows: 0, columns: 0, extending: false) }
    override func scrollToEndOfDocument(_ sender: Any?) { jump(rows: .max, columns: .max, extending: false) }

    override func pageDown(_ sender: Any?) { page(by: 1) }
    override func pageUp(_ sender: Any?) { page(by: -1) }
    override func scrollPageDown(_ sender: Any?) { page(by: 1) }
    override func scrollPageUp(_ sender: Any?) { page(by: -1) }

    /// Moves a screenful up or down, selection and all.
    private func page(by direction: Int) {
        guard let document else { return }
        let metrics = document.state.metrics
        let visible = visibleRect
        let rows = max(1, metrics.rows(in: Double(visible.minY)...Double(visible.maxY), overscan: 0).count - 1)
        jump(rows: document.state.selectedAddress.row + direction * rows, extending: false)
    }

    // MARK: - In-cell editing

    /// Opens the editor on a cell: over what it holds, or, with `seed`,
    /// replacing it.
    func beginEditing(at address: CellAddress, seed: String?) {
        guard let document else { return }
        let state = document.state
        if state.selectedChartID != nil || state.selectedDrawingID != nil { return }
        isEnteringByTyping = false
        state.beginEditing(address, in: document.workbook, replacingWith: seed)
        state.isFormulaBarActive = false
        document.notify()
        if let editor {
            window?.makeFirstResponder(editor)
            editor.currentEditor()?.selectedRange = NSRange(location: editor.stringValue.utf16.count, length: 0)
        }
    }

    /// Starts a function: into the formula being typed, at the caret, or
    /// else as a new formula in the selected cell.
    func startFunction(_ name: String) {
        guard let document else { return }
        if document.state.isEnteringFormula, let field = window?.firstResponder as? NSTextView {
            field.insertText(name + "(", replacementRange: field.selectedRange())
            return
        }
        if document.state.editingAddress != nil { commitEditing(then: nil) }
        window?.makeFirstResponder(self)
        beginEditing(at: document.state.selectedAddress, seed: "=" + name + "(")
    }

    /// Writes what was typed into the cell and moves on.
    func commitEditing(then direction: EditorState.MoveDirection?) {
        guard let document, document.state.editingAddress != nil else { return }
        isEndingEditing = true
        defer { isEndingEditing = false }
        let state = document.state
        document.edit { state.commitEditing(in: &$0, then: direction) }
        window?.makeFirstResponder(self)
        document.notify()
    }

    func cancelEditing() {
        guard let document else { return }
        isEndingEditing = true
        defer { isEndingEditing = false }
        document.state.cancelEditing()
        window?.makeFirstResponder(self)
        document.notify()
    }

    /// Puts the in-cell editor where the edit is, or takes it away.
    private func syncEditor(in document: WorkbookDocument) {
        let state = document.state
        guard let address = state.editingAddress, !state.isFormulaBarActive else {
            if let editor {
                isEndingEditing = true
                editor.removeFromSuperview()
                self.editor = nil
                isEndingEditing = false
            }
            return
        }
        let sheet = document.activeSheet
        let metrics = state.metrics
        let frame = metrics.frame(for: sheet.mergedRange(containing: address) ?? CellRange(address))
        let host = editorHost(for: address, in: sheet)
        let field = editor ?? makeEditor(in: host)
        let isFormula = state.editingText.hasPrefix("=")
        let style = sheet[address].style
        field.font = isFormula
            ? .monospacedSystemFont(ofSize: 13 * metrics.zoom, weight: .regular)
            : CellRenderer.font(for: style, zoom: metrics.zoom)
        field.padding = 6 * metrics.zoom
        field.textColor = .labelColor
        // At least the cell, and wide enough for what is typed, as Excel's
        // editor grows over its neighbours.
        if field.stringValue != state.editingText { field.stringValue = state.editingText }
        let needed = field.attributedStringValue.size().width + 12 * metrics.zoom + 4
        field.frame = CGRect(x: frame.minX, y: frame.minY, width: max(frame.width, min(needed, 600)), height: frame.height)
        // A frozen cell is edited in the pane that shows it, which shares
        // the sheet's coordinates; the grid beneath would be covered.
        if field.superview !== host {
            let hadFocus = window?.firstResponder === field.currentEditor()
            isEndingEditing = true
            field.removeFromSuperview()
            host.addSubview(field)
            isEndingEditing = false
            if hadFocus { window?.makeFirstResponder(field) }
        }
    }

    private func editorHost(for address: CellAddress, in sheet: Worksheet) -> NSView {
        let inRows = address.row < sheet.frozenRows, inColumns = address.column < sheet.frozenColumns
        let part: FrozenPaneView.Part? = inRows && inColumns ? .corner : (inRows ? .rows : (inColumns ? .columns : nil))
        return panes.first { $0.part == part && !$0.isHidden } ?? self
    }

    private func makeEditor(in host: NSView) -> CellEditorField {
        let field = CellEditorField()
        field.delegate = self
        host.addSubview(field)
        editor = field
        return field
    }

    /// After a reference is pointed at, shows the formula as it now reads,
    /// with the caret at its end.
    private func showEditedText(in document: WorkbookDocument) {
        document.notify()
        if document.state.isFormulaBarActive, let bar = formulaBarField?() {
            bar.stringValue = document.state.editingText
            window?.makeFirstResponder(bar)
            bar.currentEditor()?.selectedRange = NSRange(location: bar.stringValue.utf16.count, length: 0)
        } else if let editor {
            window?.makeFirstResponder(editor)
            editor.currentEditor()?.selectedRange = NSRange(location: editor.stringValue.utf16.count, length: 0)
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let document, let editor else { return }
        document.state.editingText = editor.stringValue
        document.notify()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(insertNewline(_:)):
            commitEditing(then: NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? .up : .down)
        case #selector(insertTab(_:)):
            commitEditing(then: .right)
        case #selector(insertBacktab(_:)):
            commitEditing(then: .left)
        case #selector(cancelOperation(_:)):
            cancelEditing()
        case #selector(moveUp(_:)) where isEnteringByTyping:
            commitEditing(then: .up)
        case #selector(moveDown(_:)) where isEnteringByTyping:
            commitEditing(then: .down)
        case #selector(moveLeft(_:)) where isEnteringByTyping:
            commitEditing(then: .left)
        case #selector(moveRight(_:)) where isEnteringByTyping:
            commitEditing(then: .right)
        default:
            return false
        }
        return true
    }

    /// Clicking away from the editor, anywhere but the formula bar, keeps
    /// what was typed.
    func controlTextDidEndEditing(_ notification: Notification) {
        guard !isEndingEditing, let document, document.state.editingAddress != nil,
              !document.state.isFormulaBarActive else { return }
        if let bar = formulaBarField?(), window?.firstResponder === bar.currentEditor() { return }
        commitEditing(then: nil)
    }

    // MARK: - Charts and pictures

    /// Keeps a view for each chart and picture near the window.
    private func syncObjects(in document: WorkbookDocument) {
        let state = document.state
        let sheet = document.activeSheet
        let metrics = state.metrics
        var wanted: Set<AnyHashable> = []
        let controlIDs = Set(sheet.formControls.map(\.id))

        if !sheet.isChartSheet {
            for chart in sheet.charts {
                let frame = chart.placement.frame(in: metrics)
                guard frame.width > 0, frame.height > 0 else { continue }
                let key = AnyHashable(chart.id)
                wanted.insert(key)
                let view = objectViews[key] ?? addObject(key, content: ChartContentView())
                (view.content as? ChartContentView)?.show(chart, data: chart.resolved(in: document.workbook), zoom: metrics.zoom)
                view.configure(frame: frame, isSelected: state.selectedChartID == chart.id, isMovable: true,
                               isResizable: true, keepsAspectRatio: false)
                view.onSelect = { [weak self] in self?.selectObject(chart: chart.id) }
                view.onCommit = { [weak self] frame in self?.moveObject(chart: chart.id, to: frame) }
                view.onDoubleClick = { [weak self] in
                    NSApp.sendAction(#selector(WorkbookViewController.editChart(_:)), to: nil, from: self)
                }
                view.menu = chartMenu()
            }
        }
        for anchor in sheet.preservedDrawingAnchors {
            guard let placement = anchor.placement, !(anchor.vmlShapeID.map(controlIDs.contains) ?? false) else { continue }
            let frame = placement.frame(in: metrics)
            guard frame.width > 0, frame.height > 0 else { continue }
            let key = AnyHashable(anchor.id)
            wanted.insert(key)
            let image = anchor.picture.flatMap { picture in
                document.workbook.preservedPackage.parts[picture.target].flatMap {
                    PictureCache.shared.image(for: picture, data: $0)
                }
            }
            let view = objectViews[key] ?? addObject(key, content: PictureContentView())
            (view.content as? PictureContentView)?.show(image, isChart: anchor.isChart)
            view.configure(frame: frame, isSelected: state.selectedDrawingID == anchor.id,
                           isMovable: !anchor.locks.noMove, isResizable: !anchor.locks.noResize,
                           keepsAspectRatio: anchor.locks.noChangeAspect)
            view.onSelect = { [weak self] in self?.selectObject(drawing: anchor.id) }
            view.onCommit = { [weak self] frame in self?.moveObject(drawing: anchor.id, to: frame) }
            view.onDoubleClick = {}
            view.menu = nil
        }
        for (key, view) in objectViews where !wanted.contains(key) {
            view.removeFromSuperview()
            objectViews[key] = nil
        }
    }

    private func addObject(_ key: AnyHashable, content: NSView) -> FloatingObjectView {
        let view = FloatingObjectView(content: content)
        addSubview(view)
        objectViews[key] = view
        return view
    }

    private func selectObject(chart: Chart.ID? = nil, drawing: PreservedDrawingAnchor.ID? = nil) {
        guard let document else { return }
        let state = document.state
        if state.editingAddress != nil { commitEditing(then: nil) }
        if let chart { state.selectChart(chart) } else { state.selectDrawing(drawing) }
        window?.makeFirstResponder(self)
        document.notify()
    }

    private func moveObject(chart: Chart.ID? = nil, drawing: PreservedDrawingAnchor.ID? = nil, to frame: CGRect) {
        guard let document else { return }
        let state = document.state
        let zoom = state.metrics.zoom
        let unzoomed = CGRect(x: frame.minX / zoom, y: frame.minY / zoom, width: frame.width / zoom, height: frame.height / zoom)
        if let chart {
            document.edit { state.moveChart(chart, to: unzoomed, in: &$0) }
        } else if let drawing {
            document.edit { state.moveDrawing(drawing, to: unzoomed, in: &$0) }
        }
    }

    private func chartMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(MainMenu.item(String(localized: "Toolbar.EditChart"),
                                   #selector(WorkbookViewController.editChart(_:))))
        menu.addItem(MainMenu.item(String(localized: "Mac.Menu.MoveChartToSheet"),
                                   #selector(WorkbookViewController.moveChartToNewSheet(_:))))
        menu.addItem(.separator())
        menu.addItem(MainMenu.item(String(localized: "Mac.Menu.Delete"), #selector(NSText.delete(_:))))
        return menu
    }
}

/// The text field the grid edits a cell in, laid out exactly as the cell
/// draws its text — same padding, same vertical centring — so opening the
/// editor leaves the glyphs where they were.
final class CellEditorField: NSTextField {
    override class var cellClass: AnyClass? {
        get { CellEditorCell.self }
        set { _ = newValue }
    }

    init() {
        super.init(frame: .zero)
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        usesSingleLineMode = true
        cell?.isScrollable = true
        cell?.wraps = false
        lineBreakMode = .byClipping
        setAccessibilityIdentifier("cellEditor")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The horizontal padding the cell's text has, at the grid's zoom.
    var padding: CGFloat {
        get { (cell as? CellEditorCell)?.padding ?? 6 }
        set { (cell as? CellEditorCell)?.padding = newValue }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        super.draw(dirtyRect)
        let ring = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        ring.lineWidth = 2
        NSColor.controlAccentColor.setStroke()
        ring.stroke()
    }
}

/// Keeps the editor's one line of text centred in the cell and padded from
/// its edges, while it is shown and while it is being typed in.
final class CellEditorCell: NSTextFieldCell {
    var padding: CGFloat = 6

    private func textRect(forBounds rect: NSRect) -> NSRect {
        let height = ceil((font ?? .systemFont(ofSize: 12)).boundingRectForFont.height)
        let lineHeight = min(rect.height, ceil(cellSize(forBounds: rect).height))
        let box = rect.insetBy(dx: padding, dy: 0)
        let used = max(lineHeight, min(height, rect.height))
        return NSRect(x: box.minX, y: rect.midY - used / 2, width: max(0, box.width), height: used)
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect { textRect(forBounds: rect) }
    override func drawingRect(forBounds rect: NSRect) -> NSRect { textRect(forBounds: rect) }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText,
                       delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: textRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText,
                         delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: textRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate,
                     start: selStart, length: selLength)
    }
}

/// The colours a formula's references are told apart by, both where they
/// are outlined on the grid and where they are written in the formula bar.
enum ReferenceColors {
    private static let palette: [NSColor] = [
        .systemBlue, .systemRed, .systemPurple, .systemGreen,
        .systemOrange, .systemTeal, .systemPink, .systemBrown,
    ]

    static func color(at index: Int) -> NSColor { palette[index % palette.count] }
}
