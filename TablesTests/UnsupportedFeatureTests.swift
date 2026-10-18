import Foundation
import Testing
@testable import Tables
@testable import TablesEngine
@testable import TablesMacros

/// Guards what happens to the parts of a workbook Tables cannot edit. A file
/// opened here and saved again must come back with them intact, or without
/// them and without any reference to them — never half of one.
@Suite("Unsupported features")
struct UnsupportedFeatureTests {

    // MARK: - Package construction

    /// A part of a package under test: its path, its bytes, and the content
    /// type the package should declare for it.
    private struct Part {
        var path: String
        var xml: String
        /// An `<Override>` entry. Parts covered by a `<Default>` leave this nil.
        var contentType: String?

        init(_ path: String, _ xml: String, contentType: String? = nil) {
            self.path = path
            self.xml = xml
            self.contentType = contentType
        }
    }

    private static let sheetContentType =
        "application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"

    /// Builds a package around one or more worksheets plus whatever extra parts
    /// a test wants to see survive — or fail to.
    ///
    /// Deliberately separate from `ExcelCompatibilityTests`' own helper: these
    /// tests need several sheets, arbitrary extra parts, per-part relationships
    /// and content types, none of which that one has any business growing.
    private func package(
        sheets sheetBodies: [String],
        extraParts: [Part] = [],
        contentTypeDefaults: [String: String] = [:],
        rootRelationships: String = "",
        workbookRelationships: String = "",
        sheetRelationships: [Int: String] = [:],
        styleSheetTail: String = ""
    ) throws -> Data {
        var contentTypes = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>
        """
        for (ext, type) in contentTypeDefaults.sorted(by: { $0.key < $1.key }) {
            contentTypes += "<Default Extension=\"\(ext)\" ContentType=\"\(type)\"/>"
        }
        for index in sheetBodies.indices {
            contentTypes += "<Override PartName=\"/xl/worksheets/sheet\(index + 1).xml\""
            contentTypes += " ContentType=\"\(Self.sheetContentType)\"/>"
        }
        for part in extraParts {
            guard let type = part.contentType else { continue }
            contentTypes += "<Override PartName=\"/\(part.path)\" ContentType=\"\(type)\"/>"
        }
        contentTypes += "</Types>"

        let rootRels = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" \
        Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" \
        Target="xl/workbook.xml"/>\(rootRelationships)</Relationships>
        """

        var workbookSheets = ""
        var workbookRels = ""
        for index in sheetBodies.indices {
            workbookSheets += "<sheet name=\"Sheet\(index + 1)\" sheetId=\"\(index + 1)\" r:id=\"rId\(index + 1)\"/>"
            workbookRels += "<Relationship Id=\"rId\(index + 1)\" "
            workbookRels += "Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" "
            workbookRels += "Target=\"worksheets/sheet\(index + 1).xml\"/>"
        }
        let workbook = """
        <?xml version="1.0" encoding="UTF-8"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
        <sheets>\(workbookSheets)</sheets></workbook>
        """
        let workbookRelsPart = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        \(workbookRels)\(workbookRelationships)</Relationships>
        """
        let styles = """
        <?xml version="1.0" encoding="UTF-8"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
        <fonts count="1"><font><sz val="11"/></font></fonts>\
        <fills count="1"><fill><patternFill patternType="none"/></fill></fills>\
        <borders count="1"><border/></borders>\
        <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
        <cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs>\
        \(styleSheetTail)</styleSheet>
        """

        var entries: [(path: String, data: Data)] = [
            ("[Content_Types].xml", Data(contentTypes.utf8)),
            ("_rels/.rels", Data(rootRels.utf8)),
            ("xl/workbook.xml", Data(workbook.utf8)),
            ("xl/_rels/workbook.xml.rels", Data(workbookRelsPart.utf8)),
            ("xl/styles.xml", Data(styles.utf8)),
        ]
        for (index, body) in sheetBodies.enumerated() {
            entries.append(("xl/worksheets/sheet\(index + 1).xml", Data(sheetXML(body: body).utf8)))
            guard let relationships = sheetRelationships[index] else { continue }
            let payload = """
            <?xml version="1.0" encoding="UTF-8"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            \(relationships)</Relationships>
            """
            entries.append(("xl/worksheets/_rels/sheet\(index + 1).xml.rels", Data(payload.utf8)))
        }
        for part in extraParts { entries.append((part.path, Data(part.xml.utf8))) }
        return try ZipArchive.archive(entries: entries)
    }

    /// Wraps worksheet children in a worksheet with one populated cell, so the
    /// sheet is something our reader would keep even without the extras.
    private func sheetXML(body: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
        <sheetData><row r="1"><c r="A1"><v>1</v></c></row></sheetData>\(body)</worksheet>
        """
    }

    /// Reads a package, writes it straight back out, and hands back both the
    /// model and the entries of the file that came out.
    private func roundTrip(_ data: Data) throws -> (workbook: Workbook, entries: [String: Data]) {
        let workbook = try XLSXReader.workbook(from: data)
        return (workbook, try ZipArchive.entries(in: try XLSXWriter.data(from: workbook)))
    }

    private func text(_ entries: [String: Data], _ path: String) throws -> String {
        let payload = try #require(entries[path], "\(path) is missing from the package")
        return String(decoding: payload, as: UTF8.self)
    }

    // MARK: - Worksheet children

    @Test("An unmodelled worksheet child comes back in its schema position")
    func worksheetChildOrder() throws {
        // Given to the reader in an order the schema does not allow, so that
        // simply echoing the input back could not pass this test.
        let body = """
        <conditionalFormatting sqref="A1"><cfRule type="expression" priority="1">\
        <formula>A1&gt;0</formula></cfRule></conditionalFormatting>\
        <autoFilter ref="A1:B1"/><pageSetup orientation="landscape"/>\
        <dataValidations count="1"><dataValidation sqref="A1" type="list">\
        <formula1>"a,b"</formula1></dataValidation></dataValidations>
        """
        let (_, entries) = try roundTrip(try package(sheets: [body]))
        let sheet = try text(entries, "xl/worksheets/sheet1.xml")

        for name in ["autoFilter", "conditionalFormatting", "dataValidations", "pageSetup"] {
            #expect(sheet.contains("<\(name)"), "\(name) did not survive")
        }
        let positions = ["sheetData", "autoFilter", "conditionalFormatting", "dataValidations", "pageSetup"]
            .map { sheet.range(of: "<\($0)")?.lowerBound }
        #expect(positions.allSatisfy { $0 != nil })
        #expect(positions == positions.sorted { ($0 ?? sheet.startIndex) < ($1 ?? sheet.startIndex) })

        // The fragment itself has to survive whole, not just its element name.
        #expect(sheet.contains("orientation=\"landscape\""))
        #expect(sheet.contains("A1&gt;0"))
        #expect(sheet.contains("&quot;a,b&quot;"))
    }

    @Test("A frozen pane is read, and written back ahead of the parts we generate")
    func frozenPanesSurvive() throws {
        let body = "<sheetViews><sheetView workbookViewId=\"0\" zoomScale=\"120\">"
            + "<pane xSplit=\"1\" ySplit=\"2\" topLeftCell=\"B3\" activePane=\"bottomRight\" state=\"frozen\"/>"
            + "<selection pane=\"bottomRight\" activeCell=\"C4\"/>"
            + "</sheetView></sheetViews>"
        let (workbook, entries) = try roundTrip(try package(sheets: [body]))
        let sheet = try text(entries, "xl/worksheets/sheet1.xml")

        #expect(workbook.sheets[0].frozenRows == 2)
        #expect(workbook.sheets[0].frozenColumns == 1)
        // Attributes come out in name order.
        #expect(sheet.contains("<pane activePane=\"bottomRight\" state=\"frozen\" topLeftCell=\"B3\" xSplit=\"1\" ySplit=\"2\"/>"))
        // The rest of the view comes along; one pane only.
        #expect(sheet.contains("zoomScale=\"120\""))
        #expect(sheet.components(separatedBy: "<pane").count == 2)
        // `sheetViews` precedes `sheetFormatPr` and `sheetData` in the schema.
        let views = try #require(sheet.range(of: "<sheetViews"))
        let format = try #require(sheet.range(of: "<sheetFormatPr"))
        #expect(views.lowerBound < format.lowerBound)
        #expect(workbook.unsupportedFeatures.isEmpty)
    }

    @Test("A split that isn't frozen is kept, and named as unsupported")
    func splitPanesSurvive() throws {
        let body = "<sheetViews><sheetView workbookViewId=\"0\">"
            + "<pane xSplit=\"2400\" ySplit=\"1200\" topLeftCell=\"C5\"/>"
            + "</sheetView></sheetViews>"
        let (workbook, entries) = try roundTrip(try package(sheets: [body]))

        #expect(try text(entries, "xl/worksheets/sheet1.xml").contains("xSplit=\"2400\""))
        #expect(workbook.sheets[0].frozenRows == 0)
        #expect(workbook.unsupportedFeatures.preserved.contains(.frozenPanes))
    }

    @Test("Freezing a sheet with no view of its own writes one")
    func freezingWritesAView() throws {
        var sheet = Worksheet(name: "Sheet1")
        sheet.frozenRows = 1
        let data = try XLSXWriter.data(from: Workbook(sheets: [sheet]))
        let reread = try XLSXReader.workbook(from: data)
        #expect(reread.sheets[0].frozenRows == 1)
        #expect(reread.sheets[0].frozenColumns == 0)
    }

    @Test("A view carrying only a cursor position is not called a lost feature")
    func plainSheetViewIsNotReported() throws {
        let body = "<sheetViews><sheetView workbookViewId=\"0\"><selection activeCell=\"B2\"/></sheetView></sheetViews>"
        let (workbook, entries) = try roundTrip(try package(sheets: [body]))

        #expect(try text(entries, "xl/worksheets/sheet1.xml").contains("activeCell=\"B2\""))
        #expect(workbook.unsupportedFeatures.isEmpty)
    }

    // MARK: - Package parts

    @Test("An extra part survives with its content type and its relationship")
    func extraPartSurvives() throws {
        let theme = Part(
            "xl/theme/theme1.xml",
            "<?xml version=\"1.0\"?><theme xmlns=\"http://schemas.openxmlformats.org/drawingml/2006/main\"/>",
            contentType: "application/vnd.openxmlformats-officedocument.theme+xml"
        )
        let properties = Part(
            "docProps/core.xml",
            "<?xml version=\"1.0\"?><coreProperties xmlns=\"http://purl.org/dc/elements/1.1/\"/>",
            contentType: "application/vnd.openxmlformats-package.core-properties+xml"
        )
        let data = try package(
            sheets: [""],
            extraParts: [theme, properties],
            rootRelationships: "<Relationship Id=\"rIdX\" "
                + "Type=\"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties\" "
                + "Target=\"docProps/core.xml\"/>",
            workbookRelationships: "<Relationship Id=\"rIdY\" "
                + "Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme\" "
                + "Target=\"theme/theme1.xml\"/>"
        )
        let (workbook, entries) = try roundTrip(data)

        #expect(entries["xl/theme/theme1.xml"] != nil)
        #expect(entries["docProps/core.xml"] != nil)

        let types = try text(entries, "[Content_Types].xml")
        #expect(types.contains("PartName=\"/xl/theme/theme1.xml\""))
        #expect(types.contains("PartName=\"/docProps/core.xml\""))

        #expect(try text(entries, "xl/_rels/workbook.xml.rels").contains("Target=\"theme/theme1.xml\""))
        #expect(try text(entries, "_rels/.rels").contains("Target=\"docProps/core.xml\""))
        // Our own relationship ids must still be the ones the workbook names.
        #expect(try text(entries, "xl/_rels/workbook.xml.rels")
            .contains("Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\""))
        #expect(workbook.unsupportedFeatures.preserved.contains(.documentProperties))
    }

    @Test("Form control properties and ActiveX parts survive with the controls list that names them")
    func controlsSurvive() throws {
        let properties = Part(
            "xl/ctrlProps/ctrlProp1.xml",
            "<?xml version=\"1.0\"?><formControlPr "
                + "xmlns=\"http://schemas.microsoft.com/office/spreadsheetml/2009/9/main\" objectType=\"Button\"/>",
            contentType: "application/vnd.ms-excel.controlproperties+xml"
        )
        let activeX = Part(
            "xl/activeX/activeX1.xml",
            "<?xml version=\"1.0\"?><ax:ocx xmlns:ax=\"http://schemas.microsoft.com/office/2006/activeX\"/>",
            contentType: "application/vnd.ms-office.activeX+xml"
        )
        // Excel 2010 and later hide the list from older readers behind
        // markup compatibility.
        let controls = "<mc:AlternateContent xmlns:mc=\"http://schemas.openxmlformats.org/markup-compatibility/2006\">"
            + "<mc:Choice Requires=\"x14\"><controls><control shapeId=\"1025\" r:id=\"rId1\" name=\"Button 1\"/>"
            + "<control shapeId=\"1026\" r:id=\"rId2\" name=\"CommandButton1\"/></controls></mc:Choice>"
            + "</mc:AlternateContent>"
        let data = try package(
            sheets: [controls],
            extraParts: [properties, activeX],
            sheetRelationships: [0: "<Relationship Id=\"rId1\" "
                + "Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/ctrlProp\" "
                + "Target=\"../ctrlProps/ctrlProp1.xml\"/><Relationship Id=\"rId2\" "
                + "Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/control\" "
                + "Target=\"../activeX/activeX1.xml\"/>"]
        )
        let (_, entries) = try roundTrip(data)

        #expect(entries["xl/ctrlProps/ctrlProp1.xml"] != nil)
        #expect(entries["xl/activeX/activeX1.xml"] != nil)
        let sheet = try text(entries, "xl/worksheets/sheet1.xml")
        #expect(sheet.contains("<mc:Choice Requires=\"x14\"><controls"))
        #expect(sheet.contains("shapeId=\"1026\""))
        #expect(try text(entries, "xl/worksheets/_rels/sheet1.xml.rels").contains("Target=\"../ctrlProps/ctrlProp1.xml\""))
    }

    @Test("A part is dropped whole when a part it needs cannot be kept")
    func unsatisfiableDependencyDropsThePart() throws {
        // The drawing reaches an embedded object, which is a family we never
        // carry through, so the drawing itself has to go with it.
        let drawing = Part(
            "xl/drawings/drawing1.xml",
            "<?xml version=\"1.0\"?><wsDr xmlns=\"http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing\"/>",
            contentType: "application/vnd.openxmlformats-officedocument.drawing+xml"
        )
        let drawingRels = Part(
            "xl/drawings/_rels/drawing1.xml.rels",
            """
            <?xml version="1.0"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" \
            Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/oleObject" \
            Target="../embeddings/object1.bin"/></Relationships>
            """
        )
        let embedding = Part("xl/embeddings/object1.bin", "binary")
        let data = try package(
            sheets: ["<drawing r:id=\"rId1\"/>"],
            extraParts: [drawing, drawingRels, embedding],
            contentTypeDefaults: ["bin": "application/vnd.openxmlformats-officedocument.oleObject"],
            sheetRelationships: [
                0: "<Relationship Id=\"rId1\" "
                    + "Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/drawing\" "
                    + "Target=\"../drawings/drawing1.xml\"/>",
            ]
        )
        let (workbook, entries) = try roundTrip(data)

        #expect(entries["xl/drawings/drawing1.xml"] == nil)
        #expect(entries["xl/embeddings/object1.bin"] == nil)
        // The sheet's own `_rels` named the drawing, so it cannot be re-emitted
        // either — and without it the `<drawing>` element has nothing to resolve.
        #expect(entries["xl/worksheets/_rels/sheet1.xml.rels"] == nil)
        #expect(!(try text(entries, "xl/worksheets/sheet1.xml").contains("<drawing")))
        #expect(!(try text(entries, "[Content_Types].xml").contains("drawing1.xml")))

        #expect(workbook.unsupportedFeatures.lost.contains(.chartsAndImages))
        #expect(!workbook.unsupportedFeatures.preserved.contains(.chartsAndImages))
    }

    @Test("A relationship-naming child needs its sheet's relationships to come too")
    func relationshipDependentChildNeedsItsRelationships() throws {
        // No `_rels` part for the sheet at all, so `rId9` resolves to nothing.
        let data = try package(sheets: ["<hyperlinks><hyperlink ref=\"A1\" r:id=\"rId9\"/></hyperlinks>"])
        let (workbook, entries) = try roundTrip(data)

        #expect(!(try text(entries, "xl/worksheets/sheet1.xml").contains("<hyperlinks")))
        #expect(workbook.unsupportedFeatures.lost.contains(.hyperlinks))
    }

    @Test("A sheet's relationships follow it when the sheets are reordered")
    func sheetRelationshipsFollowTheirSheet() throws {
        let table = Part(
            "xl/tables/table1.xml",
            "<?xml version=\"1.0\"?><table xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\""
                + " id=\"1\" name=\"T\" displayName=\"T\" ref=\"A1:B2\"/>",
            contentType: "application/vnd.openxmlformats-officedocument.spreadsheetml.table+xml"
        )
        let data = try package(
            sheets: ["", "<tableParts count=\"1\"><tablePart r:id=\"rId1\"/></tableParts>"],
            extraParts: [table],
            sheetRelationships: [
                1: "<Relationship Id=\"rId1\" "
                    + "Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/table\" "
                    + "Target=\"../tables/table1.xml\"/>",
            ]
        )
        var workbook = try XLSXReader.workbook(from: data)
        #expect(workbook.unsupportedFeatures.preserved.contains(.tables))

        workbook.moveSheet(workbook.sheets[1].id, to: 0)
        let entries = try ZipArchive.entries(in: try XLSXWriter.data(from: workbook))

        #expect(try text(entries, "xl/worksheets/sheet1.xml").contains("<tableParts"))
        #expect(try text(entries, "xl/worksheets/_rels/sheet1.xml.rels").contains("tables/table1.xml"))
        #expect(entries["xl/worksheets/_rels/sheet2.xml.rels"] == nil)
        #expect(entries["xl/tables/table1.xml"] != nil)
    }

    @Test("A duplicated sheet keeps only what stands on its own")
    func duplicatedSheetDropsRelationshipDependentChildren() throws {
        let table = Part(
            "xl/tables/table1.xml",
            "<?xml version=\"1.0\"?><table xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\""
                + " id=\"1\" name=\"T\" displayName=\"T\" ref=\"A1:B2\"/>",
            contentType: "application/vnd.openxmlformats-officedocument.spreadsheetml.table+xml"
        )
        let data = try package(
            sheets: ["<autoFilter ref=\"A1:B1\"/><tableParts count=\"1\"><tablePart r:id=\"rId1\"/></tableParts>"],
            extraParts: [table],
            sheetRelationships: [
                0: "<Relationship Id=\"rId1\" "
                    + "Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/table\" "
                    + "Target=\"../tables/table1.xml\"/>",
            ]
        )
        var workbook = try XLSXReader.workbook(from: data)
        _ = workbook.duplicateSheet(workbook.sheets[0].id)
        let entries = try ZipArchive.entries(in: try XLSXWriter.data(from: workbook))

        // Two tables sharing one identifier is a file Excel refuses, so the
        // copy keeps the filter and loses the table.
        let copy = try text(entries, "xl/worksheets/sheet2.xml")
        #expect(copy.contains("<autoFilter"))
        #expect(!copy.contains("<tableParts"))
        #expect(try text(entries, "xl/worksheets/sheet1.xml").contains("<tableParts"))
    }

    @Test("Conditional formatting is dropped when its differential formats are not there")
    func conditionalFormattingNeedsDifferentialFormats() throws {
        let rule = "<conditionalFormatting sqref=\"A1\">"
            + "<cfRule type=\"cellIs\" operator=\"greaterThan\" priority=\"1\" dxfId=\"0\">"
            + "<formula>100</formula></cfRule></conditionalFormatting>"

        let without = try roundTrip(try package(sheets: [rule]))
        #expect(!(try text(without.entries, "xl/worksheets/sheet1.xml").contains("cfRule")))
        #expect(without.workbook.unsupportedFeatures.lost.contains(.conditionalFormatting))

        let dxfs = "<dxfs count=\"1\"><dxf><fill><patternFill><bgColor rgb=\"FFFF0000\"/>"
            + "</patternFill></fill></dxf></dxfs>"
        let with = try roundTrip(try package(sheets: [rule], styleSheetTail: dxfs))
        #expect(try text(with.entries, "xl/worksheets/sheet1.xml").contains("dxfId=\"0\""))
        #expect(try text(with.entries, "xl/styles.xml").contains("<dxfs"))
        #expect(with.workbook.unsupportedFeatures.preserved.contains(.conditionalFormatting))
        // `<dxfs>` follows `<cellStyles>` in the stylesheet schema.
        let styles = try text(with.entries, "xl/styles.xml")
        let cellStyles = try #require(styles.range(of: "<cellStyles"))
        let differential = try #require(styles.range(of: "<dxfs"))
        #expect(cellStyles.lowerBound < differential.lowerBound)
    }

    @Test("Sparklines and Excel 2010's other sheet extensions survive; slicers' references do not dangle")
    func sheetExtensionsSurvive() throws {
        let body = """
        <extLst><ext uri="{05C60535-1F16-4fd2-B633-F4F36F0B64E0}" \
        xmlns:x14="http://schemas.microsoft.com/office/spreadsheetml/2009/9/main">\
        <x14:sparklineGroups xmlns:xm="http://schemas.microsoft.com/office/excel/2006/main">\
        <x14:sparklineGroup displayEmptyCellsAs="gap" markers="1"><x14:colorSeries rgb="FF376092"/>\
        <x14:sparklines><x14:sparkline><xm:f>Sheet1!A1:A1</xm:f><xm:sqref>B1</xm:sqref></x14:sparkline>\
        </x14:sparklines></x14:sparklineGroup></x14:sparklineGroups></ext>\
        <ext uri="{A8765BA9-456A-4dab-B4F3-ACF838C121DE}" \
        xmlns:x14="http://schemas.microsoft.com/office/spreadsheetml/2009/9/main">\
        <x14:slicerList><x14:slicer r:id="rId7"/></x14:slicerList></ext></extLst>
        """
        let (workbook, entries) = try roundTrip(try package(sheets: [body]))
        let sheet = try text(entries, "xl/worksheets/sheet1.xml")
        #expect(sheet.contains("<x14:sparkline>"))
        #expect(sheet.contains("<xm:f>Sheet1!A1:A1</xm:f>"))
        #expect(sheet.contains("xmlns:xm=\"http://schemas.microsoft.com/office/excel/2006/main\""))
        #expect(!sheet.contains("slicer"))
        #expect(sheet.hasSuffix("</extLst></worksheet>"))
        #expect(workbook.unsupportedFeatures.preserved.contains(.sparklines))
    }

    @Test("A sheet with a PivotTable or a slicer keeps its hyperlinks; the slicer is reported lost")
    func pivotAndSlicerRelationshipsDoNotTakeTheSheetsWithThem() throws {
        let slicer = Part(
            "xl/slicers/slicer1.xml",
            "<?xml version=\"1.0\"?><slicers xmlns=\"http://schemas.microsoft.com/office/spreadsheetml/2009/9/main\"/>",
            contentType: "application/vnd.ms-excel.slicer+xml"
        )
        let pivot = Part(
            "xl/pivotTables/pivotTable1.xml",
            "<?xml version=\"1.0\"?><pivotTableDefinition xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"/>",
            contentType: "application/vnd.openxmlformats-officedocument.spreadsheetml.pivotTable+xml"
        )
        let body = """
        <hyperlinks><hyperlink ref="A1" r:id="rId1"/></hyperlinks>\
        <extLst><ext uri="{A8765BA9-456A-4dab-B4F3-ACF838C121DE}" \
        xmlns:x14="http://schemas.microsoft.com/office/spreadsheetml/2009/9/main">\
        <x14:slicerList><x14:slicer r:id="rId3"/></x14:slicerList></ext></extLst>
        """
        let data = try package(
            sheets: [body],
            extraParts: [slicer, pivot],
            sheetRelationships: [
                0: "<Relationship Id=\"rId1\" "
                    + "Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink\" "
                    + "Target=\"https://example.com\" TargetMode=\"External\"/>"
                    + "<Relationship Id=\"rId2\" "
                    + "Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/pivotTable\" "
                    + "Target=\"../pivotTables/pivotTable1.xml\"/>"
                    + "<Relationship Id=\"rId3\" "
                    + "Type=\"http://schemas.microsoft.com/office/2007/relationships/slicer\" "
                    + "Target=\"../slicers/slicer1.xml\"/>",
            ]
        )
        let (workbook, entries) = try roundTrip(data)
        let sheet = try text(entries, "xl/worksheets/sheet1.xml")
        #expect(sheet.contains("<hyperlinks") && sheet.contains("r:id=\"rId1\" ref=\"A1\""), "\(sheet)")
        #expect(!sheet.contains("slicer"))
        let relationships = try text(entries, "xl/worksheets/_rels/sheet1.xml.rels")
        #expect(relationships.contains("https://example.com"))
        #expect(!relationships.contains("pivotTable") && !relationships.contains("slicer"))
        #expect(entries["xl/slicers/slicer1.xml"] == nil)

        let report = workbook.unsupportedFeatures
        #expect(report.preserved.contains(.hyperlinks))
        #expect(report.lost.contains(.slicers))
        #expect(report.lost.contains(.pivotTables))
    }

    @Test("A part typed by a specific .xml default is kept, with an override of its own")
    func specificXMLDefaultTypesAPart() throws {
        let app = Part(
            "docProps/app.xml",
            "<?xml version=\"1.0\"?><Properties xmlns=\"http://schemas.openxmlformats.org/officeDocument/2006/extended-properties\"/>"
        )
        let extended = "application/vnd.openxmlformats-officedocument.extended-properties+xml"
        var data = try package(
            sheets: [""], extraParts: [app],
            rootRelationships: "<Relationship Id=\"rId9\" "
                + "Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties\" "
                + "Target=\"docProps/app.xml\"/>"
        )
        // As one generator writes it: the `.xml` default names a real type.
        var entries = try ZipArchive.entries(in: data)
        let types = String(decoding: try #require(entries["[Content_Types].xml"]), as: UTF8.self)
            .replacingOccurrences(of: "Extension=\"xml\" ContentType=\"application/xml\"",
                                  with: "Extension=\"xml\" ContentType=\"\(extended)\"")
        entries["[Content_Types].xml"] = Data(types.utf8)
        data = try ZipArchive.archive(entries: entries.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })

        let (workbook, written) = try roundTrip(data)
        #expect(written["docProps/app.xml"] != nil)
        #expect(try text(written, "[Content_Types].xml").contains(
            "<Override PartName=\"/docProps/app.xml\" ContentType=\"\(extended)\"/>"
        ))
        #expect(!workbook.unsupportedFeatures.lost.contains(.documentProperties))
    }

    // MARK: - Reporting

    @Test("The report names what is kept and what is not, and nothing else")
    func reportContents() throws {
        let table = Part(
            "xl/tables/table1.xml",
            "<?xml version=\"1.0\"?><table xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"/>",
            contentType: "application/vnd.openxmlformats-officedocument.spreadsheetml.table+xml"
        )
        // A pivot cache is always dropped: what binds it to the workbook lives
        // in the part we regenerate.
        let pivot = Part(
            "xl/pivotCache/pivotCacheDefinition1.xml",
            "<?xml version=\"1.0\"?><pivotCacheDefinition xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"/>",
            contentType: "application/vnd.openxmlformats-officedocument.spreadsheetml.pivotCacheDefinition+xml"
        )
        let data = try package(
            sheets: ["<sheetProtection sheet=\"1\"/>"],
            extraParts: [table, pivot],
            sheetRelationships: [
                0: "<Relationship Id=\"rId1\" "
                    + "Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/table\" "
                    + "Target=\"../tables/table1.xml\"/>",
            ]
        )
        let workbook = try XLSXReader.workbook(from: data)
        let report = workbook.unsupportedFeatures

        #expect(report.preserved == [.sheetProtection, .tables])
        #expect(report.lost == [.pivotTables])
        #expect(!report.isEmpty)

        // The notice is translated, so this asks after its shape rather than its
        // English: every feature named, in whichever half it belongs to.
        let message = report.noticeMessage
        let halves = message.components(separatedBy: "\n\n")
        // The two halves say different things, and the wording has to make the
        // difference plain rather than listing everything together.
        #expect(halves.count == 2)
        #expect(halves.first?.contains(UnsupportedFeature.sheetProtection.label) == true)
        #expect(halves.first?.contains(UnsupportedFeature.tables.label) == true)
        #expect(halves.last?.contains(UnsupportedFeature.pivotTables.label) == true)
        #expect(halves.first?.contains(UnsupportedFeature.pivotTables.label) == false)
    }

    @Test("A workbook with nothing unusual raises no notice")
    func plainWorkbookReportsNothing() throws {
        let workbook = try XLSXReader.workbook(from: try package(sheets: [""]))
        #expect(workbook.unsupportedFeatures.isEmpty)
        #expect(workbook.unsupportedFeatures.noticeMessage.isEmpty)

        // Nor does one we wrote ourselves, read back.
        let ours = try XLSXReader.workbook(from: try XLSXWriter.data(from: Workbook()))
        #expect(ours.unsupportedFeatures.isEmpty)
    }

    @Test("A feature lost on one sheet is not reported as safe because another kept it")
    func lostBeatsPreserved() {
        var report = UnsupportedFeatureReport()
        report.record(.hyperlinks, isPreserved: true)
        report.record(.hyperlinks, isPreserved: false)
        #expect(report.lost == [.hyperlinks])
        #expect(report.preserved.isEmpty)

        // And the order of the sightings makes no difference.
        var reversed = UnsupportedFeatureReport()
        reversed.record(.hyperlinks, isPreserved: false)
        reversed.record(.hyperlinks, isPreserved: true)
        #expect(reversed.lost == [.hyperlinks])
        #expect(reversed.preserved.isEmpty)
    }

    // MARK: - Serialization

    @Test("Serializing an element round-trips its attributes, text and prefixes")
    func serializationRoundTrip() throws {
        let source = """
        <?xml version="1.0"?>
        <root xmlns="http://main" xmlns:r="http://rel">\
        <hyperlinks><hyperlink ref="A1" r:id="rId1" display="a &amp; b &lt; c"/>\
        <hyperlink ref="A2"><note xml:space="preserve">  kept  </note></hyperlink></hyperlinks></root>
        """
        let root = try XMLLite.parse(Data(source.utf8))
        let links = try #require(root.firstChild(named: "hyperlinks"))
        let fragment = try #require(XMLLite.serialize(links))

        // The fragment stands alone: nothing it uses is left to be inherited.
        let reparsed = try XMLLite.parse(Data(fragment.utf8))
        #expect(reparsed.name == "hyperlinks")
        let rebuilt = reparsed.children(named: "hyperlink")
        #expect(rebuilt.count == 2)
        #expect(rebuilt[0].attribute("id") == "rId1")
        #expect(rebuilt[0].attribute("display") == "a & b < c")
        #expect(rebuilt[0].qualifiedAttributes["r:id"] == "rId1")
        #expect(rebuilt[1].firstChild(named: "note")?.text == "  kept  ")
        #expect(fragment.contains("xmlns:r=\"http://rel\""))
        #expect(fragment.contains("xmlns=\"http://main\""))
    }

    @Test("Mixed content is refused rather than rearranged")
    func mixedContentIsRefused() throws {
        let source = "<?xml version=\"1.0\"?><root>text<child/>more</root>"
        let root = try XMLLite.parse(Data(source.utf8))
        #expect(XMLLite.serialize(root) == nil)
    }
}
