import Foundation
import Testing
@testable import Tables
@testable import TablesEngine

/// Shapes on a sheet's drawing — rectangles, ovals, lines, arrows and text
/// boxes — read well enough to draw, moved with their cells, and written back
/// as the file had them.
@Suite("Drawing shapes")
struct DrawingShapeTests {

    // MARK: - Fixtures

    private static let relationships = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    private static let spreadsheetDrawing = "http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing"
    private static let drawingML = "http://schemas.openxmlformats.org/drawingml/2006/main"

    private static func marker(_ name: String, column: Int, row: Int) -> String {
        "<xdr:\(name)><xdr:col>\(column)</xdr:col><xdr:colOff>0</xdr:colOff>"
            + "<xdr:row>\(row)</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:\(name)>"
    }

    private static func twoCell(_ from: (Int, Int), _ to: (Int, Int), _ object: String) -> String {
        "<xdr:twoCellAnchor>" + marker("from", column: from.0, row: from.1) + marker("to", column: to.0, row: to.1)
            + object + "<xdr:clientData/></xdr:twoCellAnchor>"
    }

    private static let transform = "<a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"1270000\" cy=\"635000\"/></a:xfrm>"

    /// A rectangle as Excel inserts one: no fill or line of its own, only
    /// the theme's, through its style.
    static let styledRectangle = twoCell((1, 1), (4, 5), """
    <xdr:sp macro="" textlink=""><xdr:nvSpPr><xdr:cNvPr id="2" name="Rectangle 1"/><xdr:cNvSpPr/></xdr:nvSpPr>\
    <xdr:spPr>\(transform)<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></xdr:spPr>\
    <xdr:style><a:lnRef idx="2"><a:schemeClr val="accent1"><a:shade val="50000"/></a:schemeClr></a:lnRef>\
    <a:fillRef idx="1"><a:schemeClr val="accent1"/></a:fillRef><a:effectRef idx="0"><a:schemeClr val="accent1"/>\
    </a:effectRef><a:fontRef idx="minor"><a:schemeClr val="lt1"/></a:fontRef></xdr:style>\
    <xdr:txBody><a:bodyPr anchor="ctr"/><a:lstStyle/><a:p><a:pPr algn="ctr"/><a:r><a:rPr lang="en-US" sz="1400"/>\
    <a:t>Total</a:t></a:r></a:p></xdr:txBody></xdr:sp>
    """)

    static let ellipse = twoCell((6, 1), (9, 5), """
    <xdr:sp macro="" textlink=""><xdr:nvSpPr><xdr:cNvPr id="3" name="Oval 2"/><xdr:cNvSpPr/></xdr:nvSpPr>\
    <xdr:spPr>\(transform)<a:prstGeom prst="ellipse"><a:avLst/></a:prstGeom>\
    <a:solidFill><a:srgbClr val="FFC000"/></a:solidFill><a:ln w="25400"><a:solidFill><a:srgbClr val="C00000"/>\
    </a:solidFill></a:ln></xdr:spPr></xdr:sp>
    """)

    static let textBox = twoCell((1, 7), (5, 11), """
    <xdr:sp macro="" textlink=""><xdr:nvSpPr><xdr:cNvPr id="4" name="TextBox 3"/><xdr:cNvSpPr txBox="1"/>\
    </xdr:nvSpPr><xdr:spPr>\(transform)<a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/>\
    <a:ln w="9525"><a:solidFill><a:srgbClr val="000000"/></a:solidFill></a:ln></xdr:spPr>\
    <xdr:txBody><a:bodyPr wrap="square" anchor="b"/><a:lstStyle/><a:p><a:pPr algn="r"/><a:r>\
    <a:rPr lang="en-US" sz="1000"><a:solidFill><a:srgbClr val="2F5597"/></a:solidFill></a:rPr><a:t>First line</a:t>\
    </a:r></a:p><a:p><a:r><a:rPr lang="en-US" sz="1000"/><a:t>Second</a:t></a:r></a:p></xdr:txBody></xdr:sp>
    """)

    static let arrow = twoCell((6, 7), (9, 11), """
    <xdr:cxnSp macro=""><xdr:nvCxnSpPr><xdr:cNvPr id="5" name="Straight Arrow Connector 4"/><xdr:cNvCxnSpPr/>\
    </xdr:nvCxnSpPr><xdr:spPr><a:xfrm flipV="1"><a:off x="0" y="0"/><a:ext cx="1270000" cy="635000"/></a:xfrm>\
    <a:prstGeom prst="straightConnector1"><a:avLst/></a:prstGeom><a:ln w="19050"><a:solidFill>\
    <a:srgbClr val="70AD47"/></a:solidFill><a:tailEnd type="triangle"/></a:ln></xdr:spPr></xdr:cxnSp>
    """)

    static let roundedRectangle = twoCell((11, 1), (14, 5), """
    <xdr:sp macro="" textlink=""><xdr:nvSpPr><xdr:cNvPr id="6" name="Rounded Rectangle 5"/><xdr:cNvSpPr/>\
    </xdr:nvSpPr><xdr:spPr><a:xfrm rot="2700000"><a:off x="0" y="0"/><a:ext cx="1270000" cy="635000"/></a:xfrm>\
    <a:prstGeom prst="roundRect"><a:avLst/></a:prstGeom><a:solidFill><a:schemeClr val="accent6"/></a:solidFill>\
    <a:ln><a:noFill/></a:ln></xdr:spPr></xdr:sp>
    """)

    /// A star: kept, and shown as the placeholder, since it is not drawn here.
    static let star = twoCell((11, 7), (14, 11), """
    <xdr:sp macro="" textlink=""><xdr:nvSpPr><xdr:cNvPr id="7" name="Star 6"/><xdr:cNvSpPr/></xdr:nvSpPr>\
    <xdr:spPr>\(transform)<a:prstGeom prst="star5"><a:avLst/></a:prstGeom><a:solidFill><a:srgbClr val="FF0000"/>\
    </a:solidFill></xdr:spPr></xdr:sp>
    """)

    static let picture = """
    <xdr:oneCellAnchor><xdr:from><xdr:col>16</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>1</xdr:row>\
    <xdr:rowOff>0</xdr:rowOff></xdr:from><xdr:ext cx="952500" cy="952500"/><xdr:pic><xdr:nvPicPr>\
    <xdr:cNvPr id="8" name="Picture 7" descr="A red square"/><xdr:cNvPicPr><a:picLocks noChangeAspect="1"/>\
    </xdr:cNvPicPr></xdr:nvPicPr><xdr:blipFill><a:blip r:embed="rIdImage"/><a:stretch><a:fillRect/></a:stretch>\
    </xdr:blipFill><xdr:spPr><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></xdr:spPr></xdr:pic>\
    <xdr:clientData/></xdr:oneCellAnchor>
    """

    static var allAnchors: String {
        styledRectangle + ellipse + textBox + arrow + roundedRectangle + star + picture
    }

    /// One worksheet, "Shapes", with `anchors` on its drawing and a picture
    /// part for any of them that shows one.
    static func package(anchors: String, image: Data = Data([0x89, 0x50, 0x4E, 0x47])) throws -> Data {
        let entries: [(String, Data)] = [
            ("[Content_Types].xml", Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
            <Default Extension="xml" ContentType="application/xml"/>\
            <Default Extension="png" ContentType="image/png"/>\
            <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
            <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>\
            <Override PartName="/xl/drawings/drawing1.xml" ContentType="application/vnd.openxmlformats-officedocument.drawing+xml"/>\
            </Types>
            """.utf8)),
            ("_rels/.rels", Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="\(relationships)/officeDocument" Target="xl/workbook.xml"/></Relationships>
            """.utf8)),
            ("xl/workbook.xml", Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="\(relationships)">\
            <sheets><sheet name="Shapes" sheetId="1" r:id="rId1"/></sheets></workbook>
            """.utf8)),
            ("xl/_rels/workbook.xml.rels", Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="\(relationships)/worksheet" Target="worksheets/sheet1.xml"/></Relationships>
            """.utf8)),
            ("xl/worksheets/sheet1.xml", Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="\(relationships)">\
            <sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>Shapes and pictures</t></is></c></row></sheetData>\
            <drawing r:id="rId1"/></worksheet>
            """.utf8)),
            ("xl/worksheets/_rels/sheet1.xml.rels", Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="\(relationships)/drawing" Target="../drawings/drawing1.xml"/></Relationships>
            """.utf8)),
            ("xl/drawings/drawing1.xml", Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <xdr:wsDr xmlns:xdr="\(spreadsheetDrawing)" xmlns:a="\(drawingML)" xmlns:r="\(relationships)">\
            \(anchors)</xdr:wsDr>
            """.utf8)),
            ("xl/drawings/_rels/drawing1.xml.rels", Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rIdImage" Type="\(relationships)/image" Target="../media/image1.png"/></Relationships>
            """.utf8)),
            ("xl/media/image1.png", image),
        ]
        return try ZipArchive.archive(entries: entries.map { (path: $0.0, data: $0.1) })
    }

    private func shapes(_ workbook: Workbook) -> [DrawingShape?] {
        workbook.sheets[0].preservedDrawingAnchors.map(\.shape)
    }

    // MARK: - Reading

    @Test("A theme-styled rectangle takes its fill, outline and text colour from the theme")
    func styledRectangle() throws {
        let workbook = try XLSXReader.workbook(from: Self.package(anchors: Self.styledRectangle))
        let shape = try #require(shapes(workbook).first ?? nil)
        #expect(shape.kind == .rectangle)
        #expect(shape.fillHex == "4472C4")
        #expect(shape.outlineHex != nil && shape.outlineHex != "4472C4")
        #expect(shape.outlineWidth == 1)
        #expect(shape.text == "Total")
        #expect(shape.textHex == "FFFFFF")
        #expect(shape.fontSize == 14)
        #expect(shape.textAlignment == .center)
        #expect(shape.textAnchor == .center)
    }

    @Test("Ovals, text boxes, arrows and rounded rectangles are read as what they are")
    func eachKind() throws {
        let workbook = try XLSXReader.workbook(from: Self.package(anchors: Self.allAnchors))
        let read = shapes(workbook)
        #expect(read.count == 7)

        let ellipse = try #require(read[1])
        #expect(ellipse.kind == .ellipse)
        #expect(ellipse.fillHex == "FFC000")
        #expect(ellipse.outlineHex == "C00000")
        #expect(ellipse.outlineWidth == 2)
        #expect(ellipse.text.isEmpty)

        let box = try #require(read[2])
        #expect(box.kind == .textBox)
        #expect(box.fillHex == nil)
        #expect(box.outlineHex == "000000")
        #expect(box.text == "First line\nSecond")
        #expect(box.textHex == "2F5597")
        #expect(box.fontSize == 10)
        #expect(box.textAlignment == .trailing)
        #expect(box.textAnchor == .bottom)

        let arrow = try #require(read[3])
        #expect(arrow.kind == .arrow)
        #expect(arrow.outlineHex == "70AD47")
        #expect(arrow.outlineWidth == 1.5)
        #expect(arrow.hasArrowAtEnd && !arrow.hasArrowAtStart)
        #expect(arrow.flipsVertically && !arrow.flipsHorizontally)

        let rounded = try #require(read[4])
        #expect(rounded.kind == .roundedRectangle)
        #expect(rounded.fillHex == "70AD47")
        #expect(rounded.outlineHex == nil)
        #expect(rounded.rotation == 45)

        // Not drawn here: a star stays a kept object, as does the picture.
        #expect(read[5] == nil)
        #expect(read[6] == nil)
        #expect(workbook.sheets[0].preservedDrawingAnchors[6].picture?.target == "xl/media/image1.png")
    }

    @Test("A hidden shape is left to the placeholder rather than drawn")
    func hiddenShape() throws {
        let hidden = Self.ellipse.replacingOccurrences(of: "name=\"Oval 2\"", with: "name=\"Oval 2\" hidden=\"1\"")
        let workbook = try XLSXReader.workbook(from: Self.package(anchors: hidden))
        #expect(workbook.sheets[0].preservedDrawingAnchors.count == 1)
        #expect(shapes(workbook) == [nil])
    }

    // MARK: - Following the cells and saving

    @Test("Shapes and pictures move with rows inserted above them and keep their look")
    func followRows() throws {
        var workbook = try XLSXReader.workbook(from: Self.package(anchors: Self.allAnchors))
        let before = shapes(workbook)
        workbook.sheets[0].insertRows(2, at: 0)
        let rows = workbook.sheets[0].preservedDrawingAnchors.compactMap { $0.placement?.from.row }
        #expect(rows == [3, 3, 9, 9, 3, 9, 3])
        #expect(shapes(workbook) == before)
    }

    @Test("Saved and reopened, every shape and picture is still there and still drawn the same")
    func roundTrip() throws {
        var workbook = try XLSXReader.workbook(from: Self.package(anchors: Self.allAnchors))
        let before = shapes(workbook)
        workbook.sheets[0].insertRows(2, at: 0)

        let saved = try XLSXWriter.data(from: workbook)
        let entries = try ZipArchive.entries(in: saved)
        let drawingPath = try #require(entries.keys.first { $0.hasPrefix("xl/drawings/drawing") && $0.hasSuffix(".xml") })
        let drawing = String(decoding: try #require(entries[drawingPath]), as: UTF8.self)
        for name in ["Rectangle 1", "Oval 2", "TextBox 3", "Straight Arrow Connector 4", "Rounded Rectangle 5",
                     "Star 6", "Picture 7"] {
            #expect(drawing.contains("name=\"\(name)\""))
        }
        #expect(drawing.contains("prst=\"straightConnector1\""))
        #expect(drawing.contains("<a:tailEnd type=\"triangle\"/>"))
        #expect(entries["xl/media/image1.png"] != nil)

        let reopened = try XLSXReader.workbook(from: saved)
        #expect(shapes(reopened) == before)
        #expect(reopened.sheets[0].preservedDrawingAnchors.compactMap { $0.placement?.from.row } == [3, 3, 9, 9, 3, 9, 3])
        #expect(reopened.sheets[0].preservedDrawingAnchors[6].picture?.target == "xl/media/image1.png")
    }
}
