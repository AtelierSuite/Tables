import Foundation
import Testing
@testable import Tables
@testable import TablesEngine
@testable import TablesMacros

/// Covers text made of runs with their own fonts: reading them from shared
/// and inline strings, keeping them through a save, and dropping them only
/// when the text they describe changes.
@MainActor
@Suite("Rich text")
struct RichTextTests {

    // MARK: - Helpers

    private func address(_ text: String) -> CellAddress {
        CellAddress(a1: text)!
    }

    /// The runs of H₂O as Excel writes them: a theme-coloured run in the
    /// body font, a subscript and a bold red run in another font and size.
    private let water = """
    <si><r><rPr><sz val="11"/><color theme="1"/><rFont val="Calibri"/><family val="2"/>\
    <scheme val="minor"/></rPr><t>H</t></r>\
    <r><rPr><vertAlign val="subscript"/><sz val="11"/><color theme="1"/><rFont val="Calibri"/>\
    <family val="2"/><scheme val="minor"/></rPr><t>2</t></r>\
    <r><rPr><b/><i/><u val="double"/><strike/><sz val="14"/><color rgb="FFFF0000"/>\
    <rFont val="Georgia"/><family val="1"/></rPr><t xml:space="preserve">O is wet</t></r></si>
    """

    /// The smallest package the reader accepts, around one sheet and the
    /// items of a shared string table.
    private func package(sheet cells: String, strings: String = "") throws -> Data {
        let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        let relationships = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/></Types>
        """
        let rootRelationships = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="\(relationships)/officeDocument" Target="xl/workbook.xml"/></Relationships>
        """
        let workbook = """
        <?xml version="1.0" encoding="UTF-8"?>
        <workbook xmlns="\(main)" xmlns:r="\(relationships)">\
        <sheets><sheet name="S" sheetId="1" r:id="rId1"/></sheets></workbook>
        """
        let workbookRelationships = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="\(relationships)/worksheet" Target="worksheets/sheet1.xml"/>\
        <Relationship Id="rId2" Type="\(relationships)/sharedStrings" Target="sharedStrings.xml"/>\
        </Relationships>
        """
        let sheet = """
        <?xml version="1.0" encoding="UTF-8"?>
        <worksheet xmlns="\(main)"><sheetData><row r="1">\(cells)</row></sheetData></worksheet>
        """
        let table = """
        <?xml version="1.0" encoding="UTF-8"?>
        <sst xmlns="\(main)">\(strings)</sst>
        """
        return try ZipArchive.archive(entries: [
            ("[Content_Types].xml", Data(contentTypes.utf8)),
            ("_rels/.rels", Data(rootRelationships.utf8)),
            ("xl/workbook.xml", Data(workbook.utf8)),
            ("xl/_rels/workbook.xml.rels", Data(workbookRelationships.utf8)),
            ("xl/sharedStrings.xml", Data(table.utf8)),
            ("xl/worksheets/sheet1.xml", Data(sheet.utf8)),
        ])
    }

    private func sharedStrings(in data: Data) throws -> String {
        String(decoding: try #require(ZipArchive.entries(in: data)["xl/sharedStrings.xml"]), as: UTF8.self)
    }

    /// A cell of two runs, the second bold, with no `<rPr>` kept from a file.
    private func boldEnding(_ start: String, _ end: String) -> Cell {
        var bold = RunFont()
        bold.isBold = true
        return Cell(
            value: .text(start + end),
            richText: RichText(runs: [TextRun(text: start), TextRun(text: end, font: bold)])
        )
    }

    // MARK: - Reading

    @Test("Runs in a shared string are read with their fonts")
    func readsSharedStringRuns() throws {
        let data = try package(sheet: #"<c r="A1" t="s"><v>0</v></c>"#, strings: water)
        let cell = try XLSXReader.workbook(from: data).sheets[0][address("A1")]
        #expect(cell.value == .text("H2O is wet"))
        let runs = try #require(cell.richText?.runs)
        #expect(runs.map(\.text) == ["H", "2", "O is wet"])

        let plain = try #require(runs[0].font)
        #expect(!plain.isBold && !plain.isItalic && !plain.isUnderlined && !plain.isStruckThrough)
        #expect(plain.fontName == "Calibri")
        #expect(plain.fontSize == 11)
        #expect(plain.verticalAlignment == .baseline)
        // Theme colour 1 is the theme's dark text.
        #expect(plain.colorHex == "FF000000")

        #expect(runs[1].font?.verticalAlignment == .subscript)

        let loud = try #require(runs[2].font)
        #expect(loud.isBold && loud.isItalic && loud.isUnderlined && loud.isStruckThrough)
        #expect(loud.fontName == "Georgia")
        #expect(loud.fontSize == 14)
        #expect(loud.colorHex == "FFFF0000")
    }

    @Test("Runs in an inline string are read with their fonts")
    func readsInlineStringRuns() throws {
        let cells = """
        <c r="A1" t="inlineStr"><is><r><t>x</t></r>\
        <r><rPr><vertAlign val="superscript"/></rPr><t>2</t></r></is></c>\
        <c r="B1" t="inlineStr"><is><t>plain</t></is></c>
        """
        let sheet = try XLSXReader.workbook(from: package(sheet: cells)).sheets[0]
        let cell = sheet[address("A1")]
        #expect(cell.value == .text("x2"))
        #expect(cell.richText?.runs.map(\.text) == ["x", "2"])
        #expect(cell.richText?.runs[0].font == nil)
        #expect(cell.richText?.runs[1].font?.verticalAlignment == .superscript)
        #expect(sheet[address("B1")].value == .text("plain"))
        #expect(sheet[address("B1")].richText == nil)
    }

    @Test("Runs that all take the cell's font are plain text")
    func runsWithoutFontsArePlain() throws {
        let data = try package(
            sheet: #"<c r="A1" t="s"><v>0</v></c>"#, strings: "<si><r><t>one </t></r><r><t>two</t></r></si>")
        let cell = try XLSXReader.workbook(from: data).sheets[0][address("A1")]
        #expect(cell.value == .text("one two"))
        #expect(cell.richText == nil)
    }

    @Test("A flag switched off in a run is off")
    func readsFlagValues() throws {
        let strings = #"<si><r><rPr><b val="0"/><i val="1"/><u val="none"/></rPr><t>a</t></r></si>"#
        let data = try package(sheet: #"<c r="A1" t="s"><v>0</v></c>"#, strings: strings)
        let font = try #require(XLSXReader.workbook(from: data).sheets[0][address("A1")].richText?.runs[0].font)
        #expect(!font.isBold)
        #expect(font.isItalic)
        #expect(!font.isUnderlined)
    }

    // MARK: - Writing

    @Test("Runs come back from a save as the file had them")
    func runsSurviveASave() throws {
        let cells = #"<c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>0</v></c>"#
        let opened = try XLSXReader.workbook(from: package(sheet: cells, strings: water))
        let saved = try XLSXWriter.data(from: opened)

        // What the model does not hold is written back too: the theme colour,
        // the font scheme and the double underline.
        let xml = try sharedStrings(in: saved)
        #expect(xml.contains(#"<color theme="1"/>"#))
        #expect(xml.contains(#"<scheme val="minor"/>"#))
        #expect(xml.contains(#"<u val="double"/>"#))
        #expect(xml.contains(#"<vertAlign val="subscript"/>"#))
        #expect(xml.contains(#"<t xml:space="preserve">O is wet</t>"#))
        // Two cells share the one string.
        #expect(xml.contains(#"count="2" uniqueCount="1""#))

        let reopened = try XLSXReader.workbook(from: saved).sheets[0]
        #expect(reopened[address("A1")] == opened.sheets[0][address("A1")])
        #expect(reopened[address("B1")].richText == opened.sheets[0][address("A1")].richText)
    }

    @Test("Runs made here are written with a font of their own")
    func writesRunsWithoutKeptXML() throws {
        var sheet = Worksheet(name: "S")
        var raised = RunFont()
        raised.verticalAlignment = .superscript
        raised.colorHex = "FF0000FF"
        raised.fontName = "Courier New"
        raised.fontSize = 9
        let richText = RichText(runs: [TextRun(text: "x"), TextRun(text: "2", font: raised)])
        sheet[address("A1")] = Cell(value: .text("x2"), richText: richText)
        let saved = try XLSXWriter.data(from: Workbook(sheets: [sheet]))
        #expect(try sharedStrings(in: saved).contains(
            #"<r><rPr><vertAlign val="superscript"/><sz val="9"/><color rgb="FF0000FF"/>"#
                + #"<rFont val="Courier New"/></rPr><t xml:space="preserve">2</t></r>"#))

        let font = try #require(XLSXReader.workbook(from: saved).sheets[0][address("A1")].richText?.runs[1].font)
        #expect(font.verticalAlignment == .superscript)
        #expect(font.colorHex == "FF0000FF")
        #expect(font.fontName == "Courier New")
        #expect(font.fontSize == 9)
    }

    @Test("The same text plain and in runs are two strings")
    func plainAndRichAreDistinctStrings() throws {
        var sheet = Worksheet(name: "S")
        sheet[address("A1")] = boldEnding("very ", "bold")
        sheet[address("A2")] = Cell(value: .text("very bold"))
        sheet[address("A3")] = boldEnding("very ", "bold")
        let saved = try XLSXWriter.data(from: Workbook(sheets: [sheet]))
        #expect(try sharedStrings(in: saved).contains(#"count="3" uniqueCount="2""#))

        let reopened = try XLSXReader.workbook(from: saved).sheets[0]
        #expect(reopened[address("A1")].richText?.runs.map(\.text) == ["very ", "bold"])
        #expect(reopened[address("A2")].richText == nil)
        #expect(reopened[address("A3")].richText?.runs[1].font?.isBold == true)
    }

    // MARK: - The cell

    @Test("Runs go when the text they describe does")
    func runsFollowTheValue() {
        let rich = boldEnding("very ", "bold")
        #expect(rich.richText != nil)

        var same = rich
        same.value = .text("very bold")
        #expect(same.richText != nil)

        var retyped = rich
        retyped.value = .text("very plain")
        #expect(retyped.richText == nil)

        var computed = rich
        computed.formula = "A2"
        #expect(computed.richText == nil)

        var restyled = rich
        restyled.style.isItalic = true
        #expect(restyled.richText != nil)

        // Runs that do not add up to the value are never kept.
        let mismatched = Cell(value: .text("other"), richText: rich.richText)
        #expect(mismatched.richText == nil)
        var number = Cell(value: .number(1))
        number.richText = rich.richText
        #expect(number.richText == nil)
    }

    @Test("Typing the same text over a cell keeps its runs")
    func committingUnchangedTextKeepsRuns() {
        let rich = boldEnding("very ", "bold")
        #expect(CellInputParser.cell(from: "very bold", replacing: rich).richText == rich.richText)
        #expect(CellInputParser.cell(from: "very bald", replacing: rich).richText == nil)
        #expect(CellInputParser.cell(from: "=A2", replacing: rich).richText == nil)
    }

    @Test("Stepping through a cell in the editor keeps its runs")
    func editorCommitKeepsRuns() {
        var workbook = Workbook()
        workbook.sheets[0][address("A1")] = boldEnding("very ", "bold")
        let state = EditorState()
        state.activeSheetID = workbook.sheets[0].id
        state.beginEditing(address("A1"), in: workbook)
        state.commitEditing(in: &workbook)
        #expect(workbook.sheets[0][address("A1")].richText?.runs.count == 2)

        state.beginEditing(address("A1"), in: workbook, replacingWith: "new")
        state.commitEditing(in: &workbook)
        #expect(workbook.sheets[0][address("A1")].value == .text("new"))
        #expect(workbook.sheets[0][address("A1")].richText == nil)
    }

    @Test("A cell is no bigger for being able to hold runs")
    func cellSizeIsUnchanged() {
        // The stored properties a cell had before it could hold runs.
        struct Before {
            var value: CellValue
            var formula: String?
            var style: CellStyle
            var isSpilled: Bool
            var arrayExtent: (rows: Int, columns: Int)?
            var savedResultInputs: Int?
        }
        #expect(MemoryLayout<Cell>.stride <= MemoryLayout<Before>.stride)
        #expect(MemoryLayout<Cell>.size <= MemoryLayout<Before>.size)
    }

    // MARK: - Editing around runs

    @Test("Copying and pasting a cell takes its runs along")
    func copyAndPasteKeepRuns() {
        var workbook = Workbook()
        workbook.sheets[0][address("A1")] = boldEnding("very ", "bold")
        let state = EditorState()
        state.activeSheetID = workbook.sheets[0].id
        state.select(address("A1"))
        state.copySelection(in: workbook)
        state.select(address("B2"))
        state.paste(in: &workbook)
        #expect(workbook.sheets[0][address("B2")].richText == workbook.sheets[0][address("A1")].richText)
        #expect(workbook.sheets[0][address("A1")].richText != nil)
    }

    @Test("Filling copies runs, and a series that counts on drops them")
    func fillKeepsRunsOfCopiedText() {
        var sheet = Worksheet(name: "S")
        sheet[address("A1")] = boldEnding("very ", "bold")
        sheet[address("B1")] = boldEnding("Week ", "1")
        let filled = sheet.autoFill(
            from: CellRange(start: address("A1"), end: address("B1")),
            to: CellRange(start: address("A1"), end: address("B3")))
        #expect(filled)
        #expect(sheet[address("A3")].richText == sheet[address("A1")].richText)
        #expect(sheet[address("B1")].richText != nil)
        #expect(sheet[address("B3")].value == .text("Week 3"))
        #expect(sheet[address("B3")].richText == nil)
    }

    @Test("Sorting moves runs with their cells")
    func sortKeepsRuns() throws {
        var workbook = Workbook()
        workbook.sheets[0][address("A1")] = boldEnding("b ", "bold")
        workbook.sheets[0][address("A2")] = Cell(value: .text("a plain"))
        try WorkbookAutomation.sort(
            CellRange(start: address("A1"), end: address("A2")), by: 0, ascending: true, hasHeader: false,
            sheet: 0, in: &workbook)
        #expect(workbook.sheets[0][address("A1")].value == .text("a plain"))
        #expect(workbook.sheets[0][address("A1")].richText == nil)
        #expect(workbook.sheets[0][address("A2")].richText?.runs.map(\.text) == ["b ", "bold"])
    }

    @Test("Find reads through runs, and undo brings them back")
    func findAndUndo() {
        var workbook = Workbook()
        workbook.sheets[0][address("A1")] = boldEnding("very ", "bold")
        // A match can straddle two runs.
        #expect(workbook.matches(for: "ry bo").map(\.address.a1) == ["A1"])

        let before = workbook
        workbook.sheets[0][address("A1")].value = .text("gone")
        #expect(workbook.sheets[0][address("A1")].richText == nil)
        workbook = before
        #expect(workbook.sheets[0][address("A1")].richText?.runs.count == 2)
    }

    @Test("Inserting rows and columns moves runs with their cells")
    func structureKeepsRuns() {
        var sheet = Worksheet(name: "S")
        sheet[address("B2")] = boldEnding("very ", "bold")
        sheet.insertRows(1, at: 0)
        sheet.insertColumns(1, at: 0)
        #expect(sheet[address("C3")].richText?.runs.count == 2)
    }

    // MARK: - Drawing

    @Test("Text as drawn is cut into the pieces of its runs")
    func piecesFollowTheDrawnText() {
        let cell = boldEnding("H2", "O")
        func pieces(_ text: String) -> [String] {
            (cell.styledPieces(of: text) ?? []).map { "\($0.text)\($0.style.isBold ? "*" : "")" }
        }
        #expect(pieces("H2O") == ["H2", "O*"])
        // Text a renderer adds is set like the text before it.
        #expect(pieces("H…") == ["H…"])
        #expect(pieces("H2O…") == ["H2", "O…*"])
        // Stacked, each glyph's line break stays with it.
        #expect(pieces("H\n2\nO") == ["H\n2\n", "O*"])
        // A direction mark leading the line goes with the first run.
        #expect(pieces("\u{200E}H2…") == ["\u{200E}H2…"])
    }

    @Test("A run takes from the cell what its font leaves unsaid")
    func runStylesInheritFromTheCell() throws {
        var raised = RunFont()
        raised.verticalAlignment = .superscript
        var cell = Cell(
            value: .text("x2"), richText: RichText(runs: [TextRun(text: "x"), TextRun(text: "2", font: raised)]))
        cell.style.isBold = true
        cell.style.fontSize = 20
        cell.style.fontName = "Georgia"
        cell.style.textColorHex = "FF112233"
        let pieces = try #require(cell.styledPieces(of: "x2"))
        // A run without a font is the cell's, bold and all.
        #expect(pieces[0].style == cell.style)
        // A run with one states its own bold, and takes the rest.
        #expect(!pieces[1].style.isBold)
        #expect(pieces[1].style.fontName == "Georgia")
        #expect(pieces[1].style.fontSize == 20)
        #expect(pieces[1].style.textColorHex == "FF112233")
        #expect(raised.glyphSize(of: 20) < 20)
        #expect(raised.baselineOffset(of: 20) > 0)
    }

    @Test("A cell whose format rewrites its text is drawn plain")
    func formattedTextIsDrawnPlain() {
        var cell = boldEnding("very ", "bold")
        #expect(cell.styledPieces(of: "very bold") != nil)
        cell.style.numberFormat = #"0;0;0;"Say: "@"#
        #expect(CellFormatter.displayText(for: cell) == "Say: very bold")
        #expect(cell.styledPieces(of: CellFormatter.displayText(for: cell)) == nil)
        // The runs are still there to be saved.
        #expect(cell.richText != nil)
    }
}
