import Foundation

/// Combining workbooks: copying every sheet of one workbook into another, as
/// Excel's "Move or Copy" does with "Create a copy" into another book.
///
/// The sheets come across whole: cells with their values, formulas and
/// formatting, the sheet's layout, notes, charts and controls, and the parts
/// of the file that hang off the sheet — its tables, pictures and conditional
/// formats. What clashes with the receiving workbook is renamed, and the
/// formulas that named it follow: a second `Sales` sheet becomes `Sales 2`,
/// a second `Table1` becomes `Table1_2`. A workbook-level name that means
/// something else in the receiving workbook stays with the sheets it came
/// with, scoped to each of them. Macros, and anything else that belongs to
/// the workbook as a whole, stay with the workbook they came from.
extension Workbook {
    /// The first workbook with the sheets of the others added after its own,
    /// in order, and recalculated.
    public static func combining(_ workbooks: [Workbook]) -> Workbook {
        guard var combined = workbooks.first else { return Workbook() }
        for other in workbooks.dropFirst() { combined.appendSheets(of: other) }
        combined.recalculate()
        return combined
    }

    /// Adds copies of `other`'s sheets after this workbook's, and returns
    /// their ids. Formulas are not recalculated.
    @discardableResult
    public mutating func appendSheets(of other: Workbook) -> [Worksheet.ID] {
        var incoming = other

        // Sheets are told apart by id everywhere, so a copy of a sheet this
        // workbook already holds — the same workbook combined with itself —
        // needs ids of its own.
        for sheet in incoming.sheets where index(of: sheet.id) != nil {
            incoming.replaceSheetID(sheet.id, with: UUID())
        }

        let tableRenames = renamesForTables(of: incoming)
        let differentialOffset = adoptDifferentialFormats(of: incoming)
        var importer = PartImporter(source: incoming.preservedPackage, tableRenames: tableRenames,
                                    differentialOffset: differentialOffset)

        var sheetRenames: [String: String] = [:]
        var added: [Worksheet.ID] = []
        for var sheet in incoming.sheets {
            let name = uniqueSheetName(basedOn: sheet.name)
            if name != sheet.name { sheetRenames[sheet.name.lowercased()] = name }
            sheet.name = name
            // Code names tie sheets to the macros of the workbook they came
            // from, and those stay behind; the file's sheet numbers are that
            // file's.
            sheet.codeName = nil
            sheet.fileSheetID = nil
            sheet.origins = nil
            importer.carryParts(of: &sheet, into: &preservedPackage)
            sheets.append(sheet)
            added.append(sheet.id)
        }

        let rename = { (formula: String) in
            FormulaNameRewriter.rewrite(formula, sheets: sheetRenames, tables: tableRenames)
        }
        if !sheetRenames.isEmpty || !tableRenames.isEmpty {
            for index in sheets.indices where added.contains(sheets[index].id) {
                for (address, cell) in sheets[index].cells {
                    guard let formula = cell.formula else { continue }
                    let rewritten = rename(formula)
                    if rewritten != formula { sheets[index].cells[address]?.formula = rewritten }
                }
                for rule in sheets[index].conditionalRules.indices {
                    sheets[index].conditionalRules[rule].formulas =
                        sheets[index].conditionalRules[rule].formulas.map(rename)
                }
            }
        }

        for var table in incoming.tables {
            table.name = tableRenames[table.name.lowercased()] ?? table.name
            tables.append(table)
        }

        for var name in incoming.definedNames {
            name.formula = rename(name.formula)
            guard name.scope == nil else {
                definedNames.append(name)
                continue
            }
            let existing = definedNames.first {
                $0.scope == nil && $0.name.compare(name.name, options: .caseInsensitive) == .orderedSame
            }
            guard let existing else {
                definedNames.append(name)
                continue
            }
            // The same name meaning something else here: each sheet that came
            // with it keeps its meaning, as a name of its own.
            guard existing.formula != name.formula, !name.isBuiltIn else { continue }
            for id in added where incoming.sheets.contains(where: { $0.id == id && !$0.isChartSheet }) {
                var scoped = name
                scoped.scope = id
                definedNames.append(scoped)
            }
        }

        canvases += incoming.canvases
        return added
    }

    /// Gives a sheet a new id, and points everything that named the old one at it.
    private mutating func replaceSheetID(_ oldID: Worksheet.ID, with newID: Worksheet.ID) {
        for index in sheets.indices {
            if sheets[index].id == oldID { sheets[index].id = newID }
            for chart in sheets[index].charts.indices { sheets[index].charts[chart].retarget(from: oldID, to: newID) }
            for control in sheets[index].formControls.indices {
                if sheets[index].formControls[control].linkedCell?.sheetID == oldID {
                    sheets[index].formControls[control].linkedCell?.sheetID = newID
                }
                if sheets[index].formControls[control].listRange?.sheetID == oldID {
                    sheets[index].formControls[control].listRange?.sheetID = newID
                }
            }
        }
        for index in definedNames.indices where definedNames[index].scope == oldID {
            definedNames[index].scope = newID
        }
        for index in tables.indices where tables[index].sheetID == oldID { tables[index].sheetID = newID }
        for canvas in canvases.indices {
            for table in canvases[canvas].tables.indices where canvases[canvas].tables[table].sheetID == oldID {
                canvases[canvas].tables[table].sheetID = newID
            }
        }
        if let part = preservedPackage.sheetRelationshipParts.removeValue(forKey: oldID) {
            preservedPackage.sheetRelationshipParts[newID] = part
        }
    }

    /// New names for `other`'s tables that this workbook already uses, keyed
    /// by the old name in lower case. Table names share one namespace with
    /// defined names and have to be unique across the workbook.
    private func renamesForTables(of other: Workbook) -> [String: String] {
        var taken = Set(tables.map { $0.name.lowercased() } + definedNames.map { $0.name.lowercased() })
        var renames: [String: String] = [:]
        for table in other.tables {
            var name = table.name
            if taken.contains(name.lowercased()) {
                var suffix = 2
                while taken.contains("\(table.name)_\(suffix)".lowercased()) { suffix += 1 }
                name = "\(table.name)_\(suffix)"
                renames[table.name.lowercased()] = name
            }
            taken.insert(name.lowercased())
        }
        return renames
    }

    /// Adds `other`'s differential formats — the styles conditional formats
    /// and tables point at by position — after this workbook's own, and
    /// returns how far its positions move.
    private mutating func adoptDifferentialFormats(of other: Workbook) -> Int {
        func formats(_ elements: [PreservedElement]) -> [XMLElement] {
            guard let xml = elements.first(where: { $0.name == "dxfs" })?.xml,
                  let root = try? XMLLite.parse(Data(xml.utf8)) else { return [] }
            return root.children(named: "dxf")
        }
        let own = formats(preservedPackage.styleSheetElements)
        let theirs = formats(other.preservedPackage.styleSheetElements)
        guard !theirs.isEmpty else { return own.count }
        let pieces = (own + theirs).compactMap { XMLLite.serialize($0) }
        guard pieces.count == own.count + theirs.count else { return own.count }
        let merged = PreservedElement(name: "dxfs", xml: "<dxfs count=\"\(pieces.count)\">" + pieces.joined() + "</dxfs>")
        if let index = preservedPackage.styleSheetElements.firstIndex(where: { $0.name == "dxfs" }) {
            preservedPackage.styleSheetElements[index] = merged
        } else {
            preservedPackage.styleSheetElements.append(merged)
        }
        return own.count
    }
}

// MARK: - Parts

/// Copies the parts a sheet's relationships reach from one package into
/// another, under file names the other does not already use.
private struct PartImporter {
    let source: PreservedPackage
    let tableRenames: [String: String]
    let differentialOffset: Int
    /// Source path → the path it was given in the destination.
    private var imported: [String: String] = [:]

    init(source: PreservedPackage, tableRenames: [String: String], differentialOffset: Int) {
        self.source = source
        self.tableRenames = tableRenames
        self.differentialOffset = differentialOffset
    }

    private typealias Packaging = XLSXReader.PackagePreservation

    mutating func carryParts(of sheet: inout Worksheet, into destination: inout PreservedPackage) {
        let directory = sheet.isChartSheet ? "xl/chartsheets" : "xl/worksheets"
        if let payload = source.sheetRelationshipParts[sheet.id] {
            destination.sheetRelationshipParts[sheet.id] = relationships(payload, in: directory, into: &destination)
        }
        if let payload = sheet.preservedVMLRelationships {
            sheet.preservedVMLRelationships = relationships(payload, in: "xl/drawings", into: &destination)
        }
        for anchor in sheet.preservedDrawingAnchors.indices {
            for index in sheet.preservedDrawingAnchors[anchor].relationships.indices {
                let relationship = sheet.preservedDrawingAnchors[anchor].relationships[index]
                guard relationship.isPackagePart,
                      let path = importPart(relationship.target, into: &destination) else { continue }
                sheet.preservedDrawingAnchors[anchor].relationships[index].target = path
            }
            if let target = sheet.preservedDrawingAnchors[anchor].picture?.target,
               let path = importPart(target, into: &destination) {
                sheet.preservedDrawingAnchors[anchor].picture?.target = path
            }
        }
        for control in sheet.formControls.indices {
            sheet.formControls[control].source.propertiesPart = sheet.formControls[control].source.propertiesPart
                .flatMap { importPart($0, into: &destination) }
        }
        sheet.preservedElements = sheet.preservedElements.map { element in
            guard element.name == "conditionalFormatting" else { return element }
            return PreservedElement(name: element.name,
                                    xml: Self.shiftingDifferentialFormats(element.xml, by: differentialOffset))
        }
    }

    /// A `_rels` part with its internal targets imported and pointed at their new names.
    private mutating func relationships(
        _ payload: Data, in directory: String, into destination: inout PreservedPackage
    ) -> Data {
        guard let root = try? XMLLite.parse(payload) else { return payload }
        for element in root.children(named: "Relationship") {
            guard let target = element.attribute("Target"), element.attribute("TargetMode") != "External",
                  !target.hasPrefix("#") else { continue }
            let path = Packaging.absolutePath(target, relativeTo: directory)
            guard let newPath = importPart(path, into: &destination), newPath != path else { continue }
            // Parts keep their folder, so only the file name changes.
            let fileName = newPath.split(separator: "/").last.map(String.init) ?? newPath
            let folder = target.split(separator: "/", omittingEmptySubsequences: false).dropLast()
                .joined(separator: "/")
            element.setAttribute("Target", folder.isEmpty && !target.hasPrefix("/") ? fileName : folder + "/" + fileName)
        }
        guard let xml = XMLLite.serialize(root) else { return payload }
        return Data(("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" + xml).utf8)
    }

    /// Copies a part, and what its own relationships reach, into the
    /// destination; returns its path there, or nil when the source has no
    /// such part (one the writer generates).
    private mutating func importPart(_ path: String, into destination: inout PreservedPackage) -> String? {
        if let done = imported[path] { return done }
        guard var data = source.parts[path] else { return nil }
        let newPath = Self.freePath(for: path, avoiding: destination.parts)
        imported[path] = newPath

        if path.hasPrefix("xl/tables/") {
            data = table(data, id: Self.nextTableID(in: destination))
        }
        destination.parts[newPath] = data
        if let payload = source.parts[Packaging.relationshipsPath(for: path)] {
            destination.parts[Packaging.relationshipsPath(for: newPath)] =
                relationships(payload, in: Packaging.directory(of: path), into: &destination)
        }
        if let type = source.contentTypeOverrides["/" + path] {
            destination.contentTypeOverrides["/" + newPath] = type
        }
        if let dot = path.lastIndex(of: "."), let type = source.contentTypeDefaults[String(path[path.index(after: dot)...])] {
            let ext = String(path[path.index(after: dot)...])
            if destination.contentTypeDefaults[ext] == nil { destination.contentTypeDefaults[ext] = type }
        }
        return newPath
    }

    /// A table part with a workbook-unique id, its new name if it was
    /// renamed, and its styles pointing where the differential formats now are.
    private func table(_ data: Data, id: Int) -> Data {
        let shifted = Data(Self.shiftingDifferentialFormats(String(decoding: data, as: UTF8.self),
                                                            by: differentialOffset).utf8)
        guard let root = try? XMLLite.parse(shifted) else { return shifted }
        root.setAttribute("id", String(id))
        let current = root.attribute("displayName") ?? root.attribute("name") ?? ""
        if let renamed = tableRenames[current.lowercased()] {
            root.setAttribute("name", renamed)
            root.setAttribute("displayName", renamed)
        }
        guard let xml = XMLLite.serialize(root) else { return shifted }
        return Data(("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" + xml).utf8)
    }

    /// Excel numbers every table in a workbook uniquely.
    private static func nextTableID(in package: PreservedPackage) -> Int {
        let ids = package.parts.filter { $0.key.hasPrefix("xl/tables/") && !$0.key.hasSuffix(".rels") }
            .compactMap { try? XMLLite.parse($0.value).attribute("id").flatMap(Int.init) }
        return (ids.max() ?? 0) + 1
    }

    /// `path` itself when the destination doesn't use it; otherwise the same
    /// name with the first free number, as `table3.xml` beside `table1.xml`.
    static func freePath(for path: String, avoiding parts: [String: Data]) -> String {
        guard parts[path] != nil else { return path }
        let folder = Packaging.directory(of: path)
        let file = folder.isEmpty ? path : String(path.dropFirst(folder.count + 1))
        let dot = file.lastIndex(of: ".") ?? file.endIndex
        let ext = String(file[dot...])
        let stem = String(file[..<dot].reversed().drop(while: \.isNumber).reversed())
        var number = 1
        while true {
            let candidate = (folder.isEmpty ? "" : folder + "/") + "\(stem)\(number)\(ext)"
            if parts[candidate] == nil { return candidate }
            number += 1
        }
    }

    /// Adds `offset` to every `dxfId`, and to the `…DxfId` attributes tables
    /// use, in a fragment of XML.
    static func shiftingDifferentialFormats(_ xml: String, by offset: Int) -> String {
        guard offset != 0 else { return xml }
        var result = ""
        var rest = Substring(xml)
        while let marker = rest.range(of: "xfId=\"") {
            let before = rest[..<marker.lowerBound]
            result += before
            result += rest[marker]
            rest = rest[marker.upperBound...]
            let digits = rest.prefix(while: \.isNumber)
            // `dxfId` and `…DxfId`, not a cell format's `xfId`.
            let isDifferential = before.hasSuffix("d") || before.hasSuffix("D")
            if isDifferential, !digits.isEmpty, let value = Int(digits) {
                result += String(value + offset)
                rest = rest.dropFirst(digits.count)
            }
        }
        return result + rest
    }
}

// MARK: - Formulas

/// Renames sheets and tables inside formula text, leaving everything else as
/// it was written.
enum FormulaNameRewriter {
    /// `sheets` and `tables` map lower-cased old names to new ones.
    static func rewrite(_ formula: String, sheets: [String: String], tables: [String: String]) -> String {
        guard !sheets.isEmpty || !tables.isEmpty,
              let tokens = try? FormulaLexer.tokenizeWithOffsets(formula) else { return formula }
        func name(_ token: FormulaToken) -> String? {
            switch token {
            case .identifier(let text), .quotedName(let text): return text
            default: return nil
            }
        }
        var edits: [(range: Range<Int>, text: String)] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index].token
            let next = index + 1 < tokens.count ? tokens[index + 1].token : nil
            // An external workbook's sheet, `[1]Sales!A1`, is not ours.
            var isExternal = false
            if index > 0, case .bracket = tokens[index - 1].token { isExternal = true }
            if let text = name(token), !isExternal {
                // `Jan:Mar!A1`, a reference through several sheets.
                if next == .colon, index + 3 < tokens.count, let last = name(tokens[index + 2].token),
                   tokens[index + 3].token == .bang {
                    let first = sheets[text.lowercased()] ?? text
                    let end = sheets[last.lowercased()] ?? last
                    if first != text || end != last {
                        edits.append((tokens[index].range.lowerBound..<tokens[index + 2].range.upperBound,
                                      ChartReference.quotedSheetName(first + ":" + end)))
                    }
                    index += 4
                    continue
                }
                if next == .bang {
                    let parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
                    let renamed = parts.map { sheets[$0.lowercased()] ?? $0 }
                    if renamed != parts {
                        edits.append((tokens[index].range,
                                      ChartReference.quotedSheetName(renamed.joined(separator: ":"))))
                    }
                    index += 2
                    continue
                }
                if case .identifier = token, case .bracket = next, let renamed = tables[text.lowercased()] {
                    edits.append((tokens[index].range, renamed))
                }
            }
            index += 1
        }
        guard !edits.isEmpty else { return formula }
        var characters = Array(formula)
        for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            characters.replaceSubrange(edit.range, with: Array(edit.text))
        }
        return String(characters)
    }
}
