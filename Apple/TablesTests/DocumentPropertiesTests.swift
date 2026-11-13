import Foundation
import Testing
@testable import Tables
@testable import TablesEngine

/// Title, author and the rest: read out of `docProps`, changed in the model,
/// and written back without disturbing anything else in those parts.
@Suite("Document properties")
struct DocumentPropertiesTests {

    // MARK: - Package construction

    private static let coreXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" \
        xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" \
        xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">\
        <dc:title>Budget &amp; Plan</dc:title><dc:subject>Finance</dc:subject><dc:creator>Ayane</dc:creator>\
        <cp:keywords>q3 budget</cp:keywords><dc:description>Draft for review</dc:description>\
        <cp:lastModifiedBy>Serika</cp:lastModifiedBy>\
        <dcterms:created xsi:type="dcterms:W3CDTF">2024-01-02T03:04:05Z</dcterms:created>\
        <dcterms:modified xsi:type="dcterms:W3CDTF">2024-02-03T04:05:06Z</dcterms:modified>\
        <cp:category>Reports</cp:category><cp:contentStatus>Draft</cp:contentStatus></cp:coreProperties>
        """

    private static let appXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" \
        xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">\
        <Application>Microsoft Excel</Application><Company>Atelier</Company><AppVersion>16.0300</AppVersion></Properties>
        """

    private static let customXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/custom-properties" \
        xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">\
        <property fmtid="{D5CDD505-2E9C-101B-9397-08002B2CF9AE}" pid="2" name="Project">\
        <vt:lpwstr>Tables</vt:lpwstr></property></Properties>
        """

    /// A workbook as Excel saves one: core, extended and custom properties.
    private func excelPackage() throws -> Data {
        var plain = Workbook()
        plain.sheets[0].cells[CellAddress(row: 0, column: 0)] = Cell(value: .text("Hello"))
        var entries = try ZipArchive.entries(in: try XLSXWriter.data(from: plain))
        entries["docProps/core.xml"] = Data(Self.coreXML.utf8)
        entries["docProps/app.xml"] = Data(Self.appXML.utf8)
        entries["docProps/custom.xml"] = Data(Self.customXML.utf8)
        let types = try text(entries, "[Content_Types].xml").replacingOccurrences(
            of: "</Types>",
            with: "<Override PartName=\"/docProps/custom.xml\" "
                + "ContentType=\"application/vnd.openxmlformats-officedocument.custom-properties+xml\"/></Types>")
        entries["[Content_Types].xml"] = Data(types.utf8)
        let relationships = try text(entries, "_rels/.rels").replacingOccurrences(
            of: "</Relationships>",
            with: "<Relationship Id=\"rId99\" "
                + "Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/custom-properties\" "
                + "Target=\"docProps/custom.xml\"/></Relationships>")
        entries["_rels/.rels"] = Data(relationships.utf8)
        return try ZipArchive.archive(entries: entries.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })
    }

    private func text(_ entries: [String: Data], _ path: String) throws -> String {
        let payload = try #require(entries[path], "\(path) is missing from the package")
        return String(decoding: payload, as: UTF8.self)
    }

    private func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    // MARK: - Reading

    @Test("Core and extended properties are read into the workbook")
    func readsProperties() throws {
        let workbook = try XLSXReader.workbook(from: try excelPackage())
        let properties = workbook.documentProperties
        // Custom properties are kept without being shown, and said so.
        #expect(workbook.unsupportedFeatures.preserved.contains(.documentProperties))
        #expect(properties.title == "Budget & Plan")
        #expect(properties.author == "Ayane")
        #expect(properties.subject == "Finance")
        #expect(properties.keywords == "q3 budget")
        #expect(properties.category == "Reports")
        #expect(properties.comments == "Draft for review")
        #expect(properties.lastModifiedBy == "Serika")
        #expect(properties.created == date("2024-01-02T03:04:05Z"))
        #expect(properties.modified == date("2024-02-03T04:05:06Z"))
        #expect(properties.application == "Microsoft Excel")
        #expect(properties.company == "Atelier")
    }

    @Test("A file without properties reads as empty ones")
    func readsNoProperties() throws {
        var entries = try ZipArchive.entries(in: try XLSXWriter.data(from: Workbook()))
        entries["docProps/core.xml"] = nil
        entries["docProps/app.xml"] = nil
        let data = try ZipArchive.archive(entries: entries.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })
        #expect(try XLSXReader.workbook(from: data).documentProperties == DocumentProperties())
    }

    // MARK: - Writing

    @Test("Unchanged properties come back byte for byte")
    func unchangedPartsSurvive() throws {
        let workbook = try XLSXReader.workbook(from: try excelPackage())
        let written = try ZipArchive.entries(in: try XLSXWriter.data(from: workbook))
        #expect(try text(written, "docProps/core.xml") == Self.coreXML)
        #expect(try text(written, "docProps/app.xml") == Self.appXML)
        #expect(try text(written, "docProps/custom.xml") == Self.customXML)
    }

    @Test("Edited properties are written back, and everything else in the parts is kept")
    func editsAreWrittenBack() throws {
        var workbook = try XLSXReader.workbook(from: try excelPackage())
        workbook.documentProperties.title = "Budget 2025"
        workbook.documentProperties.keywords = "budget, final"
        workbook.documentProperties.comments = ""
        workbook.stampDocumentProperties(savedAt: date("2025-06-07T08:09:10Z"), by: "Kotone")

        let written = try ZipArchive.entries(in: try XLSXWriter.data(from: workbook))
        let core = try text(written, "docProps/core.xml")
        #expect(core.contains("<dc:title>Budget 2025</dc:title>"))
        #expect(core.contains("<cp:keywords>budget, final</cp:keywords>"))
        #expect(!core.contains("description"))
        #expect(core.contains("<cp:lastModifiedBy>Kotone</cp:lastModifiedBy>"))
        #expect(core.contains(">2025-06-07T08:09:10Z</dcterms:modified>"))
        // What the panel doesn't show, and what wasn't changed, stays as it was.
        #expect(core.contains("<dcterms:created xsi:type=\"dcterms:W3CDTF\">2024-01-02T03:04:05Z</dcterms:created>"))
        #expect(core.contains("<cp:contentStatus>Draft</cp:contentStatus>"))
        #expect(core.contains("<dc:creator>Ayane</dc:creator>"))
        #expect(try text(written, "docProps/app.xml") == Self.appXML)
        #expect(try text(written, "docProps/custom.xml") == Self.customXML)

        let reopened = try XLSXReader.workbook(from: try XLSXWriter.data(from: workbook)).documentProperties
        #expect(reopened.title == "Budget 2025")
        #expect(reopened.keywords == "budget, final")
        #expect(reopened.comments.isEmpty)
        #expect(reopened.subject == "Finance")
        #expect(reopened.modified == date("2025-06-07T08:09:10Z"))
    }

    @Test("A property the file didn't have is added in its namespace")
    func addsMissingProperty() throws {
        var workbook = try XLSXReader.workbook(from: try excelPackage())
        workbook.documentProperties.category = ""
        var written = try ZipArchive.entries(in: try XLSXWriter.data(from: workbook))
        workbook = try XLSXReader.workbook(from: try ZipArchive.archive(
            entries: written.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }))
        #expect(workbook.documentProperties.category.isEmpty)

        workbook.documentProperties.category = "Plans <draft>"
        written = try ZipArchive.entries(in: try XLSXWriter.data(from: workbook))
        #expect(try text(written, "docProps/core.xml").contains("<cp:category>Plans &lt;draft&gt;</cp:category>"))
        let reopened = try XLSXReader.workbook(from: try ZipArchive.archive(
            entries: written.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }))
        #expect(reopened.documentProperties.category == "Plans <draft>")
    }

    @Test("A save without a name to use leaves the last author as it was")
    func noAuthorIsInvented() throws {
        var workbook = try XLSXReader.workbook(from: try excelPackage())
        workbook.stampDocumentProperties(savedAt: date("2025-06-07T08:09:10Z"), by: nil)
        #expect(workbook.documentProperties.lastModifiedBy == "Serika")
        workbook.stampDocumentProperties(savedAt: date("2025-06-07T08:09:10Z"), by: "  ")
        #expect(workbook.documentProperties.lastModifiedBy == "Serika")
        // An opened file keeps its own creation time and author.
        #expect(workbook.documentProperties.created == date("2024-01-02T03:04:05Z"))
        #expect(workbook.documentProperties.author == "Ayane")
    }

    // MARK: - New workbooks

    @Test("A workbook made in Tables is saved with core and extended properties")
    func newWorkbookGetsProperties() throws {
        var workbook = Workbook()
        workbook.documentProperties.title = "Groceries"
        workbook.stampDocumentProperties(savedAt: date("2025-06-07T08:09:10Z"), by: "Kotone")

        let data = try XLSXWriter.data(from: workbook)
        let written = try ZipArchive.entries(in: data)
        let core = try text(written, "docProps/core.xml")
        #expect(core.contains("<dc:title>Groceries</dc:title>"))
        #expect(core.contains("<dc:creator>Kotone</dc:creator>"))
        #expect(core.contains("<cp:lastModifiedBy>Kotone</cp:lastModifiedBy>"))
        #expect(core.contains("<dcterms:created xsi:type=\"dcterms:W3CDTF\">2025-06-07T08:09:10Z</dcterms:created>"))
        #expect(try text(written, "docProps/app.xml").contains("<Application>Tables</Application>"))

        let types = try text(written, "[Content_Types].xml")
        #expect(types.contains("<Override PartName=\"/docProps/core.xml\" "
            + "ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/>"))
        #expect(types.contains("<Override PartName=\"/docProps/app.xml\" "
            + "ContentType=\"application/vnd.openxmlformats-officedocument.extended-properties+xml\"/>"))
        let relationships = try text(written, "_rels/.rels")
        #expect(relationships.contains("metadata/core-properties\" Target=\"docProps/core.xml\""))
        #expect(relationships.contains("relationships/extended-properties\" Target=\"docProps/app.xml\""))

        let reopened = try XLSXReader.workbook(from: data)
        #expect(reopened.documentProperties.title == "Groceries")
        #expect(reopened.documentProperties.application == "Tables")
        // Read back as Excel's own properties would be: nothing to warn about.
        #expect(!reopened.unsupportedFeatures.lost.contains(.documentProperties))
        // Saved again, it keeps one set of parts rather than gaining another.
        let again = try text(try ZipArchive.entries(in: try XLSXWriter.data(from: reopened)), "_rels/.rels")
        #expect(again.components(separatedBy: "docProps/core.xml").count == 2)
    }

    @Test("A new document is created when it is made, not when it is saved")
    func newDocumentCreationTime() throws {
        let before = Date()
        let file = WorkbookFile()
        let created = try #require(file.workbook.documentProperties.created)
        #expect(created >= before && created <= Date())
        // A file read from disk keeps the time it says.
        let opened = WorkbookFile(workbook: try XLSXReader.workbook(from: try excelPackage()))
        #expect(opened.workbook.documentProperties.created == date("2024-01-02T03:04:05Z"))
    }
}
