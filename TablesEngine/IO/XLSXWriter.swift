import Foundation

/// Serializes the app's model back into an Office Open XML workbook.
public enum XLSXWriter {
    /// `macroEnabled` writes an `.xlsm`, which keeps any macros the workbook
    /// came with. Without it the macros are left out, as Excel does when a
    /// macro workbook is saved as `.xlsx`.
    public static func data(from workbook: Workbook, macroEnabled: Bool = false) throws -> Data {
        let strings = SharedStringTable(workbook: workbook)
        let styles = StyleTable(workbook: workbook)
        let preserved = macroEnabled ? workbook.preservedPackage : workbook.preservedPackage.removingMacros()
        let drawings = DrawingPlan(workbook: workbook)
        let formulas = FormulaPlan(workbook: workbook)
        let comments = CommentPlan(workbook: workbook, preserved: preserved)

        var parts: [(path: String, data: Data)] = [
            (
                "[Content_Types].xml",
                contentTypes(workbook: workbook, drawings: drawings, preserved: preserved,
                             hasMetadata: formulas.usesDynamicArrays, comments: comments,
                             macroEnabled: macroEnabled).utf8Data
            ),
            ("_rels/.rels", rootRelationships(preserved: preserved).utf8Data),
            ("xl/workbook.xml", workbookPart(workbook).utf8Data),
            (
                "xl/_rels/workbook.xml.rels",
                workbookRelationships(workbook: workbook, drawings: drawings, preserved: preserved,
                                      hasMetadata: formulas.usesDynamicArrays,
                                      hasPersons: comments.personsPath != nil).utf8Data
            ),
            ("xl/styles.xml", styles.xml.utf8Data),
            ("xl/sharedStrings.xml", strings.xml.utf8Data),
        ]
        if formulas.usesDynamicArrays { parts.append((FormulaPlan.metadataPath, FormulaPlan.metadataPart.utf8Data)) }
        if let personsPath = comments.personsPath {
            parts.append((personsPath, CommentParts.personsPart(comments.authors).utf8Data))
        }
        for (index, sheet) in workbook.sheets.enumerated() {
            let preservedRelationships = preserved.sheetRelationshipParts[sheet.id]
            let sheetDrawing = drawings.sheets[sheet.id]
            let path = drawings.sheetPath(at: index, of: sheet)

            // A sheet's `_rels` follows it to its new position: the file names
            // change when sheets are reordered, the contents do not. Its old
            // drawing relationship is dropped for the one we now write.
            var relationships = XLSXReader.PackagePreservation.relationships(in: preservedRelationships)
                .filter { $0.type != ChartWriter.drawingRelationshipType }
            var drawingID: String?
            if let sheetDrawing {
                let id = Self.freshRelationshipID(avoiding: Set(relationships.compactMap(\.id)))
                drawingID = id
                relationships.append(.init(
                    id: id, type: ChartWriter.drawingRelationshipType,
                    target: relativePath(from: path, to: sheetDrawing.path), targetMode: nil
                ))
            }

            // Comments: the notes part, the VML drawing they are drawn in,
            // and the threaded conversations.
            var legacyDrawingID: String?
            if let sheetComments = comments.sheets[sheet.id] {
                func relate(_ type: String, _ target: String) -> String {
                    let id = Self.freshRelationshipID(avoiding: Set(relationships.compactMap(\.id)))
                    relationships.append(.init(id: id, type: type, target: relativePath(from: path, to: target),
                                               targetMode: nil))
                    return id
                }
                legacyDrawingID = relate(CommentParts.vmlType, sheetComments.vmlPath)
                parts.append((sheetComments.vmlPath, CommentParts.vmlPart(
                    sheet.comments, preservedShapes: sheet.preservedVMLShapes,
                    controlShapes: sheet.formControls.map { FormControlParts.vml(for: $0, on: sheet, in: workbook) },
                    sheetNumber: index + 1).utf8Data))
                if let payload = sheet.preservedVMLRelationships {
                    parts.append((XLSXReader.PackagePreservation.relationshipsPath(for: sheetComments.vmlPath), payload))
                }
                if let commentsPath = sheetComments.commentsPath {
                    _ = relate(CommentParts.commentsType, commentsPath)
                    parts.append((commentsPath, CommentParts.commentsPart(sheet.comments).utf8Data))
                }
                if let threadsPath = sheetComments.threadsPath, let xml = CommentParts.threadsPart(sheet.comments) {
                    _ = relate(CommentParts.threadType, threadsPath)
                    parts.append((threadsPath, xml.utf8Data))
                }
            }

            let body: String
            if drawings.isChartSheet(sheet) {
                body = ChartWriter.chartSheet(
                    drawingRelationshipID: drawingID, preserved: sheet.preservedElements,
                    mainNamespace: mainNamespace
                )
            } else {
                // The `<controls>` list repeats where each control sits.
                var sheet = sheet
                sheet.preservedElements = sheet.preservedElements.map { element in
                    element.name == "controls"
                        ? FormControlParts.controlsElement(element, controls: sheet.formControls) : element
                }
                body = sheetPart(
                    sheet, strings: strings, styles: styles, formulas: formulas.forms[sheet.id] ?? [:],
                    hasRelationshipsPart: preservedRelationships != nil, drawingRelationshipID: drawingID,
                    legacyDrawingRelationshipID: legacyDrawingID
                )
            }
            parts.append((path, body.utf8Data))
            if !relationships.isEmpty {
                parts.append((
                    XLSXReader.PackagePreservation.relationshipsPath(for: path),
                    relationshipsPart(relationships).utf8Data
                ))
            }

            guard let sheetDrawing else { continue }
            parts.append((
                sheetDrawing.path,
                ChartWriter.drawing(
                    charts: sheetDrawing.charts.map { ($0.chart, $0.relationshipID) },
                    preserved: sheetDrawing.anchors,
                    isChartSheet: drawings.isChartSheet(sheet)
                ).utf8Data
            ))
            var drawingRelationships: [XLSXReader.PackagePreservation.RelationshipEntry] = []
            for anchor in sheetDrawing.anchors {
                for relationship in anchor.relationships
                where !drawingRelationships.contains(where: { $0.id == relationship.id }) {
                    drawingRelationships.append(.init(
                        id: relationship.id, type: relationship.type,
                        target: !relationship.isPackagePart
                            ? relationship.target : relativePath(from: sheetDrawing.path, to: relationship.target),
                        targetMode: relationship.isExternal ? "External" : nil
                    ))
                }
            }
            for entry in sheetDrawing.charts {
                drawingRelationships.append(.init(
                    id: entry.relationshipID, type: ChartWriter.chartRelationshipType,
                    target: relativePath(from: sheetDrawing.path, to: entry.path), targetMode: nil
                ))
                parts.append((entry.path, ChartWriter.chartSpace(entry.chart, workbook: workbook).utf8Data))
                guard !entry.companions.isEmpty else { continue }
                var chartRelationships: [XLSXReader.PackagePreservation.RelationshipEntry] = []
                var used = Set(entry.companions.compactMap(\.companion.relationshipID))
                for companion in entry.companions {
                    parts.append((companion.path, companion.companion.data))
                    let id = companion.companion.relationshipID ?? XLSXWriter.freshRelationshipID(avoiding: used)
                    used.insert(id)
                    chartRelationships.append(.init(
                        id: id, type: companion.companion.relationshipType,
                        target: relativePath(from: entry.path, to: companion.path), targetMode: nil
                    ))
                }
                parts.append((
                    XLSXReader.PackagePreservation.relationshipsPath(for: entry.path),
                    relationshipsPart(chartRelationships).utf8Data
                ))
            }
            if !drawingRelationships.isEmpty {
                parts.append((
                    XLSXReader.PackagePreservation.relationshipsPath(for: sheetDrawing.path),
                    relationshipsPart(drawingRelationships).utf8Data
                ))
            }
        }
        // A control's `ctrlProps` part is kept, with its state brought up to date.
        var controlProperties: [String: Data] = [:]
        for sheet in workbook.sheets {
            for control in sheet.formControls {
                guard let path = control.source.propertiesPart, let data = preserved.parts[path],
                      let updated = FormControlParts.properties(data, for: control, on: sheet, in: workbook)
                else { continue }
                controlProperties[path] = updated
            }
        }
        for path in preserved.parts.keys.sorted() {
            parts.append((path, controlProperties[path] ?? preserved.parts[path] ?? Data()))
        }
        return try ZipArchive.archive(entries: parts)
    }

    // MARK: - Drawings

    /// Where every sheet's drawing and charts go in the package, worked out
    /// before anything is written because the content types, the workbook's
    /// relationships and the sheets themselves all have to agree on it.
    public struct DrawingPlan: Sendable {
        public struct ChartEntry: Sendable {
            public var chart: Chart
            public var path: String
            public var relationshipID: String
            /// The style, colour and user shape parts carried over with a chart
            /// from a file.
            public var companions: [(companion: ChartCompanion, path: String)] = []
        }

        public struct SheetDrawing: Sendable {
            public var path: String
            public var charts: [ChartEntry]
            public var anchors: [PreservedDrawingAnchor]
        }

        public var sheets: [Worksheet.ID: SheetDrawing] = [:]
        /// Chart sheets with something to show. One emptied of its chart is
        /// written as a blank worksheet instead: the schema requires a chart
        /// sheet to have a drawing.
        private var chartSheets: Set<Worksheet.ID> = []

        public init(workbook: Workbook) {
            // Part names are numbered clear of anything carried over: a chart
            // we could not model may well be sitting at `chart1.xml` already.
            var taken = Set(workbook.preservedPackage.parts.keys)
            func allocate(_ stem: String) -> String {
                var number = 1
                while taken.contains("\(stem)\(number).xml") { number += 1 }
                let path = "\(stem)\(number).xml"
                taken.insert(path)
                return path
            }

            for sheet in workbook.sheets {
                let charts = sheet.isChartSheet ? Array(sheet.charts.prefix(1)) : sheet.charts
                guard !charts.isEmpty || !sheet.preservedDrawingAnchors.isEmpty else { continue }
                if sheet.isChartSheet { chartSheets.insert(sheet.id) }

                let reserved = Set(sheet.preservedDrawingAnchors.flatMap(\.relationships).map(\.id))
                var used = reserved
                let entries = charts.map { chart in
                    let id = XLSXWriter.freshRelationshipID(avoiding: used)
                    used.insert(id)
                    let companions = (chart.original?.companions ?? []).map { companion in
                        (companion: companion, path: allocate(companion.stem))
                    }
                    return ChartEntry(
                        chart: chart, path: allocate("xl/charts/chart"), relationshipID: id, companions: companions
                    )
                }
                sheets[sheet.id] = SheetDrawing(
                    path: allocate("xl/drawings/drawing"), charts: entries,
                    anchors: sheet.preservedDrawingAnchors
                )
            }
        }

        public func isChartSheet(_ sheet: Worksheet) -> Bool { chartSheets.contains(sheet.id) }

        public func sheetPath(at index: Int, of sheet: Worksheet) -> String {
            isChartSheet(sheet)
                ? "xl/chartsheets/sheet\(index + 1).xml"
                : "xl/worksheets/sheet\(index + 1).xml"
        }
    }

    /// The first `rIdN` not already in use in a part's relationships.
    public static func freshRelationshipID(avoiding used: Set<String>) -> String {
        var number = 1
        while used.contains("rId\(number)") { number += 1 }
        return "rId\(number)"
    }

    /// A relationship target relative to the part that holds it, which is how
    /// Excel writes them and how every reader resolves them.
    public static func relativePath(from source: String, to target: String) -> String {
        let sourceDirectory = XLSXReader.PackagePreservation.directory(of: source)
            .split(separator: "/").map(String.init)
        let targetComponents = target.split(separator: "/").map(String.init)
        var shared = 0
        while shared < sourceDirectory.count, shared < targetComponents.count - 1,
              sourceDirectory[shared] == targetComponents[shared] {
            shared += 1
        }
        let ups = Array(repeating: "..", count: sourceDirectory.count - shared)
        return (ups + targetComponents[shared...]).joined(separator: "/")
    }

    private static func relationshipsPart(_ entries: [XLSXReader.PackagePreservation.RelationshipEntry]) -> String {
        var xml = declaration
        xml += "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        for entry in entries {
            xml += "<Relationship Id=\"\(XMLLite.escape(entry.id ?? ""))\""
            xml += " Type=\"\(XMLLite.escape(entry.type))\""
            xml += " Target=\"\(XMLLite.escape(entry.target))\""
            if let mode = entry.targetMode { xml += " TargetMode=\"\(XMLLite.escape(mode))\"" }
            xml += "/>"
        }
        xml += "</Relationships>"
        return xml
    }

    private static let declaration = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
    private static let mainNamespace = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    private static let relationshipNamespace = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

    // MARK: - Package parts

    private static func contentTypes(
        workbook: Workbook, drawings: DrawingPlan, preserved: PreservedPackage, hasMetadata: Bool,
        comments: CommentPlan, macroEnabled: Bool
    ) -> String {
        var xml = declaration
        xml += "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
        xml += "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
        xml += "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
        // The two extensions above are already stated; restating either would
        // make the part invalid rather than merely redundant.
        for (ext, type) in preserved.contentTypeDefaults.sorted(by: { $0.key < $1.key })
        where ext != "rels" && ext != "xml" {
            xml += "<Default Extension=\"\(XMLLite.escape(ext))\" ContentType=\"\(XMLLite.escape(type))\"/>"
        }
        // The workbook's own type is what says the package is an `.xlsm`;
        // Excel refuses a file whose extension and type disagree, even one
        // with no macros in it yet.
        let workbookType = macroEnabled
            ? "application/vnd.ms-excel.sheet.macroEnabled.main+xml"
            : "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"
        xml += "<Override PartName=\"/xl/workbook.xml\" ContentType=\"\(workbookType)\"/>"
        for (index, sheet) in workbook.sheets.enumerated() {
            let type = drawings.isChartSheet(sheet)
                ? ChartWriter.chartSheetContentType
                : "application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"
            xml += "<Override PartName=\"/\(drawings.sheetPath(at: index, of: sheet))\" ContentType=\"\(type)\"/>"
        }
        for drawing in drawings.sheets.values.sorted(by: { $0.path < $1.path }) {
            xml += "<Override PartName=\"/\(drawing.path)\" ContentType=\"\(ChartWriter.drawingContentType)\"/>"
            for chart in drawing.charts {
                xml += "<Override PartName=\"/\(chart.path)\" ContentType=\"\(ChartWriter.chartContentType)\"/>"
                for companion in chart.companions {
                    xml += "<Override PartName=\"/\(companion.path)\" ContentType=\"\(companion.companion.contentType)\"/>"
                }
            }
        }
        xml += "<Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>"
        xml += "<Override PartName=\"/xl/sharedStrings.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml\"/>"
        if hasMetadata {
            xml += "<Override PartName=\"/\(FormulaPlan.metadataPath)\" ContentType=\"\(FormulaPlan.metadataContentType)\"/>"
        }
        for sheetComments in comments.sheets.values.sorted(by: { $0.vmlPath < $1.vmlPath }) {
            xml += "<Override PartName=\"/\(sheetComments.vmlPath)\" ContentType=\"\(CommentParts.vmlContentType)\"/>"
            if let path = sheetComments.commentsPath {
                xml += "<Override PartName=\"/\(path)\" ContentType=\"\(CommentParts.commentsContentType)\"/>"
            }
            if let path = sheetComments.threadsPath {
                xml += "<Override PartName=\"/\(path)\" ContentType=\"\(CommentParts.threadContentType)\"/>"
            }
        }
        if let path = comments.personsPath {
            xml += "<Override PartName=\"/\(path)\" ContentType=\"\(CommentParts.personContentType)\"/>"
        }
        for (name, type) in preserved.contentTypeOverrides.sorted(by: { $0.key < $1.key })
        where !generatedPartNames.contains(name) && !comments.generatedPartNames.contains(name) {
            xml += "<Override PartName=\"\(XMLLite.escape(name))\" ContentType=\"\(XMLLite.escape(type))\"/>"
        }
        xml += "</Types>"
        return xml
    }

    /// Part names we always write an override for ourselves, so a preserved
    /// one naming the same part is skipped rather than duplicated.
    private static let generatedPartNames: Set<String> = [
        "/xl/workbook.xml", "/xl/styles.xml", "/xl/sharedStrings.xml", "/xl/metadata.xml",
    ]

    private static func rootRelationships(preserved: PreservedPackage) -> String {
        var xml = declaration
        xml += "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        xml += "<Relationship Id=\"rId1\" Type=\"\(relationshipNamespace)/officeDocument\" Target=\"xl/workbook.xml\"/>"
        xml += relationshipEntries(preserved.rootRelationships, startingAt: 2)
        xml += "</Relationships>"
        return xml
    }

    private static func workbookRelationships(
        workbook: Workbook, drawings: DrawingPlan, preserved: PreservedPackage, hasMetadata: Bool, hasPersons: Bool
    ) -> String {
        let sheetCount = workbook.sheets.count
        var xml = declaration
        xml += "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        for (index, sheet) in workbook.sheets.enumerated() {
            let type = drawings.isChartSheet(sheet) ? "chartsheet" : "worksheet"
            let target = String(drawings.sheetPath(at: index, of: sheet).dropFirst("xl/".count))
            xml += "<Relationship Id=\"rId\(index + 1)\" Type=\"\(relationshipNamespace)/\(type)\" Target=\"\(target)\"/>"
        }
        xml += "<Relationship Id=\"rId\(sheetCount + 1)\" Type=\"\(relationshipNamespace)/styles\" Target=\"styles.xml\"/>"
        xml += "<Relationship Id=\"rId\(sheetCount + 2)\" Type=\"\(relationshipNamespace)/sharedStrings\" Target=\"sharedStrings.xml\"/>"
        let carried = preserved.workbookRelationships.filter {
            $0.type != FormulaPlan.metadataRelationshipType && $0.type != CommentParts.personType
        }
        xml += relationshipEntries(carried, startingAt: sheetCount + 3)
        var nextID = sheetCount + 3 + carried.count
        if hasMetadata {
            xml += "<Relationship Id=\"rId\(nextID)\" Type=\"\(FormulaPlan.metadataRelationshipType)\" Target=\"metadata.xml\"/>"
            nextID += 1
        }
        if hasPersons {
            xml += "<Relationship Id=\"rId\(nextID)\" Type=\"\(CommentParts.personType)\" Target=\"persons/person.xml\"/>"
        }
        xml += "</Relationships>"
        return xml
    }

    /// Re-emits carried-over relationships under fresh ids.
    ///
    /// Renumbering is safe here and only here: nothing in the parts we generate
    /// names these ids, because the parts they reach — the theme, the document
    /// properties — are found by relationship type instead.
    private static func relationshipEntries(
        _ relationships: [PreservedRelationship], startingAt firstID: Int
    ) -> String {
        var xml = ""
        for (offset, relationship) in relationships.enumerated() {
            xml += "<Relationship Id=\"rId\(firstID + offset)\""
            xml += " Type=\"\(XMLLite.escape(relationship.type))\""
            xml += " Target=\"\(XMLLite.escape(relationship.target))\""
            if let mode = relationship.targetMode { xml += " TargetMode=\"\(XMLLite.escape(mode))\"" }
            xml += "/>"
        }
        return xml
    }

    private static func workbookPart(_ workbook: Workbook) -> String {
        var xml = declaration
        xml += "<workbook xmlns=\"\(mainNamespace)\" xmlns:r=\"\(relationshipNamespace)\">"
        if let codeName = workbook.codeName {
            xml += "<workbookPr codeName=\"\(XMLLite.escape(codeName))\"/>"
        }
        xml += "<sheets>"
        let hasVisibleSheet = workbook.sheets.contains { !$0.isHidden }
        for (index, sheet) in workbook.sheets.enumerated() {
            xml += "<sheet name=\"\(XMLLite.escape(sheet.name))\" sheetId=\"\(sheetIDs[index])\""
            // Excel refuses to open a workbook with nothing visible, so the
            // first sheet stays visible however the model got into that state.
            if sheet.isHidden, hasVisibleSheet || index > 0 { xml += " state=\"hidden\"" }
            xml += " r:id=\"rId\(index + 1)\"/>"
        }
        xml += "</sheets>"
    /// The number each sheet goes by in the file: the one it was read
    /// with, unless another sheet already has it, and the next free one
    /// for a sheet new to the file.
    static func fileSheetIDs(of workbook: Workbook) -> [Int] {
        var used: Set<Int> = []
        var ids = workbook.sheets.map { sheet -> Int? in
            guard let id = sheet.fileSheetID, id > 0, used.insert(id).inserted else { return nil }
            return id
        }
        var next = (used.max() ?? 0) + 1
        for index in ids.indices where ids[index] == nil {
            ids[index] = next
            next += 1
        }
        return ids.map { $0 ?? 0 }
    }

        // A name scoped to a sheet that is gone is dropped rather than written
        // unscoped: promoting it to workbook scope would let it answer formulas
        // it never applied to.
        let names = workbook.definedNames.compactMap { name -> (DefinedName, Int?)? in
            guard let scope = name.scope else { return (name, nil) }
            guard let position = workbook.index(of: scope) else { return nil }
            return (name, position)
        }
        let sheetIDs = fileSheetIDs(of: workbook)
        // Element order inside `<workbook>` is schema-enforced: `<definedNames>`
        // sits between `<sheets>` and `<calcPr>`, and Excel rejects the part if
        // it appears anywhere else.
        if !names.isEmpty {
            xml += "<definedNames>"
            for (name, position) in names {
                xml += "<definedName name=\"\(XMLLite.escape(name.name))\""
                if let position { xml += " localSheetId=\"\(position)\"" }
                xml += ">\(XMLLite.escape(FormulaDialect.toFile(name.formula)))</definedName>"
            }
            xml += "</definedNames>"
        }
        // Ask Excel to recalculate on open: we store our own cached results, and
        // where a function differs in the last digit its answer should win.
        xml += "<calcPr calcId=\"0\" fullCalcOnLoad=\"1\"/>"
        xml += "</workbook>"
        return xml
    }

    // MARK: - Worksheets

    /// The order `CT_Worksheet` fixes for the children of `<worksheet>`, from
    /// ECMA-376 Part 1 §18.3.1.99. Excel refuses to open a worksheet whose
    /// children appear in any other order, so every fragment we write — ours
    /// and the ones carried over from the file — is placed by this list.
    private static let worksheetChildOrder: [String] = [
        "sheetPr", "dimension", "sheetViews", "sheetFormatPr", "cols", "sheetData",
        "sheetCalcPr", "sheetProtection", "protectedRanges", "scenarios", "autoFilter",
        "sortState", "dataConsolidate", "customSheetViews", "mergeCells", "phoneticPr",
        "conditionalFormatting", "dataValidations", "hyperlinks", "printOptions",
        "pageMargins", "pageSetup", "headerFooter", "rowBreaks", "colBreaks",
        "customProperties", "cellWatches", "ignoredErrors", "smartTags", "drawing",
        "legacyDrawing", "legacyDrawingHF", "picture", "oleObjects", "controls",
        "webPublishItems", "tableParts", "extLst",
    ]

    private static func sheetPart(
        _ sheet: Worksheet, strings: SharedStringTable, styles: StyleTable, formulas: [CellAddress: FormulaPlan.Form] = [:],
        hasRelationshipsPart: Bool, drawingRelationshipID: String? = nil, legacyDrawingRelationshipID: String? = nil
    ) -> String {
        /// Fragments paired with their schema position, plus the order they
        /// were added in so repeatable children — several `<conditionalFormatting>`
        /// blocks, say — keep the sequence the file had them in.
        var fragments: [(order: Int, sequence: Int, xml: String)] = []
        func add(_ name: String, _ body: String) {
            let order = worksheetChildOrder.firstIndex(of: name) ?? worksheetChildOrder.count
            fragments.append((order, fragments.count, body))
        }

        if let codeName = sheet.codeName {
            add("sheetPr", "<sheetPr codeName=\"\(XMLLite.escape(codeName))\"/>")
        }
        add("dimension", "<dimension ref=\"A1:\(CellAddress(row: sheet.rowCount - 1, column: sheet.columnCount - 1).a1)\"/>")

        // Our defaults differ from Excel's, so state them: otherwise every row
        // and column we did not size explicitly would render at Excel's size.
        var xml = "<sheetFormatPr defaultRowHeight=\"\(format(Worksheet.defaultRowHeight))\""
        xml += " defaultColWidth=\"\(format(Worksheet.columnWidthCharacters(points: Worksheet.defaultColumnWidth)))\"/>"
        add("sheetFormatPr", xml)

        // Column metadata: widths and hidden state.
        var columnEntries: [String] = []
        for column in 0..<sheet.columnCount {
            let hidden = sheet.hiddenColumns.contains(column)
            let custom = sheet.columnWidths[column]
            guard hidden || custom != nil else { continue }
            let points = custom ?? Worksheet.defaultColumnWidth
            let characters = max(0, Worksheet.columnWidthCharacters(points: points))
            var entry = "<col min=\"\(column + 1)\" max=\"\(column + 1)\" width=\"\(format(characters))\""
            if custom != nil { entry += " customWidth=\"1\"" }
            if hidden { entry += " hidden=\"1\"" }
            entry += "/>"
            columnEntries.append(entry)
        }
        if !columnEntries.isEmpty { add("cols", "<cols>" + columnEntries.joined() + "</cols>") }

        xml = "<sheetData>"
        // Bucketed in one pass rather than by asking the sheet for each row's
        // cells in turn: that question costs a scan of every cell in the sheet,
        // and a sheet with tens of thousands of rows would pay it that many
        // times over just to save the file once.
        var cellsByRow: [Int: [(address: CellAddress, cell: Cell)]] = [:]
        for (address, cell) in sheet.cells
        where address.row < sheet.rowCount && address.column < sheet.columnCount {
            cellsByRow[address.row, default: []].append((address, cell))
        }
        let interestingRows = Set(cellsByRow.keys)
            .union(sheet.hiddenRows)
            .union(sheet.rowHeights.keys)
            .filter { $0 < sheet.rowCount }
            .sorted()

        for row in interestingRows {
            var attributes = "r=\"\(row + 1)\""
            if let height = sheet.rowHeights[row] {
                attributes += " ht=\"\(format(height))\""
                if !sheet.fittedRows.contains(row) { attributes += " customHeight=\"1\"" }
            }
            if sheet.hiddenRows.contains(row) { attributes += " hidden=\"1\"" }

            guard var cells = cellsByRow[row], !cells.isEmpty else {
                xml += "<row \(attributes)/>"
                continue
            }
            cells.sort { $0.address.column < $1.address.column }
            xml += "<row \(attributes)>"
            for (address, cell) in cells {
                xml += cellPart(cell, at: address, strings: strings, styles: styles, formula: formulas[address])
            }
            xml += "</row>"
        }
        xml += "</sheetData>"
        add("sheetData", xml)

        var merges: [CellRange] = []
        for range in sheet.mergedRanges {
            let box: CellRange = range.normalized
            guard box.end.row < sheet.rowCount, box.end.column < sheet.columnCount else { continue }
            merges.append(box)
        }
        merges.sort { first, second in
            first.start == second.start ? first.end < second.end : first.start < second.start
        }
        if !merges.isEmpty {
            xml = "<mergeCells count=\"\(merges.count)\">"
            for merge in merges { xml += "<mergeCell ref=\"\(merge.a1)\"/>" }
            xml += "</mergeCells>"
            add("mergeCells", xml)
        }

        for element in preservedElements(of: sheet) {
            // A duplicated sheet carries its predecessor's fragments but not
            // its `_rels`, so the ids in them would resolve to nothing.
            guard hasRelationshipsPart || !element.needsSheetRelationships else { continue }
            add(element.name, element.xml)
        }

        if let drawingRelationshipID { add("drawing", "<drawing r:id=\"\(drawingRelationshipID)\"/>") }
        if let legacyDrawingRelationshipID {
            add("legacyDrawing", "<legacyDrawing r:id=\"\(legacyDrawingRelationshipID)\"/>")
        }

        // Sorting rather than appending in place is what keeps the carried-over
        // fragments in their schema slots instead of wherever we happened to
        // reach them.
        fragments.sort { $0.order == $1.order ? $0.sequence < $1.sequence : $0.order < $1.order }
        return declaration
            + "<worksheet xmlns=\"\(mainNamespace)\" xmlns:r=\"\(relationshipNamespace)\">"
            + fragments.map(\.xml).joined()
            + "</worksheet>"
    }

    /// The sheet's kept fragments, with its frozen pane written into the
    /// first sheet view — the one the file had, or one of our own.
    private static func preservedElements(of sheet: Worksheet) -> [PreservedElement] {
        var elements = sheet.preservedElements
        guard sheet.frozenRows > 0 || sheet.frozenColumns > 0 else { return elements }
        let pane = frozenPane(for: sheet)
        if let index = elements.firstIndex(where: { $0.name == "sheetViews" }),
           let views = try? XMLLite.parse(Data(elements[index].xml.utf8)),
           let view = views.firstChild(named: "sheetView"),
           let paneElement = XMLLite.fragment(pane, namespaces: [:]) {
            // The pane leads the view: it comes before any selection in the schema.
            view.insertChild(paneElement, at: 0)
            if let xml = XMLLite.serialize(views) {
                elements[index] = PreservedElement(name: "sheetViews", xml: xml)
                return elements
            }
        }
        elements.removeAll { $0.name == "sheetViews" }
        elements.append(PreservedElement(
            name: "sheetViews", xml: "<sheetViews><sheetView workbookViewId=\"0\">\(pane)</sheetView></sheetViews>"))
        return elements
    }

    /// Excel's `<pane>` for frozen rows and columns: where the split falls,
    /// the first cell below and right of it, and which quarter scrolls.
    private static func frozenPane(for sheet: Worksheet) -> String {
        let rows = sheet.frozenRows, columns = sheet.frozenColumns
        var xml = "<pane"
        if columns > 0 { xml += " xSplit=\"\(columns)\"" }
        if rows > 0 { xml += " ySplit=\"\(rows)\"" }
        xml += " topLeftCell=\"\(CellAddress(row: rows, column: columns).a1)\""
        let active = rows > 0 && columns > 0 ? "bottomRight" : (rows > 0 ? "bottomLeft" : "topRight")
        xml += " activePane=\"\(active)\" state=\"frozen\"/>"
        return xml
    }

    private static func cellPart(
        _ cell: Cell, at address: CellAddress, strings: SharedStringTable, styles: StyleTable,
        formula form: FormulaPlan.Form? = nil
    ) -> String {
        var attributes = "r=\"\(address.a1)\""
        let styleIndex = styles.index(for: cell.style)
        if styleIndex != 0 { attributes += " s=\"\(styleIndex)\"" }

        var body = ""
        var isDynamic = false
        switch form {
        case .plain(let text)?:
            body += "<f>\(XMLLite.escape(text))</f>"
        case .array(let text, let block, let dynamic)?:
            body += "<f t=\"array\" ref=\"\(block.a1)\">\(XMLLite.escape(text))</f>"
            isDynamic = dynamic
        case nil:
            if let formula = cell.formula {
                body += "<f>\(XMLLite.escape(FormulaDialect.toFile(formula)))</f>"
            }
        }

        switch cell.value {
        case .empty:
            break
        case .number(let number):
            body += "<v>\(format(number))</v>"
        case .boolean(let flag):
            attributes += " t=\"b\""
            body += "<v>\(flag ? 1 : 0)</v>"
        case .error(let error):
            attributes += " t=\"e\""
            body += "<v>\(XMLLite.escape(error.ooxmlValue))</v>"
        case .text(let text):
            if cell.formula != nil {
                attributes += " t=\"str\""
                body += "<v>\(XMLLite.escape(text))</v>"
            } else {
                attributes += " t=\"s\""
                body += "<v>\(strings.index(for: text))</v>"
            }
        }

        // `cm` points at the metadata marking the formula as a dynamic array;
        // the schema puts it after `t`.
        if isDynamic { attributes += " cm=\"1\"" }
        return body.isEmpty ? "<c \(attributes)/>" : "<c \(attributes)>\(body)</c>"
    }

    /// Round-trip-safe number rendering: full precision, no separators.
    private static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return String(format: "%.15g", value)
    }

    // MARK: - Shared strings

    public final class SharedStringTable {
        public private(set) var strings: [String] = []
        private var lookup: [String: Int] = [:]
        private var referenceCount = 0

        public init(workbook: Workbook) {
            for sheet in workbook.sheets {
                for (address, cell) in sheet.cells
                where address.row < sheet.rowCount && address.column < sheet.columnCount {
                    guard cell.formula == nil, case .text(let text) = cell.value else { continue }
                    referenceCount += 1
                    _ = index(for: text)
                }
            }
        }

        @discardableResult
        public func index(for text: String) -> Int {
            if let existing = lookup[text] { return existing }
            let index = strings.count
            strings.append(text)
            lookup[text] = index
            return index
        }

        public var xml: String {
            var xml = XLSXWriter.declaration
            xml += "<sst xmlns=\"\(XLSXWriter.mainNamespace)\" count=\"\(referenceCount)\" uniqueCount=\"\(strings.count)\">"
            for text in strings {
                xml += "<si><t xml:space=\"preserve\">\(XMLLite.escape(text))</t></si>"
            }
            xml += "</sst>"
            return xml
        }
    }

    // MARK: - Styles

    public final class StyleTable {
        /// Stand-in for a side whose source file named no colour.
        private let defaultBorderColorHex = "FF8E8E93"

        private var styles: [CellStyle] = [.default]
        private var lookup: [CellStyle: Int] = [.default: 0]
        /// Carried-over children of the original `<styleSheet>`.
        private let preservedElements: [PreservedElement]

        /// The order `CT_Stylesheet` fixes for the children we re-emit, from
        /// ECMA-376 Part 1 §18.8.39. They all follow `<cellStyles>`, which is
        /// the last one we generate ourselves.
        private static let trailingElementOrder = ["dxfs", "tableStyles", "colors", "extLst"]

        public init(workbook: Workbook) {
            preservedElements = workbook.preservedPackage.styleSheetElements
            for sheet in workbook.sheets {
                for cell in sheet.cells.values where !cell.style.isDefault {
                    _ = index(for: cell.style)
                }
            }
        }

        @discardableResult
        public func index(for style: CellStyle) -> Int {
            if let existing = lookup[style] { return existing }
            let index = styles.count
            styles.append(style)
            lookup[style] = index
            return index
        }

        /// Custom number format codes start at 164 by convention.
        private var customFormats: [String: Int] {
            var result: [String: Int] = [:]
            var nextID = 164
            for style in styles where style.numberFormat != "General" {
                guard result[style.numberFormat] == nil else { continue }
                result[style.numberFormat] = nextID
                nextID += 1
            }
            return result
        }

        public var xml: String {
            let formats = customFormats
            var xml = XLSXWriter.declaration
            xml += "<styleSheet xmlns=\"\(XLSXWriter.mainNamespace)\">"

            if !formats.isEmpty {
                xml += "<numFmts count=\"\(formats.count)\">"
                for (code, id) in formats.sorted(by: { $0.value < $1.value }) {
                    xml += "<numFmt numFmtId=\"\(id)\" formatCode=\"\(XMLLite.escape(code))\"/>"
                }
                xml += "</numFmts>"
            }

            xml += "<fonts count=\"\(styles.count)\">"
            for style in styles {
                xml += "<font><sz val=\"\(XLSXWriter.format(style.fontSize))\"/>"
                xml += "<name val=\"\(XMLLite.escape(style.fontName))\"/>"
                if style.isBold { xml += "<b/>" }
                if style.isItalic { xml += "<i/>" }
                if style.isUnderlined { xml += "<u/>" }
                if style.isStruckThrough { xml += "<strike/>" }
                if let color = style.textColorHex { xml += "<color rgb=\"\(color)\"/>" }
                xml += "</font>"
            }
            xml += "</fonts>"

            // Indices 0 and 1 are reserved by the format for "none" and "gray125".
            xml += "<fills count=\"\(styles.count + 2)\">"
            xml += "<fill><patternFill patternType=\"none\"/></fill>"
            xml += "<fill><patternFill patternType=\"gray125\"/></fill>"
            for style in styles {
                if let color = style.fillColorHex {
                    xml += "<fill><patternFill patternType=\"solid\"><fgColor rgb=\"\(color)\"/>"
                    xml += "<bgColor indexed=\"64\"/></patternFill></fill>"
                } else {
                    xml += "<fill><patternFill patternType=\"none\"/></fill>"
                }
            }
            xml += "</fills>"

            xml += "<borders count=\"\(styles.count + 1)\">"
            xml += "<border><left/><right/><top/><bottom/><diagonal/></border>"
            for style in styles {
                let diagonal = style.diagonalBorder.flatMap { $0.isVisible ? $0 : nil }
                xml += "<border"
                if diagonal?.goesUp == true { xml += " diagonalUp=\"1\"" }
                if diagonal?.goesDown == true { xml += " diagonalDown=\"1\"" }
                xml += ">"
                // Excel requires the sides in schema order, not the order we
                // happen to iterate a dictionary in.
                for edge in [BorderEdge.leading, .trailing, .top, .bottom] {
                    guard let side = style.borderSides[edge] else {
                        xml += "<\(edge.ooxmlTag)/>"
                        continue
                    }
                    xml += "<\(edge.ooxmlTag) style=\"\(side.lineStyle.rawValue)\">"
                    xml += "<color rgb=\"\(side.colorHex ?? defaultBorderColorHex)\"/>"
                    xml += "</\(edge.ooxmlTag)>"
                }
                if let diagonal {
                    xml += "<diagonal style=\"\(diagonal.lineStyle.rawValue)\">"
                    xml += "<color rgb=\"\(diagonal.colorHex ?? defaultBorderColorHex)\"/>"
                    xml += "</diagonal>"
                } else {
                    xml += "<diagonal/>"
                }
                xml += "</border>"
            }
            xml += "</borders>"

            xml += "<cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs>"
            xml += "<cellXfs count=\"\(styles.count)\">"
            for (index, style) in styles.enumerated() {
                let formatID = style.numberFormat == "General" ? 0 : (formats[style.numberFormat] ?? 0)
                let fillID = style.fillColorHex == nil ? 0 : index + 2
                let hasBorder = !style.borderSides.isEmpty || style.diagonalBorder?.isVisible == true
                let borderID = hasBorder ? index + 1 : 0
                xml += "<xf numFmtId=\"\(formatID)\" fontId=\"\(index)\" fillId=\"\(fillID)\" borderId=\"\(borderID)\""
                xml += " xfId=\"0\" applyFont=\"1\" applyNumberFormat=\"1\" applyFill=\"1\" applyBorder=\"1\""
                xml += " applyAlignment=\"1\">"
                xml += "<alignment"
                switch style.horizontalAlignment {
                case .automatic: break
                case .leading: xml += " horizontal=\"left\""
                case .center: xml += " horizontal=\"center\""
                case .trailing: xml += " horizontal=\"right\""
                }
                switch style.verticalAlignment {
                case .top: xml += " vertical=\"top\""
                case .middle: xml += " vertical=\"center\""
                case .bottom: xml += " vertical=\"bottom\""
                }
                if style.wrapsText { xml += " wrapText=\"1\"" }
                if style.indent > 0 { xml += " indent=\"\(style.indent)\"" }
                if style.textRotation != 0 { xml += " textRotation=\"\(style.textRotation)\"" }
                xml += "/></xf>"
            }
            xml += "</cellXfs>"
            xml += "<cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles>"
            for element in preservedElements.sorted(by: {
                (Self.trailingElementOrder.firstIndex(of: $0.name) ?? Self.trailingElementOrder.count)
                    < (Self.trailingElementOrder.firstIndex(of: $1.name) ?? Self.trailingElementOrder.count)
            }) {
                xml += element.xml
            }
            xml += "</styleSheet>"
            return xml
        }
    }
}

private extension String {
    var utf8Data: Data { Data(utf8) }
}
