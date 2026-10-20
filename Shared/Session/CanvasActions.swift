import Foundation
import TablesEngine

/// Everything the UI does to canvases — sheets laid out together as tables
/// on one page — alongside the cell edits in `EditorActions`.
extension EditorState {
    /// The canvas the active sheet is shown on, when it shares one with
    /// another sheet still in view; a sheet on its own is a grid.
    func activeCanvas(in workbook: Workbook) -> SheetCanvas? {
        let sheet = activeSheet(in: workbook)
        guard let canvas = workbook.canvas(containing: sheet.id), workbook.sheets(on: canvas).count > 1 else {
            return nil
        }
        return canvas
    }

    /// Adds a new table below the active sheet, on the canvas it is on or a
    /// new one with it, and goes to it.
    func addTable(in workbook: inout Workbook) {
        guard allowsArrangingCanvases else { return }
        let anchor = activeSheet(in: workbook).id
        let index = (workbook.index(of: anchor) ?? workbook.sheets.count - 1) + 1
        let id = workbook.addSheet(at: index)
        workbook.placeSheet(id, onCanvasWith: anchor)
        selectSheet(id, in: workbook)
    }

    /// Lays a sheet out on the canvas another is on, starting one when that
    /// sheet has the page to itself.
    func placeSheet(_ id: Worksheet.ID, onCanvasWith target: Worksheet.ID, in workbook: inout Workbook) {
        guard allowsArrangingCanvases else { return }
        workbook.placeSheet(id, onCanvasWith: target)
        selectSheet(id, in: workbook)
    }

    /// Takes a sheet off its canvas, back to a sheet of its own.
    func removeFromCanvas(_ id: Worksheet.ID, in workbook: inout Workbook) {
        guard allowsArrangingCanvases else { return }
        workbook.removeFromCanvas(id)
        selectSheet(id, in: workbook)
    }

    /// Moves a table on its canvas, to a place in points at 100%.
    func moveTable(_ id: Worksheet.ID, toX x: Double, y: Double, in workbook: inout Workbook) {
        guard allowsArrangingCanvases else { return }
        workbook.moveTable(id, toX: x, y: y)
    }

    func setTableNameShown(_ shown: Bool, for id: Worksheet.ID, in workbook: inout Workbook) {
        guard allowsArrangingCanvases,
              let canvas = workbook.canvases.firstIndex(where: { $0.contains(id) }),
              let table = workbook.canvases[canvas].tables.firstIndex(where: { $0.sheetID == id }) else { return }
        workbook.canvases[canvas].tables[table].showsName = shown
    }

    /// The sheets the active one could join on a canvas: every other one
    /// with cells, one per canvas.
    func canvasTargets(in workbook: Workbook) -> [Worksheet] {
        let active = activeSheet(in: workbook)
        let own = workbook.canvas(containing: active.id)
        var seen: Set<SheetCanvas.ID> = own.map { [$0.id] } ?? []
        return workbook.visibleSheets.filter { sheet in
            guard sheet.id != active.id, !sheet.isChartSheet else { return false }
            guard let canvas = workbook.canvas(containing: sheet.id) else { return true }
            return seen.insert(canvas.id).inserted
        }
    }
}
