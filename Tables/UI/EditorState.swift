import SwiftUI

/// A modal panel presented over the grid. iOS shows these as sheets; macOS uses
/// popovers anchored to the toolbar.
enum EditorPanel: String, Identifiable, Hashable {
    case format
    case numberFormat
    case rowsAndColumns
    case functions
    case chart
    case comment
    case find

    var id: String { rawValue }

    var title: String {
        switch self {
        case .format: return String(localized: "Panel.Format.Title")
        case .numberFormat: return String(localized: "Panel.NumberFormat.Title")
        case .rowsAndColumns: return String(localized: "Panel.RowsAndColumns.Title")
        case .functions: return String(localized: "Panel.Functions.Title")
        case .chart: return String(localized: "Panel.Chart.Title")
        case .comment: return String(localized: "Panel.Comment.Title")
        case .find: return String(localized: "Panel.Find.Title")
        }
    }
}

/// Everything about the editing session that isn't part of the document itself.
@MainActor
@Observable
final class EditorState {
    var activeSheetID: Worksheet.ID?
    var selection = CellRange(CellAddress(row: 0, column: 0))
    /// Ranges selected alongside `selection`, oldest first, from holding one
    /// finger on the sheet and picking further ranges with another. `selection`
    /// is always the newest of them, and the one edits and movement work from.
    var additionalSelections: [CellRange] = []
    /// The cell keyboard entry extends from when the selection is grown.
    var anchor = CellAddress(row: 0, column: 0)
    var editingAddress: CellAddress?
    var editingText = ""
    var isFormulaBarActive = false
    /// The chart picked out on the sheet, which the chart panel edits and the
    /// Delete key removes. On a chart sheet, that sheet's chart.
    var selectedChartID: Chart.ID?
    /// The picture or other kept object picked out on the sheet, which can
    /// then be moved, resized or deleted. Never set alongside a chart.
    var selectedDrawingID: PreservedDrawingAnchor.ID?

    /// Distance scrolled from the top-left of the content, insets removed.
    var scrollOffset = CGPoint.zero
    /// The scroll view's leading/top content insets, needed to convert back to
    /// the raw offsets `ScrollPosition` expects.
    var scrollInsets = CGSize.zero
    var viewportSize = CGSize.zero
    var metrics = SheetMetrics()
    var scrollTarget: CellAddress?

    /// Pinch-to-zoom factor for the grid.
    var zoom: Double = 1
    static let zoomRange: ClosedRange<Double> = 0.5...3

    /// While a formula is being typed, the range most recently inserted into it,
    /// so dragging can grow that reference instead of appending a new one.
    var pendingReferenceRange: CellRange?

    var presentedPanel: EditorPanel?
    /// The kind of comment the comment panel starts when a cell has none.
    var newCommentKind: CellComment.Kind = .thread
    /// False for delimited text, which has nowhere to keep styling.
    var allowsFormatting = true
    /// False for Numbers documents, whose cells keep their styles and
    /// formulas where they are: inserting or deleting rows and columns would
    /// move the values away from them.
    var allowsInsertingAndDeleting = true
    var errorMessage: String?
    var clipboard: [[Cell]]?
    /// The comments on the copied cells, position for position.
    var clipboardComments: [[CellComment?]] = []
    /// Where the copied cells came from, so pasted formulas can move their
    /// relative references by the distance travelled.
    var clipboardOrigin: CellAddress?
    /// Whether the toolbar's popover about parts of the file we cannot edit is up.
    var isShowingUnsupportedFeatureNotice = false

    // MARK: - Sheet resolution

    /// The active sheet's index, falling back to the first sheet.
    func activeIndex(in workbook: Workbook) -> Int {
        if let activeSheetID, let index = workbook.index(of: activeSheetID) { return index }
        return 0
    }

    func activeSheet(in workbook: Workbook) -> Worksheet {
        workbook.sheets[activeIndex(in: workbook)]
    }

    func selectSheet(_ id: Worksheet.ID, in workbook: Workbook) {
        activeSheetID = id
        editingAddress = nil
        selection = CellRange(CellAddress(row: 0, column: 0))
        additionalSelections = []
        anchor = CellAddress(row: 0, column: 0)
        scrollOffset = .zero
        let sheet = workbook[id]
        selectedChartID = sheet?.isChartSheet == true ? sheet?.charts.first?.id : nil
        selectedDrawingID = nil
        if selectedChartID == nil, presentedPanel == .chart { presentedPanel = nil }
        refreshMetrics(in: workbook)
    }

    /// After an undo or redo: brings the sheet that changed into view, and
    /// lets go of anything the change took away.
    func showRestored(_ workbook: Workbook, replacing previous: Workbook) {
        editingAddress = nil
        if let changed = workbook.changedSheetID(from: previous), changed != activeSheetID {
            selectSheet(changed, in: workbook)
        } else if activeSheetID.flatMap({ workbook[$0] }) == nil {
            // The active sheet itself was undone away: its neighbour, as
            // deleting a sheet does.
            let index = activeSheetID.flatMap { previous.index(of: $0) } ?? 0
            selectSheet(workbook.sheets[min(index, workbook.sheets.count - 1)].id, in: workbook)
        }
        if let chart = selectedChartID,
           !workbook.sheets.contains(where: { $0.charts.contains { $0.id == chart } }) {
            selectedChartID = nil
            if presentedPanel == .chart { presentedPanel = nil }
        }
        if let drawing = selectedDrawingID,
           !activeSheet(in: workbook).preservedDrawingAnchors.contains(where: { $0.id == drawing }) {
            selectedDrawingID = nil
        }
        clampSelection(to: activeSheet(in: workbook))
        refreshMetrics(in: workbook)
    }

    func refreshMetrics(in workbook: Workbook) {
        metrics = SheetMetrics(sheet: activeSheet(in: workbook), zoom: zoom)
    }

    /// True while the user is typing a formula, when tapping a cell should
    /// insert a reference rather than move the selection.
    var isEnteringFormula: Bool {
        editingAddress != nil && editingText.hasPrefix("=")
    }

    /// Keeps the selection inside the sheet after rows or columns disappear.
    func clampSelection(to sheet: Worksheet) {
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
        if let editingAddress, !sheet.contains(editingAddress) { self.editingAddress = nil }
    }

    // MARK: - Selection

    var selectedAddress: CellAddress { selection.normalized.start }

    /// Every selected range, oldest first, with `selection` last. Usually just
    /// the one; more once the multi-range gesture has been used.
    var selectedRanges: [CellRange] { additionalSelections + [selection] }

    var hasMultipleSelections: Bool { !additionalSelections.isEmpty }

    func isSelected(_ address: CellAddress) -> Bool {
        selectedRanges.contains { $0.contains(address) }
    }

    func select(_ address: CellAddress, extending: Bool = false) {
        if extending {
            selection = CellRange(start: anchor, end: address)
        } else {
            anchor = address
            selection = CellRange(address)
            additionalSelections = []
        }
    }

    /// Selects a cell, growing the range to cover any merged region it falls
    /// inside so that clicking anywhere in a merge selects the whole of it.
    func select(_ address: CellAddress, extending: Bool = false, in sheet: Worksheet) {
        if extending {
            let raw = CellRange(start: anchor, end: address)
            let expanded = sheet.expandedToMerges(raw)
            // Keep the raw range while no merge grew it: its `end` is the edge
            // the user is dragging, and normalizing would lose that direction.
            selection = expanded == raw.normalized ? raw : expanded
        } else {
            let merge = sheet.mergedRange(containing: address)
            anchor = merge?.normalized.start ?? address
            selection = merge ?? CellRange(address)
            additionalSelections = []
        }
    }

    /// Starts another range beside the ones already selected, and makes it the
    /// active one — the multi-range gesture's way in. Everything already
    /// selected stays selected.
    func addRange(startingAt address: CellAddress, in sheet: Worksheet) {
        // Normalized on the way in: the direction a range was dragged in only
        // matters while it is the active one, and two ranges covering the same
        // cells would draw over each other and be edited twice.
        let completed = selection.normalized
        if !additionalSelections.contains(completed) { additionalSelections.append(completed) }
        let merge = sheet.mergedRange(containing: address)
        anchor = merge?.normalized.start ?? address
        selection = merge ?? CellRange(address)
    }

    func selectEntireRows(_ range: ClosedRange<Int>, in sheet: Worksheet) {
        additionalSelections = []
        anchor = CellAddress(row: range.lowerBound, column: 0)
        selection = CellRange(
            start: anchor,
            end: CellAddress(row: range.upperBound, column: max(0, sheet.columnCount - 1))
        )
    }

    func selectEntireColumns(_ range: ClosedRange<Int>, in sheet: Worksheet) {
        additionalSelections = []
        anchor = CellAddress(row: 0, column: range.lowerBound)
        selection = CellRange(
            start: anchor,
            end: CellAddress(row: max(0, sheet.rowCount - 1), column: range.upperBound)
        )
    }

    func selectAll(in sheet: Worksheet) {
        additionalSelections = []
        anchor = CellAddress(row: 0, column: 0)
        selection = CellRange(
            start: anchor,
            end: CellAddress(row: max(0, sheet.rowCount - 1), column: max(0, sheet.columnCount - 1))
        )
    }

    /// True when the selection covers every row of some columns, and vice versa.
    func selectionSpansEntireColumns(in sheet: Worksheet) -> Bool {
        let box = selection.normalized
        return box.start.row == 0 && box.end.row >= sheet.rowCount - 1
    }

    func selectionSpansEntireRows(in sheet: Worksheet) -> Bool {
        let box = selection.normalized
        return box.start.column == 0 && box.end.column >= sheet.columnCount - 1
    }

    // MARK: - Movement

    enum MoveDirection { case up, down, left, right }

    func move(_ direction: MoveDirection, extending: Bool = false, in sheet: Worksheet) {
        let origin = extending ? selection.end : stepOrigin(for: direction, in: sheet)
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
        // Landing inside a merge means landing on the merge: selecting from its
        // top-left corner is what makes the next step leave from the far edge.
        if !extending, let merge = sheet.mergedRange(containing: target) {
            target = merge.normalized.start
        }
        select(target, extending: extending, in: sheet)
        scrollTarget = target
    }

    /// Where a step starts from. Leaving a merged region measures from the edge
    /// the movement exits by, so one press steps clear of it instead of landing
    /// back inside.
    private func stepOrigin(for direction: MoveDirection, in sheet: Worksheet) -> CellAddress {
        guard let merge = sheet.mergedRange(containing: selectedAddress)?.normalized else {
            return selectedAddress
        }
        switch direction {
        case .down, .right: return merge.end
        case .up, .left: return merge.start
        }
    }
}
