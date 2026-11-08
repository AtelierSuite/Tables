import Foundation

extension Workbook {
    /// Moves a block of cells, as dragging a selection's border does: the
    /// cells land at `destination` with their contents, formatting and
    /// comments, the block they left is emptied, and every formula in the
    /// workbook that read them reads them where they are now. With `copying`
    /// the original stays put and the copy's formulas move as a paste's do.
    ///
    /// Gives up — returning false — when a merged region straddles either
    /// block, which has no one way to be carried, or when the block would
    /// fall off the sheet.
    @discardableResult
    public mutating func moveCells(
        _ source: CellRange, on sheetID: Worksheet.ID, to destination: CellAddress, copying: Bool = false
    ) -> Bool {
        guard let index = index(of: sheetID) else { return false }
        let box = source.normalized
        let rowDelta = destination.row - box.start.row
        let columnDelta = destination.column - box.start.column
        guard rowDelta != 0 || columnDelta != 0 else { return false }
        let target = CellRange(
            start: destination,
            end: CellAddress(row: box.end.row + rowDelta, column: box.end.column + columnDelta)
        )
        let sheet = sheets[index]
        guard sheet.contains(target.start), sheet.contains(target.end),
              !sheet.mergedRanges.contains(where: { $0.intersects(box) || $0.intersects(target) }) else { return false }

        if !copying {
            // Everything that read the old block reads the new one, the moved
            // cells' own formulas included.
            for sheetIndex in sheets.indices {
                let scope = FormulaReferenceShifter.Scope(sheet: sheet.name, host: sheets[sheetIndex].name)
                for (address, cell) in sheets[sheetIndex].cells {
                    guard let formula = cell.formula else { continue }
                    let rewritten = FormulaReferenceShifter.moved(
                        formula, from: box, rowDelta: rowDelta, columnDelta: columnDelta, scope: scope)
                    if rewritten != formula { sheets[sheetIndex].cells[address]?.formula = rewritten }
                }
            }
        }

        var moved: [CellAddress: Cell] = [:]
        var comments: [CellAddress: CellComment] = [:]
        box.forEachAddress { address in
            var cell = sheets[index][address]
            let landing = CellAddress(row: address.row + rowDelta, column: address.column + columnDelta)
            if copying, let formula = cell.formula {
                cell.formula = FormulaReferenceShifter.translated(formula, rowDelta: rowDelta, columnDelta: columnDelta)
            }
            moved[landing] = cell
            comments[landing] = sheets[index].comments[address]
            if !copying {
                sheets[index][address] = Cell()
                sheets[index].comments[address] = nil
            }
        }

        target.forEachAddress { address in
            var cell = moved[address] ?? Cell()
            cell.isSpilled = false
            sheets[index][address] = cell
            sheets[index].comments[address] = comments[address]
        }
        recalculate()
        return true
    }
}
