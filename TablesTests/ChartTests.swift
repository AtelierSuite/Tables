import Foundation
import Testing
@testable import Tables
@testable import TablesEngine
@testable import TablesMacros

/// Charts: reading what Excel writes, writing what Excel reads, and keeping
/// everything else on a drawing — pictures, chart types we do not model —
/// exactly as it was.
@Suite("Charts")
struct ChartTests {

    // MARK: - Fixtures

    private static let drawingType = "application/vnd.openxmlformats-officedocument.drawing+xml"
    private static let chartType = "application/vnd.openxmlformats-officedocument.drawingml.chart+xml"
    private static let relationships = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

    /// A sheet of quarterly figures: a header row, a label column, two series.
    private static let dataSheet = """
    <sheetData>\
    <row r="1"><c r="A1" t="inlineStr"><is><t>Quarter</t></is></c>\
    <c r="B1" t="inlineStr"><is><t>North</t></is></c><c r="C1" t="inlineStr"><is><t>South</t></is></c></row>\
    <row r="2"><c r="A2" t="inlineStr"><is><t>Q1</t></is></c><c r="B2"><v>10</v></c><c r="C2"><v>4</v></c></row>\
    <row r="3"><c r="A3" t="inlineStr"><is><t>Q2</t></is></c><c r="B3"><v>12</v></c><c r="C3"><v>6</v></c></row>\
    <row r="4"><c r="A4" t="inlineStr"><is><t>Q3</t></is></c><c r="B4"><v>15</v></c><c r="C4"><v>9</v></c></row>\
    </sheetData>
    """

    /// The column chart Excel 2016 writes for the sheet above, trimmed of
    /// nothing that matters: theme colours with modifiers, `txPr` fonts,
    /// caches, axis settings.
    private static let excelColumnChart = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <c:chartSpace xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart" \
    xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
    xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
    <c:date1904 val="0"/><c:roundedCorners val="0"/>\
    <c:chart><c:title><c:tx><c:rich><a:bodyPr/><a:lstStyle/><a:p><a:pPr>\
    <a:defRPr sz="1600" b="1"><a:solidFill><a:schemeClr val="tx1"><a:lumMod val="65000"/>\
    <a:lumOff val="35000"/></a:schemeClr></a:solidFill></a:defRPr></a:pPr>\
    <a:r><a:rPr lang="en-US"/><a:t>Sales by Region</a:t></a:r></a:p></c:rich></c:tx>\
    <c:overlay val="0"/></c:title><c:autoTitleDeleted val="0"/>\
    <c:plotArea><c:layout/><c:barChart><c:barDir val="col"/><c:grouping val="stacked"/>\
    <c:varyColors val="0"/>\
    <c:ser><c:idx val="0"/><c:order val="0"/><c:tx><c:strRef><c:f>Data!$B$1</c:f><c:strCache>\
    <c:ptCount val="1"/><c:pt idx="0"><c:v>North</c:v></c:pt></c:strCache></c:strRef></c:tx>\
    <c:spPr><a:solidFill><a:schemeClr val="accent1"/></a:solidFill></c:spPr>\
    <c:invertIfNegative val="0"/>\
    <c:cat><c:strRef><c:f>Data!$A$2:$A$4</c:f><c:strCache><c:ptCount val="3"/>\
    <c:pt idx="0"><c:v>Q1</c:v></c:pt><c:pt idx="1"><c:v>Q2</c:v></c:pt><c:pt idx="2"><c:v>Q3</c:v></c:pt>\
    </c:strCache></c:strRef></c:cat>\
    <c:val><c:numRef><c:f>Data!$B$2:$B$4</c:f><c:numCache><c:formatCode>General</c:formatCode>\
    <c:ptCount val="3"/><c:pt idx="0"><c:v>10</c:v></c:pt><c:pt idx="1"><c:v>12</c:v></c:pt>\
    <c:pt idx="2"><c:v>15</c:v></c:pt></c:numCache></c:numRef></c:val></c:ser>\
    <c:ser><c:idx val="1"/><c:order val="1"/><c:tx><c:strRef><c:f>Data!$C$1</c:f></c:strRef></c:tx>\
    <c:spPr><a:solidFill><a:srgbClr val="FF0000"/></a:solidFill></c:spPr>\
    <c:invertIfNegative val="0"/>\
    <c:cat><c:strRef><c:f>Data!$A$2:$A$4</c:f></c:strRef></c:cat>\
    <c:val><c:numRef><c:f>Data!$C$2:$C$4</c:f></c:numRef></c:val></c:ser>\
    <c:dLbls><c:showLegendKey val="0"/><c:showVal val="1"/><c:showCatName val="0"/>\
    <c:showSerName val="0"/><c:showPercent val="0"/><c:showBubbleSize val="0"/></c:dLbls>\
    <c:gapWidth val="219"/><c:overlap val="100"/>\
    <c:axId val="11"/><c:axId val="22"/></c:barChart>\
    <c:catAx><c:axId val="11"/><c:scaling><c:orientation val="minMax"/></c:scaling><c:delete val="0"/>\
    <c:axPos val="b"/><c:numFmt formatCode="General" sourceLinked="1"/><c:majorTickMark val="none"/>\
    <c:minorTickMark val="none"/><c:tickLblPos val="nextTo"/>\
    <c:txPr><a:bodyPr/><a:lstStyle/><a:p><a:pPr><a:defRPr sz="900" i="1"/></a:pPr>\
    <a:endParaRPr lang="en-US"/></a:p></c:txPr>\
    <c:crossAx val="22"/><c:crosses val="autoZero"/><c:auto val="1"/><c:lblAlgn val="ctr"/>\
    <c:lblOffset val="100"/><c:noMultiLvlLbl val="0"/></c:catAx>\
    <c:valAx><c:axId val="22"/><c:scaling><c:orientation val="minMax"/><c:max val="40"/><c:min val="0"/>\
    </c:scaling><c:delete val="0"/><c:axPos val="l"/><c:majorGridlines/>\
    <c:title><c:tx><c:rich><a:bodyPr rot="-5400000"/><a:lstStyle/><a:p><a:r><a:t>Units</a:t></a:r></a:p>\
    </c:rich></c:tx><c:overlay val="0"/></c:title>\
    <c:numFmt formatCode="#,##0" sourceLinked="0"/><c:majorTickMark val="none"/>\
    <c:minorTickMark val="none"/><c:tickLblPos val="nextTo"/><c:crossAx val="11"/>\
    <c:crosses val="autoZero"/><c:crossBetween val="between"/><c:majorUnit val="10"/></c:valAx>\
    </c:plotArea><c:legend><c:legendPos val="t"/><c:overlay val="0"/></c:legend>\
    <c:plotVisOnly val="1"/><c:dispBlanksAs val="gap"/></c:chart>\
    <c:txPr><a:bodyPr/><a:lstStyle/><a:p><a:pPr><a:defRPr sz="1000">\
    <a:latin typeface="Avenir Next"/></a:defRPr></a:pPr><a:endParaRPr lang="en-US"/></a:p></c:txPr>\
    </c:chartSpace>
    """

    /// A chart type outside the model — and so one that must survive untouched.
    private static let unsupportedChart = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <c:chartSpace xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart">\
    <c:chart><c:plotArea><c:bar3DChart><c:barDir val="col"/><c:grouping val="standard"/>\
    <c:axId val="1"/><c:axId val="2"/><c:axId val="3"/></c:bar3DChart></c:plotArea></c:chart>\
    </c:chartSpace>
    """

    private static func anchor(id: Int, relationship: String, from: (Int, Int), to: (Int, Int)) -> String {
        """
        <xdr:twoCellAnchor editAs="oneCell"><xdr:from><xdr:col>\(from.0)</xdr:col><xdr:colOff>12700</xdr:colOff>\
        <xdr:row>\(from.1)</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:from><xdr:to><xdr:col>\(to.0)</xdr:col>\
        <xdr:colOff>0</xdr:colOff><xdr:row>\(to.1)</xdr:row><xdr:rowOff>25400</xdr:rowOff></xdr:to>\
        <xdr:graphicFrame macro=""><xdr:nvGraphicFramePr><xdr:cNvPr id="\(id)" name="Chart \(id)"/>\
        <xdr:cNvGraphicFramePr/></xdr:nvGraphicFramePr><xdr:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/>\
        </xdr:xfrm><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/chart">\
        <c:chart xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart" r:id="\(relationship)"/>\
        </a:graphicData></a:graphic></xdr:graphicFrame><xdr:clientData/></xdr:twoCellAnchor>
        """
    }

    private static let pictureAnchor = """
    <xdr:oneCellAnchor><xdr:from><xdr:col>8</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>1</xdr:row>\
    <xdr:rowOff>0</xdr:rowOff></xdr:from><xdr:ext cx="952500" cy="952500"/><xdr:pic><xdr:nvPicPr>\
    <xdr:cNvPr id="7" name="Picture 7"/><xdr:cNvPicPr/></xdr:nvPicPr><xdr:blipFill>\
    <a:blip r:embed="rIdImage"/><a:stretch><a:fillRect/></a:stretch></xdr:blipFill><xdr:spPr>\
    <a:prstGeom prst="rect"><a:avLst/></a:prstGeom></xdr:spPr></xdr:pic><xdr:clientData/></xdr:oneCellAnchor>
    """

    /// One worksheet called "Data" carrying `anchors` on its drawing, and
    /// whatever chart parts and media they name.
    private func package(
        anchors: String, drawingRelationships: String, extraParts: [(String, String, String?)],
        extraSheets: [(name: String, path: String, xml: String, type: String, rels: String?)] = [],
        drawingDeclarations: String = ""
    ) throws -> Data {
        var contentTypes = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Default Extension="png" ContentType="image/png"/>\
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
        <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>\
        <Override PartName="/xl/drawings/drawing1.xml" ContentType="\(Self.drawingType)"/>
        """
        for part in extraParts {
            if let type = part.2 { contentTypes += "<Override PartName=\"/\(part.0)\" ContentType=\"\(type)\"/>" }
        }
        for sheet in extraSheets {
            contentTypes += "<Override PartName=\"/\(sheet.path)\" ContentType=\"\(sheet.type)\"/>"
        }
        contentTypes += "</Types>"

        var sheets = "<sheet name=\"Data\" sheetId=\"1\" r:id=\"rId1\"/>"
        var workbookRels = "<Relationship Id=\"rId1\" Type=\"\(Self.relationships)/worksheet\" Target=\"worksheets/sheet1.xml\"/>"
        for (offset, sheet) in extraSheets.enumerated() {
            let id = "rId\(offset + 10)"
            sheets += "<sheet name=\"\(sheet.name)\" sheetId=\"\(offset + 2)\" r:id=\"\(id)\"/>"
            let kind = sheet.path.contains("chartsheets") ? "chartsheet" : "worksheet"
            workbookRels += "<Relationship Id=\"\(id)\" Type=\"\(Self.relationships)/\(kind)\" "
                + "Target=\"\(sheet.path.dropFirst(3))\"/>"
        }

        var entries: [(path: String, data: Data)] = [
            ("[Content_Types].xml", Data(contentTypes.utf8)),
            ("_rels/.rels", Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="\(Self.relationships)/officeDocument" Target="xl/workbook.xml"/>\
            </Relationships>
            """.utf8)),
            ("xl/workbook.xml", Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
            xmlns:r="\(Self.relationships)"><sheets>\(sheets)</sheets></workbook>
            """.utf8)),
            ("xl/_rels/workbook.xml.rels", Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            \(workbookRels)</Relationships>
            """.utf8)),
            ("xl/worksheets/sheet1.xml", Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
            xmlns:r="\(Self.relationships)">\(Self.dataSheet)<drawing r:id="rId1"/></worksheet>
            """.utf8)),
            ("xl/worksheets/_rels/sheet1.xml.rels", Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="\(Self.relationships)/drawing" Target="../drawings/drawing1.xml"/>\
            </Relationships>
            """.utf8)),
            ("xl/drawings/drawing1.xml", Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <xdr:wsDr xmlns:xdr="http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing" \
            xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
            xmlns:r="\(Self.relationships)"\(drawingDeclarations)>\(anchors)</xdr:wsDr>
            """.utf8)),
            ("xl/drawings/_rels/drawing1.xml.rels", Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            \(drawingRelationships)</Relationships>
            """.utf8)),
        ]
        for part in extraParts { entries.append((part.0, Data(part.1.utf8))) }
        for sheet in extraSheets {
            entries.append((sheet.path, Data(sheet.xml.utf8)))
            if let rels = sheet.rels {
                entries.append((XLSXReader.PackagePreservation.relationshipsPath(for: sheet.path), Data(rels.utf8)))
            }
        }
        return try ZipArchive.archive(entries: entries)
    }

    private func chartRelationship(_ id: String, _ target: String) -> String {
        "<Relationship Id=\"\(id)\" Type=\"\(Self.relationships)/chart\" Target=\"\(target)\"/>"
    }

    private func roundTrip(_ workbook: Workbook) throws -> (workbook: Workbook, entries: [String: Data]) {
        let data = try XLSXWriter.data(from: workbook)
        return (try XLSXReader.workbook(from: data), try ZipArchive.entries(in: data))
    }

    private func text(_ entries: [String: Data], _ path: String) throws -> String {
        String(decoding: try #require(entries[path], "\(path) is missing"), as: UTF8.self)
    }

    /// The structural rules a package must keep for Excel to open it without
    /// offering a repair: every part typed, every internal relationship
    /// landing on a part, and every relationship id a part names declared in
    /// its own `_rels`.
    private func expectConsistentPackage(_ entries: [String: Data]) throws {
        typealias Plan = XLSXReader.PackagePreservation
        let types = Plan.contentTypes(entries["[Content_Types].xml"])
        for path in entries.keys where !Plan.isRelationshipsPart(path) && path != "[Content_Types].xml" {
            let typed = types.overrides["/" + path] != nil
                || types.defaults[(path as NSString).pathExtension.lowercased()] != nil
            #expect(typed, "\(path) has no content type")
        }
        for (path, payload) in entries where Plan.isRelationshipsPart(path) {
            // `xl/drawings/_rels/drawing1.xml.rels` belongs to `xl/drawings/drawing1.xml`.
            let source = path.replacingOccurrences(of: "_rels/", with: "").replacingOccurrences(of: ".rels", with: "")
            let directory = Plan.directory(of: source)
            var ids: Set<String> = []
            for relationship in Plan.relationships(in: payload) {
                if let id = relationship.id { #expect(ids.insert(id).inserted, "\(path) repeats \(id)") }
                guard let target = Plan.packagePath(of: relationship, relativeTo: directory) else { continue }
                #expect(entries[target] != nil, "\(path) points at missing \(target)")
            }
            // Every r:id the source part uses must be one of these.
            if let source = entries[source] {
                let xml = String(decoding: source, as: UTF8.self)
                for match in xml.matches(of: #/r:(?:id|embed)="([^"]+)"/#) {
                    #expect(ids.contains(String(match.1)), "\(source) names undeclared \(match.1)")
                }
            }
        }
    }

    // MARK: - Reading Excel's charts

    @Test("An Excel column chart reads with its data, fonts, colours and axes")
    func readsExcelChart() throws {
        let data = try package(
            anchors: Self.anchor(id: 2, relationship: "rIdChart", from: (4, 1), to: (10, 15)),
            drawingRelationships: chartRelationship("rIdChart", "../charts/chart1.xml"),
            extraParts: [("xl/charts/chart1.xml", Self.excelColumnChart, Self.chartType)]
        )
        let workbook = try XLSXReader.workbook(from: data)
        let sheet = workbook.sheets[0]
        let chart = try #require(sheet.charts.first)

        #expect(sheet.preservedDrawingAnchors.isEmpty)
        #expect(workbook.unsupportedFeatures.isEmpty)
        #expect(chart.name == "Chart 2")
        #expect(chart.kind == .column)
        #expect(chart.grouping == .stacked)
        #expect(chart.title?.text == "Sales by Region")
        #expect(chart.title?.textStyle.fontSize == 16)
        #expect(chart.title?.textStyle.isBold == true)
        // tx1 at 65% luminance plus 35%: Office's "Black, Text 1, Lighter 35%".
        #expect(chart.title?.textStyle.colorHex == "FF595959")
        #expect(chart.textStyle.fontSize == 10)
        #expect(chart.textStyle.fontName == "Avenir Next")
        #expect(chart.legend == .top)
        #expect(chart.dataLabels.showsValue)
        #expect(chart.gapWidth == 219)

        #expect(chart.series.count == 2)
        #expect(chart.series[0].colorHex == "FF4472C4")
        #expect(chart.series[1].colorHex == "FFFF0000")
        let values = try #require(CellRange(a1Range: "B2:B4"))
        #expect(chart.series[0].values.reference == ChartReference(sheetID: sheet.id, range: values))

        #expect(chart.categoryAxis.textStyle.isItalic == true)
        #expect(chart.valueAxis.maximum == 40)
        #expect(chart.valueAxis.minimum == 0)
        #expect(chart.valueAxis.majorUnit == 10)
        #expect(chart.valueAxis.numberFormat == "#,##0")
        #expect(chart.valueAxis.showsMajorGridlines)
        #expect(!chart.categoryAxis.showsMajorGridlines)
        #expect(chart.valueAxis.title?.text == "Units")

        #expect(chart.placement.from == ChartAnchor(row: 1, column: 4, rowOffset: 0, columnOffset: 1))
        #expect(chart.placement.to == ChartAnchor(row: 15, column: 10, rowOffset: 2, columnOffset: 0))

        let resolved = chart.resolved(in: workbook)
        #expect(resolved.categories == ["Q1", "Q2", "Q3"])
        #expect(resolved.series.map(\.name) == ["North", "South"])
        #expect(resolved.series[1].values == [4, 6, 9])
    }

    @Test("A chart we cannot model, and a picture, are kept byte for byte beside one we can")
    func keepsWhatItCannotModel() throws {
        let anchors = Self.anchor(id: 2, relationship: "rIdChart", from: (4, 1), to: (10, 15))
            + Self.anchor(id: 3, relationship: "rId3D", from: (4, 16), to: (10, 30))
            + Self.pictureAnchor
        let relationships = chartRelationship("rIdChart", "../charts/chart1.xml")
            + chartRelationship("rId3D", "../charts/chart2.xml")
            + "<Relationship Id=\"rIdImage\" Type=\"\(Self.relationships)/image\" Target=\"../media/image1.png\"/>"
        let data = try package(
            anchors: anchors, drawingRelationships: relationships,
            extraParts: [
                ("xl/charts/chart1.xml", Self.excelColumnChart, Self.chartType),
                ("xl/charts/chart2.xml", Self.unsupportedChart, Self.chartType),
                ("xl/media/image1.png", "PNGDATA", nil),
            ]
        )
        let workbook = try XLSXReader.workbook(from: data)
        #expect(workbook.sheets[0].charts.count == 1)
        #expect(workbook.sheets[0].preservedDrawingAnchors.count == 2)
        // The picture knows its image, so it can be drawn rather than stood in for.
        #expect(workbook.sheets[0].preservedDrawingAnchors.compactMap(\.picture).map(\.target) == ["xl/media/image1.png"])
        #expect(workbook.sheets[0].preservedDrawingAnchors.first { $0.isChart }?.picture == nil)
        #expect(workbook.unsupportedFeatures.preserved.contains(.chartsAndImages))
        #expect(workbook.unsupportedFeatures.lost.isEmpty)

        let written = try ZipArchive.entries(in: XLSXWriter.data(from: workbook))
        try expectConsistentPackage(written)
        // The unmodelled chart stays exactly where it was, under its own name.
        #expect(try text(written, "xl/charts/chart2.xml") == Self.unsupportedChart)
        #expect(written["xl/media/image1.png"] == Data("PNGDATA".utf8))
        let drawing = try text(written, "xl/drawings/drawing1.xml")
        #expect(drawing.contains("r:embed=\"rIdImage\""))
        #expect(drawing.contains("r:id=\"rId3D\""))
        // The modelled chart was rewritten into a part that does not collide.
        let rels = try text(written, "xl/drawings/_rels/drawing1.xml.rels")
        #expect(rels.contains("Target=\"../charts/chart1.xml\""))
        #expect(rels.contains("Target=\"../charts/chart2.xml\""))

        // And it all reads back the same way.
        let reread = try XLSXReader.workbook(from: XLSXWriter.data(from: workbook))
        #expect(reread.sheets[0].charts.count == 1)
        #expect(reread.sheets[0].preservedDrawingAnchors.count == 2)
    }

    @Test("A chart reaching a part we cannot keep is preserved only with it, or reported lost")
    func anchorLosingItsPartIsReported() throws {
        // The picture names media the package never declares a type for.
        let data = try package(
            anchors: Self.pictureAnchor,
            drawingRelationships: "<Relationship Id=\"rIdImage\" Type=\"\(Self.relationships)/image\" "
                + "Target=\"../media/image1.bin\"/>",
            extraParts: [("xl/media/image1.bin", "BINARY", nil)]
        )
        let workbook = try XLSXReader.workbook(from: data)
        #expect(workbook.sheets[0].preservedDrawingAnchors.isEmpty)
        #expect(workbook.unsupportedFeatures.lost.contains(.chartsAndImages))

        let written = try ZipArchive.entries(in: XLSXWriter.data(from: workbook))
        try expectConsistentPackage(written)
        #expect(written["xl/drawings/drawing1.xml"] == nil)
        #expect(!(try text(written, "xl/worksheets/sheet1.xml").contains("<drawing")))
    }

    // MARK: - Writing

    /// A workbook with the quarterly data and a chart built from it.
    private func workbookWithChart(_ kind: ChartKind = .column) throws -> Workbook {
        let data = try package(anchors: "", drawingRelationships: "", extraParts: [])
        var workbook = try XLSXReader.workbook(from: data)
        let sheet = workbook.sheets[0]
        let range = try #require(CellRange(a1Range: "A1:C4"))
        var chart = try #require(ChartBuilder.chart(kind, from: range, in: sheet, named: "Chart 1"))
        chart.placement = ChartPlacement(
            from: ChartAnchor(row: 5, column: 1, rowOffset: 3, columnOffset: 4),
            to: ChartAnchor(row: 18, column: 6)
        )
        workbook.sheets[0].charts = [chart]
        return workbook
    }

    @Test("A chart made here survives a save and a reopen intact", arguments: ChartKind.allCases)
    func roundTripsEveryKind(_ kind: ChartKind) throws {
        var workbook = try workbookWithChart(kind)
        workbook.sheets[0].charts[0].title = ChartTitle(
            text: "Two\nLines", textStyle: ChartTextStyle(fontSize: 18, isBold: true, colorHex: "FF007AFF")
        )
        workbook.sheets[0].charts[0].series[0].colorHex = "FF34C759"
        workbook.sheets[0].charts[0].legend = .left
        workbook.sheets[0].charts[0].dataLabels.showsValue = true
        workbook.sheets[0].charts[0].textStyle = ChartTextStyle(fontSize: 11, fontName: "Helvetica Neue")
        if !kind.isRadial {
            workbook.sheets[0].charts[0].valueAxis.maximum = 50
            workbook.sheets[0].charts[0].valueAxis.title = ChartTitle(text: "Units")
            workbook.sheets[0].charts[0].categoryAxis.isVisible = false
        }
        if kind.supportsGrouping { workbook.sheets[0].charts[0].grouping = .percentStacked }

        let (reread, entries) = try roundTrip(workbook)
        try expectConsistentPackage(entries)
        let original = workbook.sheets[0].charts[0]
        let chart = try #require(reread.sheets[0].charts.first)

        #expect(chart.kind == kind)
        #expect(chart.name == original.name)
        #expect(chart.grouping == original.grouping)
        #expect(chart.title == original.title)
        #expect(chart.legend == .left)
        #expect(chart.dataLabels.showsValue)
        #expect(chart.textStyle == original.textStyle)
        #expect(chart.series.count == original.series.count)
        #expect(chart.series[0].colorHex == "FF34C759")
        // Sheet identities are minted afresh on every read, so compare where
        // the references point rather than the identities themselves.
        #expect(chart.series.map(\.values.reference?.range) == original.series.map(\.values.reference?.range))
        #expect(chart.series.map(\.categories.reference?.range) == original.series.map(\.categories.reference?.range))
        #expect(chart.series.map(\.name.reference?.range) == original.series.map(\.name.reference?.range))
        #expect(chart.series.allSatisfy { $0.values.reference?.sheetID == reread.sheets[0].id })
        #expect(chart.placement == original.placement)
        if !kind.isRadial {
            #expect(chart.valueAxis.maximum == 50)
            #expect(chart.valueAxis.title?.text == "Units")
            #expect(!chart.categoryAxis.isVisible)
        }
        #expect(chart.resolved(in: reread) == original.resolved(in: workbook))
    }

    @Test("Written series carry fresh caches, so other apps show current values")
    func cachesAreCurrent() throws {
        var workbook = try workbookWithChart()
        workbook.sheets[0][CellAddress(row: 1, column: 1)] = Cell(value: .number(99))
        let entries = try ZipArchive.entries(in: XLSXWriter.data(from: workbook))
        let chart = try text(entries, "xl/charts/chart1.xml")
        #expect(chart.contains("<c:f>Data!$B$2:$B$4</c:f>"))
        #expect(chart.contains("<c:pt idx=\"0\"><c:v>99</c:v></c:pt>"))
        #expect(chart.contains("<c:f>Data!$A$2:$A$4</c:f>"))
        #expect(chart.contains("<c:v>Q1</c:v>"))
    }

    @Test("Sheet names that need quoting are quoted in series formulas")
    func quotedSheetNames() throws {
        var workbook = try workbookWithChart()
        workbook.renameSheet(workbook.sheets[0].id, to: "Q1 Sales")
        let entries = try ZipArchive.entries(in: XLSXWriter.data(from: workbook))
        #expect(try text(entries, "xl/charts/chart1.xml").contains("<c:f>&apos;Q1 Sales&apos;!$B$2:$B$4</c:f>"))
        #expect(ChartReference.quotedSheetName("Data") == "Data")
        #expect(ChartReference.quotedSheetName("Bob's") == "'Bob''s'")
        #expect(ChartReference.quotedSheetName("A1") == "'A1'")
        #expect(ChartReference.quotedSheetName("2024") == "'2024'")

        let reread = try XLSXReader.workbook(from: XLSXWriter.data(from: workbook))
        #expect(reread.sheets[0].charts[0].series[0].values.reference?.sheetID == reread.sheets[0].id)
        let quoted = try #require(ChartReference(formula: "'Bob''s'!$A$1:$A$3", in: Workbook(sheets: [Worksheet(name: "Bob's")])))
        #expect(quoted.range == CellRange(a1Range: "A1:A3"))
    }

    // MARK: - Chart sheets

    @Test("A chart sheet reads as a chart sheet and writes back as one")
    func chartSheets() throws {
        let chartSheet = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <chartsheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
        xmlns:r="\(Self.relationships)"><sheetPr/><sheetViews><sheetView zoomScale="115" workbookViewId="0" \
        zoomToFit="1"/></sheetViews><drawing r:id="rId1"/></chartsheet>
        """
        let chartSheetDrawing = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <xdr:wsDr xmlns:xdr="http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing" \
        xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><xdr:absoluteAnchor>\
        <xdr:pos x="0" y="0"/><xdr:ext cx="8670727" cy="6297083"/><xdr:graphicFrame macro="">\
        <xdr:nvGraphicFramePr><xdr:cNvPr id="2" name="Chart 1"/><xdr:cNvGraphicFramePr/></xdr:nvGraphicFramePr>\
        <xdr:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/></xdr:xfrm><a:graphic>\
        <a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/chart">\
        <c:chart xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart" \
        xmlns:r="\(Self.relationships)" r:id="rId1"/></a:graphicData></a:graphic></xdr:graphicFrame>\
        <xdr:clientData/></xdr:absoluteAnchor></xdr:wsDr>
        """
        let data = try package(
            anchors: "", drawingRelationships: "",
            extraParts: [
                ("xl/drawings/drawing2.xml", chartSheetDrawing, Self.drawingType),
                ("xl/drawings/_rels/drawing2.xml.rels", "<?xml version=\"1.0\"?><Relationships "
                    + "xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
                    + chartRelationship("rId1", "../charts/chart1.xml") + "</Relationships>", nil),
                ("xl/charts/chart1.xml", Self.excelColumnChart, Self.chartType),
            ],
            extraSheets: [(
                name: "Sales Chart", path: "xl/chartsheets/sheet1.xml", xml: chartSheet,
                type: ChartWriter.chartSheetContentType,
                rels: "<?xml version=\"1.0\"?><Relationships "
                    + "xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
                    + "<Relationship Id=\"rId1\" Type=\"\(Self.relationships)/drawing\" "
                    + "Target=\"../drawings/drawing2.xml\"/></Relationships>"
            )]
        )
        let workbook = try XLSXReader.workbook(from: data)
        let sheet = try #require(workbook.sheet(named: "Sales Chart"))
        #expect(sheet.isChartSheet)
        #expect(sheet.charts.first?.title?.text == "Sales by Region")
        #expect(workbook.unsupportedFeatures.isEmpty)

        let (reread, entries) = try roundTrip(workbook)
        try expectConsistentPackage(entries)
        #expect(try text(entries, "xl/workbook.xml").contains("name=\"Sales Chart\""))
        let workbookRels = try text(entries, "xl/_rels/workbook.xml.rels")
        #expect(workbookRels.contains("relationships/chartsheet\" Target=\"chartsheets/sheet2.xml\""))
        let written = try text(entries, "xl/chartsheets/sheet2.xml")
        #expect(written.contains("zoomScale=\"115\""))
        #expect(written.contains("<drawing r:id="))
        #expect(entries["xl/worksheets/sheet2.xml"] == nil)
        #expect(reread.sheets[1].isChartSheet)
        #expect(reread.sheets[1].charts.first?.series.count == 2)
    }

    @Test("Moving a chart to its own sheet and back keeps it whole")
    @MainActor
    func moveChartBetweenSheets() throws {
        var workbook = try workbookWithChart()
        let state = EditorState()
        state.selectSheet(workbook.sheets[0].id, in: workbook)
        state.selectChart(workbook.sheets[0].charts[0].id)

        state.moveSelectedChartToNewSheet(in: &workbook)
        #expect(workbook.sheets.count == 2)
        #expect(workbook.sheets[0].charts.isEmpty)
        #expect(workbook.sheets[1].isChartSheet)
        #expect(state.activeSheetID == workbook.sheets[1].id)
        #expect(state.selectedChartID == workbook.sheets[1].charts.first?.id)

        let (reread, entries) = try roundTrip(workbook)
        try expectConsistentPackage(entries)
        #expect(reread.sheets[1].isChartSheet)

        state.moveChartSheetIntoWorksheet(workbook.sheets[0].id, in: &workbook)
        #expect(workbook.sheets.count == 1)
        #expect(workbook.sheets[0].charts.count == 1)
    }

    // MARK: - Building from a selection

    @Test("A selection with headings both ways makes one series per column")
    func builderReadsHeadings() throws {
        let workbook = try workbookWithChart()
        let sheet = workbook.sheets[0]
        let range = try #require(CellRange(a1Range: "A1:C4"))
        let layout = try #require(ChartBuilder.layout(of: range, in: sheet, for: .column))
        #expect(layout.hasHeaderRow)
        #expect(layout.hasLabelColumn)
        #expect(layout.seriesInColumns)

        let chart = try #require(ChartBuilder.chart(.column, from: layout.range, in: sheet, named: "C"))
        let resolved = chart.resolved(in: workbook)
        #expect(resolved.series.map(\.name) == ["North", "South"])
        #expect(resolved.categories == ["Q1", "Q2", "Q3"])
        #expect(chart.legend != nil)
    }

    @Test("A single cell grows to the block of data around it")
    func builderGrowsSingleCell() throws {
        let workbook = try workbookWithChart()
        let region = ChartBuilder.currentRegion(around: CellAddress(row: 2, column: 1), in: workbook.sheets[0])
        #expect(region == CellRange(a1Range: "A1:C4"))
    }

    @Test("A block wider than it is tall runs its series along the rows")
    func builderOrientation() throws {
        var sheet = Worksheet(name: "S")
        for column in 0..<6 {
            sheet[CellAddress(row: 0, column: column)] = Cell(value: .number(Double(column)))
            sheet[CellAddress(row: 1, column: column)] = Cell(value: .number(Double(column * 2)))
        }
        let range = try #require(CellRange(a1Range: "A1:F2"))
        let layout = try #require(ChartBuilder.layout(of: range, in: sheet, for: .line))
        #expect(!layout.hasHeaderRow)
        #expect(!layout.hasLabelColumn)
        #expect(!layout.seriesInColumns)
        #expect(ChartBuilder.series(for: layout, in: sheet).count == 2)
        // A single-series chart is titled by its series, as Excel's is.
        let single = try #require(ChartBuilder.chart(.column, from: CellRange(a1Range: "A1:F1")!, in: sheet, named: "C"))
        #expect(single.showsAutomaticTitle)
        #expect(single.legend == nil)
    }

    @Test("Text with no numbers anywhere makes no chart")
    func builderRefusesText() {
        var sheet = Worksheet(name: "S")
        sheet[CellAddress(row: 0, column: 0)] = Cell(value: .text("a"))
        #expect(ChartBuilder.chart(.column, from: CellRange(CellAddress(row: 0, column: 0)), in: sheet, named: "C") == nil)
    }

    // MARK: - Structural edits

    @Test("Inserting rows moves the chart and stretches its ranges")
    @MainActor
    func insertingRowsFollows() throws {
        var workbook = try workbookWithChart()
        let state = EditorState()
        state.selectSheet(workbook.sheets[0].id, in: workbook)
        state.select(CellAddress(row: 2, column: 0))
        state.insertRows(above: true, in: &workbook)

        let chart = workbook.sheets[0].charts[0]
        #expect(chart.series[0].values.reference?.range == CellRange(a1Range: "B2:B5"))
        #expect(chart.series[0].name.reference?.range == CellRange(a1Range: "B1"))
        #expect(chart.placement.from.row == 6)
        #expect(chart.placement.to.row == 19)
        #expect(chart.resolved(in: workbook).series[0].values == [10, nil, 12, 15])
    }

    @Test("Deleting every row a series reads keeps the values it showed")
    @MainActor
    func deletingRowsDetaches() throws {
        var workbook = try workbookWithChart()
        let state = EditorState()
        state.selectSheet(workbook.sheets[0].id, in: workbook)
        state.selection = CellRange(a1Range: "A2:A4")!
        state.deleteSelectedRows(in: &workbook)

        let series = workbook.sheets[0].charts[0].series[0]
        #expect(series.values.reference == nil)
        #expect(series.values.cache == [.number(10), .number(12), .number(15)])
        // The name, in row 1, was untouched.
        #expect(series.name.reference?.range == CellRange(a1Range: "B1"))
        let entries = try ZipArchive.entries(in: XLSXWriter.data(from: workbook))
        #expect(try text(entries, "xl/charts/chart1.xml").contains("<c:numLit>"))
    }

    @Test("A copied sheet's chart reads the copy, and a deleted source leaves values behind")
    func copyingAndDeletingSheets() throws {
        var workbook = try workbookWithChart()
        let original = workbook.sheets[0].id
        let duplicated = workbook.duplicateSheet(original)
        let copy = try #require(duplicated)
        let copied = try #require(workbook[copy]?.charts.first)
        #expect(copied.series[0].values.reference?.sheetID == copy)
        #expect(copied.id != workbook.sheets[0].charts[0].id)

        // A chart on a third sheet reading the original keeps its numbers once
        // the original is gone.
        let third = workbook.addSheet()
        let charts = workbook.sheets[0].charts
        workbook[third]?.charts = charts
        let removed = workbook.removeSheet(original)
        #expect(removed)
        let orphan = try #require(workbook[third]?.charts.first)
        #expect(orphan.series[0].values.reference == nil)
        #expect(orphan.resolved(in: workbook).series[0].values == [10, 12, 15])
    }

    @Test("Hidden rows drop out of the plot unless the chart asks for them")
    func hiddenRows() throws {
        var workbook = try workbookWithChart()
        workbook.sheets[0].hiddenRows = [2]
        #expect(workbook.sheets[0].charts[0].resolved(in: workbook).series[0].values == [10, 15])
        workbook.sheets[0].charts[0].plotsVisibleCellsOnly = false
        #expect(workbook.sheets[0].charts[0].resolved(in: workbook).series[0].values == [10, 12, 15])
    }

    @Test("Typing a data range rebuilds the series and keeps their colours")
    @MainActor
    func editingTheDataRange() throws {
        var workbook = try workbookWithChart()
        workbook.sheets[0].charts[0].series[0].colorHex = "FFFF9500"
        let state = EditorState()
        state.selectSheet(workbook.sheets[0].id, in: workbook)
        state.selectChart(workbook.sheets[0].charts[0].id)

        #expect(EditorState.dataRange(of: workbook.sheets[0].charts[0])?.displayText(in: workbook) == "Data!A1:C4")
        let narrowed = state.setSelectedChartData("A1:B4", seriesInColumns: nil, in: &workbook)
        #expect(narrowed)
        #expect(workbook.sheets[0].charts[0].series.count == 1)
        #expect(workbook.sheets[0].charts[0].series[0].colorHex == "FFFF9500")

        let byRows = state.setSelectedChartData("Data!A1:C4", seriesInColumns: false, in: &workbook)
        #expect(byRows)
        #expect(workbook.sheets[0].charts[0].series.count == 3)
        let nowhere = state.setSelectedChartData("Nowhere!A1:B2", seriesInColumns: nil, in: &workbook)
        #expect(!nowhere)
    }

    // MARK: - Fidelity

    /// A line chart formatted the way people format them in Excel, with
    /// everything the model does not hold: dashes, marker shapes, gradients,
    /// manual layouts, a deleted legend entry, a log scale, display units,
    /// a custom label on one point, the 2010 style element, print settings.
    private static let formattedLineChart = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <c:chartSpace xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart" \
    xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
    xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
    xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" \
    xmlns:c14="http://schemas.microsoft.com/office/drawing/2007/8/2/chart">\
    <c:date1904 val="0"/><c:lang val="en-US"/><c:roundedCorners val="0"/>\
    <mc:AlternateContent><mc:Choice Requires="c14"><c14:style val="102"/></mc:Choice>\
    <mc:Fallback><c:style val="2"/></mc:Fallback></mc:AlternateContent>\
    <c:chart><c:title><c:tx><c:rich><a:bodyPr/><a:lstStyle/><a:p><a:pPr><a:defRPr sz="1400"/></a:pPr>\
    <a:r><a:rPr lang="en-US" sz="1400" b="1"/><a:t>Trend</a:t></a:r>\
    <a:r><a:rPr lang="en-US" sz="1400" i="1"/><a:t> so far</a:t></a:r></a:p></c:rich></c:tx>\
    <c:layout><c:manualLayout><c:xMode val="edge"/><c:yMode val="edge"/><c:x val="0.3"/><c:y val="0.02"/>\
    </c:manualLayout></c:layout><c:overlay val="0"/></c:title><c:autoTitleDeleted val="0"/>\
    <c:plotArea><c:layout><c:manualLayout><c:layoutTarget val="inner"/><c:xMode val="edge"/><c:yMode val="edge"/>\
    <c:x val="0.1"/><c:y val="0.2"/><c:w val="0.7"/><c:h val="0.6"/></c:manualLayout></c:layout>\
    <c:lineChart><c:grouping val="standard"/><c:varyColors val="0"/>\
    <c:ser><c:idx val="0"/><c:order val="0"/><c:tx><c:strRef><c:f>Data!$B$1</c:f></c:strRef></c:tx>\
    <c:spPr><a:ln w="38100" cap="rnd"><a:solidFill><a:schemeClr val="accent1"/></a:solidFill>\
    <a:prstDash val="dash"/><a:round/></a:ln></c:spPr>\
    <c:marker><c:symbol val="square"/><c:size val="7"/></c:marker>\
    <c:dLbls><c:dLbl><c:idx val="1"/><c:tx><c:rich><a:bodyPr/><a:lstStyle/><a:p><a:r><a:t>Peak</a:t></a:r></a:p>\
    </c:rich></c:tx><c:dLblPos val="t"/><c:showLegendKey val="0"/><c:showVal val="1"/><c:showCatName val="0"/>\
    <c:showSerName val="0"/><c:showPercent val="0"/><c:showBubbleSize val="0"/></c:dLbl>\
    <c:dLblPos val="r"/><c:showLegendKey val="0"/><c:showVal val="0"/><c:showCatName val="0"/>\
    <c:showSerName val="0"/><c:showPercent val="0"/><c:showBubbleSize val="0"/></c:dLbls>\
    <c:cat><c:strRef><c:f>Data!$A$2:$A$4</c:f></c:strRef></c:cat>\
    <c:val><c:numRef><c:f>Data!$B$2:$B$4</c:f></c:numRef></c:val><c:smooth val="0"/></c:ser>\
    <c:ser><c:idx val="1"/><c:order val="1"/><c:tx><c:strRef><c:f>Data!$C$1</c:f></c:strRef></c:tx>\
    <c:spPr><a:ln w="28575"><a:solidFill><a:srgbClr val="00B050"/></a:solidFill></a:ln></c:spPr>\
    <c:marker><c:symbol val="diamond"/><c:size val="9"/></c:marker>\
    <c:cat><c:strRef><c:f>Data!$A$2:$A$4</c:f></c:strRef></c:cat>\
    <c:val><c:numRef><c:f>Data!$C$2:$C$4</c:f></c:numRef></c:val><c:smooth val="0"/></c:ser>\
    <c:marker val="1"/><c:axId val="11"/><c:axId val="22"/></c:lineChart>\
    <c:catAx><c:axId val="11"/><c:scaling><c:orientation val="minMax"/></c:scaling><c:delete val="0"/>\
    <c:axPos val="b"/><c:numFmt formatCode="General" sourceLinked="1"/><c:majorTickMark val="out"/>\
    <c:minorTickMark val="none"/><c:tickLblPos val="low"/><c:crossAx val="22"/><c:crosses val="autoZero"/>\
    <c:auto val="1"/><c:lblAlgn val="ctr"/><c:lblOffset val="100"/><c:noMultiLvlLbl val="0"/></c:catAx>\
    <c:valAx><c:axId val="22"/><c:scaling><c:logBase val="10"/><c:orientation val="minMax"/></c:scaling>\
    <c:delete val="0"/><c:axPos val="l"/><c:majorGridlines><c:spPr><a:ln><a:prstDash val="sysDot"/></a:ln>\
    </c:spPr></c:majorGridlines><c:minorGridlines/><c:numFmt formatCode="General" sourceLinked="1"/>\
    <c:majorTickMark val="cross"/><c:minorTickMark val="none"/><c:tickLblPos val="nextTo"/><c:crossAx val="11"/>\
    <c:crossesAt val="1"/><c:crossBetween val="between"/><c:dispUnits><c:builtInUnit val="hundreds"/>\
    </c:dispUnits></c:valAx>\
    <c:spPr><a:gradFill><a:gsLst><a:gs pos="0"><a:srgbClr val="FFFFFF"/></a:gs><a:gs pos="100000">\
    <a:srgbClr val="DDEEFF"/></a:gs></a:gsLst><a:lin ang="5400000" scaled="0"/></a:gradFill></c:spPr>\
    </c:plotArea>\
    <c:legend><c:legendPos val="r"/><c:legendEntry><c:idx val="1"/><c:delete val="1"/></c:legendEntry>\
    <c:layout><c:manualLayout><c:xMode val="edge"/><c:yMode val="edge"/><c:x val="0.8"/><c:y val="0.4"/>\
    </c:manualLayout></c:layout><c:overlay val="1"/></c:legend>\
    <c:plotVisOnly val="1"/><c:dispBlanksAs val="span"/></c:chart>\
    <c:spPr><a:solidFill><a:schemeClr val="bg1"/></a:solidFill><a:ln w="19050"><a:solidFill>\
    <a:schemeClr val="accent2"/></a:solidFill></a:ln><a:effectLst><a:outerShdw blurRad="50800"><a:prstClr val="black"/></a:outerShdw></a:effectLst>\
    </c:spPr>\
    <c:printSettings><c:headerFooter/><c:pageMargins b="0.75" l="0.7" r="0.7" t="0.75" header="0.3" footer="0.3"/>\
    <c:pageSetup/></c:printSettings></c:chartSpace>
    """

    private static let chartStyle = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <cs:chartStyle xmlns:cs="http://schemas.microsoft.com/office/drawing/2012/chartStyle" id="227"/>
    """

    private static let chartColors = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <cs:colorStyle xmlns:cs="http://schemas.microsoft.com/office/drawing/2012/chartStyle" meth="cycle" id="10"/>
    """

    private func formattedWorkbook() throws -> Workbook {
        let anchor = Self.anchor(id: 2, relationship: "rIdChart", from: (4, 1), to: (10, 15))
            .replacingOccurrences(of: "name=\"Chart 2\"/>", with: "name=\"Chart 2\" descr=\"Sales trend by quarter\"/>")
            .replacingOccurrences(of: "<xdr:clientData/>", with: "<xdr:clientData fPrintsWithSheet=\"0\"/>")
        let chartRelationships = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId2" Type="\(ChartCompanion.styleType)" Target="style1.xml"/>\
        <Relationship Id="rId1" Type="\(ChartCompanion.colorsType)" Target="colors1.xml"/>\
        </Relationships>
        """
        let data = try package(
            anchors: anchor,
            drawingRelationships: chartRelationship("rIdChart", "../charts/chart1.xml"),
            extraParts: [
                ("xl/charts/chart1.xml", Self.formattedLineChart, Self.chartType),
                ("xl/charts/_rels/chart1.xml.rels", chartRelationships, nil),
                ("xl/charts/style1.xml", Self.chartStyle, "application/vnd.ms-office.chartstyle+xml"),
                ("xl/charts/colors1.xml", Self.chartColors, "application/vnd.ms-office.chartcolorstyle+xml"),
            ]
        )
        return try XLSXReader.workbook(from: data)
    }

    /// What the file had that the model does not, and that a save must keep.
    private static let unmodelledFormatting = [
        "<a:prstDash val=\"dash\"/>", "<c:symbol val=\"square\"/>", "<c:size val=\"7\"/>",
        "<c:symbol val=\"diamond\"/>", "<c14:style val=\"102\"/>", "<c:lang val=\"en-US\"/>",
        "<c:logBase val=\"10\"/>", "<c:builtInUnit val=\"hundreds\"/>", "<c:minorGridlines/>",
        "<c:crossesAt val=\"1\"/>", "<c:tickLblPos val=\"low\"/>", "<c:majorTickMark val=\"cross\"/>",
        "<a:prstDash val=\"sysDot\"/>", "<a:gradFill>", "<a:outerShdw", "<c:legendEntry>",
        "<c:layoutTarget val=\"inner\"/>", "<c:dispBlanksAs val=\"span\"/>", "<a:t>Peak</a:t>",
        "<c:dLblPos val=\"r\"/>", "<c:printSettings>", "<a:schemeClr val=\"accent1\"/>", "<a:schemeClr val=\"bg1\"/>",
    ]

    @Test("A chart saved untouched keeps every bit of formatting the model does not hold")
    func untouchedChartKeepsItsFormatting() throws {
        let workbook = try formattedWorkbook()
        let chart = try #require(workbook.sheets[0].charts.first)
        #expect(chart.altText == "Sales trend by quarter")
        #expect(chart.series.map(\.colorHex) == ["FF4472C4", "FF00B050"])

        let (reopened, entries) = try roundTrip(workbook)
        let xml = try text(entries, "xl/charts/chart1.xml")
        for fragment in Self.unmodelledFormatting {
            #expect(xml.contains(fragment), "lost \(fragment)")
        }
        // The cached values are fresh, read from the sheet.
        #expect(xml.contains("<c:v>15</c:v>"))

        let drawing = try text(entries, "xl/drawings/drawing1.xml")
        #expect(drawing.contains("descr=\"Sales trend by quarter\""))
        #expect(drawing.contains("fPrintsWithSheet=\"0\""))

        let chartRelationships = try text(entries, "xl/charts/_rels/chart1.xml.rels")
        #expect(chartRelationships.contains(ChartCompanion.styleType))
        #expect(chartRelationships.contains(ChartCompanion.colorsType))
        let types = try text(entries, "[Content_Types].xml")
        #expect(types.contains("application/vnd.ms-office.chartstyle+xml"))
        #expect(types.contains("application/vnd.ms-office.chartcolorstyle+xml"))
        try expectConsistentPackage(entries)

        // And it still reads as the same chart.
        let again = try #require(reopened.sheets[0].charts.first)
        #expect(again.series.map(\.colorHex) == chart.series.map(\.colorHex))
        #expect(again.title?.text == "Trend so far")
        #expect(again.altText == chart.altText)
        // A second save of the reopened file keeps it all again.
        let second = try text(roundTrip(reopened).entries, "xl/charts/chart1.xml")
        for fragment in Self.unmodelledFormatting {
            #expect(second.contains(fragment), "second save lost \(fragment)")
        }
    }

    @Test("An edit changes what was edited and nothing else")
    func editsArePatchedIn() throws {
        var workbook = try formattedWorkbook()
        workbook.sheets[0].charts[0].series[1].colorHex = "FFFF9500"
        workbook.sheets[0].charts[0].legend = .bottom
        workbook.sheets[0].charts[0].valueAxis.maximum = 1000
        workbook.sheets[0].charts[0].title?.textStyle.colorHex = "FF0000FF"
        workbook.sheets[0].charts[0].altText = "Edited"

        let (reopened, entries) = try roundTrip(workbook)
        let xml = try text(entries, "xl/charts/chart1.xml")
        let chart = try #require(reopened.sheets[0].charts.first)
        #expect(chart.series[1].colorHex == "FFFF9500")
        #expect(chart.series[0].colorHex == "FF4472C4")
        #expect(chart.legend == .bottom)
        #expect(chart.valueAxis.maximum == 1000)
        #expect(chart.title?.textStyle.colorHex == "FF0000FF")
        #expect(chart.altText == "Edited")
        #expect(!xml.contains("00B050"))
        // The title's two differently styled runs are both still there.
        #expect(xml.contains("<a:t>Trend</a:t>") && xml.contains("<a:t> so far</a:t>"))

        // Moving the legend lets go of where it had been dragged; nothing else
        // let go of anything.
        let legendXML = String(try #require(xml.firstMatch(of: #/<c:legend>.*?<\/c:legend>/#)).output)
        #expect(!legendXML.contains("manualLayout"))
        #expect(legendXML.contains("<c:legendEntry>"))
        for fragment in Self.unmodelledFormatting {
            #expect(xml.contains(fragment), "lost \(fragment)")
        }
        try expectConsistentPackage(entries)
    }

    @Test("Inserted rows and added or removed series reach the file's own XML")
    @MainActor
    func structuralEditsArePatchedIn() throws {
        var workbook = try formattedWorkbook()
        let state = EditorState()
        state.selectSheet(workbook.sheets[0].id, in: workbook)
        state.select(CellAddress(row: 2, column: 0))
        state.insertRows(above: true, in: &workbook)

        var xml = try text(roundTrip(workbook).entries, "xl/charts/chart1.xml")
        #expect(xml.contains("<c:f>Data!$B$2:$B$5</c:f>"))
        #expect(xml.contains("<c:symbol val=\"square\"/>"))

        // A third series, then the first one gone: the survivors keep their
        // own formatting and are renumbered in order.
        let sheetID = workbook.sheets[0].id
        var added = ChartSeries()
        added.values = ChartSource(reference: ChartReference(sheetID: sheetID, range: CellRange(a1Range: "C2:C5")!))
        workbook.sheets[0].charts[0].series.append(added)
        workbook.sheets[0].charts[0].series.removeFirst()

        let (reopened, entries) = try roundTrip(workbook)
        xml = try text(entries, "xl/charts/chart1.xml")
        #expect(xml.components(separatedBy: "<c:ser>").count - 1 == 2)
        #expect(!xml.contains("<c:symbol val=\"square\"/>"))
        #expect(xml.contains("<c:symbol val=\"diamond\"/>"))
        #expect(xml.contains("<c:idx val=\"2\"/><c:order val=\"1\"/>"))
        let chart = try #require(reopened.sheets[0].charts.first)
        #expect(chart.series.count == 2)
        #expect(chart.series[0].colorHex == "FF00B050")
        try expectConsistentPackage(entries)
    }

    @Test("Changing to an unrelated chart type writes the chart afresh")
    func changingTypeRebuilds() throws {
        var workbook = try formattedWorkbook()
        workbook.sheets[0].charts[0].kind = .pie
        let (reopened, entries) = try roundTrip(workbook)
        let xml = try text(entries, "xl/charts/chart1.xml")
        #expect(xml.contains("<c:pieChart>"))
        #expect(!xml.contains("<c:lineChart>"))
        #expect(reopened.sheets[0].charts.first?.kind == .pie)
        // The style parts still travel with it.
        #expect(entries["xl/charts/_rels/chart1.xml.rels"] != nil)
        try expectConsistentPackage(entries)
    }

    @Test("Column and bar swap in place, keeping their formatting")
    func columnToBarIsPatched() throws {
        let data = try package(
            anchors: Self.anchor(id: 2, relationship: "rIdChart", from: (4, 1), to: (10, 15)),
            drawingRelationships: chartRelationship("rIdChart", "../charts/chart1.xml"),
            extraParts: [("xl/charts/chart1.xml", Self.excelColumnChart, Self.chartType)]
        )
        var workbook = try XLSXReader.workbook(from: data)
        workbook.sheets[0].charts[0].kind = .bar
        workbook.sheets[0].charts[0].grouping = .standard
        let (reopened, entries) = try roundTrip(workbook)
        let xml = try text(entries, "xl/charts/chart1.xml")
        #expect(xml.contains("<c:barDir val=\"bar\"/>"))
        #expect(xml.contains("<c:grouping val=\"clustered\"/>"))
        #expect(xml.contains("<a:latin typeface=\"Avenir Next\"/>"))
        #expect(reopened.sheets[0].charts.first?.kind == .bar)
    }

    // MARK: - User shapes

    /// A text box over a chart as templates leave one: placed, but empty and
    /// with neither fill nor line.
    private static func userShapes(text: String) -> String {
        """
        <c:userShapes xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart">\
        <cdr:relSizeAnchor xmlns:cdr="http://schemas.openxmlformats.org/drawingml/2006/chartDrawing">\
        <cdr:from><cdr:x>0.001</cdr:x><cdr:y>0.006</cdr:y></cdr:from><cdr:to><cdr:x>0.17</cdr:x><cdr:y>0.13</cdr:y></cdr:to>\
        <cdr:sp macro="" textlink=""><cdr:nvSpPr><cdr:cNvPr id="2" name="TextBox 1"/><cdr:cNvSpPr txBox="1"/></cdr:nvSpPr>\
        <cdr:spPr><a:xfrm xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><a:off x="9526" y="38862"/>\
        <a:ext cx="1580322" cy="817548"/></a:xfrm><a:prstGeom xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
        prst="rect"><a:avLst/></a:prstGeom></cdr:spPr><cdr:txBody>\
        <a:bodyPr xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"/>\
        <a:p xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">\(text)<a:endParaRPr lang="en-US"/></a:p>\
        </cdr:txBody></cdr:sp></cdr:relSizeAnchor></c:userShapes>
        """
    }

    private func workbookWithUserShapes(text: String = "") throws -> Workbook {
        let chart = Self.excelColumnChart
            .replacingOccurrences(of: "</c:chartSpace>", with: "<c:userShapes r:id=\"rId3\"/></c:chartSpace>")
        let chartRelationships = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId3" Type="\(ChartCompanion.userShapesType)" Target="../drawings/drawing2.xml"/>\
        <Relationship Id="rId1" Type="\(ChartCompanion.styleType)" Target="style1.xml"/>\
        </Relationships>
        """
        let data = try package(
            anchors: Self.anchor(id: 2, relationship: "rIdChart", from: (4, 1), to: (10, 15)),
            drawingRelationships: chartRelationship("rIdChart", "../charts/chart1.xml"),
            extraParts: [
                ("xl/charts/chart1.xml", chart, Self.chartType),
                ("xl/charts/_rels/chart1.xml.rels", chartRelationships, nil),
                ("xl/charts/style1.xml", Self.chartStyle, "application/vnd.ms-office.chartstyle+xml"),
                ("xl/drawings/drawing2.xml", Self.userShapes(text: text),
                 "application/vnd.openxmlformats-officedocument.drawingml.chartshapes+xml"),
            ]
        )
        return try XLSXReader.workbook(from: data)
    }

    @Test("A chart under shapes that draw nothing is read, and the shapes are saved with it")
    func emptyUserShapesAreKept() throws {
        let workbook = try workbookWithUserShapes()
        #expect(workbook.sheets[0].charts.count == 1)
        #expect(workbook.sheets[0].preservedDrawingAnchors.isEmpty)

        let (reopened, entries) = try roundTrip(workbook)
        try expectConsistentPackage(entries)
        #expect(try text(entries, "xl/charts/chart1.xml").contains("<c:userShapes r:id=\"rId3\"/>"))
        let relationships = try text(entries, "xl/charts/_rels/chart1.xml.rels")
        #expect(relationships.contains("Id=\"rId3\" Type=\"\(ChartCompanion.userShapesType)\""))
        #expect(reopened.sheets[0].charts.count == 1)
        // The shapes part lands clear of the sheet's own drawing.
        let shapes = entries.filter { String(decoding: $0.value, as: UTF8.self).hasPrefix("<c:userShapes") }
        #expect(shapes.count == 1)
        #expect(shapes.keys.first?.hasPrefix("xl/drawings/") == true)
    }

    @Test("A chart rebuilt from the model still names its shapes")
    func rebuiltChartKeepsUserShapes() throws {
        var workbook = try workbookWithUserShapes()
        workbook.sheets[0].charts[0].kind = .pie
        let entries = try roundTrip(workbook).entries
        try expectConsistentPackage(entries)
        let xml = try text(entries, "xl/charts/chart1.xml")
        #expect(xml.contains("<c:pieChart>"))
        #expect(xml.contains("<c:userShapes r:id=\"rId3\"/>"))
    }

    @Test("A chart under shapes that show something is kept whole")
    func visibleUserShapesKeepTheChartWhole() throws {
        let workbook = try workbookWithUserShapes(text: "<a:r><a:t>Note</a:t></a:r>")
        #expect(workbook.sheets[0].charts.isEmpty)
        #expect(workbook.sheets[0].preservedDrawingAnchors.count == 1)
        let entries = try roundTrip(workbook).entries
        try expectConsistentPackage(entries)
        #expect(try text(entries, "xl/drawings/drawing2.xml").contains("<a:t>Note</a:t>"))
    }

    // MARK: - Excel 2016 charts

    /// A waterfall chart as Excel 2016 places one: a `cx:chart` in a choice
    /// that requires the chartex namespace, with a shape for older readers.
    private static func chartExAnchor(declaringPrefix: Bool) -> String {
        let declaration = declaringPrefix
            ? " xmlns:cx1=\"http://schemas.microsoft.com/office/drawing/2015/9/8/chartex\"" : ""
        return """
        <xdr:twoCellAnchor><xdr:from><xdr:col>4</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>1</xdr:row>\
        <xdr:rowOff>0</xdr:rowOff></xdr:from><xdr:to><xdr:col>10</xdr:col><xdr:colOff>0</xdr:colOff>\
        <xdr:row>15</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:to>\
        <mc:AlternateContent xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006">\
        <mc:Choice\(declaration) Requires="cx1"><xdr:graphicFrame macro=""><xdr:nvGraphicFramePr>\
        <xdr:cNvPr id="2" name="Chart 1"/><xdr:cNvGraphicFramePr/></xdr:nvGraphicFramePr>\
        <xdr:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/></xdr:xfrm><a:graphic>\
        <a:graphicData uri="http://schemas.microsoft.com/office/drawing/2014/chartex">\
        <cx:chart xmlns:cx="http://schemas.microsoft.com/office/drawing/2014/chartex" r:id="rIdEx"/>\
        </a:graphicData></a:graphic></xdr:graphicFrame></mc:Choice><mc:Fallback>\
        <xdr:sp macro="" textlink=""><xdr:nvSpPr><xdr:cNvPr id="0" name=""/><xdr:cNvSpPr/></xdr:nvSpPr>\
        <xdr:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="4572000" cy="2743200"/></a:xfrm>\
        <a:prstGeom prst="rect"><a:avLst/></a:prstGeom></xdr:spPr><xdr:txBody><a:bodyPr/><a:lstStyle/>\
        <a:p><a:r><a:rPr lang="en-US" sz="1100"/><a:t>This chart isn't available in your version of Excel.</a:t>\
        </a:r></a:p></xdr:txBody></xdr:sp></mc:Fallback></mc:AlternateContent><xdr:clientData/></xdr:twoCellAnchor>
        """
    }

    private static let chartEx = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <cx:chartSpace xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
    xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
    xmlns:cx="http://schemas.microsoft.com/office/drawing/2014/chartex">\
    <cx:chartData><cx:data id="0"><cx:strDim type="cat"><cx:f>Data!$A$2:$A$4</cx:f></cx:strDim>\
    <cx:numDim type="val"><cx:f>Data!$B$2:$B$4</cx:f></cx:numDim></cx:data></cx:chartData>\
    <cx:chart><cx:plotArea><cx:plotAreaRegion><cx:series layoutId="waterfall" uniqueId="{1}">\
    <cx:dataId val="0"/></cx:series></cx:plotAreaRegion></cx:plotArea></cx:chart></cx:chartSpace>
    """

    @Test("An Excel 2016 chart — waterfall, histogram, treemap — is kept whole", arguments: [true, false])
    func keepsChartEx(declaredOnChoice: Bool) throws {
        let chartExType = "http://schemas.microsoft.com/office/2014/relationships/chartEx"
        let anchors = Self.chartExAnchor(declaringPrefix: declaredOnChoice)
        // Some writers declare the prefix a choice requires on the drawing's
        // root instead, far from the fragment that gets kept.
        let rootDeclaration = declaredOnChoice
            ? "" : " xmlns:cx1=\"http://schemas.microsoft.com/office/drawing/2015/9/8/chartex\""
        let chartExRelationships = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="\(ChartCompanion.styleType)" Target="style1.xml"/>\
        </Relationships>
        """
        let data = try package(
            anchors: anchors,
            drawingRelationships: "<Relationship Id=\"rIdEx\" Type=\"\(chartExType)\" Target=\"../charts/chartEx1.xml\"/>",
            extraParts: [
                ("xl/charts/chartEx1.xml", Self.chartEx, "application/vnd.ms-office.chartex+xml"),
                ("xl/charts/_rels/chartEx1.xml.rels", chartExRelationships, nil),
                ("xl/charts/style1.xml", Self.chartStyle, "application/vnd.ms-office.chartstyle+xml"),
            ],
            drawingDeclarations: rootDeclaration
        )
        let workbook = try XLSXReader.workbook(from: data)
        let sheet = workbook.sheets[0]
        #expect(sheet.charts.isEmpty)
        let anchor = try #require(sheet.preservedDrawingAnchors.first)
        #expect(anchor.isChart)
        #expect(anchor.placement?.from.column == 4)
        #expect(workbook.unsupportedFeatures.preserved.contains(.chartsAndImages))
        #expect(!workbook.unsupportedFeatures.lost.contains(.chartsAndImages))

        let (reopened, entries) = try roundTrip(workbook)
        #expect(try text(entries, "xl/charts/chartEx1.xml") == Self.chartEx)
        #expect(entries["xl/charts/style1.xml"] != nil)
        #expect(try text(entries, "[Content_Types].xml").contains("application/vnd.ms-office.chartex+xml"))
        let drawingPath = try #require(entries.keys.first { $0.hasPrefix("xl/drawings/drawing") && $0.hasSuffix(".xml") })
        let drawing = try text(entries, drawingPath)
        #expect(drawing.contains("Requires=\"cx1\""))
        // The prefix a choice requires has to be declared where it is used,
        // or Excel takes the fallback and shows only the apology.
        let choice = try #require(drawing.firstMatch(of: #/<mc:Choice[^>]*>/#)).output
        let declared = drawing.contains("xmlns:cx1=\"http://schemas.microsoft.com/office/drawing/2015/9/8/chartex\"")
        #expect(declared, "cx1 is not declared anywhere: \(choice)")
        #expect(drawing.contains("available in your version of Excel."))
        try expectConsistentPackage(entries)
        #expect(reopened.sheets[0].preservedDrawingAnchors.count == 1)
    }

    // MARK: - Kept anchors

    @Test("Pictures and charts kept whole move with rows, as their anchoring says")
    func keptAnchorsFollowRows() throws {
        let oneCell = Self.anchor(id: 3, relationship: "rId3D", from: (4, 16), to: (10, 30))
        let twoCell = oneCell.replacingOccurrences(of: " editAs=\"oneCell\"", with: "")
            .replacingOccurrences(of: "id=\"3\" name=\"Chart 3\"", with: "id=\"4\" name=\"Chart 4\"")
        let absolute = oneCell.replacingOccurrences(of: "editAs=\"oneCell\"", with: "editAs=\"absolute\"")
            .replacingOccurrences(of: "id=\"3\" name=\"Chart 3\"", with: "id=\"5\" name=\"Chart 5\"")
        let data = try package(
            anchors: oneCell + twoCell + absolute + Self.pictureAnchor,
            drawingRelationships: chartRelationship("rId3D", "../charts/chart2.xml")
                + "<Relationship Id=\"rIdImage\" Type=\"\(Self.relationships)/image\" Target=\"../media/image1.png\"/>",
            extraParts: [
                ("xl/charts/chart2.xml", Self.unsupportedChart, Self.chartType),
                ("xl/media/image1.png", "PNGDATA", nil),
            ]
        )
        var workbook = try XLSXReader.workbook(from: data)
        #expect(workbook.sheets[0].preservedDrawingAnchors.count == 4)

        /// Each anchor's first and last row, as its XML now says.
        func rows(_ workbook: Workbook) throws -> [[Int]] {
            try workbook.sheets[0].preservedDrawingAnchors.map { anchor in
                let root = try XMLLite.parse(Data(anchor.xml.utf8))
                return ["from", "to"].compactMap { root.firstDescendant(atPath: "\($0)/row")?.text }.compactMap(Int.init)
            }
        }
        #expect(try rows(workbook) == [[16, 30], [16, 30], [16, 30], [1]])

        // Inside the charts: the default anchor stretches, "oneCell" keeps its
        // size, "absolute" does not move, and the picture above is untouched.
        workbook.sheets[0].insertRows(3, at: 20)
        #expect(try rows(workbook) == [[16, 30], [16, 33], [16, 30], [1]])
        // Above everything: all but the absolute one move down.
        workbook.sheets[0].insertRows(2, at: 0)
        #expect(try rows(workbook) == [[18, 32], [18, 35], [16, 30], [3]])
        #expect(workbook.sheets[0].preservedDrawingAnchors[3].placement?.from.row == 3)
        workbook.sheets[0].removeRows(0...1)
        #expect(try rows(workbook) == [[16, 30], [16, 33], [16, 30], [1]])

        // Written out, the moved markers are what Excel reads; nothing else in
        // the fragments changed.
        let written = try ZipArchive.entries(in: XLSXWriter.data(from: workbook))
        try expectConsistentPackage(written)
        let reread = try XLSXReader.workbook(from: XLSXWriter.data(from: workbook))
        #expect(try rows(reread) == [[16, 30], [16, 33], [16, 30], [1]])
        #expect(try text(written, "xl/drawings/drawing1.xml").contains("r:embed=\"rIdImage\""))
    }

    /// A picture as Excel inserts one: pinned by its corner, its proportions
    /// locked, its transform spelled out.
    private static let lockedPictureAnchor = """
    <xdr:oneCellAnchor><xdr:from><xdr:col>1</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>1</xdr:row>\
    <xdr:rowOff>0</xdr:rowOff></xdr:from><xdr:ext cx="952500" cy="952500"/><xdr:pic><xdr:nvPicPr>\
    <xdr:cNvPr id="7" name="Picture 7"/><xdr:cNvPicPr><a:picLocks noChangeAspect="1"/></xdr:cNvPicPr>\
    </xdr:nvPicPr><xdr:blipFill><a:blip r:embed="rIdImage"/><a:stretch><a:fillRect/></a:stretch>\
    </xdr:blipFill><xdr:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="952500" cy="952500"/></a:xfrm>\
    <a:prstGeom prst="rect"><a:avLst/></a:prstGeom></xdr:spPr></xdr:pic><xdr:clientData/></xdr:oneCellAnchor>
    """

    @Test("A picture dragged elsewhere is anchored there, its fragment otherwise untouched")
    func movedPictureIsReanchored() throws {
        let twoCell = Self.anchor(id: 3, relationship: "rId3D", from: (4, 16), to: (10, 30))
            .replacingOccurrences(of: " editAs=\"oneCell\"", with: "")
        let data = try package(
            anchors: Self.lockedPictureAnchor + twoCell,
            drawingRelationships: chartRelationship("rId3D", "../charts/chart2.xml")
                + "<Relationship Id=\"rIdImage\" Type=\"\(Self.relationships)/image\" Target=\"../media/image1.png\"/>",
            extraParts: [
                ("xl/charts/chart2.xml", Self.unsupportedChart, Self.chartType),
                ("xl/media/image1.png", "PNGDATA", nil),
            ]
        )
        var workbook = try XLSXReader.workbook(from: data)
        let sheet = workbook.sheets[0]
        #expect(sheet.preservedDrawingAnchors[0].locks == DrawingLocks(noChangeAspect: true))
        #expect(sheet.preservedDrawingAnchors[1].locks == DrawingLocks())

        let metrics = SheetMetrics(sheet: sheet)
        let frame = CGRect(x: metrics.x(ofColumn: 2) + 5, y: metrics.y(ofRow: 3) + 4, width: 100, height: 50)
        workbook.sheets[0].preservedDrawingAnchors[0].place(at: frame, in: sheet)
        workbook.sheets[0].preservedDrawingAnchors[1].place(at: frame, in: sheet)

        let picture = try XMLLite.parse(Data(workbook.sheets[0].preservedDrawingAnchors[0].xml.utf8))
        #expect(picture.firstDescendant(atPath: "from/col")?.text == "2")
        #expect(picture.firstDescendant(atPath: "from/colOff")?.text == "63500")
        #expect(picture.firstDescendant(atPath: "from/row")?.text == "3")
        #expect(picture.firstDescendant(atPath: "from/rowOff")?.text == "50800")
        #expect(picture.firstChild(named: "ext")?.attribute("cx") == "1270000")
        #expect(picture.firstChild(named: "ext")?.attribute("cy") == "635000")
        // The picture's own transform follows its anchor.
        let transform = try #require(picture.firstDescendant(atPath: "pic/spPr/xfrm"))
        #expect(transform.firstChild(named: "off")?.attribute("x") == String(Int(((frame.minX) * 12_700).rounded())))
        #expect(transform.firstChild(named: "ext")?.attribute("cx") == "1270000")
        #expect(picture.firstDescendant(atPath: "pic/blipFill/blip")?.attribute("embed") == "rIdImage")

        // A two-cell anchor has both corners moved, its frame's zeros left alone.
        let chart = try XMLLite.parse(Data(workbook.sheets[0].preservedDrawingAnchors[1].xml.utf8))
        #expect(chart.firstDescendant(atPath: "from/col")?.text == "2")
        #expect(chart.firstDescendant(atPath: "to/rowOff")?.text != nil)
        #expect(chart.firstDescendant(atPath: "graphicFrame/xfrm/ext")?.attribute("cx") == "0")
        let moved = try #require(workbook.sheets[0].preservedDrawingAnchors[1].placement)
        let placed = moved.frame(in: metrics)
        #expect(abs(placed.minX - frame.minX) < 0.01 && abs(placed.maxY - frame.maxY) < 0.01)

        // And it all reads back where it was put.
        let written = try ZipArchive.entries(in: XLSXWriter.data(from: workbook))
        try expectConsistentPackage(written)
        let reread = try XLSXReader.workbook(from: XLSXWriter.data(from: workbook))
        let reread0 = try #require(reread.sheets[0].preservedDrawingAnchors.first?.placement)
        let rereadFrame = reread0.frame(in: SheetMetrics(sheet: reread.sheets[0]))
        #expect(abs(rereadFrame.minX - frame.minX) < 0.01)
        #expect(abs(rereadFrame.width - frame.width) < 0.01)
        #expect(reread.sheets[0].preservedDrawingAnchors.first?.picture?.target == "xl/media/image1.png")
    }

    @Test("A shape anchored absolutely is moved by its position, its transform following")
    func movedAbsoluteShape() throws {
        let shape = """
        <xdr:absoluteAnchor><xdr:pos x="0" y="0"/><xdr:ext cx="1270000" cy="635000"/><xdr:sp macro="" textlink="">\
        <xdr:nvSpPr><xdr:cNvPr id="4" name="Rectangle 4"/><xdr:cNvSpPr/></xdr:nvSpPr><xdr:spPr><a:xfrm>\
        <a:off x="0" y="0"/><a:ext cx="1270000" cy="635000"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom>\
        </xdr:spPr></xdr:sp><xdr:clientData/></xdr:absoluteAnchor>
        """
        let data = try package(anchors: shape, drawingRelationships: "", extraParts: [])
        var workbook = try XLSXReader.workbook(from: data)
        let sheet = workbook.sheets[0]
        workbook.sheets[0].preservedDrawingAnchors[0].place(at: CGRect(x: 10, y: 20, width: 30, height: 40), in: sheet)

        let root = try XMLLite.parse(Data(workbook.sheets[0].preservedDrawingAnchors[0].xml.utf8))
        #expect(root.firstChild(named: "pos")?.attribute("x") == "127000")
        #expect(root.firstChild(named: "pos")?.attribute("y") == "254000")
        #expect(root.firstChild(named: "ext")?.attribute("cx") == "381000")
        #expect(root.firstDescendant(atPath: "sp/spPr/xfrm/off")?.attribute("y") == "254000")
        #expect(root.firstDescendant(atPath: "sp/spPr/xfrm/ext")?.attribute("cy") == "508000")
        let frame = try #require(workbook.sheets[0].preservedDrawingAnchors[0].placement)
            .frame(in: SheetMetrics(sheet: sheet))
        #expect(abs(frame.minX - 10) < 0.01 && abs(frame.height - 40) < 0.01)
    }

    @Test("An object wrapped in alternate content is placed, drawn and moved by the anchors inside")
    func wrappedAnchor() throws {
        // A 3D model as Excel writes one: the model for readers that know it,
        // a picture of it for those that do not.
        let model = Self.anchor(id: 5, relationship: "rIdModel", from: (2, 4), to: (6, 12))
            .replacingOccurrences(of: "http://schemas.openxmlformats.org/drawingml/2006/chart", with: "http://schemas.microsoft.com/office/drawing/2017/model3d")
        let fallback = Self.lockedPictureAnchor
            .replacingOccurrences(of: "<xdr:oneCellAnchor>", with: "<xdr:twoCellAnchor editAs=\"oneCell\">")
            .replacingOccurrences(of: "<xdr:ext cx=\"952500\" cy=\"952500\"/><xdr:pic>",
                                  with: "<xdr:to><xdr:col>6</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>12</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:to><xdr:pic>")
            .replacingOccurrences(of: "</xdr:oneCellAnchor>", with: "</xdr:twoCellAnchor>")
            .replacingOccurrences(of: "<xdr:col>1</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>1</xdr:row>",
                                  with: "<xdr:col>2</xdr:col><xdr:colOff>12700</xdr:colOff><xdr:row>4</xdr:row>")
        let wrapped = """
        <mc:AlternateContent xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006">\
        <mc:Choice xmlns:am3d="http://schemas.microsoft.com/office/drawing/2017/model3d" Requires="am3d">\
        \(model)</mc:Choice><mc:Fallback>\(fallback)</mc:Fallback></mc:AlternateContent>
        """
        let data = try package(
            anchors: wrapped,
            drawingRelationships: "<Relationship Id=\"rIdModel\" Type=\"http://schemas.microsoft.com/office/2017/06/relationships/model3d\" Target=\"../media/model3d1.glb\"/>"
                + "<Relationship Id=\"rIdImage\" Type=\"\(Self.relationships)/image\" Target=\"../media/image1.png\"/>",
            extraParts: [("xl/media/image1.png", "PNGDATA", nil), ("xl/media/model3d1.glb", "GLB", "model/gltf-binary")]
        )
        var workbook = try XLSXReader.workbook(from: data)
        let anchor = try #require(workbook.sheets[0].preservedDrawingAnchors.first)
        #expect(anchor.placement?.from == ChartAnchor(row: 4, column: 2, rowOffset: 0, columnOffset: 1))
        #expect(anchor.picture?.target == "xl/media/image1.png")

        /// Each branch's first row, as its XML now says.
        func rows(_ workbook: Workbook) throws -> [String?] {
            let root = try XMLLite.parse(Data(workbook.sheets[0].preservedDrawingAnchors[0].xml.utf8))
            return DrawingReader.anchors(in: root).map { $0.firstDescendant(atPath: "from/row")?.text }
        }
        workbook.sheets[0].insertRows(2, at: 0)
        #expect(try rows(workbook) == ["6", "6"])

        let sheet = workbook.sheets[0]
        let metrics = SheetMetrics(sheet: sheet)
        let frame = CGRect(x: metrics.x(ofColumn: 3), y: metrics.y(ofRow: 9), width: 80, height: 60)
        workbook.sheets[0].preservedDrawingAnchors[0].place(at: frame, in: sheet)
        #expect(try rows(workbook) == ["9", "9"])

        let written = try ZipArchive.entries(in: XLSXWriter.data(from: workbook))
        try expectConsistentPackage(written)
        let drawing = try text(written, "xl/drawings/drawing1.xml")
        #expect(drawing.contains("Requires=\"am3d\""))
        let reread = try XLSXReader.workbook(from: XLSXWriter.data(from: workbook))
        #expect(reread.sheets[0].preservedDrawingAnchors.first?.placement?.from.row == 9)
    }

    @Test("A picture is selected apart from charts, moved, and deleted")
    @MainActor
    func pictureSelection() throws {
        let data = try package(
            anchors: Self.lockedPictureAnchor,
            drawingRelationships: "<Relationship Id=\"rIdImage\" Type=\"\(Self.relationships)/image\" Target=\"../media/image1.png\"/>",
            extraParts: [("xl/media/image1.png", "PNGDATA", nil)]
        )
        var workbook = try XLSXReader.workbook(from: data)
        let state = EditorState()
        state.selectSheet(workbook.sheets[0].id, in: workbook)
        let id = workbook.sheets[0].preservedDrawingAnchors[0].id

        state.selectChart(UUID())
        state.selectDrawing(id)
        #expect(state.selectedDrawingID == id)
        #expect(state.selectedChartID == nil)
        state.selectChart(nil)
        #expect(state.selectedDrawingID == nil)

        state.selectDrawing(id)
        state.moveDrawing(id, to: CGRect(x: 300, y: 200, width: 40, height: 40), in: &workbook)
        let placement = try #require(workbook.sheets[0].preservedDrawingAnchors[0].placement)
        #expect(abs(placement.frame(in: SheetMetrics(sheet: workbook.sheets[0])).minX - 300) < 0.01)

        state.deleteSelectedDrawing(in: &workbook)
        #expect(workbook.sheets[0].preservedDrawingAnchors.isEmpty)
        #expect(state.selectedDrawingID == nil)
        let written = try ZipArchive.entries(in: XLSXWriter.data(from: workbook))
        try expectConsistentPackage(written)
    }

    @Test("A chart anchored absolutely stays put; one moving as a block keeps its size")
    func chartAnchoringIsHonoured() throws {
        var placement = ChartPlacement(
            from: ChartAnchor(row: 4, column: 1), to: ChartAnchor(row: 10, column: 5), editAs: "absolute"
        )
        #expect(placement.shifted(.insert(index: 0, count: 3), axis: .row) == placement)
        placement.editAs = "oneCell"
        let moved = placement.shifted(.insert(index: 0, count: 3), axis: .row)
        #expect(moved.from.row == 7 && moved.to.row == 13)
        let inside = placement.shifted(.insert(index: 6, count: 3), axis: .row)
        #expect(inside.from.row == 4 && inside.to.row == 10)
    }

    @Test("A cropped picture reads its crop as fractions of the image")
    func pictureCrop() throws {
        let cropped = Self.pictureAnchor.replacingOccurrences(
            of: "<a:stretch>", with: "<a:srcRect l=\"6589\" t=\"13099\" r=\"6742\" b=\"13099\"/><a:stretch>"
        )
        let data = try package(
            anchors: cropped,
            drawingRelationships: "<Relationship Id=\"rIdImage\" Type=\"\(Self.relationships)/image\" Target=\"../media/image1.png\"/>",
            extraParts: [("xl/media/image1.png", "PNGDATA", nil)]
        )
        let picture = try #require(XLSXReader.workbook(from: data).sheets[0].preservedDrawingAnchors.first?.picture)
        #expect(abs(picture.cropLeft - 0.06589) < 1e-9)
        #expect(abs(picture.cropBottom - 0.13099) < 1e-9)
    }

    @Test("A shape linking to a place in the workbook is kept, link and all")
    func shapeWithInWorkbookLinkSurvives() throws {
        let button = """
        <xdr:twoCellAnchor editAs="absolute"><xdr:from><xdr:col>1</xdr:col><xdr:colOff>0</xdr:colOff>\
        <xdr:row>1</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:from><xdr:to><xdr:col>3</xdr:col><xdr:colOff>0</xdr:colOff>\
        <xdr:row>3</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:to><xdr:sp macro="" textlink=""><xdr:nvSpPr>\
        <xdr:cNvPr id="9" name="Next Button"><a:hlinkClick r:id="rIdNext"/></xdr:cNvPr><xdr:cNvSpPr/></xdr:nvSpPr>\
        <xdr:spPr><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></xdr:spPr></xdr:sp><xdr:clientData/></xdr:twoCellAnchor>
        """
        let data = try package(
            anchors: button,
            drawingRelationships: "<Relationship Id=\"rIdNext\" Type=\"\(Self.relationships)/hyperlink\" Target=\"#'Data'!A1\"/>",
            extraParts: []
        )
        let workbook = try XLSXReader.workbook(from: data)
        #expect(workbook.sheets[0].preservedDrawingAnchors.count == 1)
        #expect(!workbook.unsupportedFeatures.lost.contains(.chartsAndImages))

        let written = try ZipArchive.entries(in: XLSXWriter.data(from: workbook))
        try expectConsistentPackage(written)
        let relationships = try text(written, "xl/drawings/_rels/drawing1.xml.rels")
        #expect(relationships.contains("Target=\"#&apos;Data&apos;!A1\""))
        #expect(!relationships.contains("TargetMode"))
        #expect(try text(written, "xl/drawings/drawing1.xml").contains("Next Button"))
    }
}
