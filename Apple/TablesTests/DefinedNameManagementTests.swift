import Foundation
import Testing
@testable import Tables
@testable import TablesEngine
@testable import TablesMacros

/// Covers managing a workbook's names: Excel's rules for spelling them,
/// adding, renaming, repointing and deleting them, going to their ranges,
/// and offering them while a formula is typed.
@Suite("Defined name management")
@MainActor
struct DefinedNameManagementTests {

    // MARK: - Fixtures

    /// "Data" holds 1, 2, 3 in A1:A3 under no label; "Other" is empty.
    private func workbook(names: [DefinedName] = [], formulas: [String: String] = [:]) -> Workbook {
        var data = Worksheet(name: "Data")
        for row in 0..<3 { data[CellAddress(row: row, column: 0)] = Cell(value: .number(Double(row + 1))) }
        for (address, formula) in formulas {
            data[CellAddress(a1: address)!] = CellInputParser.cell(from: formula, inheriting: .default)
        }
        var book = Workbook(sheets: [data, Worksheet(name: "Other")], definedNames: names)
        book.recalculate()
        return book
    }

    private func value(_ book: Workbook, _ address: String, sheet: Int = 0) -> CellValue {
        book.sheets[sheet][CellAddress(a1: address)!].value
    }

    private func formula(_ book: Workbook, _ address: String, sheet: Int = 0) -> String? {
        book.sheets[sheet][CellAddress(a1: address)!].formula
    }

    // MARK: - Spelling

    @Test("Names Excel accepts are accepted", arguments: [
        "Sales", "_tax", "\\path", "Q1.Total", "Rate2024", "XFE1", "売上", "A1B", "R1C1x",
    ])
    func acceptedNames(name: String) {
        #expect(DefinedName.spellingError(of: name) == nil)
    }

    @Test("Names Excel refuses are refused, each with its reason", arguments: [
        ("", DefinedNameError.empty),
        ("Sales Total", .invalidCharacters),
        (" Sales", .invalidCharacters),
        ("Sales-Total", .invalidCharacters),
        ("1Sales", .invalidStart),
        (".Sales", .invalidStart),
        ("A1", .looksLikeReference),
        ("xfd1048576", .looksLikeReference),
        ("TAX2023", .looksLikeReference),
        ("R1C1", .looksLikeReference),
        ("rc", .looksLikeReference),
        ("R", .looksLikeReference),
        ("c", .looksLikeReference),
        ("R12", .looksLikeReference),
        ("TRUE", .looksLikeReference),
        ("_xlnm.Print_Area", .reserved),
        (String(repeating: "a", count: 256), .tooLong),
    ])
    func refusedNames(name: String, error: DefinedNameError) {
        #expect(DefinedName.spellingError(of: name) == error)
        #expect(!error.message.isEmpty)
    }

    @Test("A name must be unique within its scope, ignoring case, but may repeat in another")
    func uniquenessIsPerScope() throws {
        var book = workbook(names: [DefinedName(name: "Rate", formula: "1", scope: nil)])
        let sheet = book.sheets[0].id
        #expect(book.definedNameError(for: "RATE", scope: nil) == .duplicate)
        #expect(book.definedNameError(for: "rate", scope: sheet) == nil)

        try book.addDefinedName("rate", refersTo: "2", scope: sheet)
        #expect(throws: DefinedNameError.duplicate) { try book.addDefinedName("Rate", refersTo: "3", scope: sheet) }
        #expect(book.definedNames.count == 2)
        // Changing only the case of its own name is not a clash with itself.
        #expect(book.definedNameError(for: "RATE", scope: nil, replacing: book.definedNames[0]) == nil)
    }

    // MARK: - Adding

    @Test("A name made from a selection refers to it anchored, on its sheet, quoted where it must be")
    func formulaForSelection() {
        let range = CellRange(start: CellAddress(a1: "B4")!, end: CellAddress(a1: "A2")!)
        #expect(DefinedName.formula(for: range, onSheetNamed: "Data") == "Data!$A$2:$B$4")
        #expect(DefinedName.formula(for: range, onSheetNamed: "Q1 Sales") == "'Q1 Sales'!$A$2:$B$4")
        #expect(DefinedName.formula(for: CellRange(CellAddress(a1: "C3")!), onSheetNamed: "Data") == "Data!$C$3")
    }

    @Test("Adding a name brings formulas already using it to life")
    func addingResolvesWaitingFormulas() throws {
        var book = workbook(formulas: ["B1": "=SUM(Values)"])
        #expect(value(book, "B1").errorValue == .nameError)
        try book.addDefinedName("Values", refersTo: "=Data!$A$1:$A$3", scope: nil)
        #expect(book.definedNames == [DefinedName(name: "Values", formula: "Data!$A$1:$A$3", scope: nil)])
        #expect(value(book, "B1") == .number(6))
    }

    @Test("A name refused leaves the workbook as it was")
    func refusalChangesNothing() {
        var book = workbook()
        let before = book
        #expect(throws: DefinedNameError.invalidCharacters) {
            try book.addDefinedName("Two words", refersTo: "=1", scope: nil)
        }
        #expect(throws: DefinedNameError.invalidFormula) { try book.addDefinedName("Ok", refersTo: "=SUM(", scope: nil) }
        #expect(throws: DefinedNameError.invalidFormula) { try book.addDefinedName("Ok", refersTo: "  ", scope: nil) }
        #expect(book == before)
    }

    // MARK: - Renaming

    @Test("Renaming a name rewrites the formulas using it, and they still work")
    func renameRewritesFormulas() throws {
        var book = workbook(
            names: [
                DefinedName(name: "Values", formula: "Data!$A$1:$A$3", scope: nil),
                DefinedName(name: "Doubled", formula: "SUM(Values)*2", scope: nil),
            ],
            formulas: [
                "B1": "=SUM(values)+SUM(Data!Values)",
                "B2": "=Doubled",
                // A string, and a function spelled like the name, are not uses.
                "B3": "=\"Values\"&COUNT(Values)",
            ]
        )
        book.sheets[0].conditionalRules = [
            ConditionalRule(ranges: [CellRange(CellAddress(a1: "A1")!)], formulas: ["A1>SUM(Values)"], priority: 1,
                            style: ConditionalStyle()),
        ]
        #expect(value(book, "B1") == .number(12))

        try book.renameDefinedName("Values", scope: nil, to: "Sales")
        #expect(book.definedNames.map(\.name) == ["Sales", "Doubled"])
        #expect(formula(book, "B1") == "SUM(Sales)+SUM(Data!Sales)")
        #expect(formula(book, "B3") == "\"Values\"&COUNT(Sales)")
        #expect(book.definedNames[1].formula == "SUM(Sales)*2")
        #expect(book.sheets[0].conditionalRules[0].formulas == ["A1>SUM(Sales)"])
        #expect(value(book, "B1") == .number(12))
        #expect(value(book, "B2") == .number(12))
    }

    @Test("Renaming a name leaves alone a sheet's own name of the same spelling that hides it")
    func renameRespectsShadowing() throws {
        let book0 = workbook()
        let other = book0.sheets[1].id
        var book = book0
        book.definedNames = [
            DefinedName(name: "Rate", formula: "2", scope: nil),
            DefinedName(name: "Rate", formula: "100", scope: other),
        ]
        book.sheets[0][CellAddress(a1: "B1")!] = CellInputParser.cell(from: "=Rate", inheriting: .default)
        book.sheets[1][CellAddress(a1: "B1")!] = CellInputParser.cell(from: "=Rate+Data!Rate", inheriting: .default)
        book.recalculate()

        try book.renameDefinedName("Rate", scope: nil, to: "BaseRate")
        #expect(formula(book, "B1", sheet: 0) == "BaseRate")
        // Unqualified on "Other" meant its own Rate; qualified with "Data" meant the workbook's.
        #expect(formula(book, "B1", sheet: 1) == "Rate+Data!BaseRate")
        #expect(value(book, "B1", sheet: 1) == .number(102))

        try book.renameDefinedName("Rate", scope: other, to: "LocalRate")
        #expect(formula(book, "B1", sheet: 1) == "LocalRate+Data!BaseRate")
        #expect(formula(book, "B1", sheet: 0) == "BaseRate")
    }

    @Test("Renaming to a name already taken is refused and changes nothing")
    func renameRefused() throws {
        var book = workbook(names: [
            DefinedName(name: "One", formula: "1", scope: nil),
            DefinedName(name: "Two", formula: "2", scope: nil),
        ], formulas: ["B1": "=One"])
        let before = book
        #expect(throws: DefinedNameError.duplicate) { try book.renameDefinedName("One", scope: nil, to: "two") }
        #expect(throws: DefinedNameError.looksLikeReference) { try book.renameDefinedName("One", scope: nil, to: "B2") }
        #expect(throws: DefinedNameError.notFound) { try book.renameDefinedName("Three", scope: nil, to: "Four") }
        #expect(book == before)
    }

    // MARK: - Repointing and deleting

    @Test("Pointing a name elsewhere recalculates what uses it")
    func repoint() throws {
        var book = workbook(names: [DefinedName(name: "Pick", formula: "Data!$A$1", scope: nil)],
                            formulas: ["B1": "=Pick*10"])
        #expect(value(book, "B1") == .number(10))
        try book.setDefinedNameFormula("pick", scope: nil, to: "=Data!$A$3")
        #expect(book.definedNames[0].formula == "Data!$A$3")
        #expect(value(book, "B1") == .number(30))
        #expect(throws: DefinedNameError.invalidFormula) { try book.setDefinedNameFormula("Pick", scope: nil, to: "=(") }
    }

    @Test("Deleting a name leaves the formulas using it showing #NAME?")
    func delete() throws {
        var book = workbook(names: [DefinedName(name: "Pick", formula: "Data!$A$1", scope: nil)],
                            formulas: ["B1": "=Pick*10"])
        try book.removeDefinedName("Pick", scope: nil)
        #expect(book.definedNames.isEmpty)
        #expect(formula(book, "B1") == "Pick*10")
        #expect(value(book, "B1").errorValue == .nameError)
    }

    // MARK: - Names that are only kept

    @Test("Excel's own names and hidden names are listed nowhere and cannot be changed")
    func keptNamesAreNotEditable() {
        var book = workbook(names: [
            DefinedName(name: "_xlnm.Print_Area", formula: "Data!$A$1:$B$3", scope: nil),
            DefinedName(name: "Secret", formula: "42", scope: nil, isHidden: true),
            DefinedName(name: "Shown", formula: "1", scope: nil),
        ])
        #expect(book.editableDefinedNames.map(\.name) == ["Shown"])
        #expect(throws: DefinedNameError.notFound) { try book.renameDefinedName("Secret", scope: nil, to: "Open") }
        #expect(throws: DefinedNameError.notFound) { try book.removeDefinedName("_xlnm.Print_Area", scope: nil) }
        #expect(throws: DefinedNameError.notFound) { try book.setDefinedNameFormula("Secret", scope: nil, to: "1") }
        #expect(book.definedNameCompletions(for: "s", visibleFrom: nil).map(\.name) == ["Shown"])
    }

    @Test("A hidden name stays hidden through a save, and still works in formulas")
    func hiddenNameRoundTrip() throws {
        let book = workbook(names: [DefinedName(name: "Secret", formula: "42", scope: nil, isHidden: true)],
                            formulas: ["B1": "=Secret"])
        let data = try XLSXWriter.data(from: book)
        let xml = String(decoding: try ZipArchive.entries(in: data)["xl/workbook.xml"]!, as: UTF8.self)
        #expect(xml.contains("<definedName name=\"Secret\" hidden=\"1\">42</definedName>"))
        let reopened = try XLSXReader.workbook(from: data)
        #expect(reopened.definedNames == book.definedNames)
        #expect(reopened.definedNames.first?.isHidden == true)
        #expect(value(reopened, "B1") == .number(42))
    }

    @Test("Names made and renamed here are written to the file and read back")
    func managedNamesRoundTrip() throws {
        var book = workbook(formulas: ["B1": "=SUM(Values)"])
        let other = book.sheets[1].id
        try book.addDefinedName("Values", refersTo: "=Data!$A$1:$A$3", scope: nil)
        try book.addDefinedName("Local", refersTo: "=7", scope: other)
        try book.renameDefinedName("Values", scope: nil, to: "Totals")
        let data = try XLSXWriter.data(from: book)
        let xml = String(decoding: try ZipArchive.entries(in: data)["xl/workbook.xml"]!, as: UTF8.self)
        #expect(xml.contains("<definedName name=\"Totals\">Data!$A$1:$A$3</definedName>"))
        #expect(xml.contains("<definedName name=\"Local\" localSheetId=\"1\">7</definedName>"))
        let reopened = try XLSXReader.workbook(from: data)
        #expect(formula(reopened, "B1") == "SUM(Totals)")
        #expect(value(reopened, "B1") == .number(6))
    }

    // MARK: - Going to a name

    @Test("A name's range is found on its sheet; a constant has none")
    func targets() throws {
        let book0 = workbook()
        let data = book0.sheets[0].id, other = book0.sheets[1].id
        var book = book0
        book.definedNames = [
            DefinedName(name: "Block", formula: "Data!$B$4:$A$2", scope: nil),
            DefinedName(name: "Here", formula: "$C$3", scope: other),
            DefinedName(name: "Loose", formula: "D5", scope: nil),
            DefinedName(name: "Constant", formula: "0.25", scope: nil),
            DefinedName(name: "Gone", formula: "Missing!$A$1", scope: nil),
        ]
        func target(_ index: Int, from sheet: Worksheet.ID?) -> DefinedNameTarget? {
            book.target(of: book.definedNames[index], from: sheet)
        }
        #expect(target(0, from: other) == DefinedNameTarget(
            sheetID: data, range: CellRange(start: CellAddress(a1: "A2")!, end: CellAddress(a1: "B4")!)))
        #expect(target(1, from: data) == DefinedNameTarget(sheetID: other, range: CellRange(CellAddress(a1: "C3")!)))
        #expect(target(2, from: other)?.sheetID == other)
        #expect(target(3, from: data) == nil)
        #expect(target(4, from: data) == nil)
    }

    @Test("Going to a name shows its sheet with its range selected")
    func goTo() {
        let state = EditorState()
        var book = workbook()
        book.definedNames = [DefinedName(name: "Block", formula: "Other!$B$2:$C$4", scope: nil)]
        state.selectSheet(book.sheets[0].id, in: book)
        #expect(state.go(to: book.definedNames[0], in: book))
        #expect(state.activeSheetID == book.sheets[1].id)
        #expect(state.selection.normalized == CellRange(start: CellAddress(a1: "B2")!, end: CellAddress(a1: "C4")!))
        #expect(state.scrollTarget == CellAddress(a1: "B2"))
    }

    @Test("A name for a selection is suggested from the label above it")
    func suggestedName() {
        var book = workbook()
        book.sheets[0][CellAddress(a1: "C1")!] = Cell(value: .text("Unit price"))
        book.sheets[0][CellAddress(a1: "E2")!] = Cell(value: .text("2024"))
        let sheet = book.sheets[0].id
        let column = CellRange(start: CellAddress(a1: "C2")!, end: CellAddress(a1: "C9")!)
        #expect(book.suggestedDefinedName(for: column, on: sheet) == "Unit_price")
        #expect(book.suggestedDefinedName(for: CellRange(CellAddress(a1: "F2")!), on: sheet) == "_2024")
        #expect(book.suggestedDefinedName(for: CellRange(CellAddress(a1: "A1")!), on: sheet) == "")
    }

    // MARK: - Saving from the editor

    @Test("Saving an edited name renames and repoints it as one change, or refuses both")
    func saveDraft() throws {
        let state = EditorState()
        var book = workbook(names: [DefinedName(name: "Pick", formula: "Data!$A$1", scope: nil)],
                            formulas: ["B1": "=Pick*10"])
        var draft = DefinedNameDraft(editing: book.definedNames[0])
        draft.name = "Chosen"
        draft.refersTo = "=Data!$A$2"
        try state.save(draft, in: &book)
        #expect(book.definedNames == [DefinedName(name: "Chosen", formula: "Data!$A$2", scope: nil)])
        #expect(formula(book, "B1") == "Chosen*10")
        #expect(value(book, "B1") == .number(20))

        let before = book
        var bad = DefinedNameDraft(editing: book.definedNames[0])
        bad.name = "Renamed"
        bad.refersTo = "=SUM("
        #expect(throws: DefinedNameError.invalidFormula) { try state.save(bad, in: &book) }
        #expect(book == before)
    }

    // MARK: - Autocomplete

    @Test("The word being typed is found at the caret, but not in strings or after a sheet")
    func completionWord() {
        #expect(FormulaCompletion.word(in: "=SUM(Va")?.prefix == "Va")
        #expect(FormulaCompletion.word(in: "=SUM(Va")?.range == 5..<7)
        #expect(FormulaCompletion.word(in: "=Sales.Da")?.prefix == "Sales.Da")
        #expect(FormulaCompletion.word(in: "=Rate*2", caret: 5)?.prefix == "Rate")
        #expect(FormulaCompletion.word(in: "=\"Va") == nil)
        #expect(FormulaCompletion.word(in: "=Data!Va") == nil)
        #expect(FormulaCompletion.word(in: "=1+23") == nil)
        #expect(FormulaCompletion.word(in: "Va") == nil)
        #expect(FormulaCompletion.word(in: "=SUM(") == nil)

        let word = FormulaCompletion.word(in: "=SUM(Va)", caret: 7)!
        let result = FormulaCompletion.replacing(word, with: "Values", in: "=SUM(Va)")
        #expect(result.text == "=SUM(Values)")
        #expect(result.caret == 11)
    }

    @Test("Names a formula can use are offered, a sheet's own first, hiding the workbook's of the same spelling")
    func nameCompletions() {
        let book0 = workbook()
        let data = book0.sheets[0].id, other = book0.sheets[1].id
        var book = book0
        book.definedNames = [
            DefinedName(name: "Rate", formula: "2", scope: nil),
            DefinedName(name: "Rate", formula: "100", scope: data),
            DefinedName(name: "Range2", formula: "3", scope: other),
            DefinedName(name: "Total", formula: "4", scope: nil),
        ]
        let fromData = book.definedNameCompletions(for: "ra", visibleFrom: data)
        #expect(fromData.map(\.name) == ["Rate"])
        #expect(fromData.first?.scope == data)
        #expect(book.definedNameCompletions(for: "RA", visibleFrom: other).map(\.name) == ["Range2", "Rate"])
        #expect(book.definedNameCompletions(for: "", visibleFrom: other).isEmpty)
    }

    @Test("While a formula is typed, names and functions finishing the word are offered and put in")
    func editorSuggestions() {
        let state = EditorState()
        var book = workbook()
        book.definedNames = [DefinedName(name: "SumOfSales", formula: "Data!$A$1:$A$3", scope: nil)]
        state.selectSheet(book.sheets[0].id, in: book)
        state.beginEditing(CellAddress(a1: "B1")!, in: book, replacingWith: "=1+sum")

        let suggestions = state.formulaSuggestions(in: book)
        #expect(suggestions.first == FormulaSuggestion(kind: .name, text: "SumOfSales", detail: "=Data!$A$1:$A$3"))
        #expect(suggestions.contains { $0.kind == .function && $0.text == "SUMIF" })
        // Typed out in full, a function is not offered again.
        #expect(!suggestions.contains { $0.text == "SUM" })

        state.accept(suggestions[0])
        #expect(state.editingText == "=1+SumOfSales")
        state.editingText = "=AVERA"
        state.accept(FormulaSuggestion(kind: .function, text: "AVERAGE", detail: ""))
        #expect(state.editingText == "=AVERAGE(")
    }
}
