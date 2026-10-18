import Foundation
import Testing
@testable import Tables
@testable import TablesEngine

/// Form Controls read out of a file, used, and written back.
@Suite("Form controls")
struct FormControlTests {
    private func text(_ entries: [String: Data], _ path: String) -> String {
        String(decoding: entries[path] ?? Data(), as: UTF8.self)
    }

    /// A VML control shape the way Excel writes one.
    private func shape(
        _ number: Int, _ type: String, anchor: String, text: String? = nil, data: String = ""
    ) -> String {
        var xml = "<v:shape id=\"_x0000_s\(number)\" type=\"#_x0000_t201\" style='position:absolute;"
        xml += "margin-left:0;margin-top:0;width:60pt;height:20pt;z-index:1'>"
        if let text {
            xml += "<v:textbox style='mso-direction-alt:auto'><div style='text-align:left'>"
            xml += "<font face=\"Arial\" size=\"200\" color=\"#ff0000\"><b>\(text)</b></font></div></v:textbox>"
        }
        xml += "<x:ClientData ObjectType=\"\(type)\"><x:Anchor>\n    \(anchor)</x:Anchor>\(data)</x:ClientData></v:shape>"
        return xml
    }

    private var shapes: [String] {
        [
            shape(2049, "Button", anchor: "1, 0, 1, 0, 3, 0, 3, 0", text: "Run &amp; go",
                  data: "<x:FmlaMacro>[0]!Module1.Go</x:FmlaMacro><x:TextHAlign>Center</x:TextHAlign>"),
            shape(2050, "Checkbox", anchor: "1, 0, 4, 0, 3, 0, 5, 0", text: "Include tax",
                  data: "<x:Checked>1</x:Checked><x:FmlaLink>$C$1</x:FmlaLink>"),
            shape(2051, "GBox", anchor: "4, 0, 0, 0, 7, 0, 8, 0", text: "Size"),
            shape(2052, "Radio", anchor: "4, 8, 1, 0, 6, 0, 2, 0", text: "Small",
                  data: "<x:FirstButton/><x:FmlaLink>$C$2</x:FmlaLink>"),
            shape(2053, "Radio", anchor: "4, 8, 3, 0, 6, 0, 4, 0", text: "Large", data: "<x:Checked>1</x:Checked>"),
            shape(2054, "Drop", anchor: "1, 0, 6, 0, 3, 0, 7, 0",
                  data: "<x:Sel>2</x:Sel><x:FmlaLink>$C$3</x:FmlaLink><x:FmlaRange>$A$1:$A$3</x:FmlaRange>"
                    + "<x:DropLines>4</x:DropLines>"),
            shape(2055, "Edit", anchor: "1, 0, 8, 0, 3, 0, 9, 0", text: "hello<br>world"),
            shape(2056, "Spin", anchor: "1, 0, 10, 0, 2, 0, 11, 0"),
        ]
    }

    /// A workbook carrying the controls above, the check box with a
    /// `ctrlProps` part as Excel 2010 and later write it.
    private func package() throws -> Data {
        var sheet = Worksheet(name: "Sheet1")
        for (row, fruit) in ["Apple", "Banana", "Cherry"].enumerated() {
            sheet[CellAddress(row: row, column: 0)] = Cell(value: .text(fruit))
        }
        sheet[CellAddress(a1: "C1")!] = Cell(value: .boolean(true))
        sheet[CellAddress(a1: "C2")!] = Cell(value: .number(2))
        sheet[CellAddress(a1: "C3")!] = Cell(value: .number(2))
        // A note, so the sheet is written with a VML drawing to add to.
        sheet.comments[CellAddress(a1: "Z99")!] = .note(author: "Ann", text: "Note")
        var entries = try ZipArchive.entries(in: XLSXWriter.data(from: Workbook(sheets: [sheet])))

        let vml = text(entries, "xl/drawings/vmlDrawing1.vml")
        entries["xl/drawings/vmlDrawing1.vml"] = Data(vml.replacingOccurrences(
            of: "</xml>", with: shapes.joined() + "</xml>").utf8)
        let controls = "<mc:AlternateContent xmlns:mc=\"http://schemas.openxmlformats.org/markup-compatibility/2006\">"
            + "<mc:Choice Requires=\"x14\"><controls><control shapeId=\"2050\" r:id=\"rIdCtl\" name=\"Check Box 1\">"
            + "<controlPr><anchor><from><xdr:col>1</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>4</xdr:row>"
            + "<xdr:rowOff>0</xdr:rowOff></from><to><xdr:col>3</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>5</xdr:row>"
            + "<xdr:rowOff>0</xdr:rowOff></to></anchor></controlPr></control></controls></mc:Choice></mc:AlternateContent>"
        let sheetXML = text(entries, "xl/worksheets/sheet1.xml")
            .replacingOccurrences(of: "<worksheet ", with: "<worksheet "
                + "xmlns:xdr=\"http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing\" ")
            .replacingOccurrences(of: "</worksheet>", with: controls + "</worksheet>")
        entries["xl/worksheets/sheet1.xml"] = Data(sheetXML.utf8)
        let relationships = text(entries, "xl/worksheets/_rels/sheet1.xml.rels").replacingOccurrences(
            of: "</Relationships>",
            with: "<Relationship Id=\"rIdCtl\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/"
                + "ctrlProp\" Target=\"../ctrlProps/ctrlProp1.xml\"/></Relationships>")
        entries["xl/worksheets/_rels/sheet1.xml.rels"] = Data(relationships.utf8)
        entries["xl/ctrlProps/ctrlProp1.xml"] = Data(("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
            + "<formControlPr xmlns=\"http://schemas.microsoft.com/office/spreadsheetml/2009/9/main\" "
            + "objectType=\"CheckBox\" checked=\"Checked\" fmlaLink=\"$C$1\" lockText=\"1\"/>").utf8)
        let types = text(entries, "[Content_Types].xml").replacingOccurrences(
            of: "</Types>",
            with: "<Override PartName=\"/xl/ctrlProps/ctrlProp1.xml\" "
                + "ContentType=\"application/vnd.ms-excel.controlproperties+xml\"/></Types>")
        entries["[Content_Types].xml"] = Data(types.utf8)
        return try ZipArchive.archive(entries: entries.map { ($0.key, $0.value) })
    }

    private func control(_ id: Int, in workbook: Workbook) throws -> FormControl {
        try #require(workbook.sheets[0].formControls.first { $0.id == "_x0000_s\(id)" })
    }

    @Test("Each kind of control is read with its caption, macro, cells and place")
    func reading() throws {
        let workbook = try XLSXReader.workbook(from: package())
        let controls = workbook.sheets[0].formControls
        #expect(controls.map(\.kind) == [
            .button, .checkBox, .groupBox, .optionButton, .optionButton, .dropDown, .editBox, .unsupported,
        ])
        #expect(workbook.sheets[0].comments.count == 1)
        #expect(workbook.sheets[0].preservedVMLShapes?.contains("ObjectType") != true)

        let button = try control(2049, in: workbook)
        #expect(button.text == "Run & go")
        #expect(button.font == FormControl.Font(size: 10, isBold: true, colorHex: "FF0000"))
        #expect(button.horizontalAlignment == .center)
        #expect(button.macroTarget?.module == "Module1")
        #expect(button.macroTarget?.procedure == "Go")
        #expect(button.placement.from == ChartAnchor(row: 1, column: 1))

        let radio = try control(2052, in: workbook)
        #expect(radio.placement.from.columnOffset == 6)
        #expect(try control(2055, in: workbook).text == "hello\nworld")

        let dropDown = try control(2054, in: workbook)
        #expect(dropDown.items(in: workbook) == ["Apple", "Banana", "Cherry"])
        #expect(dropDown.selection(in: workbook) == 2)
        #expect(dropDown.dropLines == 4)

        let checkBox = try control(2050, in: workbook)
        #expect(checkBox.source.propertiesPart == "xl/ctrlProps/ctrlProp1.xml")
        #expect(checkBox.checkState(in: workbook) == .checked)
    }

    @Test("A workbook nobody touched is written back with its controls as they were")
    func untouched() throws {
        let workbook = try XLSXReader.workbook(from: package())
        let saved = try ZipArchive.entries(in: XLSXWriter.data(from: workbook))
        let vml = text(saved, "xl/drawings/vmlDrawing1.vml")
        for shape in shapes { #expect(vml.contains(shape)) }
        #expect(text(saved, "xl/ctrlProps/ctrlProp1.xml").contains("checked=\"Checked\""))
        #expect(text(saved, "xl/worksheets/sheet1.xml").contains("shapeId=\"2050\""))
        #expect(text(saved, "xl/worksheets/_rels/sheet1.xml.rels").contains("ctrlProps/ctrlProp1.xml"))
    }

    @Test("A check box follows its linked cell and writes TRUE or FALSE to it")
    func checkBox() throws {
        var workbook = try XLSXReader.workbook(from: package())
        let sheetID = workbook.sheets[0].id
        let id = "_x0000_s2050"
        workbook.toggleCheckBox(id, on: sheetID)
        #expect(workbook.sheets[0][CellAddress(a1: "C1")!].value == .boolean(false))
        #expect(try control(2050, in: workbook).checkState(in: workbook) == .unchecked)

        workbook.sheets[0][CellAddress(a1: "C1")!] = Cell(value: .error(.notAvailable))
        #expect(try control(2050, in: workbook).checkState(in: workbook) == .mixed)
        workbook.sheets[0][CellAddress(a1: "C1")!] = Cell(value: .number(0))
        #expect(try control(2050, in: workbook).checkState(in: workbook) == .unchecked)

        let saved = try ZipArchive.entries(in: XLSXWriter.data(from: workbook))
        let vml = text(saved, "xl/drawings/vmlDrawing1.vml")
        let shape = try #require(CommentParts.blocks(in: vml, tag: "v:shape").first { $0.contains("_x0000_s2050") })
        #expect(FormControlParts.value("Checked", in: shape) == nil)
        #expect(!text(saved, "xl/ctrlProps/ctrlProp1.xml").contains("checked="))
        let reloaded = try XLSXReader.workbook(from: XLSXWriter.data(from: workbook))
        #expect(try control(2050, in: reloaded).checkState == .unchecked)
    }

    @Test("Option buttons in a group box switch each other and number the choice in their cell")
    func optionButtons() throws {
        var workbook = try XLSXReader.workbook(from: package())
        let sheet = workbook.sheets[0]
        let small = try #require(sheet.formControls.firstIndex { $0.id == "_x0000_s2052" })
        let large = try #require(sheet.formControls.firstIndex { $0.id == "_x0000_s2053" })
        #expect(sheet.optionGroups() == [[small, large]])
        #expect(!sheet.isOptionChosen(small, in: workbook))
        #expect(sheet.isOptionChosen(large, in: workbook))

        workbook.chooseOptionButton("_x0000_s2052", on: sheet.id)
        #expect(workbook.sheets[0][CellAddress(a1: "C2")!].value == .number(1))
        #expect(workbook.sheets[0].isOptionChosen(small, in: workbook))
        #expect(!workbook.sheets[0].isOptionChosen(large, in: workbook))

        let vml = text(try ZipArchive.entries(in: XLSXWriter.data(from: workbook)), "xl/drawings/vmlDrawing1.vml")
        let smallShape = try #require(CommentParts.blocks(in: vml, tag: "v:shape").first { $0.contains("_x0000_s2052") })
        #expect(FormControlParts.value("Checked", in: smallShape) == "1")
    }

    @Test("Picking from a drop-down writes the entry's number to its cell and the file")
    func dropDown() throws {
        var workbook = try XLSXReader.workbook(from: package())
        workbook.selectDropDownItem(3, in: "_x0000_s2054", on: workbook.sheets[0].id)
        #expect(workbook.sheets[0][CellAddress(a1: "C3")!].value == .number(3))
        let reloaded = try XLSXReader.workbook(from: XLSXWriter.data(from: workbook))
        let dropDown = try control(2054, in: reloaded)
        #expect(dropDown.selection == 3)
        #expect(dropDown.selection(in: reloaded) == 3)
    }

    @Test("What an edit box holds survives a save")
    func editBox() throws {
        var workbook = try XLSXReader.workbook(from: package())
        workbook.setEditBoxText("a < b\nc", in: "_x0000_s2055", on: workbook.sheets[0].id)
        let reloaded = try XLSXReader.workbook(from: XLSXWriter.data(from: workbook))
        #expect(try control(2055, in: reloaded).text == "a < b\nc")
    }

    @Test("Inserting rows moves controls and the cells they are linked to")
    func insertingRows() throws {
        var workbook = try XLSXReader.workbook(from: package())
        let sheetID = workbook.sheets[0].id
        let snapshot = workbook
        workbook.sheets[0].insertRows(2, at: 0)
        workbook.chartsFollow(.insert(index: 0, count: 2), axis: .row, on: sheetID, before: snapshot)

        let checkBox = try control(2050, in: workbook)
        #expect(checkBox.placement.from.row == 6)
        #expect(checkBox.linkedCell?.range.start == CellAddress(a1: "C3"))
        #expect(checkBox.checkState(in: workbook) == .checked)

        let saved = try ZipArchive.entries(in: XLSXWriter.data(from: workbook))
        let vml = text(saved, "xl/drawings/vmlDrawing1.vml")
        let shape = try #require(CommentParts.blocks(in: vml, tag: "v:shape").first { $0.contains("_x0000_s2050") })
        #expect(FormControlParts.value("Anchor", in: shape) == "1, 0, 6, 0, 3, 0, 7, 0")
        #expect(FormControlParts.value("FmlaLink", in: shape) == "$C$3")
        #expect(text(saved, "xl/ctrlProps/ctrlProp1.xml").contains("fmlaLink=\"$C$3\""))
        #expect(text(saved, "xl/worksheets/sheet1.xml").contains(">6</xdr:row>"))
    }

    @Test("A macro name may carry a workbook and a module", arguments: [
        ("[0]!Go", nil, "Go"),
        ("'Book 1.xlsm'!Module1.Go", "Module1", "Go"),
        ("Sheet1.Go", "Sheet1", "Go"),
    ] as [(String, String?, String)])
    func macroNames(macro: String, module: String?, procedure: String) {
        let control = FormControl(
            id: "_x0000_s1", kind: .button, placement: ChartPlacement(), macro: macro,
            font: FormControl.Font(size: 11),
            source: FormControl.Source(vml: "", placement: ChartPlacement(), text: "",
                                       checkState: .unchecked, selection: 0))
        #expect(control.macroTarget?.module == module)
        #expect(control.macroTarget?.procedure == procedure)
    }
}
