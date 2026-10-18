import Foundation
import TablesEngine
import UniformTypeIdentifiers

/// The workbook operations Shortcuts actions perform, kept free of App Intents
/// so they can be tested and reused. Every operation takes the workbook it
/// works on and validates its arguments up front, so a shortcut either does
/// all of what it was asked or reports why it could not.
enum WorkbookAutomation {
    enum Failure: Error, Equatable, LocalizedError {
        case unreadable
        case sheetNotFound(String)
        case invalidCell(String)
        case invalidRange(String)
        case invalidColumn(String)
        case lastSheet
        case outsideSheet(String)
        case noSaveLocation

        var errorDescription: String? {
            switch self {
            case .unreadable:
                return String(localized: "Automation.Error.Unreadable")
            case .sheetNotFound(let name):
                return String(format: String(localized: "Automation.Error.SheetNotFound"), name)
            case .invalidCell(let text):
                return String(format: String(localized: "Automation.Error.InvalidCell"), text)
            case .invalidRange(let text):
                return String(format: String(localized: "Automation.Error.InvalidRange"), text)
            case .invalidColumn(let text):
                return String(format: String(localized: "Automation.Error.InvalidColumn"), text)
            case .lastSheet:
                return String(localized: "Automation.Error.LastSheet")
            case .outsideSheet(let text):
                return String(format: String(localized: "Automation.Error.OutsideSheet"), text)
            case .noSaveLocation:
                return String(localized: "Automation.Error.NoSaveLocation")
            }
        }
    }

    enum Format: String, CaseIterable, Sendable {
        /// `.xlsm` is chosen by a file's own extension, never offered: it is
        /// how a macro workbook saved back to its file keeps its macros.
        case xlsx, xlsm, csv, tsv

        var type: UTType {
            switch self {
            case .xlsx: return .openXMLWorkbook
            case .xlsm: return .macroEnabledWorkbook
            case .csv: return .commaSeparatedText
            case .tsv: return .tabSeparatedText
            }
        }

        var fileExtension: String { rawValue }
    }

    // MARK: - Files

    /// Reads a workbook from a file's contents: an Excel workbook, or comma or
    /// tab separated text.
    static func read(_ data: Data, filename: String) throws -> Workbook {
        let name = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension.lowercased()
        if data.starts(with: [0x50, 0x4B]) || ext == "xlsx" || ext == "xlsm" {
            do {
                return try XLSXReader.workbook(from: data)
            } catch {
                throw Failure.unreadable
            }
        }
        guard !data.isEmpty || ext == "csv" || ext == "tsv" else { throw Failure.unreadable }
        return CSVCodec.workbook(from: data, sheetName: name.isEmpty ? Workbook.defaultSheetName(1) : name)
    }

    /// Writes a workbook out. Delimited text holds one sheet: the named one,
    /// or the first.
    static func write(_ workbook: Workbook, as format: Format, sheet: String? = nil) throws -> Data {
        switch format {
        case .xlsx: return try XLSXWriter.data(from: workbook)
        case .xlsm: return try XLSXWriter.data(from: workbook, macroEnabled: true)
        case .csv: return CSVCodec.data(from: workbook.sheets[try sheetIndex(sheet, in: workbook)])
        case .tsv: return CSVCodec.data(from: workbook.sheets[try sheetIndex(sheet, in: workbook)], delimiter: "\t")
        }
    }

    // MARK: - Addressing

    /// The sheet with a name, compared without regard to case; with no name,
    /// the first visible sheet.
    static func sheetIndex(_ name: String?, in workbook: Workbook) throws -> Int {
        let trimmed = name?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !trimmed.isEmpty else {
            return workbook.sheets.firstIndex { !$0.isHidden && !$0.isChartSheet } ?? 0
        }
        guard let index = workbook.sheets.firstIndex(where: {
            $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }) else { throw Failure.sheetNotFound(trimmed) }
        return index
    }

    static func address(_ text: String) throws -> CellAddress {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let address = CellAddress(a1: trimmed), address.row <= SheetLimits.maxRow,
              address.column <= SheetLimits.maxColumn else { throw Failure.invalidCell(trimmed) }
        return address
    }

    /// A range such as `A1:C10`, a single cell, or whole columns or rows
    /// (`B:D`, `2:5`), which reach as far as the sheet's contents.
    static func range(_ text: String, in sheet: Worksheet) throws -> CellRange {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let node = try? FormulaParser.parse(trimmed) else { throw Failure.invalidRange(trimmed) }
        let box: CellRange
        switch node {
        case .reference(nil, let address): box = CellRange(address)
        case .range(nil, let start, let end): box = CellRange(start: start, end: end).normalized
        default: throw Failure.invalidRange(trimmed)
        }
        // Whole lines stop at the sheet's edge rather than Excel's.
        let lastRow = box.end.row == SheetLimits.maxRow ? max(box.start.row, sheet.rowCount - 1) : box.end.row
        let lastColumn = box.end.column == SheetLimits.maxColumn
            ? max(box.start.column, sheet.columnCount - 1) : box.end.column
        return CellRange(start: box.start, end: CellAddress(row: lastRow, column: lastColumn))
    }

    /// A column given as letters (`C`) or a one-based number (`3`).
    static func column(_ text: String) throws -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let number = Int(trimmed), number >= 1, number - 1 <= SheetLimits.maxColumn { return number - 1 }
        guard let index = CellAddress.columnIndex(trimmed), index <= SheetLimits.maxColumn else {
            throw Failure.invalidColumn(trimmed)
        }
        return index
    }

    // MARK: - Reading

    /// A cell's value, as the grid shows it — dates as dates, currency with its
    /// symbol — so it reads the same in a shortcut as in the sheet.
    static func displayText(of cell: Cell) -> String {
        CellFormatter.displayText(for: cell)
    }

    static func cell(at address: CellAddress, sheet: Int, in workbook: Workbook) -> Cell {
        workbook.sheets[sheet][address]
    }

    /// The rows of a range, each a list of the cells' displayed text.
    static func rows(_ range: CellRange, sheet: Int, in workbook: Workbook) -> [[String]] {
        let source = workbook.sheets[sheet]
        return range.rowRange.map { row in
            range.columnRange.map { column in displayText(of: source[CellAddress(row: row, column: column)]) }
        }
    }

    /// The extent of a sheet's contents: from A1 to the last cell holding anything.
    static func usedRange(of sheet: Worksheet) -> CellRange {
        let filled = sheet.cells.filter { !$0.value.isBlank }.keys
        let lastRow = filled.map(\.row).max() ?? 0
        let lastColumn = filled.map(\.column).max() ?? 0
        return CellRange(start: CellAddress(row: 0, column: 0), end: CellAddress(row: lastRow, column: lastColumn))
    }

    /// Rows whose cell in `column` meets a `COUNTIF`-style condition such as
    /// `>100`, `apple*` or `<>done`.
    static func findRows(where column: Int, matches condition: String, sheet: Int, in workbook: Workbook)
        -> [[String]] {
        let source = workbook.sheets[sheet]
        let used = usedRange(of: source)
        let criterion = FormulaCriterion(.text(condition))
        return used.rowRange.compactMap { row in
            guard criterion.matches(source[CellAddress(row: row, column: column)].value) else { return nil }
            return used.columnRange.map { displayText(of: source[CellAddress(row: row, column: $0)]) }
        }
    }

    /// Works a formula out against a workbook without changing it.
    static func evaluate(_ formula: String, sheet: Int, in workbook: Workbook) -> CellValue {
        let body = formula.hasPrefix("=") ? String(formula.dropFirst()) : formula
        return CalculationEngine.preview(formula: body, in: workbook, sheetIndex: sheet)
    }

    // MARK: - Changing

    /// Enters text into a cell as if typed: numbers, dates and formulas
    /// (starting with `=`) are read as such, everything else is text.
    static func setCell(_ text: String, at address: CellAddress, sheet: Int, in workbook: inout Workbook) throws {
        try grow(&workbook.sheets[sheet], toReach: address)
        let existing = workbook.sheets[sheet][address]
        workbook.sheets[sheet][address] = CellInputParser.cell(from: text, inheriting: existing.style)
        workbook.recalculate()
    }

    /// Adds a row below the last one holding anything, and returns its number.
    @discardableResult
    static func appendRow(_ values: [String], sheet: Int, in workbook: inout Workbook) throws -> Int {
        let source = workbook.sheets[sheet]
        let hasContent = source.cells.values.contains { !$0.isBlank }
        let row = hasContent ? usedRange(of: source).end.row + 1 : 0
        for (column, value) in values.enumerated() {
            let address = CellAddress(row: row, column: column)
            try grow(&workbook.sheets[sheet], toReach: address)
            let existing = workbook.sheets[sheet][address]
            workbook.sheets[sheet][address] = CellInputParser.cell(from: value, inheriting: existing.style)
        }
        workbook.recalculate()
        return row + 1
    }

    /// Empties a range's cells, keeping their formatting.
    static func clear(_ range: CellRange, sheet: Int, in workbook: inout Workbook) {
        for address in workbook.sheets[sheet].storedAddresses(in: range) {
            var cell = workbook.sheets[sheet][address]
            cell.value = .empty
            cell.formula = nil
            cell.isSpilled = false
            workbook.sheets[sheet][address] = cell
        }
        workbook.recalculate()
    }

    /// Sorts a range's rows by one of its columns. Cells move whole, style and
    /// all; formulas are kept as written.
    static func sort(
        _ range: CellRange, by column: Int, ascending: Bool, hasHeader: Bool, sheet: Int, in workbook: inout Workbook
    ) throws {
        guard range.columnRange.contains(column) else {
            throw Failure.invalidColumn(CellAddress.columnName(column))
        }
        let firstRow = range.start.row + (hasHeader ? 1 : 0)
        guard firstRow < range.end.row else { return }
        let source = workbook.sheets[sheet]
        let rows = Array(firstRow...range.end.row)
        let keys = rows.map { source[CellAddress(row: $0, column: column)].value }
        let order = FormulaArrays.stableSorted(rows.indices.map { [CellValue.number(Double($0))] },
                                               keys: [(keys, ascending ? 1 : -1)])
        let lines = order.map { line -> [Cell] in
            guard case .number(let index) = line[0] else { return [] }
            return range.columnRange.map { source[CellAddress(row: rows[Int(index)], column: $0)] }
        }
        for (offset, line) in lines.enumerated() {
            for (position, cell) in line.enumerated() {
                workbook.sheets[sheet][CellAddress(row: firstRow + offset, column: range.start.column + position)] = cell
            }
        }
        workbook.recalculate()
    }

    @discardableResult
    static func addSheet(named name: String?, in workbook: inout Workbook) -> String {
        let trimmed = name?.trimmingCharacters(in: .whitespaces)
        let id = workbook.addSheet(named: trimmed?.isEmpty == false ? trimmed : nil)
        return workbook.sheets.first { $0.id == id }?.name ?? ""
    }

    @discardableResult
    static func renameSheet(_ sheet: Int, to name: String, in workbook: inout Workbook) -> String {
        workbook.renameSheet(workbook.sheets[sheet].id, to: name)
        workbook.recalculate()
        return workbook.sheets[sheet].name
    }

    static func deleteSheet(_ sheet: Int, in workbook: inout Workbook) throws {
        guard workbook.removeSheet(workbook.sheets[sheet].id) else { throw Failure.lastSheet }
        workbook.recalculate()
    }

    /// Widens a sheet so an address fits, within the app's grid limits.
    private static func grow(_ sheet: inout Worksheet, toReach address: CellAddress) throws {
        guard address.row < Worksheet.maximumRowCount, address.column < Worksheet.maximumColumnCount else {
            throw Failure.outsideSheet(address.a1)
        }
        sheet.rowCount = max(sheet.rowCount, address.row + 1)
        sheet.columnCount = max(sheet.columnCount, address.column + 1)
    }
}
