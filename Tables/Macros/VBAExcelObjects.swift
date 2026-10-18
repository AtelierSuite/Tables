import Foundation
import TablesEngine

// The objects of the Excel object model that Tables can stand behind.

private func lettered(_ value: VBAValue, _ interpreter: VBAInterpreter) throws -> VBAValue {
    try interpreter.letValue(value)
}

extension VBAArguments {
    func integer(_ position: Int, _ name: String? = nil, in interpreter: VBAInterpreter) throws -> Int? {
        try value(position, name).map { try interpreter.letValue($0).asInteger() }
    }

    func string(_ position: Int, _ name: String? = nil, in interpreter: VBAInterpreter) throws -> String? {
        try value(position, name).map { try interpreter.letValue($0).asString() }
    }

    func boolean(_ position: Int, _ name: String? = nil, in interpreter: VBAInterpreter) throws -> Bool? {
        try value(position, name).map { try interpreter.letValue($0).asBoolean() }
    }
}

// MARK: - Application

final class VBAApplicationObject: VBAObject {
    unowned let host: VBAExcelHost
    var typeName: String { "Application" }

    init(host: VBAExcelHost) {
        self.host = host
    }

    /// The members of `Application` that may also be written unqualified.
    func globalMember(_ name: String, _ arguments: VBAArguments, in interpreter: VBAInterpreter) throws -> VBAValue? {
        let sheet = host.activeWorksheet
        switch name.lowercased() {
        case "range", "cells", "rows", "columns":
            return try sheet.member(name, arguments, in: interpreter)
        case "activesheet":
            return .object(host.activeWorksheet)
        case "activecell":
            return .object(host.range(host.activeSheetID, CellRange(host.activeCell)))
        case "selection":
            return .object(host.range(host.activeSheetID, host.selection))
        case "worksheets", "sheets":
            let collection = VBASheetsObject(host: host, worksheetsOnly: name.lowercased() == "worksheets")
            return arguments.isEmpty ? .object(collection) : try collection.member("", arguments, in: interpreter)
        case "worksheetfunction":
            return .object(VBAWorksheetFunctionObject(host: host, raisesErrors: true))
        case "evaluate":
            return try evaluate(arguments.required(0), in: interpreter)
        case "calculate":
            host.refreshIfStale()
            return .empty
        case "union":
            return try union(arguments, in: interpreter)
        case "intersect":
            return try intersect(arguments, in: interpreter)
        default:
            return nil
        }
    }

    private func ranges(_ arguments: VBAArguments) throws -> [VBARangeObject] {
        try arguments.positional.compactMap { value -> VBARangeObject? in
            guard let value else { return nil }
            guard case .object(let object) = value, let range = object as? VBARangeObject else {
                throw VBAError.typeMismatch
            }
            return range
        }
    }

    /// Only contiguous unions — a rectangle grown to cover both — can be
    /// represented; anything else would need several areas.
    private func union(_ arguments: VBAArguments, in _: VBAInterpreter) throws -> VBAValue {
        let all = try ranges(arguments)
        guard let first = all.first else { throw VBAError.invalidCall }
        var box = first.range
        for range in all.dropFirst() {
            guard range.sheetID == first.sheetID else { throw VBAError(number: 1004, "Union of ranges on different sheets") }
            let merged = box.union(range.range)
            guard merged.cellCount == box.cellCount + range.range.cellCount - overlap(box, range.range) else {
                throw VBAError.notSupported("A union that is not a rectangle")
            }
            box = merged
        }
        return .object(host.range(first.sheetID, box))
    }

    private func overlap(_ a: CellRange, _ b: CellRange) -> Int {
        let rows = max(0, min(a.rowRange.upperBound, b.rowRange.upperBound) - max(a.rowRange.lowerBound, b.rowRange.lowerBound) + 1)
        let columns = max(0, min(a.columnRange.upperBound, b.columnRange.upperBound)
                          - max(a.columnRange.lowerBound, b.columnRange.lowerBound) + 1)
        return rows * columns
    }

    private func intersect(_ arguments: VBAArguments, in _: VBAInterpreter) throws -> VBAValue {
        let all = try ranges(arguments)
        guard let first = all.first else { throw VBAError.invalidCall }
        var top = first.range.start.row
        var left = first.range.start.column
        var bottom = first.range.end.row
        var right = first.range.end.column
        for range in all.dropFirst() {
            guard range.sheetID == first.sheetID else { return .nothing }
            top = max(top, range.range.start.row)
            left = max(left, range.range.start.column)
            bottom = min(bottom, range.range.end.row)
            right = min(right, range.range.end.column)
        }
        guard top <= bottom, left <= right else { return .nothing }
        return .object(host.range(first.sheetID, CellRange(start: CellAddress(row: top, column: left),
                                                            end: CellAddress(row: bottom, column: right))))
    }

    /// `Evaluate("SUM(A1:A3)")` and `[A1]`: a formula, worked out by the
    /// spreadsheet's own engine against the active sheet.
    func evaluate(_ expression: VBAValue, in interpreter: VBAInterpreter) throws -> VBAValue {
        let text = try interpreter.letValue(expression).asString()
        var body = text.hasPrefix("=") ? String(text.dropFirst()) : text
        if let (sheetID, range) = try? host.resolveRange(body, defaultSheet: host.activeSheetID) {
            return .object(host.range(sheetID, range))
        }
        body = body.trimmingCharacters(in: .whitespaces)
        host.refreshIfStale()
        let value = CalculationEngine.preview(formula: body, in: host.workbook,
                                              sheetIndex: try host.sheetIndex(host.activeSheetID))
        return VBAExcelHost.value(of: Cell(value: value, formula: nil, style: .default))
    }

    func member(_ name: String, _ arguments: VBAArguments, in interpreter: VBAInterpreter) throws -> VBAValue {
        let key = name.lowercased()
        if let value = try globalMember(name, arguments, in: interpreter) { return value }
        if let setting = host.applicationSettings[key] { return setting }
        switch key {
        case "", "name", "value": return .string("Microsoft Excel")
        case "application": return .object(self)
        case "thisworkbook", "activeworkbook": return .object(host.workbookObject)
        case "workbooks": return .object(VBAWorkbooksObject(host: host))
        case "version": return .string("16.0")
        case "build": return .integer(0)
        case "operatingsystem": return .string("Tables")
        case "username": return .string("")
        case "pathseparator": return .string("/")
        case "defaultfilepath": return .string(interpreter.fileSystem.map { VBAFileSystem.displayPath($0.root) } ?? "")
        case "international": return .empty
        case "decimalseparator": return .string(".")
        case "thousandsseparator": return .string(",")
        case "inputbox":
            let prompt = try arguments.string(0, "Prompt", in: interpreter) ?? ""
            let title = try arguments.string(1, "Title", in: interpreter)
            let defaultText = try arguments.string(2, "Default", in: interpreter) ?? ""
            guard let reply = host.inputBox(prompt: prompt, title: title, defaultText: defaultText) else {
                return .boolean(false)
            }
            // Type:=1 asks for a number.
            if try arguments.integer(7, "Type", in: interpreter) == 1, let number = VBAValue.parseNumber(reply) {
                return .double(number)
            }
            return .string(reply)
        case "run":
            let macro = try arguments.required(0, "Macro")
            var target = try interpreter.letValue(macro).asString()
            if let bang = target.lastIndex(of: "!") { target = String(target[target.index(after: bang)...]) }
            let parts = target.split(separator: ".").map(String.init)
            let rest = arguments.positional.dropFirst().map { $0 ?? .missing }
            return try interpreter.run(parts.last ?? target, in: parts.count > 1 ? parts[0] : nil, arguments: Array(rest))
        case "wait", "volatile", "doevents", "calculatefull", "calculatefullrebuild", "screenrefresh":
            host.refreshIfStale()
            return key == "wait" ? .boolean(true) : .empty
        case "max", "min", "sum", "average", "count", "counta", "vlookup", "hlookup", "match", "index", "round",
             "countif", "sumif", "trim", "text", "isna", "iserror":
            // `Application.Sum` works like WorksheetFunction.Sum but hands
            // back an error value instead of raising one.
            return try VBAWorksheetFunctionObject(host: host, raisesErrors: false).member(name, arguments, in: interpreter)
        case "ontime", "sendkeys", "getopenfilename", "getsaveasfilename", "filedialog", "quit":
            throw VBAError.notSupported("Application.\(name)")
        default:
            throw VBAError.unsupportedMember("Application.\(name)")
        }
    }

    func setMember(_ name: String, _: VBAArguments, to value: VBAValue,
                   in interpreter: VBAInterpreter) throws {
        let key = name.lowercased()
        switch key {
        case "activecell", "selection":
            guard case .object(let range)? = try globalMember(name, .none, in: interpreter) else { return }
            try range.setMember("", .none, to: value, in: interpreter)
        case "cutcopymode":
            host.clipboard = nil
            host.applicationSettings[key] = .boolean(false)
        default:
            guard host.applicationSettings[key] != nil else { throw VBAError.unsupportedMember("Application.\(name)") }
            host.applicationSettings[key] = try interpreter.letValue(value)
        }
    }
}

// MARK: - Workbooks

final class VBAWorkbooksObject: VBAObject {
    unowned let host: VBAExcelHost
    var typeName: String { "Workbooks" }

    init(host: VBAExcelHost) {
        self.host = host
    }

    func member(_ name: String, _ arguments: VBAArguments, in interpreter: VBAInterpreter) throws -> VBAValue {
        switch name.lowercased() {
        case "count": return .integer(1)
        case "", "item":
            let selector = try interpreter.letValue(arguments.required(0))
            if case .string(let text) = selector,
               text.caseInsensitiveCompare(host.workbookName) != .orderedSame,
               !text.lowercased().hasPrefix(host.workbookName.lowercased() + ".") {
                throw VBAError.subscriptOutOfRange
            }
            if case .string = selector {
                // A name was matched against the workbook's above.
            } else if try selector.asInteger() != 1 {
                throw VBAError.subscriptOutOfRange
            }
            return .object(host.workbookObject)
        case "open", "add":
            throw VBAError.notSupported("Opening or creating other workbooks")
        default:
            throw VBAError.unsupportedMember(name)
        }
    }

    func elements(in _: VBAInterpreter) throws -> [VBAValue] { [.object(host.workbookObject)] }
}

final class VBAWorkbookObject: VBAObject {
    unowned let host: VBAExcelHost
    var typeName: String { "Workbook" }

    init(host: VBAExcelHost) {
        self.host = host
    }

    func member(_ name: String, _ arguments: VBAArguments, in interpreter: VBAInterpreter) throws -> VBAValue {
        switch name.lowercased() {
        case "", "name": return .string(host.workbookName)
        // The workbook's working folder stands in for the folder it is in, so
        // `ThisWorkbook.Path & "\data.csv"` lands where file statements look.
        case "path": return .string(interpreter.fileSystem.map { VBAFileSystem.displayPath($0.root) } ?? "")
        case "fullname":
            guard let files = interpreter.fileSystem else { return .string(host.workbookName) }
            return .string(VBAFileSystem.displayPath(files.root.appendingPathComponent(host.workbookName)))
        case "followhyperlink":
            let address = try interpreter.letValue(arguments.required(0, "Address")).asString()
            guard let url = VBALibrary.openableURL(address) else {
                throw VBAError(number: 445, String(localized: "Macro.Unavailable.Shell"))
            }
            guard host.openURL(url) else { throw VBAFileSystem.permissionDenied }
            return .empty
        case "codename": return .string(host.workbook.codeName ?? "ThisWorkbook")
        case "worksheets", "sheets":
            let collection = VBASheetsObject(host: host, worksheetsOnly: name.lowercased() == "worksheets")
            return arguments.isEmpty ? .object(collection) : try collection.member("", arguments, in: interpreter)
        case "activesheet": return .object(host.activeWorksheet)
        case "application", "parent": return .object(host.application)
        case "save", "activate", "refreshall", "calculate":
            host.refreshIfStale()
            return .empty
        case "saved": return .boolean(false)
        case "readonly": return .boolean(false)
        case "close", "saveas", "savecopyas", "printout", "protect", "unprotect":
            throw VBAError.notSupported("Workbook.\(name)")
        default:
            throw VBAError.unsupportedMember(name)
        }
    }

    func setMember(_ name: String, _: VBAArguments, to _: VBAValue,
                   in _: VBAInterpreter) throws {
        // `ThisWorkbook.Saved = True` is how macros silence the save prompt.
        guard name.lowercased() == "saved" else { throw VBAError.unsupportedMember(name) }
    }
}

// MARK: - Sheets

final class VBASheetsObject: VBAObject {
    unowned let host: VBAExcelHost
    /// `Worksheets` leaves chart sheets out; `Sheets` has them all.
    let worksheetsOnly: Bool
    var typeName: String { "Sheets" }

    init(host: VBAExcelHost, worksheetsOnly: Bool) {
        self.host = host
        self.worksheetsOnly = worksheetsOnly
    }

    private var sheets: [Worksheet] {
        worksheetsOnly ? host.workbook.sheets.filter { !$0.isChartSheet } : host.workbook.sheets
    }

    private func sheet(_ selector: VBAValue, in interpreter: VBAInterpreter) throws -> Worksheet {
        let selector = try interpreter.letValue(selector)
        if case .string(let name) = selector {
            guard let sheet = sheets.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                throw VBAError.subscriptOutOfRange
            }
            return sheet
        }
        let index = try selector.asInteger()
        guard index >= 1, index <= sheets.count else { throw VBAError.subscriptOutOfRange }
        return sheets[index - 1]
    }

    func member(_ name: String, _ arguments: VBAArguments, in interpreter: VBAInterpreter) throws -> VBAValue {
        switch name.lowercased() {
        case "", "item":
            return .object(host.worksheetObject(try sheet(arguments.required(0, "Index"), in: interpreter).id))
        case "count":
            return .integer(sheets.count)
        case "add":
            var position = host.workbook.index(of: host.activeSheetID) ?? 0
            if let before = arguments.value(0, "Before") {
                guard case .object(let object) = before, let target = object as? VBAWorksheetObject else {
                    throw VBAError.typeMismatch
                }
                position = try host.sheetIndex(target.sheetID)
            } else if let after = arguments.value(1, "After") {
                guard case .object(let object) = after, let target = object as? VBAWorksheetObject else {
                    throw VBAError.typeMismatch
                }
                position = try host.sheetIndex(target.sheetID) + 1
            }
            let count = max(1, try arguments.integer(2, "Count", in: interpreter) ?? 1)
            var newID = host.activeSheetID
            for offset in 0..<count {
                host.modifyWorkbook { workbook in
                    newID = workbook.addSheet(at: min(position + offset, workbook.sheets.count))
                }
            }
            try host.activate(sheet: newID)
            return .object(host.worksheetObject(newID))
        case "application", "parent":
            return .object(host.application)
        case "select":
            return .empty
        default:
            throw VBAError.unsupportedMember(name)
        }
    }

    func elements(in _: VBAInterpreter) throws -> [VBAValue] {
        sheets.map { .object(host.worksheetObject($0.id)) }
    }
}

final class VBAWorksheetObject: VBAObject {
    unowned let host: VBAExcelHost
    let sheetID: Worksheet.ID
    var typeName: String { "Worksheet" }

    init(host: VBAExcelHost, sheetID: Worksheet.ID) {
        self.host = host
        self.sheetID = sheetID
    }

    private var wholeSheet: CellRange {
        CellRange(start: CellAddress(row: 0, column: 0),
                  end: CellAddress(row: Worksheet.maximumRowCount - 1, column: Worksheet.maximumColumnCount - 1))
    }

    func member(_ name: String, _ arguments: VBAArguments, in interpreter: VBAInterpreter) throws -> VBAValue {
        let sheet = try host.sheet(sheetID)
        switch name.lowercased() {
        case "", "name":
            return .string(sheet.name)
        case "codename":
            return .string(sheet.codeName ?? "")
        case "index":
            return .integer(try host.sheetIndex(sheetID) + 1)
        case "visible":
            return .integer(sheet.isHidden ? 0 : -1)
        case "range", "cells", "rows", "columns":
            return try host.range(sheetID, wholeSheet).member(name, arguments, in: interpreter)
        case "usedrange":
            return .object(host.range(sheetID, VBARangeObject.usedRange(of: sheet)))
        case "activate", "select":
            try host.activate(sheet: sheetID)
            return .empty
        case "delete":
            guard host.workbook.sheets.count > 1 else {
                throw VBAError(number: 1004, "A workbook must contain at least one visible worksheet")
            }
            host.modifyWorkbook { _ = $0.removeSheet(sheetID) }
            if host.activeSheetID == sheetID, let first = host.workbook.visibleSheets.first {
                try host.activate(sheet: first.id)
            }
            return .boolean(true)
        case "copy":
            var copyID: Worksheet.ID?
            host.modifyWorkbook { copyID = $0.duplicateSheet(sheetID) }
            guard let copyID else { throw VBAError(number: 1004, "Copy method of Worksheet class failed") }
            if let after = arguments.value(1, "After"), case .object(let object) = after,
               let target = object as? VBAWorksheetObject {
                let destination = try host.sheetIndex(target.sheetID) + 1
                host.modifyWorkbook { $0.moveSheet(copyID, to: min(destination, $0.sheets.count - 1)) }
            } else if let before = arguments.value(0, "Before"), case .object(let object) = before,
                      let target = object as? VBAWorksheetObject {
                let destination = try host.sheetIndex(target.sheetID)
                host.modifyWorkbook { $0.moveSheet(copyID, to: destination) }
            }
            try host.activate(sheet: copyID)
            return .empty
        case "move":
            if let after = arguments.value(1, "After"), case .object(let object) = after,
               let target = object as? VBAWorksheetObject {
                let destination = try host.sheetIndex(target.sheetID)
                host.modifyWorkbook { $0.moveSheet(sheetID, to: destination) }
            } else if let before = arguments.value(0, "Before"), case .object(let object) = before,
                      let target = object as? VBAWorksheetObject {
                let current = try host.sheetIndex(sheetID)
                let destination = try host.sheetIndex(target.sheetID)
                host.modifyWorkbook { $0.moveSheet(sheetID, to: destination > current ? destination - 1 : destination) }
            }
            return .empty
        case "next", "previous":
            let index = try host.sheetIndex(sheetID) + (name.lowercased() == "next" ? 1 : -1)
            guard host.workbook.sheets.indices.contains(index) else { return .nothing }
            return .object(host.worksheetObject(host.workbook.sheets[index].id))
        case "parent":
            return .object(host.workbookObject)
        case "application":
            return .object(host.application)
        case "calculate":
            host.refreshIfStale()
            return .empty
        case "evaluate":
            try host.activate(sheet: sheetID)
            return try host.application.evaluate(arguments.required(0), in: interpreter)
        case "paste":
            guard let destination = arguments.value(0, "Destination"), case .object(let object) = destination,
                  let range = object as? VBARangeObject else {
                return try host.range(host.activeSheetID, host.selection).member("PasteSpecial", .none, in: interpreter)
            }
            return try range.member("PasteSpecial", .none, in: interpreter)
        case "protect", "unprotect":
            return .empty
        case "protectcontents", "autofiltermode":
            return .boolean(false)
        case "standardwidth":
            return .double(Worksheet.columnWidthCharacters(points: Worksheet.defaultColumnWidth))
        default:
            throw VBAError.unsupportedMember("Worksheet.\(name)")
        }
    }

    func setMember(_ name: String, _: VBAArguments, to value: VBAValue,
                   in interpreter: VBAInterpreter) throws {
        switch name.lowercased() {
        case "", "name":
            let newName = Worksheet.sanitizedName(try lettered(value, interpreter).asString())
            let clash = host.workbook.sheets.contains {
                $0.id != sheetID && $0.name.caseInsensitiveCompare(newName) == .orderedSame
            }
            guard !clash else { throw VBAError(number: 1004, "That name is already taken") }
            host.modifyWorkbook { $0.renameSheet(sheetID, to: newName) }
        case "visible":
            let visible = try lettered(value, interpreter)
            let isVisible: Bool
            if case .boolean(let flag) = visible { isVisible = flag } else { isVisible = try visible.asInteger() == -1 }
            var succeeded = true
            host.modifyWorkbook { succeeded = $0.setSheet(sheetID, hidden: !isVisible) }
            guard succeeded else { throw VBAError(number: 1004, "Unable to set the Visible property of the Worksheet class") }
        case "autofiltermode", "enableselection", "scrollarea", "displaypagebreaks":
            return
        default:
            throw VBAError.unsupportedMember("Worksheet.\(name)")
        }
    }
}

// MARK: - WorksheetFunction

/// `WorksheetFunction.Sum(…)` and friends, answered by the formula engine:
/// the call is written out as formula text and evaluated, so every function
/// the grid knows is available to macros too.
final class VBAWorksheetFunctionObject: VBAObject {
    unowned let host: VBAExcelHost
    /// `WorksheetFunction` raises an error where `Application` returns one.
    let raisesErrors: Bool
    var typeName: String { "WorksheetFunction" }

    init(host: VBAExcelHost, raisesErrors: Bool) {
        self.host = host
        self.raisesErrors = raisesErrors
    }

    func member(_ name: String, _ arguments: VBAArguments, in interpreter: VBAInterpreter) throws -> VBAValue {
        var parts: [String] = []
        for argument in arguments.positional {
            guard let argument else {
                parts.append("")
                continue
            }
            parts.append(try formulaText(argument, in: interpreter))
        }
        let formula = name.uppercased() + "(" + parts.joined(separator: ",") + ")"
        host.refreshIfStale()
        let value = CalculationEngine.preview(formula: formula, in: host.workbook,
                                              sheetIndex: try host.sheetIndex(host.activeSheetID))
        if case .error(let error) = value {
            if case .nameError = error { throw VBAError.unsupportedMember("WorksheetFunction.\(name)") }
            if raisesErrors {
                throw VBAError(number: 1004, "Unable to get the \(name) property of the WorksheetFunction class")
            }
        }
        return VBAExcelHost.value(of: Cell(value: value, formula: nil, style: .default))
    }

    private func formulaText(_ value: VBAValue, in interpreter: VBAInterpreter) throws -> String {
        switch value {
        case .object(let object):
            if let range = object as? VBARangeObject { return try host.formulaReference(range.sheetID, range.range) }
            return try formulaText(interpreter.letValue(value), in: interpreter)
        case .array(let array):
            guard array.isAllocated else { return "{}" }
            if array.dimensions == 1 {
                return "{" + (try array.elements.map { try formulaText($0, in: interpreter) }.joined(separator: ",")) + "}"
            }
            guard array.dimensions == 2 else { throw VBAError.typeMismatch }
            var rows: [String] = []
            for row in 0..<array.lengths[0] {
                var cells: [String] = []
                for column in 0..<array.lengths[1] {
                    cells.append(try formulaText(array.elements[row + column * array.lengths[0]], in: interpreter))
                }
                rows.append(cells.joined(separator: ","))
            }
            return "{" + rows.joined(separator: ";") + "}"
        case .string(let text):
            return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        case .boolean(let flag):
            return flag ? "TRUE" : "FALSE"
        case .empty, .missing:
            return ""
        case .error(let code):
            return VBAExcelHost.cellError(code).rawValue
        default:
            return VBAValue.format(try value.asDouble())
        }
    }
}
