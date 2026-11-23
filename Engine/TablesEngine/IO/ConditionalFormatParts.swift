import Foundation

/// Writes conditional formats the person edited as the XML a save carries.
///
/// Until a sheet's rules are edited, the file's own `<conditionalFormatting>`
/// stays as it was read. Once they are, the sheet's formats are written afresh
/// from the rules, each styled by a `<dxf>` added to the workbook's table.
enum ConditionalFormatParts {
    /// The `<dxf>` that gives a cell `style`.
    static func differentialFormat(for style: ConditionalStyle) -> String {
        var font = ""
        if let isBold = style.isBold { font += isBold ? "<b/>" : "<b val=\"0\"/>" }
        if let isItalic = style.isItalic { font += isItalic ? "<i/>" : "<i val=\"0\"/>" }
        if let isStruckThrough = style.isStruckThrough { font += isStruckThrough ? "<strike/>" : "<strike val=\"0\"/>" }
        if let isUnderlined = style.isUnderlined { font += isUnderlined ? "<u/>" : "<u val=\"none\"/>" }
        if let color = style.textColorHex { font += "<color rgb=\"\(XMLLite.escape(color))\"/>" }
        var xml = "<dxf>"
        if !font.isEmpty { xml += "<font>\(font)</font>" }
        if let fill = style.fillColorHex {
            xml += "<fill><patternFill patternType=\"solid\"><bgColor rgb=\"\(XMLLite.escape(fill))\"/></patternFill></fill>"
        }
        return xml + "</dxf>"
    }

    /// Whether a rule of this kind is drawn by a `<dxf>`, rather than by itself.
    static func needsStyle(_ kind: ConditionalRule.Kind) -> Bool {
        switch kind {
        case .colorScale, .dataBar, .iconSet: return false
        case .test, .rank, .average, .duplicates: return true
        }
    }

    /// The `<conditionalFormatting>` holding one rule.
    static func element(for rule: ConditionalRule, priority: Int, differentialFormat: Int?) -> String {
        let sqref = rule.ranges.map { $0.normalized.a1 }.joined(separator: " ")
        var attributes: [(String, String)] = []
        var body = ""
        func formulas(_ list: [String]) -> String {
            list.map { "<formula>\(XMLLite.escape($0))</formula>" }.joined()
        }
        func points(_ thresholds: [ConditionalThreshold], keepsAutomatic: Bool = false) -> String {
            thresholds.map { point in
                var kind = point.kind
                if !keepsAutomatic {
                    if kind == .automaticMinimum { kind = .minimum }
                    if kind == .automaticMaximum { kind = .maximum }
                }
                var xml = "<cfvo type=\"\(kind.rawValue)\""
                if kind != .minimum, kind != .maximum, let value = point.value {
                    xml += " val=\"\(XMLLite.escape(value))\""
                }
                if !point.isInclusive { xml += " gte=\"0\"" }
                return xml + "/>"
            }.joined()
        }
        func color(_ hex: String) -> String { "<color rgb=\"\(XMLLite.escape(hex))\"/>" }

        let type: String
        switch rule.kind {
        case .test:
            if let comparison = rule.comparison {
                type = "cellIs"
                attributes.append(("operator", comparison.rawValue))
            } else {
                type = "expression"
            }
            let count = rule.comparison?.operandCount ?? 1
            body = formulas(Array(rule.formulas.prefix(count)))
        case .rank(let count, let isPercent, let isBottom):
            type = "top10"
            if isPercent { attributes.append(("percent", "1")) }
            if isBottom { attributes.append(("bottom", "1")) }
            attributes.append(("rank", String(count)))
        case .average(let isAbove, let includesEqual, let deviations):
            type = "aboveAverage"
            if !isAbove { attributes.append(("aboveAverage", "0")) }
            if includesEqual { attributes.append(("equalAverage", "1")) }
            if deviations != 0 { attributes.append(("stdDev", String(deviations))) }
        case .duplicates(let isUnique):
            type = isUnique ? "uniqueValues" : "duplicateValues"
        case .colorScale(let thresholds, let colors):
            type = "colorScale"
            body = "<colorScale>" + points(thresholds) + colors.map(color).joined() + "</colorScale>"
        case .dataBar(let bar):
            type = "dataBar"
            var open = "<dataBar"
            if bar.minimumLength != 10 { open += " minLength=\"\(XLSXWriter.format(bar.minimumLength))\"" }
            if bar.maximumLength != 90 { open += " maxLength=\"\(XLSXWriter.format(bar.maximumLength))\"" }
            if !bar.showsValue { open += " showValue=\"0\"" }
            body = open + ">" + points([bar.minimum, bar.maximum]) + color(bar.colorHex) + "</dataBar>"
        case .iconSet(let set):
            type = "iconSet"
            var open = "<iconSet iconSet=\"\(XMLLite.escape(set.name))\""
            if !set.showsValue { open += " showValue=\"0\"" }
            if set.isReversed { open += " reverse=\"1\"" }
            body = open + ">" + points(set.thresholds) + "</iconSet>"
        }

        var xml = "<conditionalFormatting sqref=\"\(sqref)\"><cfRule type=\"\(type)\""
        if let differentialFormat { xml += " dxfId=\"\(differentialFormat)\"" }
        xml += " priority=\"\(priority)\""
        if rule.stopsIfTrue { xml += " stopIfTrue=\"1\"" }
        for (name, value) in attributes { xml += " \(name)=\"\(XMLLite.escape(value))\"" }
        return xml + ">" + body + "</cfRule></conditionalFormatting>"
    }

    /// Whether an `<ext>` of a worksheet's `<extLst>` holds Excel 2010's formats.
    static func isFormatExtension(_ ext: XMLElement) -> Bool {
        ext.children.contains { $0.name == "conditionalFormattings" }
    }
}

extension Workbook {
    /// Replaces a sheet's conditional formats with `rules`, in order of
    /// priority, and writes them into the XML a save carries.
    public mutating func setConditionalRules(_ rules: [ConditionalRule], sheetIndex: Int) {
        guard sheets.indices.contains(sheetIndex) else { return }
        let rules = rules.filter { !$0.ranges.isEmpty }.enumerated().map { offset, rule in
            var numbered = rule
            numbered.priority = offset + 1
            if !ConditionalFormatParts.needsStyle(rule.kind) { numbered.style = ConditionalStyle() }
            return numbered
        }

        let existing = preservedPackage.styleSheetElements.firstIndex { $0.name == "dxfs" }
        guard let table = existing.map({ try? XMLLite.parse(Data(preservedPackage.styleSheetElements[$0].xml.utf8)) })
                ?? XMLLite.fragment("<dxfs/>", namespaces: [:]) else { return }
        var formats = table.children(named: "dxf").map { XMLLite.serialize($0) }
        var elements = sheets[sheetIndex].preservedElements.compactMap { element -> PreservedElement? in
            if element.name == "conditionalFormatting" { return nil }
            guard element.name == "extLst", let root = try? XMLLite.parse(Data(element.xml.utf8)) else { return element }
            let exts = root.children(named: "ext").filter(ConditionalFormatParts.isFormatExtension)
            guard !exts.isEmpty else { return element }
            for ext in exts { root.removeChild(ext) }
            guard !root.children.isEmpty, let xml = XMLLite.serialize(root) else { return nil }
            return PreservedElement(name: element.name, xml: xml)
        }
        for rule in rules {
            var index: Int?
            if ConditionalFormatParts.needsStyle(rule.kind),
               let format = XMLLite.fragment(ConditionalFormatParts.differentialFormat(for: rule.style), namespaces: [:]),
               let xml = XMLLite.serialize(format) {
                if let found = formats.firstIndex(of: xml) {
                    index = found
                } else {
                    table.insertChild(format, at: table.children.count)
                    formats.append(xml)
                    index = formats.count - 1
                }
            }
            elements.append(PreservedElement(
                name: "conditionalFormatting",
                xml: ConditionalFormatParts.element(for: rule, priority: rule.priority, differentialFormat: index)))
        }

        if !formats.isEmpty {
            table.setAttribute("count", String(formats.count))
            guard let xml = XMLLite.serialize(table) else { return }
            if let existing {
                preservedPackage.styleSheetElements[existing] = PreservedElement(name: "dxfs", xml: xml)
            } else {
                preservedPackage.styleSheetElements.append(PreservedElement(name: "dxfs", xml: xml))
            }
        }
        sheets[sheetIndex].preservedElements = elements
        sheets[sheetIndex].conditionalRules = rules
        recalculate()
    }
}
