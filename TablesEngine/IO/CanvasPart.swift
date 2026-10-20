import Foundation

/// The canvases of an Excel workbook, kept in a custom XML part of the
/// package: the place Office keeps add-ins' data, which Excel carries
/// through its own saves without showing it.
///
/// Excel sees every sheet as a sheet of its own; nothing it shows depends
/// on the part. Tables are found by the number the file knows each sheet
/// by, so renaming one in Excel keeps it on its canvas, and by name when
/// that number has gone: a sheet that can't be found any more just drops
/// off, and its canvas with it once it has fewer than two.
enum CanvasPart {
    static let namespace = "http://schemas.tsubuzaki.com/tables/2026/canvas"
    static let path = "customXml/item1.xml"
    static let propertiesPath = "customXml/itemProps1.xml"
    static let relationshipType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/customXml"
    static let propertiesRelationshipType =
        "http://schemas.openxmlformats.org/officeDocument/2006/relationships/customXmlProps"
    static let propertiesContentType = "application/vnd.openxmlformats-officedocument.customXmlProperties+xml"
    /// The part's identity in the package, the same in every file Tables writes.
    private static let itemID = "{6F1C2B7E-3D4A-4E59-9B8C-1A2D3E4F5061}"

    // MARK: Reading

    /// The canvases the package's part describes, for sheets read from it.
    static func canvases(
        entries: [String: Data], workbookRelationships: [XLSXReader.PackagePreservation.RelationshipEntry],
        sheets: [Worksheet]
    ) -> [SheetCanvas] {
        for relationship in workbookRelationships where relationship.type == relationshipType {
            guard let path = XLSXReader.PackagePreservation.packagePath(of: relationship, relativeTo: "xl"),
                  let data = entries[path], let root = try? XMLLite.parse(data),
                  root.name == "canvases", root.qualifiedAttributes["xmlns"] == namespace else { continue }
            return canvases(in: root, sheets: sheets)
        }
        return []
    }

    private static func canvases(in root: XMLElement, sheets: [Worksheet]) -> [SheetCanvas] {
        var placed: Set<Worksheet.ID> = []
        var canvases: [SheetCanvas] = []
        for element in root.children(named: "canvas") {
            var canvas = SheetCanvas(name: element.attribute("name") ?? "", tables: [])
            for table in element.children(named: "table") {
                let byNumber = table.attribute("sheetId").flatMap(Int.init).flatMap { id in
                    sheets.first { $0.fileSheetID == id }
                }
                let byName = table.attribute("sheet").flatMap { name in sheets.first { $0.name == name } }
                guard let sheet = byNumber ?? byName, !sheet.isChartSheet,
                      placed.insert(sheet.id).inserted else { continue }
                canvas.tables.append(SheetCanvas.Table(
                    sheetID: sheet.id,
                    x: table.attribute("x").flatMap(Double.init) ?? SheetCanvas.margin,
                    y: table.attribute("y").flatMap(Double.init) ?? SheetCanvas.margin,
                    showsName: table.attribute("showName") != "0"
                ))
            }
            if canvas.name.isEmpty, let first = canvas.tables.first.flatMap({ table in
                sheets.first { $0.id == table.sheetID }
            }) {
                canvas.name = first.name
            }
            if canvas.tables.count >= 2 { canvases.append(canvas) }
        }
        return canvases
    }

    // MARK: Writing

    /// The part, or nil for a workbook without canvases, which then writes
    /// none at all. `sheetIDs` are the numbers the sheets are written with.
    static func part(for workbook: Workbook, sheetIDs: [Int]) -> String? {
        let canvases = workbook.canvases.filter { $0.tables.count >= 2 }
        guard !canvases.isEmpty else { return nil }
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        xml += "<canvases xmlns=\"\(namespace)\">"
        for canvas in canvases {
            xml += "<canvas name=\"\(XMLLite.escape(canvas.name))\">"
            for table in canvas.tables {
                guard let index = workbook.index(of: table.sheetID) else { continue }
                xml += "<table sheetId=\"\(sheetIDs[index])\""
                xml += " sheet=\"\(XMLLite.escape(workbook.sheets[index].name))\""
                xml += " x=\"\(number(table.x))\" y=\"\(number(table.y))\""
                if !table.showsName { xml += " showName=\"0\"" }
                xml += "/>"
            }
            xml += "</canvas>"
        }
        xml += "</canvases>"
        return xml
    }

    /// The properties part naming the part's schema, which Office expects
    /// beside every custom XML part.
    static let propertiesPart = """
        <?xml version="1.0" encoding="UTF-8" standalone="no"?>
        <ds:datastoreItem ds:itemID="\(itemID)" \
        xmlns:ds="http://schemas.openxmlformats.org/officeDocument/2006/customXml">\
        <ds:schemaRefs><ds:schemaRef ds:uri="\(namespace)"/></ds:schemaRefs></ds:datastoreItem>
        """

    /// The part's own relationships, to its properties.
    static let relationshipsPart = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="\(propertiesRelationshipType)" Target="itemProps1.xml"/></Relationships>
        """

    private static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }
}
