import Foundation
import TablesEngine

/// How a running macro reaches the user. Each closure is called on the
/// macro's own thread and may block it while the user answers.
struct VBAInteraction: Sendable {
    var messageBox: @Sendable (_ prompt: String, _ buttons: Int, _ title: String?) -> Int = { _, _, _ in 1 }
    var inputBox: @Sendable (_ prompt: String, _ title: String?, _ defaultText: String) -> String? = { _, _, text in text }
    var debugPrint: @Sendable (_ text: String) -> Void = { _ in /* No Immediate window to print to. */ }
    /// Asks before opening a link from `Shell` or `FollowHyperlink`; true if opened.
    var openURL: @Sendable (_ url: URL) -> Bool = { _ in false }
    var showSendKeys: @Sendable (_ keys: String) -> Void = { _ in /* Nowhere to show the keys. */ }
}

/// The Excel object model over a Tables workbook: `Range`, `Cells`,
/// `Worksheets` and the rest, reading and writing a private copy of the
/// workbook that the caller takes back, whole, when the macro finishes.
final class VBAExcelHost: VBAHost {
    private(set) var workbook: Workbook
    private(set) var activeSheetID: Worksheet.ID
    /// The selection on the active sheet, and the active cell inside it.
    private(set) var selection: CellRange
    private(set) var activeCell: CellAddress
    let interaction: VBAInteraction
    let workbookName: String

    /// Formula results are refreshed lazily: writes only mark the workbook
    /// stale, and the next read that could see a formula recalculates.
    private var isStale = false
    private var hasFormulas: Bool
    var clipboard: (sheet: Worksheet.ID, range: CellRange)?
    /// Application settings macros toggle and Tables has no use for, kept so
    /// reading one back gives what was written.
    var applicationSettings: [String: VBAValue] = [
        "screenupdating": .boolean(true), "displayalerts": .boolean(true), "enableevents": .boolean(true),
        "calculation": .integer(-4105), "statusbar": .boolean(false), "cutcopymode": .boolean(false),
        "displaystatusbar": .boolean(true), "asktoupdatelinks": .boolean(true), "interactive": .boolean(true),
        "cursor": .integer(-4143),
    ]

    init(workbook: Workbook, name: String, activeSheet: Worksheet.ID? = nil, selection: CellRange? = nil,
         interaction: VBAInteraction = VBAInteraction()) {
        self.workbook = workbook
        workbookName = name
        let sheetID = activeSheet.flatMap { workbook.index(of: $0) != nil ? $0 : nil }
            ?? workbook.visibleSheets.first?.id ?? workbook.sheets[0].id
        activeSheetID = sheetID
        let range = selection?.normalized ?? CellRange(CellAddress(row: 0, column: 0))
        self.selection = range
        activeCell = range.start
        self.interaction = interaction
        hasFormulas = workbook.sheets.contains { $0.cells.values.contains { $0.formula != nil } }
    }

    /// The workbook as the macro left it, with every formula up to date.
    var finishedWorkbook: Workbook {
        refreshIfStale()
        return workbook
    }

    // MARK: - Workbook access

    func sheetIndex(_ id: Worksheet.ID) throws -> Int {
        guard let index = workbook.index(of: id) else { throw VBAError(number: 424, "The sheet no longer exists") }
        return index
    }

    func sheet(_ id: Worksheet.ID) throws -> Worksheet {
        refreshIfStale()
        return workbook.sheets[try sheetIndex(id)]
    }

    func refreshIfStale() {
        guard isStale else { return }
        isStale = false
        guard hasFormulas else { return }
        workbook.recalculate()
    }

    /// Edits one sheet's cells, keeping the grid big enough for them.
    func modifySheet(_ id: Worksheet.ID, extent: CellRange? = nil, _ change: (inout Worksheet) throws -> Void) throws {
        let index = try sheetIndex(id)
        try change(&workbook.sheets[index])
        if let extent {
            let end = extent.normalized.end
            workbook.sheets[index].rowCount = min(Worksheet.maximumRowCount,
                                                  max(workbook.sheets[index].rowCount, end.row + 1))
            workbook.sheets[index].columnCount = min(Worksheet.maximumColumnCount,
                                                     max(workbook.sheets[index].columnCount, end.column + 1))
        }
        isStale = true
    }

    func noteFormulaWritten() { hasFormulas = true }

    func modifyWorkbook(_ change: (inout Workbook) throws -> Void) rethrows {
        try change(&workbook)
        isStale = true
    }

    func activate(sheet id: Worksheet.ID, selecting range: CellRange? = nil) throws {
        let index = try sheetIndex(id)
        if workbook.sheets[index].isHidden { throw VBAError(number: 1004, "Activate method of Worksheet class failed") }
        if id != activeSheetID {
            activeSheetID = id
            selection = CellRange(CellAddress(row: 0, column: 0))
            activeCell = selection.start
        }
        if let range {
            selection = range.normalized
            activeCell = selection.start
        }
    }

    func setActiveCell(_ address: CellAddress) {
        activeCell = address
        if !selection.contains(address) { selection = CellRange(address) }
    }

    // MARK: - Objects

    lazy var application = VBAApplicationObject(host: self)
    lazy var workbookObject = VBAWorkbookObject(host: self)

    func worksheetObject(_ id: Worksheet.ID) -> VBAWorksheetObject { VBAWorksheetObject(host: self, sheetID: id) }

    func range(_ id: Worksheet.ID, _ range: CellRange) -> VBARangeObject {
        VBARangeObject(host: self, sheetID: id, range: range.normalized)
    }

    var activeWorksheet: VBAWorksheetObject { worksheetObject(activeSheetID) }

    // MARK: - VBAHost

    func globalMember(_ name: String, _ arguments: VBAArguments, in interpreter: VBAInterpreter) throws -> VBAValue? {
        switch name.lowercased() {
        case "application": return .object(application)
        case "thisworkbook", "activeworkbook": return .object(workbookObject)
        case "workbooks": return .object(VBAWorkbooksObject(host: self))
        default: break
        }
        return try application.globalMember(name, arguments, in: interpreter)
    }

    func setGlobalMember(_ name: String, _ arguments: VBAArguments, to value: VBAValue,
                         in interpreter: VBAInterpreter) throws -> Bool {
        // `ActiveCell = 5`: the only globals a bare assignment can reach.
        guard ["activecell", "selection"].contains(name.lowercased()) else { return false }
        try application.setMember(name, arguments, to: value, in: interpreter)
        return true
    }

    func documentObject(codeName: String, in _: VBAInterpreter) -> (any VBAObject)? {
        if let workbookCodeName = workbook.codeName, workbookCodeName.caseInsensitiveCompare(codeName) == .orderedSame {
            return workbookObject
        }
        if workbook.codeName == nil, codeName.caseInsensitiveCompare("ThisWorkbook") == .orderedSame {
            return workbookObject
        }
        guard let sheet = workbook.sheets.first(where: {
            $0.codeName?.caseInsensitiveCompare(codeName) == .orderedSame
        }) else { return nil }
        return worksheetObject(sheet.id)
    }

    func constant(named name: String) -> VBAValue? {
        VBAExcelConstants.values[name.lowercased()].map(VBAValue.integer)
    }

    func createObject(_: String, in _: VBAInterpreter) -> (any VBAObject)? { nil }

    func messageBox(prompt: String, buttons: Int, title: String?) -> Int {
        interaction.messageBox(prompt, buttons, title)
    }

    func inputBox(prompt: String, title: String?, defaultText: String) -> String? {
        interaction.inputBox(prompt, title, defaultText)
    }

    func debugPrint(_ text: String) {
        interaction.debugPrint(text)
    }

    func openURL(_ url: URL) -> Bool {
        interaction.openURL(url)
    }

    func showSendKeys(_ keys: String) {
        interaction.showSendKeys(keys)
    }

    // MARK: - Values

    static func errorCode(_ error: CellError) -> Int {
        switch error {
        case .nullError: return 2000
        case .divideByZero: return 2007
        case .valueError: return 2015
        case .referenceError: return 2023
        case .nameError: return 2029
        case .numberError: return 2036
        case .notAvailable: return 2042
        case .spill: return 2045
        case .calc: return 2050
        case .circularReference: return 2023
        }
    }

    static func cellError(_ code: Int) -> CellError {
        switch code {
        case 2000: return .nullError
        case 2007: return .divideByZero
        case 2023: return .referenceError
        case 2029: return .nameError
        case 2036: return .numberError
        case 2042: return .notAvailable
        case 2045: return .spill
        case 2050: return .calc
        default: return .valueError
        }
    }

    /// What `.Value` reads: numbers in a date format come back as dates.
    static func value(of cell: Cell) -> VBAValue {
        switch cell.value {
        case .empty: return .empty
        case .number(let number):
            return CellFormatter.isDateFormat(cell.style.numberFormat) ? .date(number) : .double(number)
        case .text(let text): return .string(text)
        case .boolean(let flag): return .boolean(flag)
        case .error(let error): return .error(errorCode(error))
        }
    }

    /// Writes a value into a cell as `.Value` does: text is read the way
    /// typing it would be, so `"=A1*2"` is a formula and `"12"` a number.
    func write(_ value: VBAValue, to address: CellAddress, in sheet: inout Worksheet,
               interpreter: VBAInterpreter) throws {
        var cell = sheet[address]
        switch try interpreter.letValue(value) {
        case .empty, .missing, .null:
            cell.value = .empty
            cell.formula = nil
        case .string(let text):
            cell = CellInputParser.cell(from: text, inheriting: cell.style)
            if cell.formula != nil { noteFormulaWritten() }
        case .integer(let number):
            cell.value = .number(Double(number))
            cell.formula = nil
        case .double(let number):
            cell.value = .number(number)
            cell.formula = nil
        case .boolean(let flag):
            cell.value = .boolean(flag)
            cell.formula = nil
        case .date(let serial):
            cell.value = .number(serial)
            cell.formula = nil
            if !CellFormatter.isDateFormat(cell.style.numberFormat) {
                cell.style.numberFormat = serial == serial.rounded(.down) ? "m/d/yyyy" : "m/d/yyyy h:mm"
            }
        case .error(let code):
            cell.value = .error(Self.cellError(code))
            cell.formula = nil
        case .object, .nothing, .array:
            throw VBAError.typeMismatch
        }
        sheet[address] = cell
    }

    // MARK: - Ranges from text

    /// Resolves `"A1"`, `"A1:C3"`, `"B:B"`, `"2:4"`, `"Sheet2!A1"` or a
    /// defined name. `defaultSheet` is where an unqualified reference lands.
    func resolveRange(_ text: String, defaultSheet: Worksheet.ID) throws -> (Worksheet.ID, CellRange) {
        var reference = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: "")
        var sheetID = defaultSheet
        if let bang = reference.lastIndex(of: "!") {
            var sheetName = String(reference[..<bang])
            if sheetName.hasPrefix("'"), sheetName.hasSuffix("'"), sheetName.count >= 2 {
                sheetName = String(sheetName.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
            }
            guard let sheet = workbook.sheet(named: sheetName) else { throw Self.rangeFailed }
            sheetID = sheet.id
            reference = String(reference[reference.index(after: bang)...])
        }
        if reference.contains(",") {
            throw VBAError.notSupported("A range of several areas (\(text))")
        }
        let parts = reference.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 1, let address = CellAddress(a1: parts[0].uppercased()) {
            return (sheetID, CellRange(address))
        }
        if parts.count == 2 {
            if let start = CellAddress(a1: parts[0].uppercased()), let end = CellAddress(a1: parts[1].uppercased()) {
                return (sheetID, CellRange(start: start, end: end).normalized)
            }
            if let first = CellAddress.columnIndex(parts[0].uppercased()),
               let last = CellAddress.columnIndex(parts[1].uppercased()) {
                return (sheetID, CellRange(start: CellAddress(row: 0, column: min(first, last)),
                                           end: CellAddress(row: Worksheet.maximumRowCount - 1, column: max(first, last))))
            }
            if let first = Int(parts[0]), let last = Int(parts[1]), first >= 1, last >= 1 {
                return (sheetID, CellRange(start: CellAddress(row: min(first, last) - 1, column: 0),
                                           end: CellAddress(row: max(first, last) - 1,
                                                            column: Worksheet.maximumColumnCount - 1)))
            }
        }
        // A defined name standing for a range.
        if let name = workbook.definedName(reference, visibleFrom: sheetID) {
            let formula = name.formula.hasPrefix("=") ? String(name.formula.dropFirst()) : name.formula
            guard formula.caseInsensitiveCompare(reference) != .orderedSame else { throw Self.rangeFailed }
            return try resolveRange(formula, defaultSheet: sheetID)
        }
        throw Self.rangeFailed
    }

    static let rangeFailed = VBAError(number: 1004, "Method 'Range' of object '_Global' failed")

    /// Formats a range reference for `Address`.
    static func address(_ range: CellRange, rowAbsolute: Bool = true, columnAbsolute: Bool = true) -> String {
        func cell(_ address: CellAddress) -> String {
            (columnAbsolute ? "$" : "") + CellAddress.columnName(address.column)
                + (rowAbsolute ? "$" : "") + String(address.row + 1)
        }
        let normalized = range.normalized
        if normalized.start.row == 0, normalized.end.row >= Worksheet.maximumRowCount - 1 {
            let first = (columnAbsolute ? "$" : "") + CellAddress.columnName(normalized.start.column)
            let last = (columnAbsolute ? "$" : "") + CellAddress.columnName(normalized.end.column)
            return first + ":" + last
        }
        if normalized.start.column == 0, normalized.end.column >= Worksheet.maximumColumnCount - 1 {
            let prefix = rowAbsolute ? "$" : ""
            return prefix + String(normalized.start.row + 1) + ":" + prefix + String(normalized.end.row + 1)
        }
        return normalized.isSingleCell ? cell(normalized.start) : cell(normalized.start) + ":" + cell(normalized.end)
    }

    /// A reference to a range as formula text, for handing to the formula engine.
    func formulaReference(_ id: Worksheet.ID, _ range: CellRange) throws -> String {
        let name = workbook.sheets[try sheetIndex(id)].name.replacingOccurrences(of: "'", with: "''")
        return "'\(name)'!" + Self.address(range, rowAbsolute: false, columnAbsolute: false)
    }

    // MARK: - Colours

    /// VBA colours are BGR integers; Tables keeps AARRGGBB hex.
    static func colorValue(_ hex: String?) -> Int? {
        guard let hex, let value = UInt32(hex.suffix(6), radix: 16) else { return nil }
        let red = Int(value >> 16 & 0xFF)
        let green = Int(value >> 8 & 0xFF)
        let blue = Int(value & 0xFF)
        return red | green << 8 | blue << 16
    }

    static func colorHex(_ value: Int) -> String {
        let red = value & 0xFF
        let green = value >> 8 & 0xFF
        let blue = value >> 16 & 0xFF
        return String(format: "FF%02X%02X%02X", red, green, blue)
    }
}

// MARK: - Constants

enum VBAExcelConstants {
    static let values: [String: Int] = [
        "xlup": -4162, "xldown": -4121, "xltoleft": -4159, "xltoright": -4161,
        "xlvalues": -4163, "xlformulas": -4123, "xlcomments": -4144,
        "xlcalculationmanual": -4135, "xlcalculationautomatic": -4105, "xlcalculationsemiautomatic": 2,
        "xlgeneral": 1, "xlleft": -4131, "xlcenter": -4108, "xlright": -4152, "xljustify": -4130,
        "xltop": -4160, "xlbottom": -4107, "xlnone": -4142, "xlautomatic": -4105,
        "xlascending": 1, "xldescending": 2, "xlyes": 1, "xlno": 2, "xlguess": 0,
        "xlpasteall": -4104, "xlpastevalues": -4163, "xlpasteformats": -4122, "xlpasteformulas": -4123,
        "xlpastevaluesandnumberformats": 12, "xlpasteformulasandnumberformats": 11,
        "xlcelltypelastcell": 11, "xlcelltypeconstants": 2, "xlcelltypeformulas": -4123,
        "xlcelltypeblanks": 4, "xlcelltypevisible": 12,
        "xlwhole": 1, "xlpart": 2, "xlbyrows": 1, "xlbycolumns": 2, "xlnext": 1, "xlprevious": 2,
        "xlerrdiv0": 2007, "xlerrna": 2042, "xlerrname": 2029, "xlerrnull": 2000, "xlerrnum": 2036,
        "xlerrref": 2023, "xlerrvalue": 2015, "xlerrspill": 2045, "xlerrcalc": 2050,
        "xlsheetvisible": -1, "xlsheethidden": 0, "xlsheetveryhidden": 2,
        "xlshiftup": -4162, "xlshiftdown": -4121, "xlshifttoleft": -4159, "xlshifttoright": -4161,
        "xlcontinuous": 1, "xldash": -4115, "xldot": -4118, "xldouble": -4119, "xldashdot": 4,
        "xldashdotdot": 5, "xllinestylenone": -4142,
        "xlhairline": 1, "xlthin": 2, "xlmedium": -4138, "xlthick": 4,
        "xledgeleft": 7, "xledgetop": 8, "xledgebottom": 9, "xledgeright": 10,
        "xlinsidevertical": 11, "xlinsidehorizontal": 12, "xldiagonaldown": 5, "xldiagonalup": 6,
        "xlunderlinestylesingle": 2, "xlunderlinestylenone": -4142, "xlunderlinestyledouble": -4119,
        "xla1": 1, "xlr1c1": -4150, "xlworksheet": -4167, "xlwbatworksheet": -4167,
        "xlsolid": 1, "xlcolorindexnone": -4142, "xlcolorindexautomatic": -4105,
        "xltopten": 1, "xland": 1, "xlor": 2, "xlfilterinplace": 1, "xlfiltercopy": 2,
        "xlopenxmlworkbook": 51, "xlopenxmlworkbookmacroenabled": 52, "xlcsv": 6,
        "xlwait": 2, "xldefault": -4143, "xlnorthwestarrow": 1, "xlibeam": 3,
        "xlmaximized": -4137, "xlminimized": -4140, "xlnormal": -4143,
    ]
}
