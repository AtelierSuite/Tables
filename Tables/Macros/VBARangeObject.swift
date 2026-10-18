import Foundation
import TablesEngine

/// A rectangle of cells on one sheet — `Range("A1:B2")`, `Cells(1, 1)`,
/// `Rows(3)`. Holds only the sheet and the coordinates; every read and
/// write goes through to the host's workbook.
final class VBARangeObject: VBAObject {
    /// `Rows` and `Columns` are the same cells counted and walked a line at
    /// a time.
    enum Mode {
        case cells, rows, columns
    }

    unowned let host: VBAExcelHost
    let sheetID: Worksheet.ID
    let range: CellRange
    let mode: Mode
    var typeName: String { "Range" }

    init(host: VBAExcelHost, sheetID: Worksheet.ID, range: CellRange, mode: Mode = .cells) {
        self.host = host
        self.sheetID = sheetID
        self.range = range.normalized
        self.mode = mode
    }

    private var rowCount: Int { range.rowRange.count }
    private var columnCount: Int { range.columnRange.count }
    private var spansAllRows: Bool { range.start.row == 0 && range.end.row >= Worksheet.maximumRowCount - 1 }
    private var spansAllColumns: Bool {
        range.start.column == 0 && range.end.column >= Worksheet.maximumColumnCount - 1
    }

    /// What a whole-row or whole-column range covers in practice: Tables has
    /// no formatting for rows or columns as such, only for cells, so these
    /// stop at the edge of the grid rather than formatting a million cells.
    private func covered(in sheet: Worksheet) -> CellRange {
        let endRow = spansAllRows ? max(range.start.row, sheet.rowCount - 1) : range.end.row
        let endColumn = spansAllColumns ? max(range.start.column, sheet.columnCount - 1) : range.end.column
        return CellRange(start: range.start, end: CellAddress(row: endRow, column: endColumn))
    }

    private func make(_ range: CellRange, mode: Mode = .cells) -> VBARangeObject {
        VBARangeObject(host: host, sheetID: sheetID, range: range, mode: mode)
    }

    private func checked(_ address: CellAddress) throws -> CellAddress {
        guard address.row >= 0, address.column >= 0, address.row < Worksheet.maximumRowCount,
              address.column < Worksheet.maximumColumnCount else {
            throw VBAError(number: 1004, "Application-defined or object-defined error")
        }
        return address
    }

    private func checked(_ range: CellRange) throws -> CellRange {
        CellRange(start: try checked(range.start), end: try checked(range.end))
    }

    static func usedRange(of sheet: Worksheet) -> CellRange {
        let addresses = sheet.cells.filter { !$0.value.isEmptyEntirely }.keys
        guard let first = addresses.first else { return CellRange(CellAddress(row: 0, column: 0)) }
        var top = first.row
        var left = first.column
        var bottom = first.row
        var right = first.column
        for address in addresses {
            top = min(top, address.row)
            left = min(left, address.column)
            bottom = max(bottom, address.row)
            right = max(right, address.column)
        }
        return CellRange(start: CellAddress(row: top, column: left), end: CellAddress(row: bottom, column: right))
    }

    // MARK: - Indexing

    private func column(from value: VBAValue, in interpreter: VBAInterpreter) throws -> Int {
        let value = try interpreter.letValue(value)
        if case .string(let letters) = value, let index = CellAddress.columnIndex(letters.uppercased()) {
            return index + 1
        }
        return try value.asInteger()
    }

    /// `Item(row, column)` or `Item(n)`, relative to the top-left corner, and
    /// free to reach outside the range as Excel's is.
    private func item(_ arguments: VBAArguments, in interpreter: VBAInterpreter) throws -> VBARangeObject {
        let first = try arguments.required(0, "RowIndex")
        switch mode {
        case .rows:
            let row = range.start.row + (try interpreter.letValue(first).asInteger()) - 1
            return make(try checked(CellRange(start: CellAddress(row: row, column: range.start.column),
                                              end: CellAddress(row: row, column: range.end.column))))
        case .columns:
            let column = range.start.column + (try column(from: first, in: interpreter)) - 1
            return make(try checked(CellRange(start: CellAddress(row: range.start.row, column: column),
                                              end: CellAddress(row: range.end.row, column: column))))
        case .cells:
            if let second = arguments.value(1, "ColumnIndex") {
                let row = range.start.row + (try interpreter.letValue(first).asInteger()) - 1
                let column = range.start.column + (try column(from: second, in: interpreter)) - 1
                return make(CellRange(try checked(CellAddress(row: row, column: column))))
            }
            let index = try interpreter.letValue(first).asInteger() - 1
            guard index >= 0 else { throw VBAError(number: 1004, "Application-defined or object-defined error") }
            let row = range.start.row + index / columnCount
            let column = range.start.column + index % columnCount
            return make(CellRange(try checked(CellAddress(row: row, column: column))))
        }
    }

    // MARK: - Values

    private func valueArray(_ read: (Cell) -> VBAValue) throws -> VBAValue {
        let sheet = try host.sheet(sheetID)
        if range.isSingleCell { return read(sheet[range.start]) }
        let area = covered(in: sheet)
        var array = VBAArray(lowerBounds: [1, 1], upperBounds: [area.rowRange.count, area.columnRange.count])
        for (address, cell) in sheet.cells where area.contains(address) {
            try array.set([address.row - area.start.row + 1, address.column - area.start.column + 1], read(cell))
        }
        return .array(array)
    }

    private func setValues(_ value: VBAValue, in interpreter: VBAInterpreter) throws {
        if case .array(let array) = value {
            guard array.isAllocated else { return }
            let rows = array.dimensions == 1 ? 1 : array.lengths[0]
            let columns = array.dimensions == 1 ? array.lengths[0] : array.lengths[1]
            let sheet = try host.sheet(sheetID)
            let area = covered(in: sheet)
            try host.modifySheet(sheetID, extent: area) { sheet in
                for row in area.rowRange {
                    for column in area.columnRange {
                        let r = row - area.start.row
                        let c = column - area.start.column
                        let element: VBAValue
                        // A one-dimensional array is a row, repeated down the range.
                        if array.dimensions == 1, c < columns {
                            element = try array[[array.lowerBounds[0] + c]]
                        } else if r < rows, c < columns {
                            element = try array[[array.lowerBounds[0] + r, array.lowerBounds[1] + c]]
                        } else {
                            // A range larger than the array fills with #N/A, as Excel's does.
                            element = .error(2042)
                        }
                        try host.write(element, to: CellAddress(row: row, column: column), in: &sheet,
                                       interpreter: interpreter)
                    }
                }
            }
            return
        }
        let scalar = try interpreter.letValue(value)
        let area = covered(in: try host.sheet(sheetID))
        try host.modifySheet(sheetID, extent: area) { sheet in
            for address in area.addresses {
                try host.write(scalar, to: address, in: &sheet, interpreter: interpreter)
            }
        }
    }

    private func setFormulas(_ value: VBAValue, in interpreter: VBAInterpreter) throws {
        if case .array = value { return try setValues(value, in: interpreter) }
        let text = try interpreter.letValue(value).asString()
        guard text.hasPrefix("=") else { return try setValues(.string(text), in: interpreter) }
        let body = String(text.dropFirst())
        let area = covered(in: try host.sheet(sheetID))
        host.noteFormulaWritten()
        try host.modifySheet(sheetID, extent: area) { sheet in
            for address in area.addresses {
                // Every cell gets the formula as if filled from the first.
                var cell = sheet[address]
                cell.formula = FormulaReferenceShifter.translated(
                    body, rowDelta: address.row - area.start.row, columnDelta: address.column - area.start.column
                )
                sheet[address] = cell
            }
        }
    }

    // MARK: - Styles

    func style(_ read: (CellStyle) -> VBAValue) throws -> VBAValue {
        let sheet = try host.sheet(sheetID)
        let first = read(sheet[range.start].style)
        // A property that differs across the range reads as Null.
        for address in sheet.storedAddresses(in: covered(in: sheet)) where !range.isSingleCell {
            if try !same(read(sheet[address].style), first) { return .null }
        }
        return first
    }

    private func same(_ lhs: VBAValue, _ rhs: VBAValue) throws -> Bool {
        switch (lhs, rhs) {
        case (.boolean(let a), .boolean(let b)): return a == b
        case (.string(let a), .string(let b)): return a == b
        case (.null, .null), (.empty, .empty): return true
        default: return (try? lhs.asDouble()) == (try? rhs.asDouble())
        }
    }

    func modifyStyles(_ change: (inout CellStyle) throws -> Void) throws {
        let area = covered(in: try host.sheet(sheetID))
        try host.modifySheet(sheetID, extent: area) { sheet in
            for address in area.addresses {
                var cell = sheet[address]
                try change(&cell.style)
                sheet[address] = cell
            }
        }
    }

    private static let horizontal: [(Int, HorizontalTextAlignment)] = [
        (1, .automatic), (-4131, .leading), (-4108, .center), (-4152, .trailing), (7, .center),
    ]
    private static let vertical: [(Int, VerticalTextAlignment)] = [(-4160, .top), (-4108, .middle), (-4107, .bottom)]

    // MARK: - Members

    func member(_ name: String, _ arguments: VBAArguments, in interpreter: VBAInterpreter) throws -> VBAValue {
        switch name.lowercased() {
        case "":
            if !arguments.isEmpty { return .object(try item(arguments, in: interpreter)) }
            return try valueArray(VBAExcelHost.value(of:))
        case "item":
            return .object(try item(arguments, in: interpreter))
        case "value", "value2":
            if name.lowercased() == "value2" {
                return try valueArray { cell in
                    if case .number(let number) = cell.value { return .double(number) }
                    return VBAExcelHost.value(of: cell)
                }
            }
            return try valueArray(VBAExcelHost.value(of:))
        case "formula", "formulalocal":
            return try valueArray { cell in
                if let formula = cell.formula { return .string("=" + formula) }
                if case .empty = cell.value { return .string("") }
                return .string(cell.editableText)
            }
        case "text":
            let sheet = try host.sheet(sheetID)
            return .string(CellFormatter.displayText(for: sheet[range.start]))
        case "hasformula":
            let sheet = try host.sheet(sheetID)
            let flags = range.addresses.prefix(10_000).map { sheet[$0].formula != nil }
            if flags.allSatisfy({ $0 }) { return .boolean(true) }
            if flags.allSatisfy({ !$0 }) { return .boolean(false) }
            return .null
        case "address":
            let rowAbsolute = try arguments.boolean(0, "RowAbsolute", in: interpreter) ?? true
            let columnAbsolute = try arguments.boolean(1, "ColumnAbsolute", in: interpreter) ?? true
            if try arguments.integer(2, "ReferenceStyle", in: interpreter) == -4150 {
                throw VBAError.notSupported("R1C1 references")
            }
            var text = VBAExcelHost.address(range, rowAbsolute: rowAbsolute, columnAbsolute: columnAbsolute)
            if try arguments.boolean(3, "External", in: interpreter) == true {
                text = "[\(host.workbookName)]\(try host.sheet(sheetID).name)!" + text
            }
            return .string(text)
        case "row":
            return .integer(range.start.row + 1)
        case "column":
            return .integer(range.start.column + 1)
        case "count", "countlarge":
            switch mode {
            case .cells: return .integer(range.cellCount)
            case .rows: return .integer(rowCount)
            case .columns: return .integer(columnCount)
            }
        case "cells":
            if arguments.isEmpty { return .object(make(range)) }
            return .object(try make(range).item(arguments, in: interpreter))
        case "rows", "columns":
            let lineMode: Mode = name.lowercased() == "rows" ? .rows : .columns
            let lines = make(range, mode: lineMode)
            return arguments.isEmpty ? .object(lines) : .object(try lines.item(arguments, in: interpreter))
        case "range":
            return .object(try relativeRange(arguments, in: interpreter))
        case "offset":
            let rows = try arguments.integer(0, "RowOffset", in: interpreter) ?? 0
            let columns = try arguments.integer(1, "ColumnOffset", in: interpreter) ?? 0
            return .object(make(try checked(CellRange(
                start: CellAddress(row: range.start.row + rows, column: range.start.column + columns),
                end: CellAddress(row: range.end.row + rows, column: range.end.column + columns)
            )), mode: mode))
        case "resize":
            let rows = try arguments.integer(0, "RowSize", in: interpreter) ?? rowCount
            let columns = try arguments.integer(1, "ColumnSize", in: interpreter) ?? columnCount
            guard rows >= 1, columns >= 1 else { throw VBAError(number: 1004, "Application-defined or object-defined error") }
            return .object(make(try checked(CellRange(
                start: range.start,
                end: CellAddress(row: range.start.row + rows - 1, column: range.start.column + columns - 1)
            ))))
        case "end":
            return .object(make(CellRange(try end(direction: arguments.integer(0, "Direction", in: interpreter) ?? -4121))))
        case "entirerow":
            return .object(make(CellRange(start: CellAddress(row: range.start.row, column: 0),
                                          end: CellAddress(row: range.end.row, column: Worksheet.maximumColumnCount - 1)),
                                mode: .rows))
        case "entirecolumn":
            return .object(make(CellRange(start: CellAddress(row: 0, column: range.start.column),
                                          end: CellAddress(row: Worksheet.maximumRowCount - 1, column: range.end.column)),
                                mode: .columns))
        case "currentregion":
            return .object(make(try currentRegion()))
        case "worksheet", "parent":
            return .object(host.worksheetObject(sheetID))
        case "application":
            return .object(host.application)
        case "areas":
            return .object(VBAListObject(typeName: "Areas", items: [.object(self)], isZeroBased: false))
        case "mergecells":
            return .boolean(try host.sheet(sheetID).mergedRange(containing: range.start) != nil)
        case "mergearea":
            let merged = try host.sheet(sheetID).mergedRange(containing: range.start) ?? CellRange(range.start)
            return .object(make(merged))
        case "font":
            return .object(VBAFontObject(range: self))
        case "interior":
            return .object(VBAInteriorObject(range: self))
        case "borders":
            let edges = try arguments.integer(0, "Index", in: interpreter).map { [$0] } ?? [7, 8, 9, 10]
            return .object(VBABordersObject(range: self, edges: edges))
        case "numberformat", "numberformatlocal":
            return try style { .string($0.numberFormat) }
        case "horizontalalignment":
            return try style { style in .integer(Self.horizontal.first { $0.1 == style.horizontalAlignment }?.0 ?? 1) }
        case "verticalalignment":
            return try style { style in .integer(Self.vertical.first { $0.1 == style.verticalAlignment }?.0 ?? -4108) }
        case "wraptext":
            return try style { .boolean($0.wrapsText) }
        case "indentlevel":
            return try style { .integer($0.indent) }
        case "columnwidth":
            return .double(Worksheet.columnWidthCharacters(points: try host.sheet(sheetID).width(ofColumn: range.start.column)))
        case "rowheight", "height":
            let sheet = try host.sheet(sheetID)
            if name.lowercased() == "height" {
                return .double(range.rowRange.prefix(10_000).reduce(0) { $0 + sheet.height(ofRow: $1) })
            }
            return .double(sheet.height(ofRow: range.start.row))
        case "width":
            let sheet = try host.sheet(sheetID)
            return .double(range.columnRange.prefix(10_000).reduce(0) { $0 + sheet.width(ofColumn: $1) })
        case "hidden":
            let sheet = try host.sheet(sheetID)
            if mode == .columns || spansAllRows { return .boolean(range.columnRange.allSatisfy(sheet.hiddenColumns.contains)) }
            return .boolean(range.rowRange.allSatisfy(sheet.hiddenRows.contains))
        case "clear", "clearcontents", "clearformats":
            try clear(contents: name.lowercased() != "clearformats", formats: name.lowercased() != "clearcontents")
            return .empty
        case "delete":
            try delete()
            return .boolean(true)
        case "insert":
            try insert()
            return .boolean(true)
        case "select", "activate":
            if name.lowercased() == "activate", host.selection.contains(range.start), host.activeSheetID == sheetID {
                host.setActiveCell(range.start)
            } else {
                try host.activate(sheet: sheetID, selecting: covered(in: try host.sheet(sheetID)))
            }
            return .boolean(true)
        case "copy":
            if let destination = arguments.value(0, "Destination") {
                guard case .object(let object) = destination, let target = object as? VBARangeObject else {
                    throw VBAError.typeMismatch
                }
                try copy(to: target, values: true, formats: true)
            } else {
                host.clipboard = (sheetID, range)
            }
            return .boolean(true)
        case "cut":
            if let destination = arguments.value(0, "Destination"), case .object(let object) = destination,
               let target = object as? VBARangeObject {
                try copy(to: target, values: true, formats: true)
                try clear(contents: true, formats: true, except: target)
            } else {
                throw VBAError.notSupported("Cut without a destination")
            }
            return .boolean(true)
        case "pastespecial":
            guard let clipboard = host.clipboard else {
                throw VBAError(number: 1004, "PasteSpecial method of Range class failed")
            }
            let kind = try arguments.integer(0, "Paste", in: interpreter) ?? -4104
            let source = VBARangeObject(host: host, sheetID: clipboard.sheet, range: clipboard.range)
            switch kind {
            case -4163, 12: try source.copy(to: self, values: true, formats: kind == 12, valuesOnly: true)
            case -4122: try source.copy(to: self, values: false, formats: true)
            case -4123, 11: try source.copy(to: self, values: true, formats: kind == 11)
            default: try source.copy(to: self, values: true, formats: true)
            }
            return .boolean(true)
        case "merge":
            try host.modifySheet(sheetID) { _ = $0.merge(range) }
            return .empty
        case "unmerge":
            try host.modifySheet(sheetID) { $0.unmerge(range) }
            return .empty
        case "find":
            return try find(arguments, in: interpreter)
        case "specialcells":
            guard try arguments.integer(0, "Type", in: interpreter) == 11 else {
                throw VBAError.notSupported("SpecialCells other than xlCellTypeLastCell")
            }
            return .object(make(CellRange(Self.usedRange(of: try host.sheet(sheetID)).end)))
        case "sort":
            try sort(arguments, in: interpreter)
            return .empty
        case "autofit", "calculate", "show":
            host.refreshIfStale()
            return .empty
        case "formular1c1", "formular1c1local", "formulaarray", "autofilter", "advancedfilter",
             "removeduplicates", "texttocolumns", "filldown", "fillright", "autofill", "comment", "addcomment",
             "hyperlinks", "validation", "formatconditions", "name", "next", "previous":
            throw VBAError.notSupported("Range.\(name)")
        default:
            throw VBAError.unsupportedMember("Range.\(name)")
        }
    }

    func setMember(_ name: String, _ arguments: VBAArguments, to value: VBAValue,
                   in interpreter: VBAInterpreter) throws {
        if !arguments.isEmpty {
            // `rng(2, 1) = x`, or `rng.Cells(2, 1) = x`.
            let key = name.lowercased()
            guard key.isEmpty || key == "item" || key == "cells" else { throw VBAError.unsupportedMember(name) }
            return try item(arguments, in: interpreter).setMember("", .none, to: value, in: interpreter)
        }
        switch name.lowercased() {
        case "", "value", "value2":
            try setValues(value, in: interpreter)
        case "formula", "formulalocal":
            try setFormulas(value, in: interpreter)
        case "numberformat", "numberformatlocal":
            let format = try interpreter.letValue(value).asString()
            try modifyStyles { $0.numberFormat = format }
        case "horizontalalignment":
            let code = try interpreter.letValue(value).asInteger()
            guard let alignment = Self.horizontal.first(where: { $0.0 == code })?.1 else { throw VBAError.invalidCall }
            try modifyStyles { $0.horizontalAlignment = alignment }
        case "verticalalignment":
            let code = try interpreter.letValue(value).asInteger()
            guard let alignment = Self.vertical.first(where: { $0.0 == code })?.1 else { throw VBAError.invalidCall }
            try modifyStyles { $0.verticalAlignment = alignment }
        case "wraptext":
            let flag = try interpreter.letValue(value).asBoolean()
            try modifyStyles { $0.wrapsText = flag }
        case "indentlevel":
            let level = try interpreter.letValue(value).asInteger()
            try modifyStyles { $0.indent = max(0, level) }
        case "columnwidth":
            let points = Worksheet.columnWidthPoints(characters: try interpreter.letValue(value).asDouble())
            let columns = covered(in: try host.sheet(sheetID)).columnRange
            try host.modifySheet(sheetID) { sheet in
                for column in columns { sheet.columnWidths[column] = max(Worksheet.minimumColumnWidth, points) }
            }
        case "rowheight":
            let points = try interpreter.letValue(value).asDouble()
            let rows = covered(in: try host.sheet(sheetID)).rowRange
            try host.modifySheet(sheetID) { sheet in
                for row in rows {
                    sheet.rowHeights[row] = max(Worksheet.minimumRowHeight, points)
                    sheet.fittedRows.remove(row)
                }
            }
        case "hidden":
            let hidden = try interpreter.letValue(value).asBoolean()
            let area = covered(in: try host.sheet(sheetID))
            try host.modifySheet(sheetID) { sheet in
                if mode == .columns || spansAllRows {
                    sheet.setColumns(area.columnRange, hidden: hidden)
                } else {
                    sheet.setRows(area.rowRange, hidden: hidden)
                }
            }
        case "mergecells":
            if try interpreter.letValue(value).asBoolean() {
                try host.modifySheet(sheetID) { _ = $0.merge(range) }
            } else {
                try host.modifySheet(sheetID) { $0.unmerge(range) }
            }
        default:
            throw VBAError.unsupportedMember("Range.\(name)")
        }
    }

    func elements(in _: VBAInterpreter) throws -> [VBAValue] {
        let area = covered(in: try host.sheet(sheetID))
        switch mode {
        case .cells:
            // Row by row, as Excel walks a range.
            return area.rowRange.flatMap { row in
                area.columnRange.map { .object(make(CellRange(CellAddress(row: row, column: $0)))) }
            }
        case .rows:
            return area.rowRange.map { row in
                .object(make(CellRange(start: CellAddress(row: row, column: range.start.column),
                                       end: CellAddress(row: row, column: range.end.column))))
            }
        case .columns:
            return area.columnRange.map { column in
                .object(make(CellRange(start: CellAddress(row: range.start.row, column: column),
                                       end: CellAddress(row: range.end.row, column: column))))
            }
        }
    }

    // MARK: - Operations

    /// `rng.Range("B2")` is relative to the range's own top-left cell;
    /// `Range(cell1, cell2)` spans two corners.
    private func relativeRange(_ arguments: VBAArguments, in interpreter: VBAInterpreter) throws -> VBARangeObject {
        let first = try arguments.required(0, "Cell1")
        if let second = arguments.value(1, "Cell2") {
            let corners = try [first, second].map { value -> (Worksheet.ID, CellRange) in
                if case .object(let object) = value, let other = object as? VBARangeObject {
                    return (other.sheetID, other.range)
                }
                return try host.resolveRange(interpreter.letValue(value).asString(), defaultSheet: sheetID)
            }
            return VBARangeObject(host: host, sheetID: corners[0].0, range: corners[0].1.union(corners[1].1))
        }
        if case .object(let object) = first, let other = object as? VBARangeObject { return other }
        let text = try interpreter.letValue(first).asString()
        let (resolvedSheet, resolved) = try host.resolveRange(text, defaultSheet: sheetID)
        // From a whole sheet, Range("A1") is just A1.
        if range.start == CellAddress(row: 0, column: 0) || resolvedSheet != sheetID || text.contains("!") {
            return VBARangeObject(host: host, sheetID: resolvedSheet, range: resolved)
        }
        let shifted = CellRange(
            start: CellAddress(row: resolved.start.row + range.start.row, column: resolved.start.column + range.start.column),
            end: CellAddress(row: resolved.end.row + range.start.row, column: resolved.end.column + range.start.column)
        )
        return make(try checked(shifted))
    }

    /// Ctrl-arrow: to the edge of the block of filled cells, or across a gap
    /// to the next one, or to the edge of the sheet.
    private func end(direction: Int) throws -> CellAddress {
        let sheet = try host.sheet(sheetID)
        let (dr, dc): (Int, Int)
        switch direction {
        case -4162: (dr, dc) = (-1, 0)
        case -4121: (dr, dc) = (1, 0)
        case -4159: (dr, dc) = (0, -1)
        case -4161: (dr, dc) = (0, 1)
        default: throw VBAError.invalidCall
        }
        func filled(_ address: CellAddress) -> Bool { !sheet[address].isBlank }
        func inside(_ address: CellAddress) -> Bool {
            address.row >= 0 && address.column >= 0 && address.row < Worksheet.maximumRowCount
                && address.column < Worksheet.maximumColumnCount
        }
        // Only stored cells can be filled, so the search can stop at the last one.
        let used = Self.usedRange(of: sheet)
        let limitRow = dr > 0 ? used.end.row + 1 : 0
        let limitColumn = dc > 0 ? used.end.column + 1 : 0
        var current = range.start
        var next = CellAddress(row: current.row + dr, column: current.column + dc)
        guard inside(next) else { return current }
        if filled(current), filled(next) {
            while inside(next), filled(next) {
                current = next
                next = CellAddress(row: current.row + dr, column: current.column + dc)
            }
            return current
        }
        while inside(next) {
            current = next
            if filled(current) { return current }
            if (dr > 0 && current.row > limitRow) || (dc > 0 && current.column > limitColumn) {
                return CellAddress(row: dr > 0 ? Worksheet.maximumRowCount - 1 : current.row,
                                   column: dc > 0 ? Worksheet.maximumColumnCount - 1 : current.column)
            }
            next = CellAddress(row: current.row + dr, column: current.column + dc)
        }
        return current
    }

    /// The block of filled cells around the range, bounded by empty rows
    /// and columns, as Ctrl-* selects it.
    private func currentRegion() throws -> CellRange {
        let sheet = try host.sheet(sheetID)
        func filled(_ row: Int, _ column: Int) -> Bool {
            row >= 0 && column >= 0 && !sheet[CellAddress(row: row, column: column)].isBlank
        }
        var top = range.start.row
        var left = range.start.column
        var bottom = range.end.row
        var right = range.end.column
        var grew = true
        while grew {
            grew = false
            if top > 0, (left - 1...right + 1).contains(where: { filled(top - 1, $0) }) { top -= 1; grew = true }
            if (left - 1...right + 1).contains(where: { filled(bottom + 1, $0) }) { bottom += 1; grew = true }
            if left > 0, (top - 1...bottom + 1).contains(where: { filled($0, left - 1) }) { left -= 1; grew = true }
            if (top - 1...bottom + 1).contains(where: { filled($0, right + 1) }) { right += 1; grew = true }
        }
        return CellRange(start: CellAddress(row: top, column: left), end: CellAddress(row: bottom, column: right))
    }

    private func clear(contents: Bool, formats: Bool, except keep: VBARangeObject? = nil) throws {
        let sheet = try host.sheet(sheetID)
        let addresses = sheet.storedAddresses(in: covered(in: sheet)).filter { address in
            guard let keep, keep.sheetID == sheetID else { return true }
            return !keep.range.contains(address)
        }
        try host.modifySheet(sheetID) { sheet in
            for address in addresses {
                var cell = sheet[address]
                if contents {
                    cell.value = .empty
                    cell.formula = nil
                }
                if formats { cell.style = .default }
                sheet[address] = cell
            }
        }
    }

    /// Copies cells onto `target`'s top-left corner: formulas move their
    /// relative references with them, as pasting does.
    func copy(to target: VBARangeObject, values: Bool, formats: Bool, valuesOnly: Bool = false) throws {
        let source = try host.sheet(sheetID)
        let area = covered(in: source)
        let rowDelta = target.range.start.row - area.start.row
        let columnDelta = target.range.start.column - area.start.column
        var copies: [(CellAddress, Cell)] = []
        for address in area.addresses {
            copies.append((CellAddress(row: address.row + rowDelta, column: address.column + columnDelta), source[address]))
        }
        let destination = CellRange(start: target.range.start,
                                    end: CellAddress(row: area.end.row + rowDelta, column: area.end.column + columnDelta))
        try host.modifySheet(target.sheetID, extent: try checked(destination)) { sheet in
            for (address, original) in copies {
                var cell = sheet[address]
                if values {
                    cell.value = original.value
                    if valuesOnly || original.formula == nil {
                        cell.formula = nil
                    } else if let formula = original.formula {
                        cell.formula = FormulaReferenceShifter.translated(formula, rowDelta: rowDelta, columnDelta: columnDelta)
                    }
                }
                if formats { cell.style = original.style }
                sheet[address] = cell
            }
        }
        if copies.contains(where: { $0.1.formula != nil }) { host.noteFormulaWritten() }
    }

    /// Whole rows and columns only: shifting part of a sheet sideways would
    /// leave formulas pointing at the cells that moved away.
    private func delete() throws {
        if spansAllColumns {
            let rows = range.rowRange
            try structural { workbook, index in
                workbook.sheets[index].removeRows(rows)
                return (.remove(range: rows), .row)
            }
        } else if spansAllRows {
            let columns = range.columnRange
            try structural { workbook, index in
                workbook.sheets[index].removeColumns(columns)
                return (.remove(range: columns), .column)
            }
        } else {
            throw VBAError.notSupported("Deleting part of a row or column")
        }
    }

    private func insert() throws {
        if spansAllColumns {
            let start = range.start.row
            let count = rowCount
            try structural { workbook, index in
                workbook.sheets[index].insertRows(count, at: start)
                return (.insert(index: start, count: count), .row)
            }
        } else if spansAllRows {
            let start = range.start.column
            let count = columnCount
            try structural { workbook, index in
                workbook.sheets[index].insertColumns(count, at: start)
                return (.insert(index: start, count: count), .column)
            }
        } else {
            throw VBAError.notSupported("Inserting part of a row or column")
        }
    }

    private func structural(
        _ change: (inout Workbook, Int) -> (FormulaReferenceShifter.Operation, FormulaReferenceShifter.Axis)
    ) throws {
        let index = try host.sheetIndex(sheetID)
        host.modifyWorkbook { workbook in
            let snapshot = workbook
            let (operation, axis) = change(&workbook, index)
            workbook.chartsFollow(operation, axis: axis, on: sheetID, before: snapshot)
        }
    }

    private func find(_ arguments: VBAArguments, in interpreter: VBAInterpreter) throws -> VBAValue {
        let what = try interpreter.letValue(arguments.required(0, "What")).asString()
        let lookInFormulas = try arguments.integer(2, "LookIn", in: interpreter) == -4123
        let whole = try arguments.integer(3, "LookAt", in: interpreter) == 1
        let matchCase = try arguments.boolean(7, "MatchCase", in: interpreter) ?? false
        let sheet = try host.sheet(sheetID)
        let candidates = sheet.storedAddresses(in: covered(in: sheet)).sorted {
            ($0.row, $0.column) < ($1.row, $1.column)
        }
        // The search starts after the `After` cell — the first one by default —
        // and wraps round, so the first cell is looked at last.
        var start = range.start
        if case .object(let object)? = arguments.value(1, "After"), let after = object as? VBARangeObject {
            start = after.range.start
        }
        let ordered = candidates.filter { ($0.row, $0.column) > (start.row, start.column) }
            + candidates.filter { ($0.row, $0.column) <= (start.row, start.column) }
        let options: String.CompareOptions = matchCase ? [] : [.caseInsensitive]
        for address in ordered {
            let cell = sheet[address]
            let text = lookInFormulas ? cell.editableText : CellFormatter.displayText(for: cell)
            let matched = whole ? text.compare(what, options: options) == .orderedSame
                : text.range(of: what, options: options) != nil
            if matched, !cell.isBlank { return .object(make(CellRange(address))) }
        }
        return .nothing
    }

    private func sort(_ arguments: VBAArguments, in interpreter: VBAInterpreter) throws {
        var keys: [(column: Int, descending: Bool)] = []
        for (keyName, orderName, position) in [("Key1", "Order1", 0), ("Key2", "Order2", 3), ("Key3", "Order3", 5)] {
            guard let key = arguments.value(position, keyName) else { continue }
            let column: Int
            if case .object(let object) = key, let keyRange = object as? VBARangeObject {
                column = keyRange.range.start.column
            } else {
                column = try host.resolveRange(interpreter.letValue(key).asString(), defaultSheet: sheetID).1.start.column
            }
            let order = try arguments.integer(position + 1, orderName, in: interpreter) ?? 1
            keys.append((column, order == 2))
        }
        if keys.isEmpty { keys = [(range.start.column, false)] }
        let hasHeader = try arguments.integer(7, "Header", in: interpreter) == 1
        let sheet = try host.sheet(sheetID)
        let area = covered(in: sheet)
        let firstRow = area.start.row + (hasHeader ? 1 : 0)
        guard firstRow <= area.end.row else { return }
        let rows = Array(firstRow...area.end.row)
        let snapshot = rows.map { row in area.columnRange.map { sheet[CellAddress(row: row, column: $0)] } }

        func rank(_ value: CellValue) -> Int {
            switch value {
            case .number: return 0
            case .text: return 1
            case .boolean: return 2
            case .error: return 3
            case .empty: return 4
            }
        }
        let order = rows.indices.sorted { a, b in
            for key in keys {
                let offset = key.column - area.start.column
                guard offset >= 0, offset < area.columnRange.count else { continue }
                let left = snapshot[a][offset].value
                let right = snapshot[b][offset].value
                // Blanks sort last whichever way the sort runs.
                if left.isEmpty != right.isEmpty { return right.isEmpty }
                let leftRank = rank(left)
                let rightRank = rank(right)
                var comparison: ComparisonResult
                if leftRank != rightRank {
                    comparison = leftRank < rightRank ? .orderedAscending : .orderedDescending
                } else if case .number(let x) = left, case .number(let y) = right {
                    comparison = if x < y { .orderedAscending } else if x > y { .orderedDescending } else { .orderedSame }
                } else {
                    comparison = left.stringValue.compare(right.stringValue, options: [.caseInsensitive, .numeric])
                }
                if comparison == .orderedSame { continue }
                return key.descending ? comparison == .orderedDescending : comparison == .orderedAscending
            }
            return a < b
        }
        try host.modifySheet(sheetID) { sheet in
            for (destination, source) in order.enumerated() {
                for (offset, column) in area.columnRange.enumerated() {
                    sheet[CellAddress(row: rows[destination], column: column)] = snapshot[source][offset]
                }
            }
        }
    }
}

// MARK: - Formatting objects

final class VBAFontObject: VBAObject {
    let range: VBARangeObject
    var typeName: String { "Font" }

    init(range: VBARangeObject) {
        self.range = range
    }

    func member(_ name: String, _: VBAArguments, in _: VBAInterpreter) throws -> VBAValue {
        switch name.lowercased() {
        case "bold": return try range.style { .boolean($0.isBold) }
        case "italic": return try range.style { .boolean($0.isItalic) }
        case "underline": return try range.style { .integer($0.isUnderlined ? 2 : -4142) }
        case "strikethrough": return try range.style { .boolean($0.isStruckThrough) }
        case "size": return try range.style { .double($0.fontSize) }
        case "", "name": return try range.style { .string($0.fontName) }
        case "color": return try range.style { .integer(VBAExcelHost.colorValue($0.textColorHex) ?? 0) }
        case "colorindex": return try range.style { $0.textColorHex == nil ? .integer(-4105) : .integer(1) }
        default: throw VBAError.unsupportedMember("Font.\(name)")
        }
    }

    func setMember(_ name: String, _: VBAArguments, to value: VBAValue,
                   in interpreter: VBAInterpreter) throws {
        let value = try interpreter.letValue(value)
        switch name.lowercased() {
        case "bold":
            let flag = try value.asBoolean()
            try range.modifyStyles { $0.isBold = flag }
        case "italic":
            let flag = try value.asBoolean()
            try range.modifyStyles { $0.isItalic = flag }
        case "underline":
            let flag: Bool
            if case .boolean(let bool) = value { flag = bool } else { flag = try value.asInteger() != -4142 }
            try range.modifyStyles { $0.isUnderlined = flag }
        case "strikethrough":
            let flag = try value.asBoolean()
            try range.modifyStyles { $0.isStruckThrough = flag }
        case "size":
            let size = try value.asDouble()
            guard size > 0 else { throw VBAError.invalidCall }
            try range.modifyStyles { $0.fontSize = size }
        case "", "name":
            let fontName = try value.asString()
            try range.modifyStyles { $0.fontName = fontName }
        case "color":
            let hex = VBAExcelHost.colorHex(try value.asInteger())
            try range.modifyStyles { $0.textColorHex = hex }
        case "colorindex":
            let index = try value.asInteger()
            let hex = VBAColorIndex.hex(index)
            try range.modifyStyles { $0.textColorHex = hex }
        default:
            throw VBAError.unsupportedMember("Font.\(name)")
        }
    }
}

final class VBAInteriorObject: VBAObject {
    let range: VBARangeObject
    var typeName: String { "Interior" }

    init(range: VBARangeObject) {
        self.range = range
    }

    func member(_ name: String, _: VBAArguments, in _: VBAInterpreter) throws -> VBAValue {
        switch name.lowercased() {
        case "", "color": return try range.style { .integer(VBAExcelHost.colorValue($0.fillColorHex) ?? 0xFFFFFF) }
        case "colorindex", "pattern":
            return try range.style { $0.fillColorHex == nil ? .integer(-4142) : .integer(name.lowercased() == "pattern" ? 1 : 0) }
        default: throw VBAError.unsupportedMember("Interior.\(name)")
        }
    }

    func setMember(_ name: String, _: VBAArguments, to value: VBAValue,
                   in interpreter: VBAInterpreter) throws {
        let value = try interpreter.letValue(value)
        switch name.lowercased() {
        case "", "color":
            let hex = VBAExcelHost.colorHex(try value.asInteger())
            try range.modifyStyles { $0.fillColorHex = hex }
        case "colorindex":
            let hex = VBAColorIndex.hex(try value.asInteger())
            try range.modifyStyles { $0.fillColorHex = hex }
        case "pattern":
            if try value.asInteger() == -4142 { try range.modifyStyles { $0.fillColorHex = nil } }
        case "tintandshade", "patterncolorindex", "themecolor":
            return
        default:
            throw VBAError.unsupportedMember("Interior.\(name)")
        }
    }
}

/// `Borders` and `Borders(xlEdgeBottom)`: line style, weight and colour on
/// one or more edges of every cell along the range's outline or inside it.
final class VBABordersObject: VBAObject {
    let range: VBARangeObject
    let edges: [Int]
    var typeName: String { edges.count == 1 ? "Border" : "Borders" }

    init(range: VBARangeObject, edges: [Int]) {
        self.range = range
        self.edges = edges
    }

    func member(_ name: String, _ arguments: VBAArguments, in interpreter: VBAInterpreter) throws -> VBAValue {
        switch name.lowercased() {
        case "", "item":
            return .object(VBABordersObject(range: range, edges: [try interpreter.letValue(arguments.required(0)).asInteger()]))
        case "linestyle":
            return try range.style { $0.borderSides.isEmpty ? .integer(-4142) : .integer(1) }
        case "weight":
            return .integer(2)
        case "color":
            return try range.style { .integer(VBAExcelHost.colorValue($0.borderSides.values.first?.colorHex) ?? 0) }
        case "colorindex":
            return try range.style { $0.borderSides.isEmpty ? .integer(-4142) : .integer(-4105) }
        case "count":
            return .integer(edges.count)
        default:
            throw VBAError.unsupportedMember("Borders.\(name)")
        }
    }

    func setMember(_ name: String, _: VBAArguments, to value: VBAValue,
                   in interpreter: VBAInterpreter) throws {
        let value = try interpreter.letValue(value)
        let outline = range.range
        func apply(_ change: @escaping (inout BorderSide?) -> Void) throws {
            try range.modifyStylesAt { address, style in
                for edge in edges {
                    for side in Self.sides(for: edge, at: address, in: outline) {
                        var current = style.borderSides[side]
                        change(&current)
                        style.borderSides[side] = current
                    }
                }
            }
        }
        switch name.lowercased() {
        case "linestyle":
            let code = try value.asInteger()
            if code == -4142 {
                try apply { $0 = nil }
            } else {
                let style: BorderLineStyle = switch code {
                case -4115: .dashed
                case -4118: .dotted
                case -4119: .double
                case 4: .dashDot
                case 5: .dashDotDot
                default: .thin
                }
                try apply { side in side = BorderSide(lineStyle: style, colorHex: side?.colorHex) }
            }
        case "weight":
            let code = try value.asInteger()
            let style: BorderLineStyle = switch code {
            case 1: .hair
            case -4138: .medium
            case 4: .thick
            default: .thin
            }
            try apply { side in side = BorderSide(lineStyle: style, colorHex: side?.colorHex) }
        case "color":
            let hex = VBAExcelHost.colorHex(try value.asInteger())
            try apply { side in side = BorderSide(lineStyle: side?.lineStyle ?? .thin, colorHex: hex) }
        case "colorindex":
            let hex = VBAColorIndex.hex(try value.asInteger())
            try apply { side in side = BorderSide(lineStyle: side?.lineStyle ?? .thin, colorHex: hex) }
        case "tintandshade", "themecolor":
            return
        default:
            throw VBAError.unsupportedMember("Borders.\(name)")
        }
    }

    /// Which sides of the cell at `address` an Excel border index paints:
    /// the outline indices touch only the cells along that edge, the inside
    /// ones every boundary between cells.
    private static func sides(for edge: Int, at address: CellAddress, in outline: CellRange) -> [BorderEdge] {
        switch edge {
        case 7: return address.column == outline.start.column ? [.leading] : []
        case 8: return address.row == outline.start.row ? [.top] : []
        case 9: return address.row == outline.end.row ? [.bottom] : []
        case 10: return address.column == outline.end.column ? [.trailing] : []
        case 11: return address.column < outline.end.column ? [.trailing] : []
        case 12: return address.row < outline.end.row ? [.bottom] : []
        default: return []
        }
    }
}

extension VBARangeObject {
    func modifyStylesAt(_ change: (CellAddress, inout CellStyle) throws -> Void) throws {
        let area = covered(in: try host.sheet(sheetID))
        try host.modifySheet(sheetID, extent: area) { sheet in
            for address in area.addresses {
                var cell = sheet[address]
                try change(address, &cell.style)
                sheet[address] = cell
            }
        }
    }
}

/// The 56-colour palette `ColorIndex` numbers into.
enum VBAColorIndex {
    private static let palette: [Int] = [
        0x000000, 0xFFFFFF, 0xFF0000, 0x00FF00, 0x0000FF, 0xFFFF00, 0xFF00FF, 0x00FFFF,
        0x800000, 0x008000, 0x000080, 0x808000, 0x800080, 0x008080, 0xC0C0C0, 0x808080,
        0x9999FF, 0x993366, 0xFFFFCC, 0xCCFFFF, 0x660066, 0xFF8080, 0x0066CC, 0xCCCCFF,
        0x000080, 0xFF00FF, 0xFFFF00, 0x00FFFF, 0x800080, 0x800000, 0x008080, 0x0000FF,
        0x00CCFF, 0xCCFFFF, 0xCCFFCC, 0xFFFF99, 0x99CCFF, 0xFF99CC, 0xCC99FF, 0xFFCC99,
        0x3366FF, 0x33CCCC, 0x99CC00, 0xFFCC00, 0xFF9900, 0xFF6600, 0x666699, 0x969696,
        0x003366, 0x339966, 0x003300, 0x333300, 0x993300, 0x993366, 0x333399, 0x333333,
    ]

    /// AARRGGBB for a palette index, or nil for `xlNone` and automatic.
    static func hex(_ index: Int) -> String? {
        guard index >= 1, index <= palette.count else { return nil }
        return String(format: "FF%06X", palette[index - 1])
    }
}
