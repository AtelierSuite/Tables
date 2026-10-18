import Foundation
import Testing
@testable import Tables
@testable import TablesEngine

/// Covers style detail real Excel files carry that is easy to flatten:
/// per-edge border weights, diagonals, alignment indent and rotation, and row
/// and column geometry that has to mean the same number in both applications.
@Suite("Style fidelity")
struct StyleFidelityTests {

    // MARK: - Helpers

    /// Saves a one-sheet workbook and reads it straight back.
    private func roundTripped(_ sheet: Worksheet) throws -> Worksheet {
        let data = try XLSXWriter.data(from: Workbook(sheets: [sheet]))
        return try XLSXReader.workbook(from: data).sheets[0]
    }

    /// Saves a style applied to A1 and returns what comes back.
    private func roundTripped(_ style: CellStyle) throws -> CellStyle {
        var sheet = Worksheet(name: "S")
        sheet[CellAddress(a1: "A1")!] = Cell(value: .text("x"), formula: nil, style: style)
        return try roundTripped(sheet)[CellAddress(a1: "A1")!].style
    }

    /// Wraps sheet XML in the smallest package the reader will accept, with a
    /// style sheet the caller supplies so border and alignment parsing can be
    /// driven from the file rather than from our own writer.
    private func packaged(sheet: String, styles: String) throws -> Data {
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/></Types>
        """
        let rootRelationships = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" \
        Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" \
        Target="xl/workbook.xml"/></Relationships>
        """
        let workbook = """
        <?xml version="1.0" encoding="UTF-8"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
        <sheets><sheet name="S" sheetId="1" r:id="rId1"/></sheets></workbook>
        """
        let workbookRelationships = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" \
        Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" \
        Target="worksheets/sheet1.xml"/>\
        <Relationship Id="rId2" \
        Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" \
        Target="styles.xml"/></Relationships>
        """
        return try ZipArchive.archive(entries: [
            ("[Content_Types].xml", Data(contentTypes.utf8)),
            ("_rels/.rels", Data(rootRelationships.utf8)),
            ("xl/workbook.xml", Data(workbook.utf8)),
            ("xl/_rels/workbook.xml.rels", Data(workbookRelationships.utf8)),
            ("xl/styles.xml", Data(styles.utf8)),
            ("xl/worksheets/sheet1.xml", Data(sheet.utf8)),
        ])
    }

    /// A style sheet whose single non-default `xf` points at `borderBody` and
    /// carries `alignment`, so A1 with `s="1"` exercises exactly that.
    ///
    /// `borderBody` continues the opening `<border` tag, so it supplies the
    /// diagonal attributes, the `>` and the children.
    private func styleSheet(borderBody: String = "></border>", alignment: String = "") -> String {
        let alignmentElement = alignment.isEmpty ? "" : "<alignment \(alignment)/>"
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
        <fonts count="1"><font><sz val="11"/></font></fonts>\
        <fills count="1"><fill><patternFill patternType="none"/></fill></fills>\
        <borders count="2"><border/><border \(borderBody)</borders>\
        <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
        <cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>\
        <xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyBorder="1" \
        applyAlignment="1">\(alignmentElement)</xf></cellXfs>\
        </styleSheet>
        """
    }

    private let singleStyledCell = """
    <?xml version="1.0" encoding="UTF-8"?>
    <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>\
    <row r="1"><c r="A1" s="1" t="inlineStr"><is><t>x</t></is></c></row>\
    </sheetData></worksheet>
    """

    private func readStyle(borderBody: String = "></border>", alignment: String = "") throws -> CellStyle {
        let data = try packaged(
            sheet: singleStyledCell,
            styles: styleSheet(borderBody: borderBody, alignment: alignment)
        )
        return try XLSXReader.workbook(from: data).sheets[0][CellAddress(a1: "A1")!].style
    }

    // MARK: - Border line styles

    @Test("Every OOXML border style is read rather than flattened to thin")
    func borderStylesAreRead() throws {
        for lineStyle in BorderLineStyle.allCases {
            let style = try readStyle(borderBody: "><left style=\"\(lineStyle.rawValue)\"/></border>")
            #expect(style.borderSides[.leading]?.lineStyle == lineStyle,
                    "\(lineStyle.rawValue) was not read back")
            #expect(style.borders.contains(.leading))
        }
    }

    @Test("Every border style survives a save/open cycle on every edge")
    func borderStylesRoundTrip() throws {
        for lineStyle in BorderLineStyle.allCases {
            for edge in BorderEdge.allCases {
                var style = CellStyle.default
                style.borderSides[edge] = BorderSide(lineStyle: lineStyle, colorHex: "FF102030")
                let reloaded = try roundTripped(style)
                #expect(reloaded.borderSides[edge]?.lineStyle == lineStyle,
                        "\(lineStyle.rawValue) on \(edge.rawValue) came back wrong")
                #expect(reloaded.borderSides[edge]?.colorHex == "FF102030")
                #expect(reloaded.borderSides.count == 1)
            }
        }
    }

    @Test("Edges keep their own weights and colours instead of sharing one")
    func perEdgeDetailIsIndependent() throws {
        var style = CellStyle.default
        style.borderSides[.leading] = BorderSide(lineStyle: .thick, colorHex: "FFFF0000")
        style.borderSides[.bottom] = BorderSide(lineStyle: .double, colorHex: "FF0000FF")
        style.borderSides[.top] = BorderSide(lineStyle: .dashed, colorHex: "FF00FF00")

        let reloaded = try roundTripped(style)
        #expect(reloaded.borderSides[.leading] == BorderSide(lineStyle: .thick, colorHex: "FFFF0000"))
        #expect(reloaded.borderSides[.bottom] == BorderSide(lineStyle: .double, colorHex: "FF0000FF"))
        #expect(reloaded.borderSides[.top] == BorderSide(lineStyle: .dashed, colorHex: "FF00FF00"))
        #expect(reloaded.borderSides[.trailing] == nil)
        #expect(reloaded.borders == [.leading, .bottom, .top])
    }

    @Test("An unknown border token still leaves a rule behind")
    func unknownBorderTokenDegrades() throws {
        let style = try readStyle(borderBody: "><right style=\"someFutureStyle\"/></border>")
        #expect(style.borderSides[.trailing]?.lineStyle == .thin)
    }

    @Test("A style of none and a bare element both mean no rule at all")
    func absentBordersStayAbsent() throws {
        #expect(try readStyle(borderBody: "><left style=\"none\"/></border>").borders.isEmpty)
        #expect(try readStyle(borderBody: "><left/><right/><top/><bottom/></border>").borders.isEmpty)
    }

    @Test("The OptionSet API still describes and edits the same borders")
    func optionSetBridgeStillWorks() {
        var style = CellStyle.default
        style.borders = .all
        #expect(style.borderSides.count == 4)
        #expect(style.borders.contains(.top))
        #expect(style.borderSides[.top]?.lineStyle == .thin)

        style.borders.subtract(.top)
        #expect(!style.borders.contains(.top))
        #expect(style.borderSides[.top] == nil)
        #expect(style.borderSides.count == 3)

        style.borders = []
        #expect(style.borderSides.isEmpty)
        #expect(style.borders.isEmpty)
    }

    // MARK: - Diagonals

    @Test("Diagonal direction and style are read from the file")
    func diagonalsAreRead() throws {
        let both = try readStyle(
            borderBody: "diagonalUp=\"1\" diagonalDown=\"1\">"
                + "<diagonal style=\"medium\"><color rgb=\"FF123456\"/></diagonal></border>"
        )
        #expect(both.diagonalBorder?.goesUp == true)
        #expect(both.diagonalBorder?.goesDown == true)
        #expect(both.diagonalBorder?.lineStyle == .medium)
        #expect(both.diagonalBorder?.colorHex == "FF123456")

        // A style with no direction draws nothing, so it is not a diagonal.
        let styleOnly = try readStyle(borderBody: "><diagonal style=\"thick\"/></border>")
        #expect(styleOnly.diagonalBorder == nil)

        // Directions with no style are equally meaningless.
        let directionOnly = try readStyle(borderBody: "diagonalUp=\"1\"><diagonal/></border>")
        #expect(directionOnly.diagonalBorder == nil)
    }

    @Test("Diagonals survive a save/open cycle in either direction")
    func diagonalsRoundTrip() throws {
        for (up, down) in [(true, false), (false, true), (true, true)] {
            var style = CellStyle.default
            style.diagonalBorder = DiagonalBorder(
                lineStyle: .dashDot, colorHex: "FF445566", goesUp: up, goesDown: down
            )
            let reloaded = try roundTripped(style)
            #expect(reloaded.diagonalBorder?.goesUp == up)
            #expect(reloaded.diagonalBorder?.goesDown == down)
            #expect(reloaded.diagonalBorder?.lineStyle == .dashDot)
            #expect(reloaded.diagonalBorder?.colorHex == "FF445566")
        }
    }

    @Test("A diagonal alone is enough to earn a border record")
    func diagonalWithoutEdgesIsWritten() throws {
        var style = CellStyle.default
        style.diagonalBorder = DiagonalBorder(goesDown: true)
        let reloaded = try roundTripped(style)
        #expect(reloaded.borders.isEmpty)
        #expect(reloaded.diagonalBorder?.goesDown == true)
    }

    @Test("Clearing both directions removes the diagonal entirely")
    func clearingDiagonal() {
        var style = CellStyle.default
        style.setDiagonal(up: true, down: true)
        #expect(style.diagonalBorder?.isVisible == true)
        style.setDiagonal(up: false, down: false)
        #expect(style.diagonalBorder == nil)
    }

    // MARK: - Indent and rotation

    @Test("Indent and rotation are read from the alignment element")
    func alignmentExtrasAreRead() throws {
        let style = try readStyle(alignment: "indent=\"3\" textRotation=\"135\"")
        #expect(style.indent == 3)
        #expect(style.textRotation == 135)
        // 135 is OOXML's clockwise 45, which we render as -45.
        #expect(style.rotationDegrees == -45)

        let plain = try readStyle(alignment: "horizontal=\"left\"")
        #expect(plain.indent == 0)
        #expect(plain.textRotation == 0)
    }

    @Test("Indent and rotation survive a save/open cycle")
    func alignmentExtrasRoundTrip() throws {
        for rotation in [0, 30, 90, 91, 180, CellStyle.stackedTextRotation] {
            for indent in [0, 1, 7] {
                var style = CellStyle.default
                style.indent = indent
                style.textRotation = rotation
                let reloaded = try roundTripped(style)
                #expect(reloaded.indent == indent)
                #expect(reloaded.textRotation == rotation, "rotation \(rotation) came back wrong")
            }
        }
    }

    @Test("OOXML's split rotation range maps onto signed degrees")
    func rotationDegrees() {
        func degrees(_ raw: Int) -> Double {
            var style = CellStyle.default
            style.textRotation = raw
            return style.rotationDegrees
        }
        #expect(degrees(0) == 0)
        #expect(degrees(45) == 45)
        #expect(degrees(90) == 90)
        #expect(degrees(135) == -45)
        #expect(degrees(180) == -90)
        // Stacked text is drawn glyph-per-line, so it is not a rotation.
        #expect(degrees(CellStyle.stackedTextRotation) == 0)

        var stacked = CellStyle.default
        stacked.textRotation = CellStyle.stackedTextRotation
        #expect(stacked.isTextStacked)
    }

    @Test("Indent padding counts steps of the default font, and zero indent adds nothing")
    func indentPadding() {
        var style = CellStyle.default
        #expect(style.indentPoints == 0)
        style.indent = 2
        #expect(style.indentPoints == CellStyle.indentStepPoints * 2)
        // Three spaces of 11pt Calibri, not three characters of the cell's text.
        let small = style.indentPoints
        style.fontSize *= 2
        #expect(style.indentPoints == small)
    }

    @Test("A nonsense rotation or indent is ignored rather than stored")
    func outOfRangeAlignmentIgnored() throws {
        #expect(try readStyle(alignment: "textRotation=\"900\"").textRotation == 0)
        #expect(try readStyle(alignment: "indent=\"-4\"").indent == 0)
    }

    // MARK: - Row heights and column widths

    @Test("A row height means the same number of points in the file")
    func rowHeightsAreFaithful() throws {
        var sheet = Worksheet(name: "S")
        // 15 is Excel's own default, and is below our resize floor: an imported
        // file must keep it rather than being silently made taller.
        sheet.rowHeights = [0: 15, 1: 44, 2: 8.25, 3: 120]
        let reloaded = try roundTripped(sheet)
        #expect(reloaded.rowHeights[0] == 15)
        #expect(reloaded.rowHeights[1] == 44)
        #expect(reloaded.rowHeights[2] == 8.25)
        #expect(reloaded.rowHeights[3] == 120)
    }

    @Test("Row heights are written in points, unscaled")
    func rowHeightIsWrittenVerbatim() throws {
        var sheet = Worksheet(name: "S")
        sheet.rowHeights[0] = 42
        let data = try XLSXWriter.data(from: Workbook(sheets: [sheet]))
        let xml = String(decoding: try ZipArchive.entries(in: data)["xl/worksheets/sheet1.xml"]!, as: UTF8.self)
        #expect(xml.contains("ht=\"42\""))
    }

    @Test("Column widths round-trip to the value they started at")
    func columnWidthsRoundTrip() throws {
        var sheet = Worksheet(name: "S")
        let widths: [Int: Double] = [0: 160, 1: 48, 2: 26, 3: 300]
        sheet.columnWidths = widths
        let reloaded = try roundTripped(sheet)
        for (column, width) in widths {
            #expect(abs((reloaded.columnWidths[column] ?? 0) - width) < 0.01,
                    "column \(column) drifted from \(width)")
        }
    }

    @Test("The character-width conversion is its own inverse")
    func columnWidthConversionIsSymmetric() {
        for characters in stride(from: 1.0, through: 60.0, by: 0.37) {
            let points = Worksheet.columnWidthPoints(characters: characters)
            #expect(abs(Worksheet.columnWidthCharacters(points: points) - characters) < 1e-9)
        }
        // Excel's default 8.43 characters is 64 pixels, which is 48 points.
        #expect(abs(Worksheet.columnWidthPoints(characters: 8.43) - 48) < 0.1)
    }

    @Test("New sheets state their own defaults so Excel does not impose its own")
    func defaultsAreDeclared() throws {
        let data = try XLSXWriter.data(from: Workbook(sheets: [Worksheet(name: "S")]))
        let xml = String(decoding: try ZipArchive.entries(in: data)["xl/worksheets/sheet1.xml"]!, as: UTF8.self)
        #expect(xml.contains("<sheetFormatPr"))
        #expect(xml.contains("defaultRowHeight=\"\(Int(Worksheet.defaultRowHeight))\""))
        // The default has to leave room for the default font plus its padding.
        #expect(Worksheet.defaultRowHeight > CellStyle.default.fontSize)
    }

    @Test("An imported height below the resize floor is kept, not raised")
    func importedHeightsIgnoreTheResizeFloor() throws {
        let sheet = """
        <?xml version="1.0" encoding="UTF-8"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>\
        <row r="1" ht="15" customHeight="1"><c r="A1" t="inlineStr"><is><t>x</t></is></c></row>\
        </sheetData></worksheet>
        """
        let data = try packaged(sheet: sheet, styles: styleSheet())
        let read = try XLSXReader.workbook(from: data).sheets[0]
        #expect(read.rowHeights[0] == 15)
        #expect(read.height(ofRow: 0) == 15)
    }

    @Test("A height Excel fitted to large text is used, and written back as fitted")
    func fittedHeights() throws {
        let sheet = """
        <?xml version="1.0" encoding="UTF-8"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>\
        <row r="1" ht="15"><c r="A1" t="inlineStr"><is><t>x</t></is></c></row>\
        <row r="2" ht="59.4"><c r="A2" t="inlineStr"><is><t>Title</t></is></c></row>\
        </sheetData></worksheet>
        """
        let data = try packaged(sheet: sheet, styles: styleSheet())
        var workbook = try XLSXReader.workbook(from: data)
        // Excel's own small default stays ours; the tall fitted row is kept.
        #expect(workbook.sheets[0].rowHeights[0] == nil)
        #expect(workbook.sheets[0].height(ofRow: 1) == 59.4)

        let written = String(decoding: try ZipArchive.entries(in: XLSXWriter.data(from: workbook))["xl/worksheets/sheet1.xml"]!, as: UTF8.self)
        #expect(written.contains("<row r=\"2\" ht=\"59.4\">"))

        // Resizing it by hand makes it the user's height.
        workbook.sheets[0].insertRows(1, at: 0)
        #expect(workbook.sheets[0].fittedRows == [2])
        workbook.sheets[0].rowHeights[2] = 40
        workbook.sheets[0].fittedRows.remove(2)
        let resized = String(decoding: try ZipArchive.entries(in: XLSXWriter.data(from: workbook))["xl/worksheets/sheet1.xml"]!, as: UTF8.self)
        #expect(resized.contains("<row r=\"3\" ht=\"40\" customHeight=\"1\""))
    }
}
