import Foundation
import Testing
@testable import TablesEngine

/// A workbook laid out the way Excel writes one with a PivotTable and a
/// slicer: a sheet of data, a sheet with the PivotTable's cells as Excel
/// left them, the cache definition and records, the PivotTable definition,
/// and a slicer on its Region field.
enum PivotFixture {
    static let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    static let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    static let x14 = "http://schemas.microsoft.com/office/spreadsheetml/2009/9/main"

    /// Region, Product, Amount.
    static let rows: [(String, String, Double)] = [
        ("East", "Apples", 10), ("West", "Apples", 20), ("East", "Pears", 5),
        ("West", "Pears", 7), ("North", "Apples", 3), ("East", "Apples", 4),
    ]

    static let cacheDefinition = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <pivotCacheDefinition xmlns="\(main)" xmlns:r="\(rel)" r:id="rId1" refreshedBy="Kei" \
    refreshedDate="45000.5" createdVersion="8" refreshedVersion="8" minRefreshableVersion="3" recordCount="6">\
    <cacheSource type="worksheet"><worksheetSource ref="A1:C7" sheet="Data"/></cacheSource>\
    <cacheFields count="3">\
    <cacheField name="Region" numFmtId="0"><sharedItems count="3"><s v="East"/><s v="West"/><s v="North"/></sharedItems></cacheField>\
    <cacheField name="Product" numFmtId="0"><sharedItems count="2"><s v="Apples"/><s v="Pears"/></sharedItems></cacheField>\
    <cacheField name="Amount" numFmtId="0"><sharedItems containsSemiMixedTypes="0" containsString="0" \
    containsNumber="1" containsInteger="1" minValue="3" maxValue="20"/></cacheField>\
    </cacheFields><extLst><ext uri="{725AE2AE-9491-48be-B2B4-4EB974FC3084}" xmlns:x14="\(x14)">\
    <x14:pivotCacheDefinition pivotCacheId="1"/></ext></extLst></pivotCacheDefinition>
    """

    static let cacheRecords = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <pivotCacheRecords xmlns="\(main)" xmlns:r="\(rel)" count="6">\
    <r><x v="0"/><x v="0"/><n v="10"/></r><r><x v="1"/><x v="0"/><n v="20"/></r>\
    <r><x v="0"/><x v="1"/><n v="5"/></r><r><x v="1"/><x v="1"/><n v="7"/></r>\
    <r><x v="2"/><x v="0"/><n v="3"/></r><r><x v="0"/><x v="0"/><n v="4"/></r>\
    </pivotCacheRecords>
    """

    static let pivotTable = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <pivotTableDefinition xmlns="\(main)" name="PivotTable1" cacheId="5" applyNumberFormats="0" \
    applyBorderFormats="0" applyFontFormats="0" applyPatternFormats="0" applyAlignmentFormats="0" \
    applyWidthHeightFormats="1" dataCaption="Values" updatedVersion="8" minRefreshableVersion="3" \
    useAutoFormatting="1" itemPrintTitles="1" createdVersion="8" indent="0" outline="1" outlineData="1" \
    multipleFieldFilters="0">\
    <location ref="A3:D8" firstHeaderRow="1" firstDataRow="2" firstDataCol="1"/>\
    <pivotFields count="3">\
    <pivotField axis="axisRow" showAll="0"><items count="4"><item x="0"/><item x="2"/><item x="1"/><item t="default"/></items></pivotField>\
    <pivotField axis="axisCol" showAll="0"><items count="3"><item x="0"/><item x="1"/><item t="default"/></items></pivotField>\
    <pivotField dataField="1" showAll="0"/>\
    </pivotFields>\
    <rowFields count="1"><field x="0"/></rowFields>\
    <rowItems count="4"><i><x/></i><i><x v="1"/></i><i><x v="2"/></i><i t="grand"><x/></i></rowItems>\
    <colFields count="1"><field x="1"/></colFields>\
    <colItems count="3"><i><x/></i><i><x v="1"/></i><i t="grand"><x/></i></colItems>\
    <dataFields count="1"><dataField name="Sum of Amount" fld="2" baseField="0" baseItem="0"/></dataFields>\
    <pivotTableStyleInfo name="PivotStyleLight16" showRowHeaders="1" showColHeaders="1" showRowStripes="0" \
    showColStripes="0" showLastColumn="1"/></pivotTableDefinition>
    """

    static let slicerCache = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <slicerCacheDefinition xmlns="\(x14)" xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" \
    mc:Ignorable="x" xmlns:x="\(main)" name="Slicer_Region" sourceName="Region">\
    <pivotTables><pivotTable tabId="2" name="PivotTable1"/></pivotTables>\
    <data><tabular pivotCacheId="1"><items count="3"><i x="0" s="1"/><i x="2" s="1"/><i x="1" s="1"/></items></tabular></data>\
    </slicerCacheDefinition>
    """

    static let slicer = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <slicers xmlns="\(x14)" xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" \
    mc:Ignorable="x xr10" xmlns:x="\(main)" xmlns:xr10="http://schemas.microsoft.com/office/spreadsheetml/2016/revision10">\
    <slicer name="Region" cache="Slicer_Region" caption="Region" rowHeight="241300"/></slicers>
    """

    /// The cells Excel leaves on the PivotTable's sheet, from A3.
    static let pivotCells: [[(any Sendable)?]] = [
        ["Sum of Amount", "Column Labels", nil, nil],
        ["Row Labels", "Apples", "Pears", "Grand Total"],
        ["East", 14.0, 5.0, 19.0],
        ["North", 3.0, nil, 3.0],
        ["West", 20.0, 7.0, 27.0],
        ["Grand Total", 37.0, 12.0, 49.0],
    ]

    static func data(withSlicer: Bool = true) throws -> Data {
        var strings: [String] = []
        func cell(_ ref: String, _ value: (any Sendable)?) -> String {
            switch value {
            case let text as String:
                if !strings.contains(text) { strings.append(text) }
                return "<c r=\"\(ref)\" t=\"s\"><v>\(strings.firstIndex(of: text)!)</v></c>"
            case let number as Double:
                return "<c r=\"\(ref)\"><v>\(XLSXWriter.format(number))</v></c>"
            default:
                return ""
            }
        }
        func sheet(_ rows: [[(any Sendable)?]], firstRow: Int, tail: String = "") -> String {
            var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
            xml += "<worksheet xmlns=\"\(main)\" xmlns:r=\"\(rel)\"><sheetData>"
            for (offset, row) in rows.enumerated() {
                xml += "<row r=\"\(firstRow + offset)\">"
                for (column, value) in row.enumerated() {
                    xml += cell(CellAddress(row: firstRow + offset - 1, column: column).a1, value)
                }
                xml += "</row>"
            }
            return xml + "</sheetData>\(tail)</worksheet>"
        }
        let dataSheet = sheet([["Region", "Product", "Amount"]] + rows.map { [$0.0, $0.1, $0.2] }, firstRow: 1)
        let slicerList = withSlicer ? """
        <extLst><ext uri="{A8765BA9-456A-4dab-B4F3-ACF838C121DE}" xmlns:x14="\(x14)">\
        <x14:slicerList><x14:slicer r:id="rId2"/></x14:slicerList></ext></extLst>
        """ : ""
        let pivotSheet = sheet(pivotCells, firstRow: 3, tail: slicerList)
        let sharedStrings = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><sst xmlns=\"\(main)\""
            + " count=\"\(strings.count)\" uniqueCount=\"\(strings.count)\">"
            + strings.map { "<si><t>\(XMLLite.escape($0))</t></si>" }.joined() + "</sst>"

        let type = "application/vnd.openxmlformats-officedocument.spreadsheetml"
        var overrides = [
            ("/xl/workbook.xml", "\(type).sheet.main+xml"),
            ("/xl/worksheets/sheet1.xml", "\(type).worksheet+xml"),
            ("/xl/worksheets/sheet2.xml", "\(type).worksheet+xml"),
            ("/xl/styles.xml", "\(type).styles+xml"),
            ("/xl/sharedStrings.xml", "\(type).sharedStrings+xml"),
            ("/xl/pivotTables/pivotTable1.xml", "\(type).pivotTable+xml"),
            ("/xl/pivotCache/pivotCacheDefinition1.xml", "\(type).pivotCacheDefinition+xml"),
            ("/xl/pivotCache/pivotCacheRecords1.xml", "\(type).pivotCacheRecords+xml"),
        ]
        if withSlicer {
            overrides += [
                ("/xl/slicers/slicer1.xml", "application/vnd.ms-excel.slicer+xml"),
                ("/xl/slicerCaches/slicerCache1.xml", "application/vnd.ms-excel.slicerCache+xml"),
            ]
        }
        let contentTypes = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
            + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
            + "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
            + "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
            + overrides.map { "<Override PartName=\"\($0.0)\" ContentType=\"\($0.1)\"/>" }.joined() + "</Types>"
        func rels(_ entries: [(String, String, String)]) -> String {
            "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
                + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
                + entries.map { "<Relationship Id=\"\($0.0)\" Type=\"\($0.1)\" Target=\"\($0.2)\"/>" }.joined()
                + "</Relationships>"
        }
        var workbookRels = [
            ("rId1", "\(rel)/worksheet", "worksheets/sheet1.xml"),
            ("rId2", "\(rel)/worksheet", "worksheets/sheet2.xml"),
            ("rId3", "\(rel)/pivotCacheDefinition", "pivotCache/pivotCacheDefinition1.xml"),
            ("rId4", "\(rel)/styles", "styles.xml"),
            ("rId5", "\(rel)/sharedStrings", "sharedStrings.xml"),
        ]
        var workbookExtensions = ""
        if withSlicer {
            workbookRels.append(("rId6", "http://schemas.microsoft.com/office/2007/relationships/slicerCache",
                                 "slicerCaches/slicerCache1.xml"))
            workbookExtensions = "<extLst><ext uri=\"{BBE1A952-AA13-448e-AADC-164F8A28A991}\" xmlns:x14=\"\(x14)\">"
                + "<x14:slicerCaches><x14:slicerCache r:id=\"rId6\"/></x14:slicerCaches></ext></extLst>"
        }
        let workbook = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
            + "<workbook xmlns=\"\(main)\" xmlns:r=\"\(rel)\"><sheets>"
            + "<sheet name=\"Data\" sheetId=\"1\" r:id=\"rId1\"/><sheet name=\"Pivot\" sheetId=\"2\" r:id=\"rId2\"/></sheets>"
            + (withSlicer ? "<definedNames><definedName name=\"Slicer_Region\">#N/A</definedName></definedNames>" : "")
            + "<calcPr calcId=\"191029\"/><pivotCaches><pivotCache cacheId=\"5\" r:id=\"rId3\"/></pivotCaches>"
            + workbookExtensions + "</workbook>"
        let styles = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><styleSheet xmlns=\"\(main)\">"
            + "<fonts count=\"1\"><font><sz val=\"11\"/><name val=\"Calibri\"/></font></fonts>"
            + "<fills count=\"2\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill></fills>"
            + "<borders count=\"1\"><border><left/><right/><top/><bottom/><diagonal/></border></borders>"
            + "<cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs>"
            + "<cellXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/></cellXfs>"
            + "</styleSheet>"
        var pivotSheetRels = [("rId1", "\(rel)/pivotTable", "../pivotTables/pivotTable1.xml")]
        if withSlicer {
            pivotSheetRels.append(("rId2", "http://schemas.microsoft.com/office/2007/relationships/slicer",
                                   "../slicers/slicer1.xml"))
        }
        var entries: [(path: String, data: Data)] = [
            ("[Content_Types].xml", Data(contentTypes.utf8)),
            ("_rels/.rels", Data(rels([("rId1", "\(rel)/officeDocument", "xl/workbook.xml")]).utf8)),
            ("xl/workbook.xml", Data(workbook.utf8)),
            ("xl/_rels/workbook.xml.rels", Data(rels(workbookRels).utf8)),
            ("xl/styles.xml", Data(styles.utf8)),
            ("xl/worksheets/sheet1.xml", Data(dataSheet.utf8)),
            ("xl/worksheets/sheet2.xml", Data(pivotSheet.utf8)),
            ("xl/worksheets/_rels/sheet2.xml.rels", Data(rels(pivotSheetRels).utf8)),
            ("xl/sharedStrings.xml", Data(sharedStrings.utf8)),
            ("xl/pivotTables/pivotTable1.xml", Data(pivotTable.utf8)),
            ("xl/pivotTables/_rels/pivotTable1.xml.rels", Data(rels([
                ("rId1", "\(rel)/pivotCacheDefinition", "../pivotCache/pivotCacheDefinition1.xml"),
            ]).utf8)),
            ("xl/pivotCache/pivotCacheDefinition1.xml", Data(cacheDefinition.utf8)),
            ("xl/pivotCache/_rels/pivotCacheDefinition1.xml.rels", Data(rels([
                ("rId1", "\(rel)/pivotCacheRecords", "pivotCacheRecords1.xml"),
            ]).utf8)),
            ("xl/pivotCache/pivotCacheRecords1.xml", Data(cacheRecords.utf8)),
        ]
        if withSlicer {
            entries.append(("xl/slicers/slicer1.xml", Data(slicer.utf8)))
            entries.append(("xl/slicerCaches/slicerCache1.xml", Data(slicerCache.utf8)))
        }
        return try ZipArchive.archive(entries: entries)
    }
}

@Suite("PivotTables")
struct PivotTableTests {
    private func read(withSlicer: Bool = true) throws -> Workbook {
        try XLSXReader.workbook(from: try PivotFixture.data(withSlicer: withSlicer))
    }

    private func saved(_ workbook: Workbook) throws -> [String: Data] {
        try ZipArchive.entries(in: try XLSXWriter.data(from: workbook))
    }

    private func text(_ entries: [String: Data], _ path: String) throws -> String {
        String(decoding: try #require(entries[path], "\(path) is missing"), as: UTF8.self)
    }

    /// The PivotTable's cells, row by row, as values.
    private func grid(_ workbook: Workbook, _ range: CellRange) throws -> [[CellValue]] {
        let sheet = try #require(workbook.sheet(named: "Pivot"))
        return range.rowRange.map { row in range.columnRange.map { sheet[CellAddress(row: row, column: $0)].value } }
    }

    private func values(_ rows: [[(any Sendable)?]]) -> [[CellValue]] {
        rows.map { row in
            row.map { value -> CellValue in
                switch value {
                case let text as String: return .text(text)
                case let number as Double: return .number(number)
                default: return .empty
                }
            }
        }
    }

    private func setAmount(_ workbook: inout Workbook, row: Int, _ amount: Double) throws {
        let id = try #require(workbook.sheet(named: "Data")?.id)
        workbook[id]?[CellAddress(row: row, column: 2)] = Cell(value: .number(amount))
    }

    // MARK: - Reading

    @Test("A PivotTable's definition and cache are read: fields, areas, aggregation and records")
    func readsDefinitionAndCache() throws {
        let workbook = try read()
        let cache = try #require(workbook.pivotCaches.first)
        #expect(cache.cacheID == 5)
        #expect(cache.fields.map(\.name) == ["Region", "Product", "Amount"])
        #expect(cache.fields[0].sharedItems == [.text("East"), .text("West"), .text("North")])
        #expect(cache.fields[2].usesSharedItems == false)
        #expect(cache.source == .worksheet(sheet: "Data", reference: "A1:C7", name: nil))
        #expect(cache.records.count == 6)
        #expect(cache.records[1] == [.text("West"), .text("Apples"), .number(20)])

        let pivot = try #require(workbook.pivotTables.first)
        #expect(pivot.name == "PivotTable1")
        #expect(pivot.sheetID == workbook.sheet(named: "Pivot")?.id)
        #expect(pivot.location.a1 == "A3:D8")
        #expect(pivot.rowFields == [0])
        #expect(pivot.columnFields == [1])
        #expect(pivot.filters.isEmpty)
        #expect(pivot.dataFields == [PivotDataField(name: "Sum of Amount", field: 2, aggregation: .sum)])
        #expect(pivot.fields[0].items.map(\.sharedIndex) == [0, 2, 1, nil])
        #expect(pivot.area(of: 0) == .rows && pivot.area(of: 1) == .columns && pivot.area(of: 2) == .values)
        #expect(workbook.pivotTable(at: CellAddress(row: 5, column: 1), on: pivot.sheetID)?.id == pivot.id)

        let slicer = try #require(workbook.slicerCaches.first)
        #expect(slicer.sourceName == "Region")
        #expect(slicer.captions == ["Region"])
        #expect(workbook.slicerCaches(for: pivot).count == 1)
        #expect(workbook.unsupportedFeatures.lost.isEmpty)
    }

    // MARK: - Keeping

    @Test("An untouched PivotTable, its cache and its slicer come through a save byte for byte")
    func untouchedPartsSurvive() throws {
        let entries = try saved(try read())
        #expect(entries["xl/pivotTables/pivotTable1.xml"] == Data(PivotFixture.pivotTable.utf8))
        #expect(entries["xl/pivotCache/pivotCacheDefinition1.xml"] == Data(PivotFixture.cacheDefinition.utf8))
        #expect(entries["xl/pivotCache/pivotCacheRecords1.xml"] == Data(PivotFixture.cacheRecords.utf8))
        #expect(entries["xl/slicerCaches/slicerCache1.xml"] == Data(PivotFixture.slicerCache.utf8))
        #expect(entries["xl/slicers/slicer1.xml"] == Data(PivotFixture.slicer.utf8))
        #expect(entries["xl/pivotTables/_rels/pivotTable1.xml.rels"] != nil)
        #expect(entries["xl/pivotCache/_rels/pivotCacheDefinition1.xml.rels"] != nil)

        // The workbook declares the cache under the id its relationship now has.
        let workbookXML = try text(entries, "xl/workbook.xml")
        let relationships = XLSXReader.PackagePreservation.relationships(in: entries["xl/_rels/workbook.xml.rels"])
        let cacheID = try #require(relationships.first { $0.target == "pivotCache/pivotCacheDefinition1.xml" }?.id)
        #expect(workbookXML.contains("<pivotCaches><pivotCache cacheId=\"5\" r:id=\"\(cacheID)\"/></pivotCaches>"))
        let slicerID = try #require(relationships.first { $0.target == "slicerCaches/slicerCache1.xml" }?.id)
        #expect(workbookXML.contains("<x14:slicerCache r:id=\"\(slicerID)\"/>"))
        #expect(workbookXML.hasSuffix("</extLst></workbook>"))

        let sheet = try text(entries, "xl/worksheets/sheet2.xml")
        #expect(sheet.contains("<x14:slicerList><x14:slicer ") && sheet.contains("r:id=\"rId2\"/></x14:slicerList>"), "\(sheet)")
        let sheetRels = try text(entries, "xl/worksheets/_rels/sheet2.xml.rels")
        #expect(sheetRels.contains("pivotTables/pivotTable1.xml") && sheetRels.contains("slicers/slicer1.xml"))
        let types = try text(entries, "[Content_Types].xml")
        #expect(types.contains("/xl/pivotTables/pivotTable1.xml"))
        #expect(types.contains("/xl/pivotCache/pivotCacheRecords1.xml"))
        #expect(types.contains("/xl/slicerCaches/slicerCache1.xml"))

        // And the saved file reads back the same.
        let again = try XLSXReader.workbook(from: try ZipArchive.archive(entries: entries.map { ($0.key, $0.value) }))
        #expect(again.pivotTables.count == 1 && again.pivotCaches.first?.records.count == 6)
        #expect(again.slicerCaches.count == 1)
    }

    @Test("A PivotTable whose cache the workbook doesn't declare is dropped with its relationship")
    func undeclaredCacheDropsThePivot() throws {
        var entries = try ZipArchive.entries(in: try PivotFixture.data(withSlicer: false))
        let workbook = String(decoding: entries["xl/workbook.xml"]!, as: UTF8.self)
        entries["xl/workbook.xml"] = Data(workbook.replacingOccurrences(
            of: "<pivotCaches><pivotCache cacheId=\"5\" r:id=\"rId3\"/></pivotCaches>", with: "").utf8)
        let read = try XLSXReader.workbook(from: try ZipArchive.archive(entries: entries.map { ($0.key, $0.value) }))
        #expect(read.pivotTables.isEmpty)
        #expect(read.unsupportedFeatures.lost.contains(.pivotTables))
        let out = try saved(read)
        #expect(out["xl/pivotTables/pivotTable1.xml"] == nil)
        #expect(out["xl/pivotCache/pivotCacheDefinition1.xml"] == nil)
        #expect(!(try text(out, "xl/workbook.xml")).contains("pivotCache"))
        #expect(!(try text(out, "[Content_Types].xml")).contains("pivot"))
        #expect(out["xl/worksheets/_rels/sheet2.xml.rels"].map { String(decoding: $0, as: UTF8.self) }?
            .contains("pivotTable") != true)
    }
}
