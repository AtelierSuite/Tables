import Foundation
import TablesEngine

/// The editing session behind one browser window: the document, the selection
/// and undo. A port of the Apple apps' `EditorState` and `EditorActions`
/// without SwiftUI, calling the same engine functions so editing behaves the
/// same everywhere. Text being typed lives in the page until it is committed.
final class WebSession {
    enum MoveDirection: String { case up, down, left, right }

    struct Snapshot {
        var workbook: Workbook
        var activeSheetID: Worksheet.ID?
        var selection: CellRange
        var anchor: CellAddress
    }

    var document: WebDocument
    var activeSheetID: Worksheet.ID?
    var selection = CellRange(CellAddress(row: 0, column: 0))
    var additionalSelections: [CellRange] = []
    var anchor = CellAddress(row: 0, column: 0)

    var clipboard: [[Cell]]?
    var clipboardComments: [[CellComment?]] = []
    var clipboardOrigin: CellAddress?
    /// The text the last copy put on the system clipboard, so a paste of that
    /// same text can use the cells themselves, formulas and formatting included.
    var clipboardText: String?

    private(set) var undoStack: [Snapshot] = []
    private(set) var redoStack: [Snapshot] = []
    private static let undoLimit = 200

    /// Bumped whenever the document changes, so the page knows to redraw.
    private(set) var contentVersion = 0
    /// Bumped whenever row and column geometry, or the active sheet, changes.
    private(set) var layoutVersion = 0
    /// Changes since the last save.
    private(set) var isDirty = false
    /// A message for the user from the last action, such as why it couldn't happen.
    var message: String?

    var workbook: Workbook {
        get { document.workbook }
        set { document.workbook = newValue }
    }

    init(document: WebDocument) {
        self.document = document
        activeSheetID = document.workbook.visibleSheets.first?.id ?? document.workbook.sheets.first?.id
    }

    // MARK: - Sheet resolution

    var activeIndex: Int {
        if let activeSheetID, let index = workbook.index(of: activeSheetID) { return index }
        return 0
    }

    var activeSheet: Worksheet { workbook.sheets[activeIndex] }

    var formatting: FormattingKinds { document.formatting(in: activeSheet.id) }
    var allowsComments: Bool { !document.isPlainText && !document.isNumbers }
    var allowsFreezingPanes: Bool { !document.isPlainText && !document.isNumbers }
    var allowsInsertingAndDeleting: Bool { document.allowsMovingCells(in: activeSheet.id) }
    /// Moving and naming the tables on a canvas, which Numbers documents keep
    /// too; delimited text has no tables to lay out.
    var allowsLayingOutTables: Bool { !document.isPlainText }
    /// Putting sheets together on a canvas, or taking them off one, which
    /// only workbooks can keep.
    var allowsArrangingCanvases: Bool { !document.isPlainText && !document.isNumbers }

    func selectSheet(_ id: Worksheet.ID) {
        guard workbook[id] != nil else { return }
        activeSheetID = id
        selection = CellRange(CellAddress(row: 0, column: 0))
        additionalSelections = []
        anchor = CellAddress(row: 0, column: 0)
        layoutVersion += 1
    }

    // MARK: - Changes and undo

    /// Runs a change to the document as one undoable step.
    func change(layout: Bool = false, _ body: () -> Void) {
        let before = snapshot()
        let previous = workbook
        body()
        guard workbook != previous else { return }
        undoStack.append(before)
        if undoStack.count > Self.undoLimit { undoStack.removeFirst() }
        redoStack.removeAll()
        markChanged(layout: layout)
    }

    func markChanged(layout: Bool) {
        contentVersion += 1
        if layout { layoutVersion += 1 }
        isDirty = true
    }

    func markSaved() {
        isDirty = false
    }

    private func snapshot() -> Snapshot {
        Snapshot(workbook: workbook, activeSheetID: activeSheetID, selection: selection, anchor: anchor)
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(snapshot())
        restore(previous)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(snapshot())
        restore(next)
    }

    /// Brings the sheet that changed into view and lets go of anything the
    /// change took away, as the Apple apps' `showRestored` does.
    private func restore(_ snapshot: Snapshot) {
        let previous = workbook
        workbook = snapshot.workbook
        if let changed = workbook.changedSheetID(from: previous), changed != activeSheetID {
            activeSheetID = changed
        } else if activeSheetID.flatMap({ workbook[$0] }) == nil {
            activeSheetID = snapshot.activeSheetID
        }
        if activeSheetID == snapshot.activeSheetID {
            selection = snapshot.selection
            anchor = snapshot.anchor
        }
        additionalSelections = []
        clampSelection()
        markChanged(layout: true)
    }

    // MARK: - Selection

    var selectedAddress: CellAddress { selection.normalized.start }
    var selectedRanges: [CellRange] { additionalSelections + [selection] }
    var hasMultipleSelections: Bool { !additionalSelections.isEmpty }

    /// Keeps the selection inside the sheet after rows or columns disappear.
    func clampSelection() {
        let sheet = activeSheet
        func clamp(_ address: CellAddress) -> CellAddress {
            CellAddress(
                row: min(max(0, address.row), max(0, sheet.rowCount - 1)),
                column: min(max(0, address.column), max(0, sheet.columnCount - 1))
            )
        }
        selection = sheet.expandedToMerges(CellRange(start: clamp(selection.start), end: clamp(selection.end)))
        additionalSelections = additionalSelections.map {
            sheet.expandedToMerges(CellRange(start: clamp($0.start), end: clamp($0.end)))
        }
        anchor = clamp(anchor)
    }

    /// Selects a cell, growing the range to cover any merged region it falls
    /// inside so that clicking anywhere in a merge selects the whole of it.
    func select(_ address: CellAddress, extending: Bool = false) {
        let sheet = activeSheet
        if extending {
            let raw = CellRange(start: anchor, end: address)
            let expanded = sheet.expandedToMerges(raw)
            selection = expanded == raw.normalized ? raw : expanded
        } else {
            let merge = sheet.mergedRange(containing: address)
            anchor = merge?.normalized.start ?? address
            selection = merge ?? CellRange(address)
            additionalSelections = []
        }
    }

    /// Starts another range beside the ones already selected (Command-click).
    func addRange(startingAt address: CellAddress) {
        let sheet = activeSheet
        let completed = selection.normalized
        if !additionalSelections.contains(completed) { additionalSelections.append(completed) }
        let merge = sheet.mergedRange(containing: address)
        anchor = merge?.normalized.start ?? address
        selection = merge ?? CellRange(address)
    }

    func selectEntireRows(_ range: ClosedRange<Int>) {
        let sheet = activeSheet
        additionalSelections = []
        anchor = CellAddress(row: range.lowerBound, column: 0)
        selection = CellRange(start: anchor, end: CellAddress(row: range.upperBound, column: max(0, sheet.columnCount - 1)))
    }

    func selectEntireColumns(_ range: ClosedRange<Int>) {
        let sheet = activeSheet
        additionalSelections = []
        anchor = CellAddress(row: 0, column: range.lowerBound)
        selection = CellRange(start: anchor, end: CellAddress(row: max(0, sheet.rowCount - 1), column: range.upperBound))
    }

    func selectAll() {
        let sheet = activeSheet
        additionalSelections = []
        anchor = CellAddress(row: 0, column: 0)
        selection = CellRange(
            start: anchor, end: CellAddress(row: max(0, sheet.rowCount - 1), column: max(0, sheet.columnCount - 1)))
    }

    func move(_ direction: MoveDirection, extending: Bool = false) {
        let sheet = activeSheet
        let origin = extending ? selection.end : stepOrigin(for: direction)
        var row = origin.row
        var column = origin.column
        switch direction {
        case .up: row -= 1
        case .down: row += 1
        case .left: column -= 1
        case .right: column += 1
        }
        // Skip over hidden lines so arrow keys never land somewhere invisible.
        while row > 0, row < sheet.rowCount, sheet.hiddenRows.contains(row) {
            row += (direction == .up) ? -1 : (direction == .down ? 1 : 0)
            if direction != .up && direction != .down { break }
        }
        while column > 0, column < sheet.columnCount, sheet.hiddenColumns.contains(column) {
            column += (direction == .left) ? -1 : (direction == .right ? 1 : 0)
            if direction != .left && direction != .right { break }
        }
        var target = CellAddress(
            row: min(max(0, row), max(0, sheet.rowCount - 1)),
            column: min(max(0, column), max(0, sheet.columnCount - 1))
        )
        if !extending, let merge = sheet.mergedRange(containing: target) {
            target = merge.normalized.start
        }
        select(target, extending: extending)
    }

    /// Jumps to the edge of the data in a direction, as Command-arrow does: to
    /// the last filled cell of a run, or the next filled cell past a gap.
    func moveToEdge(_ direction: MoveDirection, extending: Bool = false) {
        let sheet = activeSheet
        let origin = extending ? selection.end : selectedAddress
        let step: (Int, Int)
        switch direction {
        case .up: step = (-1, 0)
        case .down: step = (1, 0)
        case .left: step = (0, -1)
        case .right: step = (0, 1)
        }
        func filled(_ address: CellAddress) -> Bool { !sheet[address].isBlank }
        func inside(_ address: CellAddress) -> Bool {
            address.row >= 0 && address.column >= 0 && address.row < sheet.rowCount && address.column < sheet.columnCount
        }
        var current = origin
        var next = CellAddress(row: current.row + step.0, column: current.column + step.1)
        guard inside(next) else { return }
        if filled(current) && filled(next) {
            while inside(next), filled(next) {
                current = next
                next = CellAddress(row: current.row + step.0, column: current.column + step.1)
            }
        } else {
            current = next
            while inside(current), !filled(current) {
                let ahead = CellAddress(row: current.row + step.0, column: current.column + step.1)
                guard inside(ahead) else { break }
                current = ahead
            }
        }
        select(current, extending: extending)
    }

    private func stepOrigin(for direction: MoveDirection) -> CellAddress {
        guard let merge = activeSheet.mergedRange(containing: selectedAddress)?.normalized else { return selectedAddress }
        switch direction {
        case .down, .right: return merge.end
        case .up, .left: return merge.start
        }
    }

    func forEachSelectedAddress(_ body: (CellAddress) -> Void) {
        let ranges = selectedRanges
        for (index, range) in ranges.enumerated() {
            range.forEachAddress { address in
                guard !ranges[..<index].contains(where: { $0.contains(address) }) else { return }
                body(address)
            }
        }
    }

    func selectedStoredAddresses() -> [CellAddress] {
        let sheet = activeSheet
        let ranges = selectedRanges
        guard ranges.count > 1 else { return sheet.storedAddresses(in: selection) }
        var result: [CellAddress] = []
        for (index, range) in ranges.enumerated() {
            for address in sheet.storedAddresses(in: range) where !ranges[..<index].contains(where: { $0.contains(address) }) {
                result.append(address)
            }
        }
        return result
    }

    // MARK: - Editing

    /// The text the cell editor opens with: a formula with its `=`, or the value as typed.
    var editableText: String {
        let sheet = activeSheet
        let target = sheet.mergedRange(containing: selectedAddress)?.normalized.start ?? selectedAddress
        return sheet[target].editableText
    }

    /// Writes typed text into the selected cell and recalculates, then moves on.
    func commit(_ text: String, at address: CellAddress, then advance: MoveDirection?) {
        let index = activeIndex
        let sheet = workbook.sheets[index]
        guard sheet.contains(address) else { return }
        let target = sheet.mergedRange(containing: address)?.normalized.start ?? address
        change {
            let existing = workbook.sheets[index][target]
            workbook.sheets[index][target] = CellInputParser.cell(from: text, inheriting: existing.style)
            workbook.recalculate()
        }
        select(target)
        if let advance { move(advance) }
    }

    /// Ticks a checkbox, or clears it. A checkbox showing what a formula came to is the formula's to change.
    func toggleCheckbox(at address: CellAddress) {
        let index = activeIndex
        let cell = workbook.sheets[index][address]
        guard cell.style.showsCheckbox, cell.formula == nil, case .boolean(let isOn) = cell.value else { return }
        change {
            workbook.sheets[index][address].value = .boolean(!isOn)
            workbook.recalculate()
        }
    }

    func clearContents() {
        let index = activeIndex
        let targets = selectedStoredAddresses()
        guard !targets.isEmpty else { return }
        change {
            for address in targets {
                var cell = workbook.sheets[index][address]
                cell.value = .empty
                cell.formula = nil
                workbook.sheets[index][address] = cell
            }
            workbook.recalculate()
        }
    }

    func clearFormatting() {
        guard !formatting.isEmpty else { return }
        let index = activeIndex
        change {
            for address in selectedStoredAddresses() {
                var cell = workbook.sheets[index][address]
                cell.style = .default
                workbook.sheets[index][address] = cell
            }
        }
    }

    // MARK: - Formatting

    var representativeStyle: CellStyle { activeSheet[selectedAddress].style }

    func applyStyle(_ transform: (inout CellStyle) -> Void) {
        guard !formatting.isEmpty else { return }
        let index = activeIndex
        change {
            // A change that leaves the default alone cannot show on a cell the
            // sheet never stored, so only stored cells are touched for it.
            var probe = CellStyle.default
            transform(&probe)
            guard !probe.isDefault else {
                for address in selectedStoredAddresses() {
                    var cell = workbook.sheets[index][address]
                    transform(&cell.style)
                    workbook.sheets[index][address] = cell
                }
                return
            }
            forEachSelectedAddress { address in
                guard workbook.sheets[index].contains(address) else { return }
                var cell = workbook.sheets[index][address]
                transform(&cell.style)
                workbook.sheets[index][address] = cell
            }
        }
    }

    // MARK: - Structure

    private var selectedRowRange: ClosedRange<Int> {
        let box = selection.normalized
        return box.start.row...min(box.end.row, max(0, activeSheet.rowCount - 1))
    }

    private var selectedColumnRange: ClosedRange<Int> {
        let box = selection.normalized
        return box.start.column...min(box.end.column, max(0, activeSheet.columnCount - 1))
    }

    private func allowsInsertingOrDeleting() -> Bool {
        guard allowsInsertingAndDeleting else {
            message = NumbersEditPolicy.Violation.movingCells.localizedDescription
            return false
        }
        return true
    }

    func addRows(_ count: Int = 1) {
        let index = activeIndex
        change(layout: true) { workbook.sheets[index].addRows(count) }
    }

    func addColumns(_ count: Int = 1) {
        let index = activeIndex
        change(layout: true) { workbook.sheets[index].addColumns(count) }
    }

    func insertRows(above: Bool) {
        guard allowsInsertingOrDeleting() else { return }
        let index = activeIndex
        let range = selectedRowRange
        let target = above ? range.lowerBound : range.upperBound + 1
        change(layout: true) {
            let snapshot = workbook
            workbook.sheets[index].insertRows(range.count, at: target)
            workbook.chartsFollow(.insert(index: target, count: range.count), axis: .row, on: workbook.sheets[index].id, before: snapshot)
            workbook.recalculate()
        }
        clampSelection()
    }

    func insertColumns(before: Bool) {
        guard allowsInsertingOrDeleting() else { return }
        let index = activeIndex
        let range = selectedColumnRange
        let target = before ? range.lowerBound : range.upperBound + 1
        change(layout: true) {
            let snapshot = workbook
            workbook.sheets[index].insertColumns(range.count, at: target)
            workbook.chartsFollow(.insert(index: target, count: range.count), axis: .column, on: workbook.sheets[index].id, before: snapshot)
            workbook.recalculate()
        }
        clampSelection()
    }

    func deleteSelectedRows() {
        guard allowsInsertingOrDeleting() else { return }
        let index = activeIndex
        let rows = selectedRowRange
        change(layout: true) {
            let snapshot = workbook
            workbook.sheets[index].removeRows(rows)
            workbook.chartsFollow(.remove(range: rows), axis: .row, on: workbook.sheets[index].id, before: snapshot)
            workbook.recalculate()
        }
        clampSelection()
    }

    func deleteSelectedColumns() {
        guard allowsInsertingOrDeleting() else { return }
        let index = activeIndex
        let columns = selectedColumnRange
        change(layout: true) {
            let snapshot = workbook
            workbook.sheets[index].removeColumns(columns)
            workbook.chartsFollow(.remove(range: columns), axis: .column, on: workbook.sheets[index].id, before: snapshot)
            workbook.recalculate()
        }
        clampSelection()
    }

    func setSelectedRows(hidden: Bool) {
        let index = activeIndex
        let rows = selectedRowRange
        change(layout: true) { workbook.sheets[index].setRows(rows, hidden: hidden) }
    }

    func setSelectedColumns(hidden: Bool) {
        let index = activeIndex
        let columns = selectedColumnRange
        change(layout: true) { workbook.sheets[index].setColumns(columns, hidden: hidden) }
    }

    func unhideEverything() {
        let index = activeIndex
        change(layout: true) { workbook.sheets[index].unhideAll() }
    }

    func resizeColumn(_ column: Int, to width: Double) {
        let index = activeIndex
        change(layout: true) { workbook.sheets[index].columnWidths[column] = max(Worksheet.minimumColumnWidth, width) }
    }

    func resizeRow(_ row: Int, to height: Double) {
        let index = activeIndex
        change(layout: true) {
            workbook.sheets[index].rowHeights[row] = max(Worksheet.minimumRowHeight, height)
            workbook.sheets[index].fittedRows.remove(row)
        }
    }

    /// Sizes a column to its widest visible entry, from measured widths the page supplies when it can.
    func fitColumn(_ column: Int, measuredWidth: Double?) {
        let index = activeIndex
        let sheet = workbook.sheets[index]
        var widest = Worksheet.minimumColumnWidth
        if let measuredWidth {
            widest = max(widest, measuredWidth + 14)
        } else {
            for (address, cell) in sheet.cells where address.column == column && !sheet.hiddenRows.contains(address.row) {
                let text = CellFormatter.displayText(for: cell)
                guard !text.isEmpty else { continue }
                widest = max(widest, Double(text.count) * cell.style.fontSize * 0.62 + 20)
            }
        }
        change(layout: true) { workbook.sheets[index].columnWidths[column] = min(420, widest) }
    }

    // MARK: - Merged cells

    var canMergeSelection: Bool {
        let sheet = activeSheet
        let box = sheet.expandedToMerges(selection)
        return formatting.contains(.merging) && !box.isSingleCell && !sheet.mergedRanges.contains(box)
    }

    var canUnmergeSelection: Bool {
        formatting.contains(.merging) && activeSheet.mergedRanges.contains { $0.intersects(selection.normalized) }
    }

    func mergeSelection() {
        let index = activeIndex
        let box = workbook.sheets[index].expandedToMerges(selection)
        guard !box.isSingleCell else { return }
        var merged = true
        change(layout: true) {
            guard workbook.sheets[index].merge(box) else {
                merged = false
                return
            }
            for address in workbook.sheets[index].storedAddresses(in: box) where address != box.start {
                workbook.sheets[index][address] = Cell()
            }
            workbook.recalculate()
        }
        guard merged else {
            message = String(localized: "Error.Merge.CrossesExistingMerge", bundle: nil)
            return
        }
        anchor = box.start
        selection = box
        additionalSelections = []
    }

    func unmergeSelection() {
        let index = activeIndex
        let box = selection.normalized
        change(layout: true) { workbook.sheets[index].unmerge(box) }
    }

    // MARK: - Clipboard

    /// Copies the selection and returns it as tab-separated text for the system clipboard.
    func copySelection() -> String {
        let sheet = activeSheet
        let box = selection.normalized
        clipboard = box.rowRange.map { row in box.columnRange.map { sheet[CellAddress(row: row, column: $0)] } }
        clipboardComments = box.rowRange.map { row in box.columnRange.map { sheet.comments[CellAddress(row: row, column: $0)] } }
        clipboardOrigin = box.start
        let text = plainText(for: box, in: sheet)
        clipboardText = text
        return text
    }

    func cutSelection() -> String {
        let text = copySelection()
        let index = activeIndex
        let box = selection.normalized
        change {
            for address in workbook.sheets[index].storedAddresses(in: box) {
                var cell = workbook.sheets[index][address]
                cell.value = .empty
                cell.formula = nil
                workbook.sheets[index][address] = cell
            }
            workbook.sheets[index].comments = workbook.sheets[index].comments.filter { !box.contains($0.key) }
            workbook.recalculate()
        }
        return text
    }

    /// Pastes the system clipboard's text. When it is what this window last
    /// copied, the cells themselves go in, formulas, formatting and comments included.
    func paste(text: String?) {
        if let clipboard, !clipboard.isEmpty, text == nil || text == clipboardText {
            paste(cells: clipboard, comments: clipboardComments, from: clipboardOrigin)
            return
        }
        guard let text, !text.isEmpty else { return }
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        if lines.count > 1, lines.last == "" { lines.removeLast() }
        let cells = lines.map { line in
            line.split(separator: "\t", omittingEmptySubsequences: false).map { CellInputParser.cell(from: String($0), inheriting: .default) }
        }
        paste(cells: cells)
    }

    private func paste(cells: [[Cell]], comments: [[CellComment?]] = [], from source: CellAddress? = nil) {
        let index = activeIndex
        let origin = selection.normalized.start
        var lastRow = origin.row
        var lastColumn = origin.column
        change {
            for (rowOffset, row) in cells.enumerated() {
                for (columnOffset, original) in row.enumerated() {
                    let address = CellAddress(row: origin.row + rowOffset, column: origin.column + columnOffset)
                    guard workbook.sheets[index].contains(address) else { continue }
                    var cell = original
                    if let formula = cell.formula, let source {
                        cell.formula = FormulaReferenceShifter.translated(
                            formula, rowDelta: origin.row - source.row, columnDelta: origin.column - source.column)
                    }
                    cell.isSpilled = false
                    workbook.sheets[index][address] = cell
                    if rowOffset < comments.count, columnOffset < comments[rowOffset].count {
                        workbook.sheets[index].comments[address] = comments[rowOffset][columnOffset]
                    }
                    lastRow = max(lastRow, address.row)
                    lastColumn = max(lastColumn, address.column)
                }
            }
            workbook.recalculate()
        }
        anchor = origin
        selection = CellRange(start: origin, end: CellAddress(row: lastRow, column: lastColumn))
        additionalSelections = []
    }

    private func plainText(for range: CellRange, in sheet: Worksheet) -> String {
        range.rowRange.map { row in
            range.columnRange.map { CellFormatter.displayText(for: sheet[CellAddress(row: row, column: $0)]) }.joined(separator: "\t")
        }
        .joined(separator: "\n")
    }

    // MARK: - Frozen panes

    func freezePanes(rows: Int, columns: Int) {
        guard allowsFreezingPanes else { return }
        let index = activeIndex
        let sheet = workbook.sheets[index]
        change(layout: true) {
            workbook.sheets[index].frozenRows = min(max(0, rows), max(0, sheet.rowCount - 1))
            workbook.sheets[index].frozenColumns = min(max(0, columns), max(0, sheet.columnCount - 1))
        }
    }

    func freezePanesAtSelection() {
        let start = selection.normalized.start
        freezePanes(rows: start.row, columns: start.column)
    }

    // MARK: - Fill and move

    func fillSelection(to target: CellRange) {
        let index = activeIndex
        let source = selection.normalized
        guard !hasMultipleSelections else { return }
        var filled = false
        change {
            filled = workbook.sheets[index].autoFill(from: source, to: target)
            if filled { workbook.recalculate() }
        }
        guard filled else { return }
        anchor = target.normalized.start
        selection = target.normalized
    }

    func moveSelection(to destination: CellAddress, copying: Bool) {
        let index = activeIndex
        let source = selection.normalized
        guard !hasMultipleSelections else { return }
        var moved = false
        change {
            moved = workbook.moveCells(source, on: workbook.sheets[index].id, to: destination, copying: copying)
        }
        guard moved else { return }
        anchor = destination
        selection = CellRange(
            start: destination,
            end: CellAddress(row: destination.row + source.end.row - source.start.row,
                             column: destination.column + source.end.column - source.start.column))
    }

    // MARK: - Sheets

    func addSheet() {
        var id: Worksheet.ID?
        change(layout: true) { id = workbook.addSheet() }
        if let id { selectSheet(id) }
    }

    func duplicateActiveSheet() {
        let source = activeSheet.id
        var id: Worksheet.ID?
        change(layout: true) { id = workbook.duplicateSheet(source) }
        if let id { selectSheet(id) }
    }

    func deleteSheet(_ id: Worksheet.ID) {
        guard workbook.sheets.count > 1 else {
            message = String(localized: "Error.Workbook.NeedsOneSheet", bundle: nil)
            return
        }
        let wasActive = activeSheet.id == id
        change(layout: true) { _ = workbook.removeSheet(id) }
        if wasActive, let first = workbook.visibleSheets.first { selectSheet(first.id) }
    }

    func renameSheet(_ id: Worksheet.ID, to name: String) {
        change { workbook.renameSheet(id, to: name) }
    }

    func setSheet(_ id: Worksheet.ID, hidden: Bool) {
        var allowed = true
        change(layout: true) { allowed = workbook.setSheet(id, hidden: hidden) }
        guard allowed else {
            message = String(localized: "Error.Workbook.NeedsOneVisibleSheet", bundle: nil)
            return
        }
        if hidden {
            guard activeSheet.id == id, let replacement = workbook.visibleSheets.first else { return }
            selectSheet(replacement.id)
        } else {
            selectSheet(id)
        }
    }

    func setSheetColor(_ id: Worksheet.ID, hex: String?) {
        guard let index = workbook.index(of: id) else { return }
        change { workbook.sheets[index].tabColorHex = hex }
    }

    func moveSheet(_ id: Worksheet.ID, to position: Int) {
        guard workbook.index(of: id) != nil else { return }
        // The workbook keeps a canvas's sheets together as they move.
        change { workbook.moveSheet(id, to: position) }
    }

    // MARK: - Canvases

    /// Sheets laid out together on one page, as a Numbers sheet holds its
    /// tables: the same actions as the Apple apps' `CanvasActions`.

    /// Adds a new table below the active sheet, on the canvas it is on or a
    /// new one with it, and goes to it.
    func addTable() {
        guard allowsArrangingCanvases else { return }
        let anchor = activeSheet.id
        let index = (workbook.index(of: anchor) ?? workbook.sheets.count - 1) + 1
        var id: Worksheet.ID?
        change(layout: true) {
            id = workbook.addSheet(at: index)
            if let id { workbook.placeSheet(id, onCanvasWith: anchor) }
        }
        if let id { selectSheet(id) }
    }

    /// Lays a sheet out on the canvas another is on, starting one when that
    /// sheet has the page to itself.
    func placeSheet(_ id: Worksheet.ID, onCanvasWith target: Worksheet.ID) {
        guard allowsArrangingCanvases else { return }
        change(layout: true) { workbook.placeSheet(id, onCanvasWith: target) }
        selectSheet(id)
    }

    /// Takes a sheet off its canvas, back to a sheet of its own.
    func removeFromCanvas(_ id: Worksheet.ID) {
        guard allowsArrangingCanvases else { return }
        change(layout: true) { workbook.removeFromCanvas(id) }
        selectSheet(id)
    }

    /// Moves a table on its canvas, to a place in points at 100%.
    func moveTable(_ id: Worksheet.ID, toX x: Double, y: Double) {
        guard allowsLayingOutTables else { return }
        change { workbook.moveTable(id, toX: x, y: y) }
    }

    func setTableNameShown(_ shown: Bool, for id: Worksheet.ID) {
        guard allowsLayingOutTables,
              let canvas = workbook.canvases.firstIndex(where: { $0.contains(id) }),
              let table = workbook.canvases[canvas].tables.firstIndex(where: { $0.sheetID == id }) else { return }
        change { workbook.canvases[canvas].tables[table].showsName = shown }
    }

    /// Renames a table: its own name where it has one, as a Numbers table
    /// does, and otherwise its sheet, as Excel knows it.
    func renameTable(_ id: Worksheet.ID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard allowsLayingOutTables, !trimmed.isEmpty else { return }
        if let canvas = workbook.canvases.firstIndex(where: { $0.contains(id) }),
           let table = workbook.canvases[canvas].tables.firstIndex(where: { $0.sheetID == id }),
           workbook.canvases[canvas].tables[table].name != nil {
            change { workbook.canvases[canvas].tables[table].name = trimmed }
        } else {
            let sanitized = Worksheet.sanitizedName(trimmed)
            guard !sanitized.isEmpty else { return }
            change { workbook.renameSheet(id, to: sanitized) }
        }
    }

    /// Renames the canvas a sheet is on: its tab.
    func renameCanvas(containing id: Worksheet.ID, to name: String) {
        guard allowsLayingOutTables, let canvas = workbook.canvas(containing: id) else { return }
        change { workbook.renameCanvas(canvas.id, to: name) }
    }

    // MARK: - Quick insert

    /// Wraps the selected range in a function and writes it just past the
    /// range. Returns the text to start editing with when there is no range to wrap.
    func insertAggregate(_ function: String) -> String? {
        let index = activeIndex
        let sheet = workbook.sheets[index]
        let box = selection.normalized
        let target: CellAddress
        let reference: String
        if box.isSingleCell {
            return "=\(function)("
        } else if box.end.row + 1 < sheet.rowCount {
            target = CellAddress(row: box.end.row + 1, column: box.start.column)
            reference = CellRange(start: box.start, end: CellAddress(row: box.end.row, column: box.start.column)).a1
        } else {
            target = CellAddress(row: box.start.row, column: min(box.end.column + 1, sheet.columnCount - 1))
            reference = CellRange(start: box.start, end: CellAddress(row: box.start.row, column: box.end.column)).a1
        }
        change {
            var cell = workbook.sheets[index][target]
            cell.formula = "\(function)(\(reference))"
            cell.value = .empty
            workbook.sheets[index][target] = cell
            workbook.recalculate()
        }
        select(target)
        return nil
    }
}
