import Foundation
import TablesEngine

/// The link edits the UI makes, and following a link to where it leads.
extension EditorState {
    /// Links are kept wherever comments are: not in delimited text, nor in a
    /// Numbers document, which have nowhere to keep them.
    var allowsHyperlinks: Bool { allowsComments }

    /// The link a cell on the active sheet follows: its own, or the one its
    /// `HYPERLINK` formula names.
    func hyperlink(at address: CellAddress, in workbook: Workbook) -> CellHyperlink? {
        workbook.hyperlink(at: address, onSheet: activeSheet(in: workbook).id)
    }

    /// The link set on the cell itself, the one that can be edited or removed.
    func storedHyperlink(at address: CellAddress, in workbook: Workbook) -> CellHyperlink? {
        activeSheet(in: workbook).hyperlinks[address]
    }

    /// Whether any selected cell has a link of its own.
    func selectionHasHyperlinks(in workbook: Workbook) -> Bool {
        let links = activeSheet(in: workbook).hyperlinks
        return selectedRanges.contains { range in links.keys.contains { range.normalized.contains($0) } }
    }

    /// The text a link's cell shows, which the editor offers to change.
    func hyperlinkDisplayText(at address: CellAddress, in workbook: Workbook) -> String {
        let cell = activeSheet(in: workbook)[address]
        guard cell.formula == nil else { return "" }
        return CellFormatter.displayText(for: cell)
    }

    /// Sets a cell's link from what was typed. `display` replaces what the
    /// cell shows unless it holds a formula; a blank cell with no display
    /// text shows the link itself. A cell gaining its first link takes on the
    /// look of Excel's Hyperlink style. False when there is no link to set.
    @discardableResult
    func setHyperlink(_ target: String, display: String, at address: CellAddress, in workbook: inout Workbook) -> Bool {
        let index = activeIndex(in: workbook)
        guard var link = CellHyperlink.parse(target, in: workbook, from: workbook.sheets[index].id) else { return false }
        let existing = workbook.sheets[index].hyperlinks[address]
        link.tooltip = existing?.tooltip

        var cell = workbook.sheets[index][address]
        let text = display.trimmingCharacters(in: .whitespacesAndNewlines)
        var changedValue = false
        if cell.formula == nil {
            if !text.isEmpty {
                if CellFormatter.displayText(for: cell) != text {
                    cell.value = .text(text)
                    changedValue = true
                }
            } else if cell.value == .empty {
                cell.value = .text(link.target)
                changedValue = true
            }
        }
        link.display = cell.formula == nil && !text.isEmpty ? text : nil
        if existing == nil, formatting.contains(.styles) {
            cell.style.textColorHex = CellHyperlink.textColorHex
            cell.style.isUnderlined = true
        }
        workbook.sheets[index][address] = cell
        workbook.sheets[index].hyperlinks[address] = link
        if changedValue { workbook.recalculate() }
        return true
    }

    /// Removes the links on every selected cell, and the link look with them
    /// where the cell still has it, as Excel's Remove Hyperlinks does.
    func removeHyperlinks(in workbook: inout Workbook) {
        let index = activeIndex(in: workbook)
        let ranges = selectedRanges.map(\.normalized)
        let removed = workbook.sheets[index].hyperlinks.keys.filter { address in
            ranges.contains { $0.contains(address) }
        }
        for address in removed {
            workbook.sheets[index].hyperlinks[address] = nil
            var cell = workbook.sheets[index][address]
            // Colors read from a file carry an alpha byte in front: `FF0563C1`.
            guard let color = cell.style.textColorHex?.uppercased(),
                  color == CellHyperlink.textColorHex || color == "FF" + CellHyperlink.textColorHex,
                  cell.style.isUnderlined else {
                continue
            }
            cell.style.textColorHex = nil
            cell.style.isUnderlined = false
            workbook.sheets[index][address] = cell
        }
    }

    /// Where following the link on a cell of the active sheet leads.
    func hyperlinkDestination(at address: CellAddress, in workbook: Workbook) -> HyperlinkDestination? {
        guard let link = hyperlink(at: address, in: workbook) else { return nil }
        return workbook.destination(of: link, from: activeSheet(in: workbook).id)
    }

    /// Selects the cells a link leads to, on the sheet already brought up,
    /// and scrolls them into view.
    func reveal(_ range: CellRange, in workbook: Workbook) {
        let sheet = activeSheet(in: workbook)
        let box = range.normalized
        let end = CellAddress(row: min(box.end.row, sheet.rowCount - 1), column: min(box.end.column, sheet.columnCount - 1))
        guard sheet.contains(box.start) else { return }
        select(box.start, in: sheet)
        if end != box.start { select(end, extending: true, in: sheet) }
        scrollTarget = box.start
    }

    /// The URL the system opens for an outside address. Nil for one with no
    /// scheme, such as a path relative to the workbook, which has nowhere to
    /// be resolved from.
    static func url(forHyperlinkAddress address: String) -> URL? {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed)
            ?? trimmed.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed).flatMap(URL.init(string:)),
              let scheme = url.scheme, scheme.count > 1 else { return nil }
        return url
    }
}
