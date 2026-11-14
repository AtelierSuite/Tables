import Foundation

/// Reads PivotTables, their caches and slicer caches out of the parts kept
/// for a save, and writes back the ones a refresh or a new layout changed.
///
/// An untouched PivotTable is never written from the model: its parts stay
/// in the kept package byte for byte.
public enum PivotParts {
    static let relationships = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    public static let tableType = relationships + "/pivotTable"
    public static let cacheRecordsType = relationships + "/pivotCacheRecords"
    public static let slicerType = "http://schemas.microsoft.com/office/2007/relationships/slicer"
    private static let declaration = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
    private static let mainNamespace = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    private static let x14Namespace = "http://schemas.microsoft.com/office/spreadsheetml/2009/9/main"
    private static let x15Namespace = "http://schemas.microsoft.com/office/spreadsheetml/2010/11/main"

    private typealias Plan = XLSXReader.PackagePreservation

    // MARK: - Reading

    /// Fills in the workbook's caches, PivotTables and slicer caches. Only
    /// parts that were kept are read, so everything in the model is something
    /// a save writes.
    static func read(
        into workbook: inout Workbook, workbookXML: XMLElement, workbookRelationships: Data?, sheetPaths: [String]
    ) {
        let parts = workbook.preservedPackage.parts
        var targets: [String: String] = [:]
        for entry in Plan.relationships(in: workbookRelationships) {
            guard let id = entry.id, let path = Plan.packagePath(of: entry, relativeTo: "xl") else { continue }
            targets[id] = path
        }

        for element in workbookXML.firstChild(named: "pivotCaches")?.children(named: "pivotCache") ?? [] {
            guard let cacheID = element.attribute("cacheId").flatMap(Int.init),
                  let path = element.attribute("id").flatMap({ targets[$0] }), let data = parts[path],
                  let cache = cache(from: data, cacheID: cacheID, path: path, parts: parts) else { continue }
            workbook.pivotCaches.append(cache)
        }

        for ext in workbookXML.firstChild(named: "extLst")?.children(named: "ext") ?? [] {
            guard let uri = ext.attribute("uri") else { continue }
            for element in ext.firstChild(named: "slicerCaches")?.children(named: "slicerCache") ?? [] {
                guard let path = element.attribute("id").flatMap({ targets[$0] }), let data = parts[path],
                      let cache = slicerCache(from: data, path: path, extensionURI: uri) else { continue }
                workbook.slicerCaches.append(cache)
            }
        }

        // What can't be tied to a cache the workbook now declares goes, with
        // the relationships naming it: a PivotTable or a slicer pointing at
        // a cache that is not there is what Excel calls a damaged file.
        var dropped: Set<String> = []
        var lostPivot = false, lostSlicer = false
        for (index, sheet) in workbook.sheets.enumerated() {
            let directory = Plan.directory(of: sheetPaths[index])
            var droppedIDs: Set<String> = []
            for entry in Plan.relationships(in: workbook.preservedPackage.sheetRelationshipParts[sheet.id]) {
                guard let path = Plan.packagePath(of: entry, relativeTo: directory), let data = parts[path] else { continue }
                if entry.type == tableType {
                    guard let root = try? XMLLite.parse(data), let cacheID = root.attribute("cacheId").flatMap(Int.init),
                          let cache = workbook.pivotCache(cacheID),
                          let pivot = table(from: root, path: path, sheetID: sheet.id, cache: cache) else {
                        dropped.insert(path)
                        if let id = entry.id { droppedIDs.insert(id) }
                        lostPivot = true
                        continue
                    }
                    workbook.pivotTables.append(pivot)
                } else if entry.type == slicerType {
                    let slicers = (try? XMLLite.parse(data))?.children(named: "slicer") ?? []
                    let caches = slicers.map { slicer in
                        slicer.attribute("cache").flatMap { name in workbook.slicerCaches.firstIndex { $0.name == name } }
                    }
                    guard !slicers.isEmpty, caches.allSatisfy({ $0 != nil }) else {
                        dropped.insert(path)
                        if let id = entry.id { droppedIDs.insert(id) }
                        lostSlicer = true
                        continue
                    }
                    for (slicer, at) in zip(slicers, caches.compactMap { $0 }) {
                        workbook.slicerCaches[at].captions.append(
                            slicer.attribute("caption") ?? slicer.attribute("name") ?? workbook.slicerCaches[at].name)
                    }
                }
            }
            guard !droppedIDs.isEmpty, let payload = workbook.preservedPackage.sheetRelationshipParts[sheet.id] else { continue }
            workbook.preservedPackage.sheetRelationshipParts[sheet.id] = Plan.removingRelationships(
                withIDs: droppedIDs, from: payload)
            workbook.sheets[index].preservedElements = workbook.sheets[index].preservedElements.compactMap {
                $0.removingSlicers(withIDs: droppedIDs)
            }
        }
        // Caches nothing declares, and slicer caches whose PivotTables are gone.
        let modelled = Set(workbook.pivotCaches.map(\.partPath) + workbook.pivotCaches.compactMap(\.recordsPath))
        for path in parts.keys where path.hasPrefix("xl/pivotCache/") && !Plan.isRelationshipsPart(path) && !modelled.contains(path) {
            dropped.insert(path)
            lostPivot = true
        }
        let declaredSlicers = Set(workbook.slicerCaches.map(\.partPath))
        for path in parts.keys where path.hasPrefix("xl/slicerCaches/") && !Plan.isRelationshipsPart(path)
            && !declaredSlicers.contains(path) {
            dropped.insert(path)
            lostSlicer = true
        }
        for path in dropped {
            workbook.preservedPackage.parts[path] = nil
            workbook.preservedPackage.parts[Plan.relationshipsPath(for: path)] = nil
            workbook.preservedPackage.contentTypeOverrides["/" + path] = nil
        }
        workbook.preservedPackage.workbookRelationships.removeAll { relationship in
            relationship.targetMode != "External"
                && dropped.contains(Plan.absolutePath(relationship.target, relativeTo: "xl"))
        }
        if lostPivot { workbook.unsupportedFeatures.record(.pivotTables, isPreserved: false) }
        if lostSlicer { workbook.unsupportedFeatures.record(.slicers, isPreserved: false) }

        // A PivotTable that was read is one Tables works with, so it is not
        // named among what can only be carried through.
        if !workbook.pivotTables.isEmpty, workbook.unsupportedFeatures.preserved.contains(.pivotTables) {
            workbook.unsupportedFeatures = UnsupportedFeatureReport(
                preserved: workbook.unsupportedFeatures.preserved.subtracting([.pivotTables]),
                lost: workbook.unsupportedFeatures.lost)
        }
    }

    private static func isOn(_ value: String?, default fallback: Bool) -> Bool {
        guard let value else { return fallback }
        return value == "1" || value == "true"
    }

    static func value(from element: XMLElement) -> PivotValue? {
        let raw = element.attribute("v") ?? ""
        switch element.name {
        case "m": return .blank
        case "n": return Double(raw).map(PivotValue.number)
        case "s": return .text(raw)
        case "b": return .boolean(raw == "1" || raw == "true")
        case "e": return .error(raw)
        case "d": return serial(fromISO: raw).map(PivotValue.date)
        default: return nil
        }
    }

    private static func cache(from data: Data, cacheID: Int, path: String, parts: [String: Data]) -> PivotCache? {
        guard let root = try? XMLLite.parse(data), root.name == "pivotCacheDefinition" else { return nil }
        let source: PivotSource
        let cacheSource = root.firstChild(named: "cacheSource")
        if cacheSource?.attribute("type") == "worksheet", let sheetSource = cacheSource?.firstChild(named: "worksheetSource"),
           sheetSource.attribute("id") == nil {
            source = .worksheet(
                sheet: sheetSource.attribute("sheet"), reference: sheetSource.attribute("ref"),
                name: sheetSource.attribute("name"))
        } else {
            source = .other(cacheSource?.attribute("type") ?? "")
        }

        var fields: [PivotCacheField] = []
        for element in root.firstChild(named: "cacheFields")?.children(named: "cacheField") ?? [] {
            var field = PivotCacheField(name: element.attribute("name") ?? "")
            field.isStored = isOn(element.attribute("databaseField"), default: true)
            field.isDerived = !field.isStored
                || element.attribute("formula") != nil || element.firstChild(named: "fieldGroup") != nil
            field.sharedItems = element.firstChild(named: "sharedItems")?.children.compactMap(value(from:)) ?? []
            field.usesSharedItems = !field.sharedItems.isEmpty
            fields.append(field)
        }

        var cache = PivotCache(cacheID: cacheID, partPath: path, recordsPath: nil, source: source, fields: fields, records: [])
        let recordsEntry = Plan.relationships(in: parts[Plan.relationshipsPath(for: path)])
            .first { $0.type == cacheRecordsType }
        if let recordsEntry, let recordsPath = Plan.packagePath(of: recordsEntry, relativeTo: Plan.directory(of: path)),
           let payload = parts[recordsPath], let records = try? XMLLite.parse(payload) {
            cache.recordsPath = recordsPath
            // A record has a value for each field the source has a column for.
            let columns = fields.indices.filter { fields[$0].isStored }
            cache.records = records.children(named: "r").map { record in
                var values = [PivotValue](repeating: .blank, count: fields.count)
                for (position, element) in record.children.enumerated() where position < columns.count {
                    let field = columns[position]
                    if element.name == "x" {
                        let index = element.attribute("v").flatMap(Int.init) ?? 0
                        values[field] = fields[field].sharedItems.indices.contains(index)
                            ? fields[field].sharedItems[index] : .blank
                    } else {
                        values[field] = value(from: element) ?? .blank
                    }
                }
                return values
            }
        }
        return cache
    }

    private static func table(from root: XMLElement, path: String, sheetID: Worksheet.ID, cache: PivotCache) -> PivotTable? {
        guard root.name == "pivotTableDefinition", let location = root.firstChild(named: "location"),
              let range = location.attribute("ref").flatMap({ CellRange(a1Range: $0) })?.normalized,
              let cacheID = root.attribute("cacheId").flatMap(Int.init) else { return nil }
        var pivot = PivotTable(
            name: root.attribute("name") ?? "", sheetID: sheetID, partPath: path, cacheID: cacheID, location: range)
        func number(_ name: String, _ fallback: Int) -> Int { location.attribute(name).flatMap(Int.init) ?? fallback }
        pivot.firstHeaderRow = number("firstHeaderRow", 1)
        pivot.firstDataRow = number("firstDataRow", 1)
        pivot.firstDataColumn = number("firstDataCol", 1)
        pivot.showsRowGrandTotals = isOn(root.attribute("rowGrandTotals"), default: true)
        pivot.showsColumnGrandTotals = isOn(root.attribute("colGrandTotals"), default: true)
        pivot.rowHeaderCaption = root.attribute("rowHeaderCaption")
        pivot.columnHeaderCaption = root.attribute("colHeaderCaption")
        pivot.grandTotalCaption = root.attribute("grandTotalCaption")

        let customSubtotals = [
            "sumSubtotal", "countASubtotal", "avgSubtotal", "maxSubtotal", "minSubtotal", "productSubtotal",
            "countSubtotal", "stdDevSubtotal", "stdDevPSubtotal", "varSubtotal", "varPSubtotal",
        ]
        for (index, element) in (root.firstChild(named: "pivotFields")?.children(named: "pivotField") ?? []).enumerated() {
            var field = PivotField(name: cache.fields.indices.contains(index) ? cache.fields[index].name : "")
            field.fileIndex = index
            field.hasDefaultSubtotal = isOn(element.attribute("defaultSubtotal"), default: true)
            field.isCompact = isOn(element.attribute("compact"), default: true)
            field.isOutline = isOn(element.attribute("outline"), default: true)
            field.subtotalOnTop = isOn(element.attribute("subtotalTop"), default: true)
            field.sortType = element.attribute("sortType").flatMap { $0 == "manual" ? nil : $0 }
            field.hasCustomSubtotals = customSubtotals.contains { isOn(element.attribute($0), default: false) }
            field.items = element.firstChild(named: "items")?.children(named: "item").map { item in
                PivotItem(
                    sharedIndex: item.attribute("t") == nil ? item.attribute("x").flatMap(Int.init) ?? 0 : nil,
                    kind: item.attribute("t"), isHidden: isOn(item.attribute("h"), default: false))
            } ?? []
            pivot.fields.append(field)
        }
        func axis(_ name: String) -> [Int] {
            root.firstChild(named: name)?.children(named: "field").map { $0.attribute("x").flatMap(Int.init) ?? 0 } ?? []
        }
        pivot.rowFields = axis("rowFields")
        pivot.columnFields = axis("colFields")
        pivot.filters = root.firstChild(named: "pageFields")?.children(named: "pageField").compactMap { element in
            element.attribute("fld").flatMap(Int.init).map {
                PivotFilter(field: $0, selectedItem: element.attribute("item").flatMap(Int.init))
            }
        } ?? []
        pivot.dataFields = root.firstChild(named: "dataFields")?.children(named: "dataField").compactMap { element in
            guard let field = element.attribute("fld").flatMap(Int.init) else { return nil }
            var data = PivotDataField(
                name: element.attribute("name") ?? "", field: field,
                aggregation: PivotAggregation(rawValue: element.attribute("subtotal") ?? "sum") ?? .sum)
            data.showDataAs = element.attribute("showDataAs").flatMap { $0 == "normal" ? nil : $0 }
            if let subtotal = element.attribute("subtotal"), PivotAggregation(rawValue: subtotal) == nil {
                data.showDataAs = subtotal
            }
            data.numberFormatID = element.attribute("numFmtId").flatMap(Int.init)
            return data
        } ?? []
        return pivot
    }

    private static func slicerCache(from data: Data, path: String, extensionURI: String) -> SlicerCache? {
        guard let root = try? XMLLite.parse(data), root.name == "slicerCacheDefinition",
              let name = root.attribute("name") else { return nil }
        var cache = SlicerCache(
            partPath: path, extensionURI: extensionURI, name: name, sourceName: root.attribute("sourceName") ?? "")
        cache.targets = root.firstChild(named: "pivotTables")?.children(named: "pivotTable").compactMap { element in
            element.attribute("name").map {
                SlicerCache.Target(sheetNumber: element.attribute("tabId").flatMap(Int.init), name: $0)
            }
        } ?? []
        if let tabular = root.firstDescendant(atPath: "data/tabular") {
            cache.pivotCacheID = tabular.attribute("pivotCacheId").flatMap(Int.init)
            cache.items = tabular.firstChild(named: "items")?.children(named: "i").map { item in
                SlicerCache.Item(
                    sharedIndex: item.attribute("x").flatMap(Int.init) ?? 0,
                    isSelected: isOn(item.attribute("s"), default: false))
            } ?? []
        }
        return cache
    }

    // MARK: - Workbook declarations

    /// The `<pivotCaches>` and slicer cache declarations of `xl/workbook.xml`,
    /// naming each kept cache by the id its relationship is now written under.
    static func workbookDeclarations(for workbook: Workbook, relationshipIDs: [String: String]) -> String {
        var xml = ""
        let caches = workbook.pivotCaches.compactMap { cache in
            relationshipIDs[cache.partPath].map { "<pivotCache cacheId=\"\(cache.cacheID)\" r:id=\"\($0)\"/>" }
        }
        if !caches.isEmpty { xml += "<pivotCaches>" + caches.joined() + "</pivotCaches>" }

        func entries(_ uri: String) -> String {
            workbook.slicerCaches.filter { $0.extensionURI == uri }.compactMap { cache in
                relationshipIDs[cache.partPath].map { "<x14:slicerCache r:id=\"\($0)\"/>" }
            }.joined()
        }
        var extensions = ""
        let pivotSlicers = entries(SlicerCache.pivotExtensionURI)
        if !pivotSlicers.isEmpty {
            extensions += "<ext uri=\"\(SlicerCache.pivotExtensionURI)\" xmlns:x14=\"\(x14Namespace)\">"
            extensions += "<x14:slicerCaches>\(pivotSlicers)</x14:slicerCaches></ext>"
        }
        let tableSlicers = entries(SlicerCache.tableExtensionURI)
        if !tableSlicers.isEmpty {
            extensions += "<ext uri=\"\(SlicerCache.tableExtensionURI)\" xmlns:x15=\"\(x15Namespace)\">"
            extensions += "<x15:slicerCaches xmlns:x14=\"\(x14Namespace)\">\(tableSlicers)</x15:slicerCaches></ext>"
        }
        if !extensions.isEmpty { xml += "<extLst>" + extensions + "</extLst>" }
        return xml
    }

    // MARK: - Writing a changed cache

    static func xml(for value: PivotValue) -> String {
        switch value {
        case .blank: return "<m/>"
        case .number(let number): return "<n v=\"\(XLSXWriter.format(number))\"/>"
        case .text(let text): return "<s v=\"\(XMLLite.escape(text))\"/>"
        case .boolean(let flag): return "<b v=\"\(flag ? 1 : 0)\"/>"
        case .error(let raw): return "<e v=\"\(XMLLite.escape(raw))\"/>"
        case .date(let serial): return "<d v=\"\(iso(fromSerial: serial))\"/>"
        }
    }

    /// The `<sharedItems>` of a field: its items when it keeps them, and
    /// what kinds of value the field holds either way.
    private static func sharedItems(for field: PivotCacheField, values: [PivotValue]) -> String {
        var hasText = false, hasNumber = false, hasDate = false, hasBlank = false, allIntegers = true
        var low = Double.infinity, high = -Double.infinity
        for value in values {
            switch value {
            case .blank: hasBlank = true
            case .number(let number):
                hasNumber = true
                if number != number.rounded() { allIntegers = false }
                low = Swift.min(low, number)
                high = Swift.max(high, number)
            case .date(let serial):
                hasDate = true
                low = Swift.min(low, serial)
                high = Swift.max(high, serial)
            case .text, .boolean, .error: hasText = true
            }
        }
        var xml = "<sharedItems"
        if !hasText && (hasNumber || hasDate) {
            if !hasBlank { xml += " containsSemiMixedTypes=\"0\"" }
            if hasDate && !hasNumber { xml += " containsNonDate=\"0\"" }
            if hasDate { xml += " containsDate=\"1\"" }
            xml += " containsString=\"0\""
        } else if hasText && (hasNumber || hasDate) {
            if hasDate { xml += " containsDate=\"1\"" }
            xml += " containsMixedTypes=\"1\""
        }
        if hasBlank { xml += " containsBlank=\"1\"" }
        if hasNumber {
            xml += " containsNumber=\"1\""
            if allIntegers { xml += " containsInteger=\"1\"" }
            if !hasDate { xml += " minValue=\"\(XLSXWriter.format(low))\" maxValue=\"\(XLSXWriter.format(high))\"" }
        }
        if hasDate, !hasNumber {
            xml += " minDate=\"\(iso(fromSerial: low))\" maxDate=\"\(iso(fromSerial: high))\""
        }
        guard field.usesSharedItems else { return xml + "/>" }
        xml += " count=\"\(field.sharedItems.count)\">"
        xml += field.sharedItems.map(Self.xml(for:)).joined()
        return xml + "</sharedItems>"
    }

    /// The cache definition with its fields brought up to date. Fields are
    /// matched to the part's own by name; one new to the cache is written
    /// afresh.
    static func cacheDefinition(_ data: Data, for cache: PivotCache) -> Data? {
        guard let root = try? XMLLite.parse(data), let list = root.firstChild(named: "cacheFields") else { return nil }
        var existing: [String: XMLElement] = [:]
        for element in list.children(named: "cacheField") {
            existing[(element.attribute("name") ?? "").lowercased()] = element
        }
        var elements: [XMLElement] = []
        for (index, field) in cache.fields.enumerated() {
            let values = field.usesSharedItems ? field.sharedItems : cache.records.map { $0[index] }
            let element: XMLElement
            if let found = existing[field.name.lowercased()] {
                element = found
            } else {
                element = XMLElement(name: "cacheField", attributes: ["name": field.name, "numFmtId": "0"])
            }
            guard !field.isDerived, let items = XMLLite.fragment(sharedItems(for: field, values: values), namespaces: [:])
            else {
                elements.append(element)
                continue
            }
            if let old = element.firstChild(named: "sharedItems") {
                element.replaceChild(old, with: items)
            } else {
                element.insertChild(items, at: 0)
            }
            elements.append(element)
        }
        for child in list.children { list.removeChild(child) }
        for (index, element) in elements.enumerated() { list.insertChild(element, at: index) }
        list.setAttribute("count", String(elements.count))
        root.setAttribute("recordCount", String(cache.records.count))
        if case .worksheet(let sheet, let reference, let name) = cache.source,
           let source = root.firstDescendant(atPath: "cacheSource/worksheetSource") {
            source.setAttribute("sheet", sheet)
            source.setAttribute("ref", reference)
            source.setAttribute("name", name)
        }
        return XMLLite.serialize(root).map { Data((declaration + $0).utf8) }
    }

    static func cacheRecords(for cache: PivotCache) -> Data {
        var lookups: [Int: [PivotValue: Int]] = [:]
        for (index, field) in cache.fields.enumerated() where field.usesSharedItems {
            var lookup: [PivotValue: Int] = [:]
            for (position, item) in field.sharedItems.enumerated() where lookup[item.groupingKey] == nil {
                lookup[item.groupingKey] = position
            }
            lookups[index] = lookup
        }
        var xml = declaration
        xml += "<pivotCacheRecords xmlns=\"\(mainNamespace)\" xmlns:r=\"\(relationships)\" count=\"\(cache.records.count)\">"
        for record in cache.records {
            xml += "<r>"
            for (index, value) in record.enumerated() where cache.fields[index].isStored {
                if let lookup = lookups[index], let position = lookup[value.groupingKey] {
                    xml += "<x v=\"\(position)\"/>"
                } else {
                    xml += Self.xml(for: value)
                }
            }
            xml += "</r>"
        }
        xml += "</pivotCacheRecords>"
        return Data(xml.utf8)
    }

    // MARK: - Writing a changed PivotTable

    /// One line of `<rowItems>` or `<colItems>`: a row or a column of the
    /// PivotTable, as the items of the fields that head it.
    public struct AxisItem: Hashable, Sendable {
        /// `default` for a subtotal and `grand` for a grand total.
        public var kind: String?
        /// How many leading fields repeat the line before.
        public var repeated = 0
        /// Places in each following field's item list.
        public var indexes: [Int] = []
        /// The value field the line is for, when the values are on its axis.
        public var dataIndex = 0

        public init(kind: String? = nil, repeated: Int = 0, indexes: [Int] = [], dataIndex: Int = 0) {
            self.kind = kind
            self.repeated = repeated
            self.indexes = indexes
            self.dataIndex = dataIndex
        }

        var xml: String {
            var xml = "<i"
            if let kind { xml += " t=\"\(kind)\"" }
            if repeated > 0 { xml += " r=\"\(repeated)\"" }
            if dataIndex > 0 { xml += " i=\"\(dataIndex)\"" }
            guard !indexes.isEmpty else { return xml + "/>" }
            xml += ">"
            for index in indexes { xml += index == 0 ? "<x/>" : "<x v=\"\(index)\"/>" }
            return xml + "</i>"
        }
    }

    /// The PivotTable's definition with its layout brought up to date:
    /// where it is, its fields and their items, its four areas and the
    /// rows and columns they make. Everything else the part says is kept.
    static func tableDefinition(
        _ data: Data, for pivot: PivotTable, rowItems: [AxisItem], columnItems: [AxisItem]
    ) -> Data? {
        guard let root = try? XMLLite.parse(data), root.name == "pivotTableDefinition" else { return nil }
        let oldFields = root.firstChild(named: "pivotFields")?.children(named: "pivotField") ?? []
        // What the old layout's formats point at is gone with it.
        var dropped = ["location", "pivotFields", "rowFields", "rowItems", "colFields", "colItems", "pageFields", "dataFields"]
        if pivot.hasChangedLayout { dropped += ["formats", "conditionalFormats", "chartFormats", "filters"] }
        for child in root.children where dropped.contains(child.name) { root.removeChild(child) }

        var parts: [String] = []
        var location = "<location ref=\"\(pivot.location.a1)\" firstHeaderRow=\"\(pivot.firstHeaderRow)\""
        location += " firstDataRow=\"\(pivot.firstDataRow)\" firstDataCol=\"\(pivot.firstDataColumn)\""
        if !pivot.filters.isEmpty { location += " rowPageCount=\"\(pivot.filters.count)\" colPageCount=\"1\"" }
        parts.append(location + "/>")

        func list(_ name: String, _ entries: [String]) -> String? {
            entries.isEmpty ? nil : "<\(name) count=\"\(entries.count)\">" + entries.joined() + "</\(name)>"
        }
        func append(_ xml: String?) { if let xml { parts.append(xml) } }
        let fieldPlaceholder = "<pivotFields count=\"\(pivot.fields.count)\"/>"
        parts.append(fieldPlaceholder)
        append(list("rowFields", pivot.rowFields.map { "<field x=\"\($0)\"/>" }))
        append(list("rowItems", rowItems.map(\.xml)))
        append(list("colFields", pivot.columnFields.map { "<field x=\"\($0)\"/>" }))
        append(list("colItems", columnItems.map(\.xml)))
        append(list("pageFields", pivot.filters.map { filter in
            var xml = "<pageField fld=\"\(filter.field)\""
            if let item = filter.selectedItem { xml += " item=\"\(item)\"" }
            return xml + " hier=\"-1\"/>"
        }))
        append(list("dataFields", pivot.dataFields.map { data in
            var xml = "<dataField name=\"\(XMLLite.escape(data.name))\" fld=\"\(data.field)\""
            if data.aggregation != .sum { xml += " subtotal=\"\(data.aggregation.rawValue)\"" }
            if let shown = data.showDataAs { xml += " showDataAs=\"\(XMLLite.escape(shown))\"" }
            xml += " baseField=\"0\" baseItem=\"0\""
            if let format = data.numberFormatID { xml += " numFmtId=\"\(format)\"" }
            return xml + "/>"
        }))
        for (index, part) in parts.enumerated() {
            guard let element = XMLLite.fragment(part, namespaces: [:]) else { return nil }
            root.insertChild(element, at: index)
        }

        // Each field keeps what the file said of it, with its area and items
        // made current.
        guard let fieldList = root.firstChild(named: "pivotFields") else { return nil }
        for (index, field) in pivot.fields.enumerated() {
            let element = field.fileIndex.flatMap { oldFields.indices.contains($0) ? oldFields[$0] : nil }
                ?? XMLElement(name: "pivotField", attributes: ["showAll": "0"])
            let axis: String?
            if pivot.rowFields.contains(index) {
                axis = "axisRow"
            } else if pivot.columnFields.contains(index) {
                axis = "axisCol"
            } else if pivot.filters.contains(where: { $0.field == index }) {
                axis = "axisPage"
            } else {
                axis = nil
            }
            element.setAttribute("axis", axis)
            element.setAttribute("dataField", pivot.dataFields.contains { $0.field == index } ? "1" : nil)
            var oldItems: [Int: XMLElement] = [:]
            if let items = element.firstChild(named: "items") {
                for item in items.children(named: "item") where item.attribute("t") == nil {
                    oldItems[item.attribute("x").flatMap(Int.init) ?? 0] = item
                }
                element.removeChild(items)
            }
            if !field.items.isEmpty {
                let items = XMLElement(name: "items", attributes: ["count": String(field.items.count)])
                for (position, item) in field.items.enumerated() {
                    let entry: XMLElement
                    if let shared = item.sharedIndex {
                        entry = oldItems[shared] ?? XMLElement(name: "item", attributes: [:])
                        entry.setAttribute("x", String(shared))
                        entry.setAttribute("h", item.isHidden ? "1" : nil)
                        // Every group is laid out open.
                        entry.setAttribute("sd", nil)
                    } else {
                        entry = XMLElement(name: "item", attributes: ["t": item.kind ?? "default"])
                    }
                    items.insertChild(entry, at: position)
                }
                element.insertChild(items, at: 0)
            }
            fieldList.insertChild(element, at: index)
        }

        root.setAttribute("rowGrandTotals", pivot.showsRowGrandTotals ? nil : "0")
        root.setAttribute("colGrandTotals", pivot.showsColumnGrandTotals ? nil : "0")
        root.setAttribute("rowHeaderCaption", pivot.rowHeaderCaption)
        root.setAttribute("colHeaderCaption", pivot.columnHeaderCaption)
        root.setAttribute("grandTotalCaption", pivot.grandTotalCaption)
        return XMLLite.serialize(root).map { Data((declaration + $0).utf8) }
    }

    /// A slicer cache's definition with its buttons brought up to date.
    static func slicerCacheDefinition(_ data: Data, for slicer: SlicerCache) -> Data? {
        guard let root = try? XMLLite.parse(data), let tabular = root.firstDescendant(atPath: "data/tabular") else {
            return nil
        }
        let prefix = tabular.qualifiedName.hasSuffix(":tabular") ? String(tabular.qualifiedName.dropLast("tabular".count)) : ""
        var existing: [Int: XMLElement] = [:]
        if let old = tabular.firstChild(named: "items") {
            for item in old.children(named: "i") { existing[item.attribute("x").flatMap(Int.init) ?? 0] = item }
            tabular.removeChild(old)
        }
        let items = XMLElement(
            name: "items", qualifiedName: prefix + "items",
            attributes: ["count": String(slicer.items.count)], qualifiedAttributes: ["count": String(slicer.items.count)])
        for (position, item) in slicer.items.enumerated() {
            let element = existing[item.sharedIndex] ?? XMLElement(
                name: "i", qualifiedName: prefix + "i",
                attributes: ["x": String(item.sharedIndex)], qualifiedAttributes: ["x": String(item.sharedIndex)])
            element.setAttribute("s", item.isSelected ? "1" : nil)
            items.insertChild(element, at: position)
        }
        tabular.insertChild(items, at: 0)
        return XMLLite.serialize(root).map { Data((declaration + $0).utf8) }
    }

    // MARK: - Dates

    /// Days from 1970-01-01 to a date of the proleptic Gregorian calendar.
    private static func days(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    /// 1899-12-30, which a serial counts from once past February 1900.
    private static let serialEpoch = -25_569

    /// The serial of `2024-01-15T08:30:00`, as a cache writes a date.
    static func serial(fromISO text: String) -> Double? {
        let numbers = text.split(whereSeparator: { !$0.isNumber && $0 != "." }).compactMap { Double($0) }
        guard numbers.count >= 3 else { return nil }
        var serial = Double(days(year: Int(numbers[0]), month: Int(numbers[1]), day: Int(numbers[2])) - serialEpoch)
        if serial < 61 { serial -= 1 }
        if numbers.count >= 6 { serial += (numbers[3] * 3600 + numbers[4] * 60 + numbers[5]) / 86_400 }
        return serial
    }

    static func iso(fromSerial serial: Double) -> String {
        var whole = Int(serial.rounded(.down))
        var seconds = Int(((serial - Double(whole)) * 86_400).rounded())
        if seconds >= 86_400 {
            seconds = 0
            whole += 1
        }
        // Back to days from 1970, past the February 29th that 1900 lacked.
        var z = (whole < 61 ? whole + 1 : whole) + serialEpoch + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        z -= era * 146_097
        let yearOfEra = (z - z / 1_460 + z / 36_524 - z / 146_096) / 365
        let dayOfYear = z - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let shifted = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * shifted + 2) / 5 + 1
        let month = shifted < 10 ? shifted + 3 : shifted - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        func pad(_ value: Int, _ width: Int = 2) -> String {
            let text = String(value)
            return String(repeating: "0", count: Swift.max(0, width - text.count)) + text
        }
        return "\(pad(year, 4))-\(pad(month))-\(pad(day))T\(pad(seconds / 3600)):\(pad(seconds / 60 % 60)):\(pad(seconds % 60))"
    }
}
