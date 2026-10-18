import Foundation

// MARK: - References as formulas

extension ChartReference {
    /// Reads the formula a chart part stores for a series — `Sheet1!$B$2:$B$9`
    /// or `'Q1 Sales'!$B$2:$B$9`.
    ///
    /// Returns `nil` for anything that is not one rectangle on one sheet of
    /// this workbook: a defined name, a union of ranges, a whole column, a
    /// reference into another workbook. Those are kept as formula text instead.
    public init?(formula raw: String, in workbook: Workbook) {
        var text = raw.trimmed
        if text.hasPrefix("=") { text.removeFirst() }
        guard !text.isEmpty, !text.hasPrefix("("), !text.contains("[") else { return nil }

        let sheetName: String
        let rangeText: Substring
        if text.hasPrefix("'") {
            // Quoted: the name runs to the first lone quote; a doubled quote is
            // an apostrophe inside the name.
            var name = ""
            var index = text.index(after: text.startIndex)
            var closed = false
            while index < text.endIndex {
                let character = text[index]
                if character == "'" {
                    let next = text.index(after: index)
                    if next < text.endIndex, text[next] == "'" {
                        name.append("'")
                        index = text.index(after: next)
                        continue
                    }
                    closed = true
                    index = next
                    break
                }
                name.append(character)
                index = text.index(after: index)
            }
            guard closed, index < text.endIndex, text[index] == "!" else { return nil }
            sheetName = name
            rangeText = text[text.index(after: index)...]
        } else {
            guard let bang = text.lastIndex(of: "!") else { return nil }
            sheetName = String(text[..<bang])
            rangeText = text[text.index(after: bang)...]
        }

        guard let sheet = workbook.sheet(named: sheetName),
              let range = CellRange(a1Range: String(rangeText)) else { return nil }
        self.init(sheetID: sheet.id, range: range)
    }

    /// The formula Excel expects in a chart part: absolute, sheet-qualified.
    /// `nil` once the sheet it pointed at has been deleted.
    public func formula(in workbook: Workbook) -> String? {
        guard let sheet = workbook[sheetID] else { return nil }
        let box = range.normalized
        let start = "$\(CellAddress.columnName(box.start.column))$\(box.start.row + 1)"
        let end = "$\(CellAddress.columnName(box.end.column))$\(box.end.row + 1)"
        let body = box.isSingleCell ? start : "\(start):\(end)"
        return "\(Self.quotedSheetName(sheet.name))!\(body)"
    }

    /// The reference as a person types it, without the anchors.
    public func displayText(in workbook: Workbook) -> String {
        guard let sheet = workbook[sheetID] else { return "#REF!" }
        return "\(Self.quotedSheetName(sheet.name))!\(range.a1)"
    }

    /// Quotes a sheet name when a formula would otherwise misread it: anything
    /// beyond letters, digits and underscores, a leading digit, or a name that
    /// is itself shaped like a cell reference.
    public static func quotedSheetName(_ name: String) -> String {
        let isPlain = !name.isEmpty
            && name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" }
            && !(name.first?.isNumber ?? false)
            && CellAddress(a1: name) == nil
        guard !isPlain else { return name }
        return "'" + name.replacingOccurrences(of: "'", with: "''") + "'"
    }

    /// Whether the range runs down a column rather than along a row. A single
    /// cell counts as a column.
    public var isVertical: Bool {
        let box = range.normalized
        return box.start.column == box.end.column || box.end.row > box.start.row
    }
}

// MARK: - Reading the cells

extension ChartSource {
    /// The cells this source covers, in plotting order, as the chart sees them:
    /// live from the workbook when the reference resolves, otherwise from the
    /// cache, formatted with the number format Excel cached alongside it.
    public func cells(in workbook: Workbook, visibleOnly: Bool) -> [Cell] {
        if let reference, let sheet = workbook[reference.sheetID] {
            var result: [Cell] = []
            let box = reference.range.normalized
            for row in box.rowRange {
                if visibleOnly, sheet.hiddenRows.contains(row) { continue }
                for column in box.columnRange {
                    if visibleOnly, sheet.hiddenColumns.contains(column) { continue }
                    result.append(sheet[CellAddress(row: row, column: column)])
                }
            }
            return result
        }
        return cache.map { value in
            var cell = Cell()
            cell.value = value
            if let cacheFormat { cell.style.numberFormat = cacheFormat }
            return cell
        }
    }

    /// The text a series name or a title shows.
    public func text(in workbook: Workbook) -> String? {
        let parts = cells(in: workbook, visibleOnly: false)
            .map(CellFormatter.displayText(for:))
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

// MARK: - Resolution

/// A chart's data read out of the workbook, ready to plot.
public struct ResolvedChart: Hashable, Sendable {
    public struct Series: Hashable, Sendable {
        public var name: String
        /// One per point; `nil` where the cell holds nothing plottable.
        public var values: [Double?]
        /// Scatter charts only: the X value of each point.
        public var xValues: [Double?]
        public var colorHex: String
        public var pointColors: [Int: String]
    }

    public var title: String?
    public var categories: [String]
    public var series: [Series]
    /// The format of the first value cell, which Excel's value axis follows
    /// when it has no format of its own.
    public var valueFormat: String
    public var categoryFormat: String
    /// The theme accents, which pie slices and other per-point colours cycle
    /// through.
    public var accents: [String] = []
}

extension Chart {
    /// Reads every series out of the workbook. `accents` are the theme's six
    /// accent colours, which series without a colour of their own cycle
    /// through.
    public func resolved(in workbook: Workbook, accents: [String]? = nil) -> ResolvedChart {
        let palette = accents ?? workbook.themeAccentColors
        var categories: [String] = []
        var categoryFormat = "General"
        var valueFormat = "General"
        var series: [ResolvedChart.Series] = []

        for (index, entry) in self.series.enumerated() {
            let valueCells = entry.values.cells(in: workbook, visibleOnly: plotsVisibleCellsOnly)
            let categoryCells = entry.categories.cells(in: workbook, visibleOnly: plotsVisibleCellsOnly)
            let values = valueCells.map(\.value.chartNumber)
            if index == 0 {
                categories = categoryCells.map(CellFormatter.displayText(for:))
                categoryFormat = categoryCells.first?.style.numberFormat ?? "General"
                valueFormat = valueCells.first { $0.value.chartNumber != nil }?.style.numberFormat ?? "General"
            }
            let name = entry.name.text(in: workbook)
                ?? String(format: String(localized: "Chart.Series.DefaultName", bundle: #bundle), index + 1)
            series.append(ResolvedChart.Series(
                name: name,
                values: values,
                xValues: categoryCells.map(\.value.chartNumber),
                colorHex: entry.colorHex ?? ChartPalette.color(at: index, accents: palette),
                pointColors: entry.pointColors
            ))
        }

        // Excel plots as many points as the longest series has, labelling any
        // without a category by position.
        let pointCount = series.map(\.values.count).max() ?? 0
        if categories.count < pointCount {
            categories += (categories.count..<pointCount).map { String($0 + 1) }
        }

        var resolvedTitle: String?
        if let title {
            resolvedTitle = title.reference.flatMap {
                ChartSource(reference: $0).text(in: workbook)
            } ?? title.text
        } else if showsAutomaticTitle, series.count == 1 {
            resolvedTitle = series[0].name
        }
        return ResolvedChart(
            title: resolvedTitle,
            categories: categories,
            series: series,
            valueFormat: valueFormat,
            categoryFormat: categoryFormat,
            accents: palette
        )
    }
}

extension CellValue {
    /// What a chart plots for this cell. Text, booleans and errors are gaps,
    /// the way Excel leaves them.
    public var chartNumber: Double? {
        if case .number(let number) = self, number.isFinite { return number }
        return nil
    }
}

/// The colours Excel gives series that do not choose their own.
public enum ChartPalette {
    /// Series past the sixth go round the accents again, darker and then
    /// lighter each time, as Office's default chart colours do.
    public static func color(at index: Int, accents: [String]) -> String {
        let base = accents.isEmpty ? ThemeColorScheme.office.accentColors : accents
        let accent = base[index % base.count]
        let cycle = index / base.count
        guard cycle > 0 else { return "FF" + accent }
        let tint: Double = cycle % 2 == 1 ? -0.4 : 0.4
        return "FF" + ThemeColorPalette.tinted(accent, by: tint * Double((cycle + 1) / 2) / 1.5)
    }
}

// MARK: - Structural edits

extension ChartReference {
    /// Where the reference lands after rows or columns of its sheet are
    /// inserted or removed, or `nil` when the edit takes every cell it covered.
    public func shifted(_ operation: FormulaReferenceShifter.Operation, axis: FormulaReferenceShifter.Axis) -> ChartReference? {
        let box = range.normalized
        let keyPath: WritableKeyPath<CellAddress, Int> = axis == .row ? \.row : \.column
        let span = box.start[keyPath: keyPath]...box.end[keyPath: keyPath]
        let moved: ClosedRange<Int>?
        switch operation {
        case .insert(let index, let count): moved = Worksheet.span(span, insertingAt: index, count: count)
        case .remove(let removed): moved = Worksheet.span(span, removing: removed)
        case .translate: moved = span
        }
        guard let moved else { return nil }
        var start = box.start
        var end = box.end
        start[keyPath: keyPath] = moved.lowerBound
        end[keyPath: keyPath] = moved.upperBound
        return ChartReference(sheetID: sheetID, range: CellRange(start: start, end: end))
    }
}

extension ChartSource {
    /// Moves the reference through an edit on `sheetID`. A reference the edit
    /// destroys outright falls back on the values it last showed, which is
    /// what Excel keeps plotting until the series is fixed.
    public mutating func follow(
        _ operation: FormulaReferenceShifter.Operation, axis: FormulaReferenceShifter.Axis,
        on sheetID: Worksheet.ID, in workbook: Workbook, visibleOnly: Bool
    ) {
        guard let reference, reference.sheetID == sheetID else { return }
        if let moved = reference.shifted(operation, axis: axis) {
            self.reference = moved
            return
        }
        cache = cells(in: workbook, visibleOnly: visibleOnly).map(\.value)
        self.reference = nil
    }
}

extension Chart {
    /// Retargets every reference that names one sheet to another, as copying
    /// a sheet does to the charts it carries.
    public mutating func retarget(from oldID: Worksheet.ID, to newID: Worksheet.ID) {
        func swap(_ source: inout ChartSource) {
            if source.reference?.sheetID == oldID { source.reference?.sheetID = newID }
        }
        for index in series.indices {
            swap(&series[index].name)
            swap(&series[index].categories)
            swap(&series[index].values)
        }
        if title?.reference?.sheetID == oldID { title?.reference?.sheetID = newID }
    }

    /// Every chart's references follow an edit made on `sheetID`.
    public mutating func follow(
        _ operation: FormulaReferenceShifter.Operation, axis: FormulaReferenceShifter.Axis,
        on sheetID: Worksheet.ID, in workbook: Workbook
    ) {
        for index in series.indices {
            series[index].name.follow(operation, axis: axis, on: sheetID, in: workbook, visibleOnly: false)
            series[index].categories.follow(
                operation, axis: axis, on: sheetID, in: workbook, visibleOnly: plotsVisibleCellsOnly
            )
            series[index].values.follow(
                operation, axis: axis, on: sheetID, in: workbook, visibleOnly: plotsVisibleCellsOnly
            )
        }
        if let reference = title?.reference, reference.sheetID == sheetID {
            title?.reference = reference.shifted(operation, axis: axis)
        }
    }
}

extension ChartPlacement {
    /// Moves the chart with the cells under it, as its `editAs` says Excel
    /// should: stretching with them by default, moving as a block for
    /// `oneCell`, staying put for `absolute`. A chart whose cells are all
    /// removed collapses onto the line where they were, as Excel's does.
    public func shifted(_ operation: FormulaReferenceShifter.Operation, axis: FormulaReferenceShifter.Axis) -> ChartPlacement {
        switch editAs {
        case "absolute": return self
        case "oneCell": return movedAsBlock(operation, axis: axis)
        default: return stretched(operation, axis: axis)
        }
    }

    /// Both corners move by however far the top-left one does.
    private func movedAsBlock(
        _ operation: FormulaReferenceShifter.Operation, axis: FormulaReferenceShifter.Axis
    ) -> ChartPlacement {
        let line: WritableKeyPath<ChartAnchor, Int> = axis == .row ? \.row : \.column
        var corner = self
        corner.to = corner.from
        corner.editAs = nil
        let moved = corner.stretched(operation, axis: axis)
        var result = self
        let distance = moved.from[keyPath: line] - from[keyPath: line]
        result.from = moved.from
        result.to[keyPath: line] = max(result.from[keyPath: line], to[keyPath: line] + distance)
        return result
    }

    private func stretched(
        _ operation: FormulaReferenceShifter.Operation, axis: FormulaReferenceShifter.Axis
    ) -> ChartPlacement {
        var result = self
        let line: WritableKeyPath<ChartAnchor, Int> = axis == .row ? \.row : \.column
        let offset: WritableKeyPath<ChartAnchor, Double> = axis == .row ? \.rowOffset : \.columnOffset
        let span = from[keyPath: line]...max(from[keyPath: line], to[keyPath: line])
        switch operation {
        case .insert(let index, let count):
            let moved = Worksheet.span(span, insertingAt: index, count: count)
            result.from[keyPath: line] = moved.lowerBound
            result.to[keyPath: line] = moved.upperBound
        case .remove(let removed):
            if let moved = Worksheet.span(span, removing: removed) {
                // A corner whose own line went now sits at the start of the gap.
                if removed.contains(from[keyPath: line]) { result.from[keyPath: offset] = 0 }
                if removed.contains(to[keyPath: line]) { result.to[keyPath: offset] = 0 }
                result.from[keyPath: line] = moved.lowerBound
                result.to[keyPath: line] = moved.upperBound
            } else {
                let start = max(0, removed.lowerBound)
                result.from[keyPath: line] = start
                result.to[keyPath: line] = start
                result.from[keyPath: offset] = 0
                result.to[keyPath: offset] = 0
            }
        case .translate:
            break
        }
        return result
    }
}

extension PreservedDrawingAnchor {
    /// Moves a picture, shape or unmodelled chart with the cells under it.
    ///
    /// Only the anchor's cell markers are rewritten — and of those, only the
    /// lines and offsets that actually moved — so the rest of the fragment is
    /// written back exactly as it came. A one-cell anchor moves as a block,
    /// keeping its size; an absolute one stays where it is.
    public mutating func shift(_ operation: FormulaReferenceShifter.Operation, axis: FormulaReferenceShifter.Axis) {
        guard var placement, let root = try? XMLLite.parse(Data(xml.utf8)) else { return }
        let anchors = DrawingReader.anchors(in: root)
        switch anchors.first?.name {
        case "twoCellAnchor": break
        case "oneCellAnchor": placement.editAs = "oneCell"
        default: return
        }
        var moved = placement.shifted(operation, axis: axis)
        guard moved.from != placement.from || moved.to != placement.to else { return }

        let emusPerPoint = 12_700.0
        for anchor in anchors {
            for (name, before, after) in [("from", placement.from, moved.from), ("to", placement.to, moved.to)] {
                guard let marker = anchor.firstChild(named: name) else { continue }
                func set(_ child: String, _ value: String) { marker.firstChild(named: child)?.setText(value) }
                if after.row != before.row { set("row", String(after.row)) }
                if after.column != before.column { set("col", String(after.column)) }
                if after.rowOffset != before.rowOffset {
                    set("rowOff", String(Int((after.rowOffset * emusPerPoint).rounded())))
                }
                if after.columnOffset != before.columnOffset {
                    set("colOff", String(Int((after.columnOffset * emusPerPoint).rounded())))
                }
            }
        }
        guard let rewritten = XMLLite.serialize(root) else { return }
        xml = rewritten
        moved.editAs = self.placement?.editAs
        self.placement = moved
    }
}

extension PreservedDrawingAnchor {
    /// Puts a picture, shape or unmodelled chart where it was dragged to.
    /// `frame` is in sheet points at 100% zoom.
    ///
    /// The anchor keeps its kind — a one-cell anchor is still pinned by its
    /// corner and sized by its extent, an absolute one by its position — and
    /// the object's own transform follows it, so a reader trusting either
    /// finds the object in the same place.
    public mutating func place(at frame: CGRect, in sheet: Worksheet) {
        guard let root = try? XMLLite.parse(Data(xml.utf8)) else { return }
        var moved = ChartPlacement(frame: frame, in: sheet)
        moved.editAs = placement?.editAs

        let anchors = DrawingReader.anchors(in: root)
        guard !anchors.isEmpty else { return }
        for anchor in anchors { Self.place(anchor, at: frame, corners: moved) }

        guard let rewritten = XMLLite.serialize(root) else { return }
        xml = rewritten
        placement = moved
    }

    private static func place(_ anchor: XMLElement, at frame: CGRect, corners: ChartPlacement) {
        func emus(_ points: Double) -> String { String(Int((points * 12_700).rounded())) }
        func mark(_ name: String, _ corner: ChartAnchor) {
            guard let marker = anchor.firstChild(named: name) else { return }
            marker.firstChild(named: "col")?.setText(String(corner.column))
            marker.firstChild(named: "colOff")?.setText(emus(corner.columnOffset))
            marker.firstChild(named: "row")?.setText(String(corner.row))
            marker.firstChild(named: "rowOff")?.setText(emus(corner.rowOffset))
        }
        func size(_ extent: XMLElement?) {
            extent?.setAttribute("cx", emus(frame.width))
            extent?.setAttribute("cy", emus(frame.height))
        }
        switch anchor.name {
        case "twoCellAnchor":
            mark("from", corners.from)
            mark("to", corners.to)
        case "oneCellAnchor":
            mark("from", corners.from)
            size(anchor.firstChild(named: "ext"))
        default:
            anchor.firstChild(named: "pos")?.setAttribute("x", emus(frame.minX))
            anchor.firstChild(named: "pos")?.setAttribute("y", emus(frame.minY))
            size(anchor.firstChild(named: "ext"))
        }
        // A graphic frame's transform is left alone: Excel writes it as zeros
        // and places the frame by its anchor alone.
        if let object = anchor.children.first(where: { DrawingReader.drawingObjects.contains($0.name) }),
           let transform = object.children.first(where: { $0.name == "spPr" || $0.name == "grpSpPr" })?
               .firstChild(named: "xfrm") {
            transform.firstChild(named: "off")?.setAttribute("x", emus(frame.minX))
            transform.firstChild(named: "off")?.setAttribute("y", emus(frame.minY))
            size(transform.firstChild(named: "ext"))
        }
    }
}

extension Workbook {
    /// Lets every chart, form control and formula on another sheet in the
    /// workbook follow rows or columns inserted into or removed from one
    /// sheet. The sheet's own structure must already have changed; this only
    /// touches what reads it.
    public mutating func chartsFollow(
        _ operation: FormulaReferenceShifter.Operation, axis: FormulaReferenceShifter.Axis,
        on sheetID: Worksheet.ID, before snapshot: Workbook
    ) {
        if let name = sheets.first(where: { $0.id == sheetID })?.name {
            for sheetIndex in sheets.indices where sheets[sheetIndex].id != sheetID {
                let scope = FormulaReferenceShifter.Scope(sheet: name, host: sheets[sheetIndex].name)
                FormulaReferenceShifter.apply(operation, axis: axis, to: &sheets[sheetIndex].cells, scope: scope)
            }
        }
        for sheetIndex in sheets.indices {
            for chartIndex in sheets[sheetIndex].charts.indices {
                sheets[sheetIndex].charts[chartIndex].follow(operation, axis: axis, on: sheetID, in: snapshot)
            }
        }
        formControlsFollow(operation, axis: axis, on: sheetID)
    }
}
