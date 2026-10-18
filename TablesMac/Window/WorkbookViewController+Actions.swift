import AppKit
import SwiftUI
import TablesEngine

/// The ready-made borders the Format menu and the toolbar offer.
enum BorderPreset: Int, CaseIterable {
    case all, outline, top, bottom, left, right, none

    var title: String {
        switch self {
        case .all: return String(localized: "Mac.Border.All")
        case .outline: return String(localized: "Mac.Border.Outline")
        case .top: return String(localized: "Mac.Border.Top")
        case .bottom: return String(localized: "Mac.Border.Bottom")
        case .left: return String(localized: "Mac.Border.Left")
        case .right: return String(localized: "Mac.Border.Right")
        case .none: return String(localized: "Mac.Border.None")
        }
    }

    var symbolName: String {
        switch self {
        case .all: return "square.grid.3x3"
        case .outline: return "square"
        case .top: return "square.topthird.inset.filled"
        case .bottom: return "square.bottomthird.inset.filled"
        case .left: return "square.leadingthird.inset.filled"
        case .right: return "square.trailingthird.inset.filled"
        case .none: return "square.dashed"
        }
    }

    /// The edges a cell at `address` gets in a selection boxed by `box`.
    func edges(at address: CellAddress, in box: CellRange) -> BorderEdges {
        var edges = BorderEdges()
        let top = address.row == box.start.row, bottom = address.row == box.end.row
        let left = address.column == box.start.column, right = address.column == box.end.column
        switch self {
        case .all: edges = .all
        case .outline:
            if top { edges.insert(.top) }
            if bottom { edges.insert(.bottom) }
            if left { edges.insert(.leading) }
            if right { edges.insert(.trailing) }
        case .top: if top { edges.insert(.top) }
        case .bottom: if bottom { edges.insert(.bottom) }
        case .left: if left { edges.insert(.leading) }
        case .right: if right { edges.insert(.trailing) }
        case .none: break
        }
        return edges
    }
}

/// What the colour panel is choosing a colour for.
enum ColorTarget {
    case fill, text
}

extension WorkbookViewController: NSMenuItemValidation, NSToolbarItemValidation {
    private var state: EditorState? { document?.state }

    /// Makes a change to the workbook, as one undo step.
    private func edit(_ change: (EditorState, inout Workbook) -> Void) {
        guard let document else { return }
        let state = document.state
        if state.editingAddress != nil { grid.commitEditing(then: nil) }
        document.edit { change(state, &$0) }
        document.refreshCapabilities()
        document.notify()
        // Some edits start typing, as a function inserted into a single cell.
        if state.editingAddress != nil { grid.beginEditing(at: state.editingAddress!, seed: state.editingText) }
    }

    // MARK: - Clipboard

    @objc func copy(_ sender: Any?) {
        guard let document else { return }
        document.state.copySelection(in: document.workbook)
    }

    @objc func cut(_ sender: Any?) { edit { $0.cutSelection(in: &$1) } }
    @objc func paste(_ sender: Any?) { edit { $0.paste(in: &$1) } }

    @objc func delete(_ sender: Any?) {
        edit { state, workbook in
            if state.selectedChartID != nil {
                state.deleteSelectedChart(in: &workbook)
            } else if state.selectedDrawingID != nil {
                state.deleteSelectedDrawing(in: &workbook)
            } else {
                state.clearContents(in: &workbook)
            }
        }
    }

    @objc override func selectAll(_ sender: Any?) {
        guard let document else { return }
        document.state.selectAll(in: document.activeSheet)
        document.notify()
    }

    @objc func clearContents(_ sender: Any?) { edit { $0.clearContents(in: &$1) } }

    // MARK: - Formatting

    @objc func toggleBold(_ sender: Any?) { edit { $0.toggleBold(in: &$1) } }
    @objc func toggleItalic(_ sender: Any?) { edit { $0.toggleItalic(in: &$1) } }
    @objc func toggleUnderline(_ sender: Any?) { edit { $0.toggleUnderline(in: &$1) } }
    @objc func toggleStrikethrough(_ sender: Any?) { edit { $0.toggleStrikethrough(in: &$1) } }

    @objc func increaseFontSize(_ sender: Any?) { changeFontSize(by: 1) }
    @objc func decreaseFontSize(_ sender: Any?) { changeFontSize(by: -1) }

    private func changeFontSize(by step: Double) {
        edit { state, workbook in
            state.applyStyle(in: &workbook) { $0.fontSize = min(409, max(1, $0.fontSize + step)) }
        }
    }

    @objc func alignHorizontally(_ sender: Any?) {
        guard let raw = representedString(sender), let alignment = HorizontalTextAlignment(rawValue: raw) else { return }
        edit { state, workbook in state.applyStyle(in: &workbook) { $0.horizontalAlignment = alignment } }
    }

    @objc func alignVertically(_ sender: Any?) {
        guard let raw = representedString(sender), let alignment = VerticalTextAlignment(rawValue: raw) else { return }
        edit { state, workbook in state.applyStyle(in: &workbook) { $0.verticalAlignment = alignment } }
    }

    @objc func toggleWrapText(_ sender: Any?) {
        edit { state, workbook in
            let wraps = !state.representativeStyle(in: workbook).wrapsText
            state.applyStyle(in: &workbook) { $0.wrapsText = wraps }
        }
    }

    @objc func increaseIndent(_ sender: Any?) { changeIndent(by: 1) }
    @objc func decreaseIndent(_ sender: Any?) { changeIndent(by: -1) }

    private func changeIndent(by step: Int) {
        edit { state, workbook in
            state.applyStyle(in: &workbook) { $0.indent = min(15, max(0, $0.indent + step)) }
        }
    }

    @objc func setNumberFormat(_ sender: Any?) {
        guard let raw = representedString(sender), let preset = NumberFormatPreset(rawValue: raw) else { return }
        edit { state, workbook in state.applyStyle(in: &workbook) { $0.numberFormat = preset.code } }
    }

    @objc func applyBorders(_ sender: Any?) {
        guard let tag = (sender as? NSMenuItem)?.tag ?? (sender as? NSControl)?.tag,
              let preset = BorderPreset(rawValue: tag) else { return }
        edit { state, workbook in
            let index = state.activeIndex(in: workbook)
            for range in state.selectedRanges {
                let box = workbook.sheets[index].expandedToMerges(range).normalized
                box.forEachAddress { address in
                    guard workbook.sheets[index].contains(address) else { return }
                    let edges = preset.edges(at: address, in: box)
                    guard preset == .none || !edges.isEmpty else { return }
                    var cell = workbook.sheets[index][address]
                    if preset == .none {
                        cell.style.borderSides = [:]
                        cell.style.diagonalBorder = nil
                    } else {
                        for edge in BorderEdge.allCases where edges.contains(edge.edges) {
                            cell.style.borderSides[edge] = cell.style.borderSides[edge] ?? BorderSide()
                        }
                    }
                    workbook.sheets[index][address] = cell
                }
            }
        }
    }

    @objc func orderFrontFillColorPanel(_ sender: Any?) { showColorPanel(for: .fill) }
    @objc func orderFrontTextColorPanel(_ sender: Any?) { showColorPanel(for: .text) }

    private func showColorPanel(for target: ColorTarget) {
        guard let document else { return }
        colorTarget = target
        let style = document.state.representativeStyle(in: document.workbook)
        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelDidChange(_:)))
        panel.isContinuous = true
        let hex = target == .fill ? style.fillColorHex : style.textColorHex
        if let color = Color(argbHex: hex) { panel.color = NSColor(color) }
        panel.orderFront(nil)
    }

    @objc private func colorPanelDidChange(_ sender: NSColorPanel) {
        applyColor(sender.color, to: colorTarget)
    }

    func applyColor(_ color: NSColor?, to target: ColorTarget) {
        let hex = color.flatMap { Color(nsColor: $0).argbHex }
        edit { state, workbook in
            state.applyStyle(in: &workbook) { style in
                switch target {
                case .fill: style.fillColorHex = hex
                case .text: style.textColorHex = hex
                }
            }
        }
    }

    @objc func removeFill(_ sender: Any?) { applyColor(nil, to: .fill) }

    @objc func mergeCells(_ sender: Any?) { edit { $0.mergeSelection(in: &$1) } }
    @objc func unmergeCells(_ sender: Any?) { edit { $0.unmergeSelection(in: &$1) } }
    @objc func clearFormatting(_ sender: Any?) { edit { $0.clearFormatting(in: &$1) } }

    // MARK: - Rows and columns

    @objc func insertRowsAbove(_ sender: Any?) { edit { $0.insertRows(above: true, in: &$1) } }
    @objc func insertRowsBelow(_ sender: Any?) { edit { $0.insertRows(above: false, in: &$1) } }
    @objc func insertColumnsBefore(_ sender: Any?) { edit { $0.insertColumns(before: true, in: &$1) } }
    @objc func insertColumnsAfter(_ sender: Any?) { edit { $0.insertColumns(before: false, in: &$1) } }
    @objc func addRowAtEnd(_ sender: Any?) { edit { $0.addRows(1, in: &$1) } }
    @objc func addColumnAtEnd(_ sender: Any?) { edit { $0.addColumns(1, in: &$1) } }
    @objc func deleteRows(_ sender: Any?) { edit { $0.deleteSelectedRows(in: &$1) } }
    @objc func deleteColumns(_ sender: Any?) { edit { $0.deleteSelectedColumns(in: &$1) } }
    @objc func hideRows(_ sender: Any?) { edit { $0.setSelectedRows(hidden: true, in: &$1) } }
    @objc func hideColumns(_ sender: Any?) { edit { $0.setSelectedColumns(hidden: true, in: &$1) } }
    @objc func unhideAll(_ sender: Any?) { edit { $0.unhideEverything(in: &$1) } }

    @objc func fitColumnWidth(_ sender: Any?) {
        edit { state, workbook in
            for column in state.selection.normalized.columnRange { state.fitColumn(column, in: &workbook) }
        }
    }

    // MARK: - Sheets

    @objc func newSheet(_ sender: Any?) { edit { $0.addSheet(in: &$1) } }
    @objc func duplicateSheet(_ sender: Any?) { edit { $0.duplicateActiveSheet(in: &$1) } }

    @objc func renameSheet(_ sender: Any?) {
        guard let document else { return }
        tabBar.beginRenaming(document.activeSheet.id)
    }

    @objc func hideSheet(_ sender: Any?) {
        guard let id = document?.activeSheet.id else { return }
        edit { $0.setSheet(id, hidden: true, in: &$1) }
    }

    @objc func deleteSheet(_ sender: Any?) {
        guard let id = document?.activeSheet.id else { return }
        edit { $0.deleteSheet(id, in: &$1) }
    }

    @objc func selectPreviousSheet(_ sender: Any?) { stepSheet(by: -1) }
    @objc func selectNextSheet(_ sender: Any?) { stepSheet(by: 1) }

    private func stepSheet(by step: Int) {
        guard let document else { return }
        let sheets = document.workbook.visibleSheets
        guard let index = sheets.firstIndex(where: { $0.id == document.activeSheet.id }) else { return }
        let next = index + step
        guard sheets.indices.contains(next) else { return NSSound.beep() }
        document.selectSheet(sheets[next].id)
    }

    // MARK: - Insert

    @objc func insertChart(_ sender: Any?) {
        guard let raw = representedString(sender), let kind = ChartKind(rawValue: raw) else { return }
        edit { $0.insertChart(kind, in: &$1) }
    }

    @objc func editChart(_ sender: Any?) {
        guard let document else { return }
        let state = document.state
        if state.selectedChartID == nil, document.activeSheet.isChartSheet {
            state.selectChart(document.activeSheet.charts.first?.id)
        }
        state.presentedPanel = .chart
        document.notify()
    }

    @objc func moveChartToNewSheet(_ sender: Any?) { edit { $0.moveSelectedChartToNewSheet(in: &$1) } }

    @objc func insertFunction(_ sender: Any?) {
        guard let name = representedString(sender) else { return }
        edit { $0.insertAggregate(name, in: &$1) }
    }

    // MARK: - Find

    /// The Edit ▸ Find items: show the bar, step through matches, or look
    /// for what the selected cell holds.
    @objc func performFindPanelAction(_ sender: Any?) {
        let tag = (sender as? NSMenuItem)?.tag ?? Int(NSFindPanelAction.showFindPanel.rawValue)
        switch NSFindPanelAction(rawValue: UInt(tag)) {
        case .next?:
            if findBar.isHidden { setFindBarShown(true) }
            findBar.findNext()
        case .previous?:
            if findBar.isHidden { setFindBarShown(true) }
            findBar.findPrevious()
        case .setFindString?:
            guard let document else { return }
            findBar.query = CellFormatter.displayText(for: document.activeSheet[document.state.selectedAddress])
            setFindBarShown(true)
        default:
            setFindBarShown(true)
        }
    }

    // MARK: - Comments

    @objc func newComment(_ sender: Any?) { showComment(kind: .thread) }
    @objc func newNote(_ sender: Any?) { showComment(kind: .note) }
    @objc func showCommentPanel(_ sender: Any?) { showComment(kind: .thread) }

    private func showComment(kind: CellComment.Kind) {
        guard let document else { return }
        let state = document.state
        if state.editingAddress != nil { grid.commitEditing(then: nil) }
        state.showComment(at: state.selectedAddress, kind: kind, in: document.workbook)
        document.notify()
    }

    @objc func deleteComment(_ sender: Any?) {
        edit { state, workbook in state.deleteComments(in: &workbook) }
    }

    // MARK: - View

    @objc func zoomIn(_ sender: Any?) { setZoom((state?.zoom ?? 1) * 1.25) }
    @objc func zoomOut(_ sender: Any?) { setZoom((state?.zoom ?? 1) / 1.25) }
    @objc func actualSize(_ sender: Any?) { setZoom(1) }

    // MARK: - Tools

    @objc func showUnsupportedFeatures(_ sender: Any?) {
        guard let document, let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Notice.UnsupportedFeatures.Title")
        alert.informativeText = document.unsupportedFeatures.noticeMessage
        alert.addButton(withTitle: String(localized: "Common.OK"))
        alert.beginSheetModal(for: window)
    }

    // MARK: - Context menus

    /// The menu for a right-click on a cell.
    func cellMenu(for address: CellAddress) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(MainMenu.item(String(localized: "CellMenu.Cut"), #selector(cut(_:))))
        menu.addItem(MainMenu.item(String(localized: "CellMenu.Copy"), #selector(copy(_:))))
        menu.addItem(MainMenu.item(String(localized: "CellMenu.Paste"), #selector(paste(_:))))
        menu.addItem(MainMenu.item(String(localized: "Mac.Menu.ClearContents"), #selector(clearContents(_:))))
        if let document, document.state.allowsComments {
            menu.addItem(.separator())
            if document.activeSheet.comments[address] != nil {
                menu.addItem(MainMenu.item(String(localized: "CellMenu.ShowComment"), #selector(showCommentPanel(_:))))
                menu.addItem(MainMenu.item(String(localized: "CellMenu.DeleteComment"), #selector(deleteComment(_:))))
            } else {
                menu.addItem(MainMenu.item(String(localized: "CellMenu.NewComment"), #selector(newComment(_:))))
                menu.addItem(MainMenu.item(String(localized: "CellMenu.NewNote"), #selector(newNote(_:))))
            }
        }
        menu.addItem(.separator())
        menu.addItem(MainMenu.item(String(localized: "HeaderMenu.Row.InsertAbove"), #selector(insertRowsAbove(_:))))
        menu.addItem(MainMenu.item(String(localized: "HeaderMenu.Column.InsertBefore"), #selector(insertColumnsBefore(_:))))
        menu.addItem(.separator())
        menu.addItem(MainMenu.item(String(localized: "Format.Merge.Merge"), #selector(mergeCells(_:))))
        menu.addItem(MainMenu.item(String(localized: "Format.Merge.Unmerge"), #selector(unmergeCells(_:))))
        menu.addItem(MainMenu.item(String(localized: "CellMenu.ResetFormatting"), #selector(clearFormatting(_:))))
        return menu
    }

    /// The menu for a right-click on a column letter or a row number.
    func headerMenu(forColumns isColumns: Bool) -> NSMenu {
        let menu = NSMenu()
        if isColumns {
            menu.addItem(MainMenu.item(String(localized: "HeaderMenu.Column.InsertBefore"), #selector(insertColumnsBefore(_:))))
            menu.addItem(MainMenu.item(String(localized: "HeaderMenu.Column.InsertAfter"), #selector(insertColumnsAfter(_:))))
            menu.addItem(MainMenu.item(String(localized: "HeaderMenu.Column.AddAtEnd"), #selector(addColumnAtEnd(_:))))
            menu.addItem(.separator())
            menu.addItem(MainMenu.item(String(localized: "HeaderMenu.Column.Hide"), #selector(hideColumns(_:))))
            menu.addItem(MainMenu.item(String(localized: "Mac.Menu.UnhideAll"), #selector(unhideAll(_:))))
            menu.addItem(MainMenu.item(String(localized: "HeaderMenu.Column.FitToContents"), #selector(fitColumnWidth(_:))))
            menu.addItem(.separator())
            menu.addItem(MainMenu.item(String(localized: "HeaderMenu.Column.Delete"), #selector(deleteColumns(_:))))
        } else {
            menu.addItem(MainMenu.item(String(localized: "HeaderMenu.Row.InsertAbove"), #selector(insertRowsAbove(_:))))
            menu.addItem(MainMenu.item(String(localized: "HeaderMenu.Row.InsertBelow"), #selector(insertRowsBelow(_:))))
            menu.addItem(MainMenu.item(String(localized: "HeaderMenu.Row.AddAtEnd"), #selector(addRowAtEnd(_:))))
            menu.addItem(.separator())
            menu.addItem(MainMenu.item(String(localized: "HeaderMenu.Row.Hide"), #selector(hideRows(_:))))
            menu.addItem(MainMenu.item(String(localized: "Mac.Menu.UnhideAll"), #selector(unhideAll(_:))))
            menu.addItem(.separator())
            menu.addItem(MainMenu.item(String(localized: "HeaderMenu.Row.Delete"), #selector(deleteRows(_:))))
        }
        return menu
    }

    /// The menu for a right-click on a sheet tab.
    func sheetMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(MainMenu.item(String(localized: "SheetTabBar.Menu.Rename"), #selector(renameSheet(_:))))
        menu.addItem(MainMenu.item(String(localized: "SheetTabBar.Menu.Duplicate"), #selector(duplicateSheet(_:))))
        menu.addItem(MainMenu.item(String(localized: "SheetTabBar.Menu.Hide"), #selector(hideSheet(_:))))
        menu.addItem(.separator())
        menu.addItem(MainMenu.item(String(localized: "SheetTabBar.Menu.Delete"), #selector(deleteSheet(_:))))
        return menu
    }

    // MARK: - Validation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let action = menuItem.action, let document else { return false }
        let style = document.state.representativeStyle(in: document.workbook)
        switch action {
        case #selector(toggleBold(_:)): menuItem.state = style.isBold ? .on : .off
        case #selector(toggleItalic(_:)): menuItem.state = style.isItalic ? .on : .off
        case #selector(toggleUnderline(_:)): menuItem.state = style.isUnderlined ? .on : .off
        case #selector(toggleStrikethrough(_:)): menuItem.state = style.isStruckThrough ? .on : .off
        case #selector(toggleWrapText(_:)): menuItem.state = style.wrapsText ? .on : .off
        case #selector(alignHorizontally(_:)):
            menuItem.state = style.horizontalAlignment.rawValue == representedString(menuItem) ? .on : .off
        case #selector(alignVertically(_:)):
            menuItem.state = style.verticalAlignment.rawValue == representedString(menuItem) ? .on : .off
        case #selector(setNumberFormat(_:)):
            let preset = NumberFormatPreset.preset(forCode: style.numberFormat)
            menuItem.state = preset?.rawValue == representedString(menuItem) ? .on : .off
        default: break
        }
        return isEnabled(action)
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        guard let action = item.action else { return true }
        return isEnabled(action)
    }

    /// Whether an action can be taken on what is in front.
    func isEnabled(_ action: Selector) -> Bool {
        guard let document else { return false }
        let state = document.state
        let sheet = document.activeSheet
        let formatting = state.formatting
        let isCells = !sheet.isChartSheet
        switch action {
        case #selector(toggleBold(_:)), #selector(toggleItalic(_:)), #selector(toggleUnderline(_:)),
             #selector(toggleStrikethrough(_:)), #selector(increaseFontSize(_:)), #selector(decreaseFontSize(_:)),
             #selector(alignHorizontally(_:)), #selector(alignVertically(_:)), #selector(toggleWrapText(_:)),
             #selector(orderFrontFillColorPanel(_:)), #selector(orderFrontTextColorPanel(_:)), #selector(removeFill(_:)):
            return isCells && formatting.contains(.styles)
        case #selector(increaseIndent(_:)), #selector(decreaseIndent(_:)):
            return isCells && formatting.contains(.indents)
        case #selector(setNumberFormat(_:)):
            return isCells && formatting.contains(.numberFormats)
        case #selector(applyBorders(_:)):
            return isCells && formatting.contains(.borders)
        case #selector(mergeCells(_:)):
            return isCells && formatting.contains(.merging) && state.canMergeSelection(in: document.workbook)
        case #selector(unmergeCells(_:)):
            return isCells && formatting.contains(.merging) && state.canUnmergeSelection(in: document.workbook)
        case #selector(clearFormatting(_:)):
            return isCells && !formatting.isEmpty
        case #selector(insertRowsAbove(_:)), #selector(insertRowsBelow(_:)), #selector(insertColumnsBefore(_:)),
             #selector(insertColumnsAfter(_:)), #selector(deleteRows(_:)), #selector(deleteColumns(_:)):
            return isCells && state.allowsInsertingAndDeleting
        case #selector(insertChart(_:)):
            return isCells && !document.isPlainText && !document.isNumbers
        case #selector(editChart(_:)):
            return state.selectedChartID != nil || (sheet.isChartSheet && !sheet.charts.isEmpty)
        case #selector(moveChartToNewSheet(_:)):
            return isCells && state.selectedChartID != nil
        case #selector(deleteSheet(_:)), #selector(hideSheet(_:)):
            return document.workbook.visibleSheets.count > 1
        case #selector(newSheet(_:)), #selector(duplicateSheet(_:)):
            return true
        case #selector(paste(_:)):
            return isCells && (state.clipboard?.isEmpty == false
                || NSPasteboard.general.canReadObject(forClasses: [NSString.self]))
        case #selector(newComment(_:)), #selector(newNote(_:)), #selector(showCommentPanel(_:)):
            return isCells && state.allowsComments
        case #selector(deleteComment(_:)):
            return isCells && state.allowsComments
                && state.selectedRanges.contains { range in sheet.comments.keys.contains { range.normalized.contains($0) } }
        case #selector(showUnsupportedFeatures(_:)):
            return !document.unsupportedFeatures.isEmpty
        case #selector(zoomIn(_:)):
            return state.zoom < EditorState.zoomRange.upperBound
        case #selector(zoomOut(_:)):
            return state.zoom > EditorState.zoomRange.lowerBound
        default:
            return isCells || [#selector(selectPreviousSheet(_:)), #selector(selectNextSheet(_:)),
                               #selector(renameSheet(_:))].contains(action)
        }
    }

    private func representedString(_ sender: Any?) -> String? {
        if let item = sender as? NSMenuItem { return item.representedObject as? String }
        if let control = sender as? NSControl { return control.identifier?.rawValue }
        return nil
    }
}
