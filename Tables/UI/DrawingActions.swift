import SwiftUI
import TablesEngine

/// Everything the UI does to the pictures and other objects kept from the
/// file, alongside what `ChartActions` does to charts.
extension EditorState {
    /// Where the selected object lives: its sheet's index and its own.
    func selectedDrawingLocation(in workbook: Workbook) -> (sheet: Int, drawing: Int)? {
        guard let selectedDrawingID else { return nil }
        let sheetIndex = activeIndex(in: workbook)
        guard let drawingIndex = workbook.sheets[sheetIndex].preservedDrawingAnchors
            .firstIndex(where: { $0.id == selectedDrawingID }) else { return nil }
        return (sheetIndex, drawingIndex)
    }

    /// Picks an object out, letting go of any chart: one thing on the sheet
    /// is selected at a time.
    func selectDrawing(_ id: PreservedDrawingAnchor.ID?) {
        if id != nil {
            if editingAddress != nil { cancelEditing() }
            selectedChartID = nil
            if presentedPanel == .chart { presentedPanel = nil }
        }
        selectedDrawingID = id
    }

    /// Repositions an object on the active sheet. The frame is in sheet
    /// points at 100% zoom.
    func moveDrawing(_ id: PreservedDrawingAnchor.ID, to frame: CGRect, in workbook: inout Workbook) {
        let index = activeIndex(in: workbook)
        guard let drawingIndex = workbook.sheets[index].preservedDrawingAnchors.firstIndex(where: { $0.id == id })
        else { return }
        let clamped = CGRect(
            x: max(0, frame.minX), y: max(0, frame.minY),
            width: max(1, frame.width), height: max(1, frame.height)
        )
        workbook.sheets[index].grow(toContain: clamped)
        let sheet = workbook.sheets[index]
        workbook.sheets[index].preservedDrawingAnchors[drawingIndex].place(at: clamped, in: sheet)
        refreshMetrics(in: workbook)
    }

    func deleteSelectedDrawing(in workbook: inout Workbook) {
        guard let location = selectedDrawingLocation(in: workbook) else { return }
        workbook.sheets[location.sheet].preservedDrawingAnchors.remove(at: location.drawing)
        selectedDrawingID = nil
    }
}
