import Foundation

/// A worksheet's `<hyperlinks>`, read into the model and written afresh.
///
/// A link to a place in the workbook carries it inline, in `location`. A link
/// outside it names a relationship of the sheet instead, whose target is the
/// address; those relationships are written afresh with the list.
enum HyperlinkParts {
    static let relationshipType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink"

    /// More cells than this in one link's range are left out: a link set on
    /// whole columns would otherwise become a million entries.
    static let maximumCellsPerLink = 100_000

    /// The links in a worksheet, by cell, and the ids of the relationships
    /// they used, which the sheet's kept `_rels` must no longer carry.
    static func read(
        _ sheetXML: XMLElement, sheetPath: String, entries: [String: Data]
    ) -> (links: [CellAddress: CellHyperlink], relationshipIDs: Set<String>) {
        guard let list = sheetXML.firstChild(named: "hyperlinks") else { return ([:], []) }
        let relationships = XLSXReader.PackagePreservation.relationships(
            in: entries[XLSXReader.PackagePreservation.relationshipsPath(for: sheetPath)])
        var targets: [String: String] = [:]
        for relationship in relationships where relationship.type == relationshipType {
            if let id = relationship.id { targets[id] = relationship.target }
        }

        var links: [CellAddress: CellHyperlink] = [:]
        var used: Set<String> = []
        for element in list.children(named: "hyperlink") {
            guard let ref = element.attribute("ref") else { continue }
            var link = CellHyperlink(
                location: nonEmpty(element.attribute("location")),
                display: nonEmpty(element.attribute("display")),
                tooltip: nonEmpty(element.attribute("tooltip")))
            // `r:id`: attributes are matched by their local name.
            if let id = element.attribute("id") {
                used.insert(id)
                link.address = targets[id].flatMap(nonEmpty)
            }
            // A link naming neither a place nor a relationship that resolves
            // goes nowhere, and writing it back would leave a dangling id.
            guard link.address != nil || link.location != nil else { continue }
            for range in ConditionalRule.ranges(sqref: ref) {
                let box = range.normalized
                let rows = box.end.row - box.start.row + 1
                let columns = box.end.column - box.start.column + 1
                guard rows * columns <= maximumCellsPerLink else { continue }
                box.forEachAddress { address in
                    // The first link on a cell is the one Excel follows.
                    if links[address] == nil { links[address] = link }
                }
            }
        }
        return (links, used)
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    /// The `<hyperlinks>` element for a sheet's links, in cell order, and the
    /// relationships its outside addresses need. `relate` adds one to the
    /// sheet's `_rels` and answers its id.
    static func element(
        for links: [CellAddress: CellHyperlink], rowCount: Int, columnCount: Int,
        relate: (_ target: String) -> String
    ) -> String? {
        let addresses = links.keys.filter { $0.row < rowCount && $0.column < columnCount }.sorted()
        guard !addresses.isEmpty else { return nil }
        var xml = "<hyperlinks>"
        for address in addresses {
            guard let link = links[address] else { continue }
            xml += "<hyperlink ref=\"\(address.a1)\""
            if let target = link.address, !target.isEmpty { xml += " r:id=\"\(relate(target))\"" }
            if let location = link.location, !location.isEmpty {
                xml += " location=\"\(XMLLite.escape(location))\""
            }
            if let display = link.display, !display.isEmpty { xml += " display=\"\(XMLLite.escape(display))\"" }
            if let tooltip = link.tooltip, !tooltip.isEmpty { xml += " tooltip=\"\(XMLLite.escape(tooltip))\"" }
            xml += "/>"
        }
        return xml + "</hyperlinks>"
    }
}
