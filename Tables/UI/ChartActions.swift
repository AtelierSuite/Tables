import SwiftUI
import TablesEngine

/// Everything the UI does to charts, alongside the cell edits in
/// `EditorActions`.
extension EditorState {
    /// The size Insert Chart gives a new chart, in points: Excel's own
    /// 5 × 3 inch default, which reads well beside a column or two of data.
    static let defaultChartSize = CGSize(width: 360, height: 216)

    // MARK: - Finding the chart

    /// Where the selected chart lives: its sheet's index and its own.
    func selectedChartLocation(in workbook: Workbook) -> (sheet: Int, chart: Int)? {
        guard let selectedChartID else { return nil }
        let sheetIndex = activeIndex(in: workbook)
        guard let chartIndex = workbook.sheets[sheetIndex].charts.firstIndex(where: { $0.id == selectedChartID })
        else { return nil }
        return (sheetIndex, chartIndex)
    }

    func selectedChart(in workbook: Workbook) -> Chart? {
        guard let location = selectedChartLocation(in: workbook) else { return nil }
        return workbook.sheets[location.sheet].charts[location.chart]
    }

    func updateSelectedChart(in workbook: inout Workbook, _ change: (inout Chart) -> Void) {
        guard let location = selectedChartLocation(in: workbook) else { return }
        change(&workbook.sheets[location.sheet].charts[location.chart])
    }

    /// Picks a chart out, letting go of any picture; with `nil`, lets go of
    /// both.
    func selectChart(_ id: Chart.ID?) {
        if id != nil, editingAddress != nil { cancelEditing() }
        selectedChartID = id
        selectedDrawingID = nil
    }

    // MARK: - Inserting

    /// Charts the selection, or the block of data around a single selected
    /// cell, and drops the new chart beside it.
    func insertChart(_ kind: ChartKind, in workbook: inout Workbook) {
        let index = activeIndex(in: workbook)
        let sheet = workbook.sheets[index]
        guard !sheet.isChartSheet else { return }
        if editingAddress != nil { commitEditing(in: &workbook, then: nil) }

        guard let layout = ChartBuilder.layout(of: selection, in: sheet, for: kind),
              let chart = ChartBuilder.chart(kind, from: layout.range, in: sheet, named: sheet.uniqueChartName())
        else {
            errorMessage = String(localized: "Error.Chart.NoData")
            return
        }

        var placed = chart
        let frame = initialFrame(beside: layout.range, in: sheet)
        workbook.sheets[index].grow(toContain: frame)
        placed.placement = ChartPlacement(frame: frame, in: workbook.sheets[index])
        workbook.sheets[index].charts.append(placed)
        refreshMetrics(in: workbook)
        selectChart(placed.id)
    }

    /// To the right of the data when that is on screen, otherwise in the
    /// middle of what is — Excel's choice, and the one that never makes the
    /// user hunt for what they just made. In sheet points at 100% zoom.
    private func initialFrame(beside range: CellRange, in sheet: Worksheet) -> CGRect {
        let metrics = SheetMetrics(sheet: sheet)
        // Narrowed to fit a phone held upright, keeping Excel's proportions.
        let visibleWidth = (viewportSize.width - 60) / zoom
        var size = Self.defaultChartSize
        if visibleWidth > 120, visibleWidth - 24 < size.width {
            size = CGSize(width: visibleWidth - 24, height: (visibleWidth - 24) * 0.6)
        }
        let visible = CGRect(
            x: scrollOffset.x / zoom,
            y: scrollOffset.y / zoom,
            width: max(size.width, visibleWidth),
            height: max(size.height, (viewportSize.height - 40) / zoom)
        )
        let data = metrics.frame(for: range)
        let beside = CGRect(
            x: data.maxX + metrics.width(ofColumn: range.normalized.end.column + 1) / 2 + 12,
            y: data.minY,
            width: size.width, height: size.height
        )
        if visible.contains(beside) { return beside }
        return CGRect(
            x: max(visible.minX + 12, visible.midX - size.width / 2),
            y: max(visible.minY + 12, visible.midY - size.height / 2),
            width: size.width, height: size.height
        )
    }

    // MARK: - Moving and sizing

    /// Repositions a chart on the active sheet. The frame is in sheet points
    /// at 100% zoom.
    func moveChart(_ id: Chart.ID, to frame: CGRect, in workbook: inout Workbook) {
        let index = activeIndex(in: workbook)
        guard let chartIndex = workbook.sheets[index].charts.firstIndex(where: { $0.id == id }) else { return }
        let clamped = CGRect(
            x: max(0, frame.minX), y: max(0, frame.minY),
            width: max(48, frame.width), height: max(36, frame.height)
        )
        workbook.sheets[index].grow(toContain: clamped)
        let editAs = workbook.sheets[index].charts[chartIndex].placement.editAs
        var placement = ChartPlacement(frame: clamped, in: workbook.sheets[index])
        placement.editAs = editAs
        workbook.sheets[index].charts[chartIndex].placement = placement
        refreshMetrics(in: workbook)
    }

    // MARK: - Removing and moving between sheets

    func deleteSelectedChart(in workbook: inout Workbook) {
        let index = activeIndex(in: workbook)
        // A chart sheet is its chart: deleting one is deleting the other.
        if workbook.sheets[index].isChartSheet {
            deleteSheet(workbook.sheets[index].id, in: &workbook)
            return
        }
        guard let location = selectedChartLocation(in: workbook) else { return }
        workbook.sheets[location.sheet].charts.remove(at: location.chart)
        selectedChartID = nil
        if presentedPanel == .chart { presentedPanel = nil }
    }

    /// Excel's Move Chart → New Sheet: the chart leaves the grid and becomes a
    /// sheet of its own, placed just after the one it came from.
    func moveSelectedChartToNewSheet(in workbook: inout Workbook) {
        guard let location = selectedChartLocation(in: workbook),
              !workbook.sheets[location.sheet].isChartSheet else { return }
        let chart = workbook.sheets[location.sheet].charts.remove(at: location.chart)

        var sheet = Worksheet(name: workbook.uniqueSheetName(basedOn: chart.name))
        sheet.kind = .chart
        sheet.charts = [chart]
        workbook.sheets.insert(sheet, at: location.sheet + 1)
        presentedPanel = nil
        selectSheet(sheet.id, in: workbook)
    }

    /// The reverse: the chart goes back onto a worksheet, and its sheet goes.
    func moveChartSheetIntoWorksheet(_ targetID: Worksheet.ID, in workbook: inout Workbook) {
        let index = activeIndex(in: workbook)
        guard workbook.sheets[index].isChartSheet, var chart = workbook.sheets[index].charts.first,
              let target = workbook.index(of: targetID), !workbook.sheets[target].isChartSheet else { return }
        let chartSheetID = workbook.sheets[index].id

        let size = Self.defaultChartSize
        let frame = CGRect(x: 24, y: 24, width: size.width, height: size.height)
        workbook.sheets[target].grow(toContain: frame)
        chart.placement = ChartPlacement(frame: frame, in: workbook.sheets[target])
        workbook.sheets[target].charts.append(chart)
        workbook.removeSheet(chartSheetID)
        presentedPanel = nil
        selectSheet(targetID, in: workbook)
        selectChart(chart.id)
    }

    // MARK: - Data

    /// Re-reads a chart's series from a typed range, the way Excel's Select
    /// Data box does. Formatting attached to series is kept by position.
    @discardableResult
    func setSelectedChartData(
        _ text: String, seriesInColumns: Bool?, in workbook: inout Workbook
    ) -> Bool {
        guard let chart = selectedChart(in: workbook) else { return false }
        let fallbackSheet = chart.series.lazy.compactMap(\.values.reference?.sheetID).first
            ?? (activeSheet(in: workbook).isChartSheet ? nil : activeSheet(in: workbook).id)
        guard let reference = Self.parseRange(text, in: workbook, defaultSheet: fallbackSheet),
              let sheet = workbook[reference.sheetID],
              var layout = ChartBuilder.layout(of: reference.range, in: sheet, for: chart.kind) else { return false }
        if let seriesInColumns, chart.kind != .scatter { layout.seriesInColumns = seriesInColumns }

        var series = ChartBuilder.series(for: layout, in: sheet)
        guard !series.isEmpty else { return false }
        for index in series.indices where chart.series.indices.contains(index) {
            let old = chart.series[index]
            series[index].id = old.id
            series[index].colorHex = old.colorHex
            series[index].showsLine = old.showsLine
            series[index].showsMarkers = old.showsMarkers
            series[index].isSmooth = old.isSmooth
            series[index].lineWidth = old.lineWidth
            series[index].pointColors = old.pointColors
        }
        if chart.kind.isRadial { series = Array(series.prefix(1)) }
        updateSelectedChart(in: &workbook) { $0.series = series }
        return true
    }

    /// The block every series of a chart reads from, as one range on one sheet
    /// — what Excel's Select Data box shows. `nil` when the series do not
    /// share a sheet or are not all live references.
    static func dataRange(of chart: Chart) -> ChartReference? {
        let references = chart.series.flatMap { [$0.name.reference, $0.categories.reference, $0.values.reference] }
            .compactMap { $0 }
        guard let first = references.first,
              references.allSatisfy({ $0.sheetID == first.sheetID }),
              chart.series.allSatisfy({ $0.values.reference != nil }) else { return nil }
        let box = references.dropFirst().reduce(first.range) { $0.union($1.range) }
        return ChartReference(sheetID: first.sheetID, range: box)
    }

    /// Reads "A1:C9" or "Sheet 2!A1:C9" — quoted or not — into a reference.
    static func parseRange(_ text: String, in workbook: Workbook, defaultSheet: Worksheet.ID?) -> ChartReference? {
        let trimmed = text.trimmed.hasPrefix("=") ? String(text.trimmed.dropFirst()) : text.trimmed
        if let reference = ChartReference(formula: trimmed, in: workbook) { return reference }
        if let bang = trimmed.lastIndex(of: "!") {
            // An unquoted name with spaces, as people type them.
            let name = String(trimmed[..<bang]).trimmingCharacters(in: CharacterSet(charactersIn: "'"))
            guard let sheet = workbook.sheet(named: name),
                  let range = CellRange(a1Range: String(trimmed[trimmed.index(after: bang)...])) else { return nil }
            return ChartReference(sheetID: sheet.id, range: range)
        }
        guard let defaultSheet, let range = CellRange(a1Range: trimmed) else { return nil }
        return ChartReference(sheetID: defaultSheet, range: range)
    }
}
