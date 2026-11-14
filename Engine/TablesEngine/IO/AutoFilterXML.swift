import Foundation

/// Reading and writing a sheet's `<autoFilter>`.
extension AutoFilter {
    /// The filter an `<autoFilter>` element describes, or nil when its range
    /// cannot be read.
    init?(element: XMLElement) {
        guard let ref = element.attribute("ref"), let range = CellRange(a1Range: ref) else { return nil }
        self.init(range: range)
        // Kept children are written back inside our own `<autoFilter>`, in
        // the same namespace, so they need not declare it again.
        var scope = element.namespaceDeclarations
        scope[""] = element.sourceNamespaceBinding(forPrefix: "")
        func kept(_ child: XMLElement) -> String? { XMLLite.serialize(child, inheritedNamespaces: scope) }
        for column in element.children(named: "filterColumn") {
            guard let offset = column.attribute("colId").flatMap(Int.init), offset >= 0 else { continue }
            if ["1", "true"].contains(column.attribute("hiddenButton") ?? "")
                || ["0", "false"].contains(column.attribute("showButton") ?? "") {
                hiddenButtons.insert(offset)
            }
            guard let child = column.children.first else { continue }
            columns[offset] = Self.criterion(from: child) ?? kept(child).map { .kept(xml: $0) }
        }
        sortStateXML = element.firstChild(named: "sortState").flatMap(kept)
        extensionsXML = element.firstChild(named: "extLst").flatMap(kept)
    }

    private static func criterion(from element: XMLElement) -> Criterion? {
        switch element.name {
        case "filters":
            // A calendar other than the Gregorian one is not worked out here.
            guard element.attribute("calendarType") == nil else { return nil }
            var dates: [DateGroup] = []
            for item in element.children(named: "dateGroupItem") {
                guard let grouping = item.attribute("dateTimeGrouping").flatMap(DateGroup.Grouping.init(rawValue:)),
                      let year = item.attribute("year").flatMap(Int.init) else { return nil }
                func part(_ name: String, _ fallback: Int) -> Int { item.attribute(name).flatMap(Int.init) ?? fallback }
                dates.append(DateGroup(
                    grouping: grouping, year: year, month: part("month", 1), day: part("day", 1),
                    hour: part("hour", 0), minute: part("minute", 0), second: part("second", 0)))
            }
            let values = element.children(named: "filter").compactMap { $0.attribute("val") }
            return .values(
                Set(values), includesBlanks: ["1", "true"].contains(element.attribute("blank") ?? ""), dates: dates)
        case "customFilters":
            let conditions = element.children(named: "customFilter").compactMap { item -> Condition? in
                guard let comparison = Comparison(rawValue: item.attribute("operator") ?? "equal") else { return nil }
                return Condition(comparison, item.attribute("val") ?? "")
            }
            guard let first = conditions.first, conditions.count == element.children.count, conditions.count <= 2 else {
                return nil
            }
            return .conditions(
                first, conditions.count == 2 ? conditions[1] : nil,
                matchesBoth: ["1", "true"].contains(element.attribute("and") ?? ""))
        case "top10":
            guard let count = element.attribute("val").flatMap(Double.init) else { return nil }
            return .top(
                count: count, isPercent: ["1", "true"].contains(element.attribute("percent") ?? ""),
                isBottom: ["0", "false"].contains(element.attribute("top") ?? ""))
        default:
            return nil
        }
    }

    /// The `<autoFilter>` element for this filter.
    var xml: String {
        var xml = "<autoFilter ref=\"\(range.a1)\""
        let offsets = Set(columns.keys).union(hiddenButtons).filter { $0 < range.columnRange.count }.sorted()
        guard !offsets.isEmpty || sortStateXML != nil || extensionsXML != nil else { return xml + "/>" }
        xml += ">"
        for offset in offsets {
            xml += "<filterColumn colId=\"\(offset)\""
            if hiddenButtons.contains(offset) { xml += " hiddenButton=\"1\"" }
            guard let criterion = columns[offset] else {
                xml += "/>"
                continue
            }
            xml += ">" + Self.xml(for: criterion) + "</filterColumn>"
        }
        xml += (sortStateXML ?? "") + (extensionsXML ?? "") + "</autoFilter>"
        return xml
    }

    private static func xml(for criterion: Criterion) -> String {
        switch criterion {
        case .values(let values, let includesBlanks, let dates):
            var xml = "<filters" + (includesBlanks ? " blank=\"1\"" : "") + ">"
            for value in values.sorted() { xml += "<filter val=\"\(XMLLite.escape(value))\"/>" }
            for date in dates {
                xml += "<dateGroupItem year=\"\(date.year)\""
                let parts: [(String, Int, DateGroup.Grouping)] = [
                    ("month", date.month, .month), ("day", date.day, .day), ("hour", date.hour, .hour),
                    ("minute", date.minute, .minute), ("second", date.second, .second),
                ]
                let order: [DateGroup.Grouping] = [.year, .month, .day, .hour, .minute, .second]
                let depth = order.firstIndex(of: date.grouping) ?? 0
                for (name, value, grouping) in parts where (order.firstIndex(of: grouping) ?? 0) <= depth {
                    xml += " \(name)=\"\(value)\""
                }
                xml += " dateTimeGrouping=\"\(date.grouping.rawValue)\"/>"
            }
            return xml + "</filters>"
        case .conditions(let first, let second, let matchesBoth):
            var xml = "<customFilters" + (matchesBoth && second != nil ? " and=\"1\"" : "") + ">"
            for condition in [first, second].compactMap({ $0 }) {
                xml += "<customFilter"
                if condition.comparison != .equal { xml += " operator=\"\(condition.comparison.rawValue)\"" }
                xml += " val=\"\(XMLLite.escape(condition.value))\"/>"
            }
            return xml + "</customFilters>"
        case .top(let count, let isPercent, let isBottom):
            var xml = "<top10"
            if isBottom { xml += " top=\"0\"" }
            if isPercent { xml += " percent=\"1\"" }
            return xml + " val=\"\(CellValue.plainNumberString(count))\"/>"
        case .kept(let xml):
            return xml
        }
    }
}

extension Worksheet {
    /// Takes the kept `<autoFilter>` into the model and hides the rows it
    /// turns away. A filter Tables cannot work out in full keeps the rows
    /// the file hid.
    mutating func readAutoFilter() {
        guard let index = preservedElements.firstIndex(where: { $0.name == "autoFilter" }),
              let root = try? XMLLite.parse(Data(preservedElements[index].xml.utf8)),
              var filter = AutoFilter(element: root) else { return }
        preservedElements.remove(at: index)
        // Rows the file hides inside the filter count as the filter's, as Excel takes them.
        if filter.isEvaluable {
            filter.filteredRows = rowsFilteredOut(by: filter).filter { $0 < rowCount }
            hiddenRows.formUnion(filter.filteredRows)
        } else if let rows = filter.dataRows {
            filter.filteredRows = hiddenRows.filter { rows.contains($0) }
        }
        autoFilter = filter
    }
}
