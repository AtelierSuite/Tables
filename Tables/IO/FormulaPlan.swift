import Foundation

/// How each formula is stored: as an ordinary formula where Excel's old rules
/// give the same answer, and otherwise as an array formula, marked dynamic
/// when it spills rather than filling a fixed block.
struct FormulaPlan {
    enum Form {
        case plain(String)
        case array(String, block: CellRange, dynamic: Bool)
    }

    static let metadataPath = "xl/metadata.xml"
    static let metadataContentType = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheetMetadata+xml"
    static let metadataRelationshipType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/sheetMetadata"

    /// The metadata Excel writes to mark a formula as a dynamic array. Cells
    /// carrying `cm="1"` point at its one entry.
    static let metadataPart = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <metadata xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
        xmlns:xda="http://schemas.microsoft.com/office/spreadsheetml/2017/dynamicarray">\
        <metadataTypes count="1"><metadataType name="XLDAPR" minSupportedVersion="120000" copy="1" pasteAll="1" \
        pasteValues="1" merge="1" splitFirst="1" rowColShift="1" clearFormats="1" clearComments="1" assign="1" \
        coerce="1" cellMeta="1"/></metadataTypes>\
        <futureMetadata name="XLDAPR" count="1"><bk><extLst><ext uri="{bdbb8cdc-fa1e-496e-a857-3c3f30c029c3}">\
        <xda:dynamicArrayProperties fDynamic="1" fCollapsed="0"/></ext></extLst></bk></futureMetadata>\
        <cellMetadata count="1"><bk><rc t="1" v="0"/></bk></cellMetadata></metadata>
        """

    private(set) var forms: [Worksheet.ID: [CellAddress: Form]] = [:]
    private(set) var usesDynamicArrays = false

    init(workbook: Workbook) {
        let isRangeName = workbook.isRangeName
        for sheet in workbook.sheets {
            var sheetForms: [CellAddress: Form] = [:]
            let tables = workbook.tables.filter { $0.sheetID == sheet.id }
            for (address, cell) in sheet.cells {
                guard let original = cell.formula else { continue }
                let formula = Self.writingOutTableBodies(original, on: sheet, in: workbook)
                let tableName = tables.first { $0.range.contains(address) }?.name
                func toFile(_ text: String) -> String { FormulaDialect.toFile(text, tableName: tableName) }
                if let extent = cell.arrayExtent {
                    let block = CellRange(start: address, end: CellAddress(
                        row: address.row + extent.rows - 1, column: address.column + extent.columns - 1))
                    sheetForms[address] = .array(toFile(formula), block: block, dynamic: false)
                } else if let legacy = FormulaDialect.legacyForm(formula, isRangeName: isRangeName) {
                    sheetForms[address] = .plain(toFile(legacy))
                } else {
                    let block = sheet.spills[address] ?? CellRange(address)
                    sheetForms[address] = .array(toFile(formula), block: block, dynamic: true)
                    usesDynamicArrays = true
                }
            }
            forms[sheet.id] = sheetForms
        }
    }

    /// A formula with each whole column or row of a table read from Numbers
    /// written out as the body it covers there: Excel reads a whole column
    /// as every cell in it, header and footer rows included, and a total in
    /// the footer would read itself.
    static func writingOutTableBodies(_ formula: String, on sheet: Worksheet, in workbook: Workbook) -> String {
        guard workbook.sheets.contains(where: { $0.tableEdges != nil }),
              let syntax = try? FormulaParser.parseSyntax(formula) else { return formula }
        let source = Array(formula)
        var replacements: [(range: Range<Int>, text: String)] = []
        func visit(_ syntax: FormulaSyntax) {
            if !syntax.isGroup, case .range(let name, let start, let end) = syntax.node {
                let target = name.map { name in
                    workbook.sheets.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
                } ?? sheet
                if let target, let edges = target.tableEdges,
                   let text = body(String(source[syntax.range.clamped(to: 0..<source.count)]),
                                   start: start, end: end, of: target, edges: edges) {
                    replacements.append((syntax.range, text))
                }
            }
            syntax.children.forEach(visit)
        }
        visit(syntax)
        var result = source
        for replacement in replacements.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            result.replaceSubrange(replacement.range, with: Array(replacement.text))
        }
        return String(result)
    }

    /// The body rows of whole columns, or the body columns of whole rows, as
    /// a range keeping the sheet and `$` anchors `text` had; nil for any
    /// other range, or a table without a body.
    private static func body(
        _ text: String, start: CellAddress, end: CellAddress, of sheet: Worksheet, edges: TableEdges
    ) -> String? {
        let columns = start.row == 0 && end.row == SheetLimits.maxRow
        let rows = start.column == 0 && end.column == SheetLimits.maxColumn
        guard columns != rows else { return nil }
        // A sheet name goes before the last "!".
        let bang = text.lastIndex(of: "!")
        let prefix = bang.map { String(text[...$0]) } ?? ""
        let reference = bang.map { String(text[text.index(after: $0)...]) } ?? text
        let anchors = reference.split(separator: ":").map { $0.hasPrefix("$") ? "$" : "" }
        guard anchors.count == 2 else { return nil }
        if columns {
            let first = edges.headerRows, last = sheet.rowCount - 1 - edges.footerRows
            guard first <= last else { return nil }
            return prefix + anchors[0] + CellAddress.columnName(start.column) + "$\(first + 1):"
                + anchors[1] + CellAddress.columnName(end.column) + "$\(last + 1)"
        }
        let first = edges.headerColumns, last = sheet.columnCount - 1
        guard first <= last else { return nil }
        return prefix + "$" + CellAddress.columnName(first) + anchors[0] + "\(start.row + 1):"
            + "$" + CellAddress.columnName(last) + anchors[1] + "\(end.row + 1)"
    }
}

extension Workbook {
    /// Whether a defined name stands for more than one cell, which decides
    /// where Excel's old rules intersected it down to one.
    var isRangeName: (String) -> Bool {
        let names = Set(definedNames.compactMap { name -> String? in
            switch try? FormulaParser.parse(name.formula) {
            case .range(_, let start, let end)? where start != end: return name.name.lowercased()
            case .sheetSpan?: return name.name.lowercased()
            default: return nil
            }
        })
        return { names.contains($0.lowercased()) }
    }
}
