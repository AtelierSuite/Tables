import Foundation

/// Turns a selection into a chart the way Excel's Insert Chart reads one.
///
/// Excel's rules, which people already expect: a lone cell grows to the block
/// of data around it; a header row of text names the series; a first column of
/// text or dates labels the categories; and the series run down the columns
/// unless the block is wider than it is tall.
public enum ChartBuilder {
    /// The pieces of a block of data a chart is made from.
    public struct Layout: Equatable, Sendable {
        /// The data block, after growing a single cell and trimming blank edges.
        public var range: CellRange
        public var hasHeaderRow: Bool
        public var hasLabelColumn: Bool
        public var seriesInColumns: Bool
    }

    public static func chart(
        _ kind: ChartKind, from selection: CellRange, in sheet: Worksheet, named name: String
    ) -> Chart? {
        guard let layout = layout(of: selection, in: sheet, for: kind) else { return nil }
        var chart = Chart(name: name, kind: kind)
        chart.series = series(for: layout, in: sheet)
        guard !chart.series.isEmpty else { return nil }

        switch kind {
        case .pie, .doughnut:
            chart.variesColors = true
            chart.legend = .right
            chart.valueAxis.showsMajorGridlines = false
            chart.series = Array(chart.series.prefix(1))
        case .scatter:
            // Excel's default scatter is markers alone.
            for index in chart.series.indices { chart.series[index].showsLine = false }
        case .line:
            for index in chart.series.indices { chart.series[index].showsMarkers = false }
        case .column, .bar, .area:
            break
        }
        // Excel titles a one-series chart with the series name and leaves a
        // chart of several untitled; asking for that rather than baking the
        // name in keeps the title following the cell.
        chart.showsAutomaticTitle = chart.series.count == 1
        chart.legend = chart.series.count > 1 || kind.isRadial ? (chart.legend ?? .bottom) : nil
        return chart
    }

    // MARK: - Reading the block

    public static func layout(of selection: CellRange, in sheet: Worksheet, for kind: ChartKind) -> Layout? {
        var box = selection.normalized
        if box.isSingleCell { box = currentRegion(around: box.start, in: sheet) }
        guard let trimmed = trimmed(box, in: sheet) else { return nil }
        box = trimmed

        func value(_ row: Int, _ column: Int) -> Cell { sheet[CellAddress(row: row, column: column)] }
        func isLabel(_ cell: Cell) -> Bool {
            switch cell.value {
            case .text, .empty: return true
            case .number: return CellFormatter.isDateFormat(cell.style.numberFormat)
            case .boolean, .error: return true
            }
        }
        func isNumber(_ cell: Cell) -> Bool {
            cell.value.chartNumber != nil && !CellFormatter.isDateFormat(cell.style.numberFormat)
        }

        let rows = box.rowRange
        let columns = box.columnRange

        // A header row is all labels while something below it is a number.
        var hasHeaderRow = false
        if rows.count > 1 {
            let header = columns.allSatisfy { column in
                let cell = value(rows.lowerBound, column)
                if case .number = cell.value { return false }
                return true
            }
            let numbersBelow = rows.dropFirst().contains { row in columns.contains { isNumber(value(row, $0)) } }
            hasHeaderRow = header && numbersBelow
        }

        // A label column is all text or dates below the header while some
        // column beside it holds numbers. A scatter chart reads its first
        // column as X values instead, so for it any numeric first column counts.
        var hasLabelColumn = false
        if columns.count > 1 {
            let bodyRows = hasHeaderRow ? Array(rows.dropFirst()) : Array(rows)
            let first = columns.lowerBound
            let labels = bodyRows.allSatisfy { isLabel(value($0, first)) }
                && bodyRows.contains { !value($0, first).value.isEmpty }
            let numbersBeside = bodyRows.contains { row in
                columns.dropFirst().contains { isNumber(value(row, $0)) }
            }
            hasLabelColumn = labels && numbersBeside
            // A scatter chart takes a numeric first column as its X values;
            // a text one it skips, plotting by position instead, as Excel does.
            if kind == .scatter, bodyRows.contains(where: { value($0, first).value.chartNumber != nil }) {
                hasLabelColumn = true
            }
        }
        // An empty corner with labels along both edges is Excel's surest sign
        // of a table with headings both ways.
        if rows.count > 1, columns.count > 1, value(rows.lowerBound, columns.lowerBound).value.isEmpty,
           !hasHeaderRow || !hasLabelColumn {
            let rowLabels = columns.dropFirst().allSatisfy { isLabel(value(rows.lowerBound, $0)) }
            let columnLabels = rows.dropFirst().allSatisfy { isLabel(value($0, columns.lowerBound)) }
            if rowLabels, columnLabels, kind != .scatter {
                hasHeaderRow = true
                hasLabelColumn = true
            }
        }

        let dataRows = rows.count - (hasHeaderRow ? 1 : 0)
        let dataColumns = columns.count - (hasLabelColumn ? 1 : 0)
        guard dataRows > 0, dataColumns > 0 else { return nil }
        // Something has to be a number, or there is nothing to plot.
        let body = CellRange(
            start: CellAddress(
                row: rows.lowerBound + (hasHeaderRow ? 1 : 0),
                column: columns.lowerBound + (hasLabelColumn ? 1 : 0)
            ),
            end: CellAddress(row: rows.upperBound, column: columns.upperBound)
        )
        guard sheet.storedAddresses(in: body).contains(where: { sheet[$0].value.chartNumber != nil }) else {
            return nil
        }
        // Scatter data always runs down columns: X beside each Y.
        let seriesInColumns = kind == .scatter || dataRows >= dataColumns
        return Layout(
            range: box, hasHeaderRow: hasHeaderRow, hasLabelColumn: hasLabelColumn,
            seriesInColumns: seriesInColumns
        )
    }

    public static func series(for layout: Layout, in sheet: Worksheet) -> [ChartSeries] {
        let box = layout.range
        let firstDataRow = box.start.row + (layout.hasHeaderRow ? 1 : 0)
        let firstDataColumn = box.start.column + (layout.hasLabelColumn ? 1 : 0)
        func reference(_ start: CellAddress, _ end: CellAddress) -> ChartReference {
            ChartReference(sheetID: sheet.id, range: CellRange(start: start, end: end))
        }

        var result: [ChartSeries] = []
        if layout.seriesInColumns {
            let categories = layout.hasLabelColumn
                ? reference(
                    CellAddress(row: firstDataRow, column: box.start.column),
                    CellAddress(row: box.end.row, column: box.start.column)
                )
                : nil
            for column in firstDataColumn...box.end.column {
                var series = ChartSeries()
                if layout.hasHeaderRow {
                    series.name.reference = reference(
                        CellAddress(row: box.start.row, column: column),
                        CellAddress(row: box.start.row, column: column)
                    )
                }
                series.categories.reference = categories
                series.values.reference = reference(
                    CellAddress(row: firstDataRow, column: column),
                    CellAddress(row: box.end.row, column: column)
                )
                result.append(series)
            }
        } else {
            let categories = layout.hasHeaderRow
                ? reference(
                    CellAddress(row: box.start.row, column: firstDataColumn),
                    CellAddress(row: box.start.row, column: box.end.column)
                )
                : nil
            for row in firstDataRow...box.end.row {
                var series = ChartSeries()
                if layout.hasLabelColumn {
                    series.name.reference = reference(
                        CellAddress(row: row, column: box.start.column),
                        CellAddress(row: row, column: box.start.column)
                    )
                }
                series.categories.reference = categories
                series.values.reference = reference(
                    CellAddress(row: row, column: firstDataColumn),
                    CellAddress(row: row, column: box.end.column)
                )
                result.append(series)
            }
        }
        return result
    }

    /// The block of filled cells touching `address`, as Excel's Ctrl+A or
    /// Insert Chart finds it: grown a line at a time while any cell just past
    /// an edge holds something.
    public static func currentRegion(around address: CellAddress, in sheet: Worksheet) -> CellRange {
        var box = CellRange(address)
        func filled(_ row: Int, _ column: Int) -> Bool {
            guard row >= 0, column >= 0, row < sheet.rowCount, column < sheet.columnCount else { return false }
            return !sheet[CellAddress(row: row, column: column)].isBlank
        }
        var grew = true
        while grew {
            grew = false
            let start = box.start
            let end = box.end
            let columns = (start.column - 1)...(end.column + 1)
            let rows = (start.row - 1)...(end.row + 1)
            if columns.contains(where: { filled(start.row - 1, $0) }) {
                box.start.row -= 1
                grew = true
            }
            if columns.contains(where: { filled(end.row + 1, $0) }) {
                box.end.row += 1
                grew = true
            }
            if rows.contains(where: { filled($0, start.column - 1) }) {
                box.start.column -= 1
                grew = true
            }
            if rows.contains(where: { filled($0, end.column + 1) }) {
                box.end.column += 1
                grew = true
            }
        }
        return box
    }

    /// Cuts the empty rows and columns off the edges of a block, so selecting
    /// whole columns charts the data in them rather than a hundred thousand
    /// blank rows. `nil` when the block holds nothing at all.
    public static func trimmed(_ range: CellRange, in sheet: Worksheet) -> CellRange? {
        let box = range.normalized
        let filled = sheet.storedAddresses(in: box).filter { !sheet[$0].isBlank }
        guard let first = filled.first else { return nil }
        var start = first
        var end = first
        for address in filled {
            start.row = min(start.row, address.row)
            start.column = min(start.column, address.column)
            end.row = max(end.row, address.row)
            end.column = max(end.column, address.column)
        }
        return CellRange(start: start, end: end)
    }
}

// MARK: - Placement

extension ChartPlacement {
    /// The corners of a rectangle given in sheet points at 100% zoom.
    public init(frame: CGRect, in sheet: Worksheet) {
        let metrics = SheetMetrics(sheet: sheet)
        func anchor(at point: CGPoint) -> ChartAnchor {
            let column = metrics.column(atX: max(0, point.x))
            let row = metrics.row(atY: max(0, point.y))
            return ChartAnchor(
                row: row,
                column: column,
                rowOffset: max(0, point.y - metrics.y(ofRow: row)),
                columnOffset: max(0, point.x - metrics.x(ofColumn: column))
            )
        }
        self.init(
            from: anchor(at: frame.origin),
            to: anchor(at: CGPoint(x: frame.maxX, y: frame.maxY))
        )
    }

    /// Where the corners land on screen, under the given metrics.
    public func frame(in metrics: SheetMetrics) -> CGRect {
        func point(_ anchor: ChartAnchor) -> CGPoint {
            CGPoint(
                x: metrics.x(ofColumn: anchor.column)
                    + min(anchor.columnOffset * metrics.zoom, metrics.width(ofColumn: anchor.column)),
                y: metrics.y(ofRow: anchor.row)
                    + min(anchor.rowOffset * metrics.zoom, metrics.height(ofRow: anchor.row))
            )
        }
        let origin = point(from)
        let corner = point(to)
        return CGRect(
            x: origin.x, y: origin.y,
            width: max(0, corner.x - origin.x), height: max(0, corner.y - origin.y)
        )
    }
}

extension Worksheet {
    /// Grows the sheet until a rectangle in points fits inside its grid, so a
    /// chart dropped near the edge of a small sheet is never cut off by it.
    public mutating func grow(toContain frame: CGRect) {
        while totalWidth < frame.maxX, columnCount < Self.maximumColumnCount { addColumns(1) }
        while totalHeight < frame.maxY, rowCount < Self.maximumRowCount { addRows(1) }
    }

    /// "Chart 3": the first name of that shape not already on the sheet.
    public func uniqueChartName() -> String {
        let names = Set(charts.map(\.name))
        var number = charts.count + 1
        while true {
            let candidate = String(format: String(localized: "Chart.DefaultName", bundle: #bundle), number)
            if !names.contains(candidate) { return candidate }
            number += 1
        }
    }
}
