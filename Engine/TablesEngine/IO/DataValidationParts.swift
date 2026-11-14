import Foundation

/// Reads a worksheet's data validation rules and writes them back.
///
/// Excel keeps them in two places: `<dataValidations>` itself, and — for the
/// rules whose formulas name another sheet, which Excel 2007 could not read
/// — an `x14` copy of the same list inside `<extLst>`. Both are read into the
/// one list. All of it is written as `<dataValidations>`, which every Excel
/// since 2010 reads whatever a rule's formulas name.
enum DataValidationParts {
    /// The `uri` of the `<ext>` that holds the `x14` list.
    static let extensionURI = "{CCE6A557-97BC-4b89-ADB6-D9C93CAAB3DF}"

    /// Whether an `<ext>` of a worksheet's `<extLst>` is the `x14` list.
    static func isValidationExtension(_ ext: XMLElement) -> Bool {
        ext.children.contains { $0.name == "dataValidations" }
    }

    // MARK: - Reading

    /// The rules of a worksheet, the main list first.
    static func read(from worksheet: XMLElement) -> [DataValidation] {
        var lists = worksheet.children(named: "dataValidations")
        for ext in worksheet.firstChild(named: "extLst")?.children(named: "ext") ?? [] {
            lists += ext.children(named: "dataValidations")
        }
        return lists.flatMap { $0.children(named: "dataValidation") }.compactMap(rule)
    }

    private static func rule(_ element: XMLElement) -> DataValidation? {
        // The `x14` form holds its ranges and formulas in child elements.
        let sqref = element.attribute("sqref") ?? element.firstChild(named: "sqref")?.text ?? ""
        let ranges = ConditionalRule.ranges(sqref: sqref)
        guard !ranges.isEmpty,
              let kind = DataValidation.Kind(rawValue: element.attribute("type") ?? "none") else { return nil }
        func formula(_ name: String) -> String? {
            guard let holder = element.firstChild(named: name) else { return nil }
            let text = holder.firstChild(named: "f")?.text ?? holder.text
            return text.isEmpty ? nil : FormulaDialect.fromFile(text)
        }
        func flag(_ name: String) -> Bool { ["1", "true"].contains(element.attribute(name) ?? "") }
        func text(_ name: String) -> String? {
            element.attribute(name).flatMap { $0.isEmpty ? nil : $0 }
        }
        return DataValidation(
            ranges: ranges, kind: kind,
            comparison: element.attribute("operator").flatMap(DataValidation.Comparison.init(rawValue:)) ?? .between,
            formula1: formula("formula1"), formula2: formula("formula2"),
            allowsBlank: flag("allowBlank"),
            // The attribute says the opposite of its name: set, the arrow is hidden.
            showsDropDown: !flag("showDropDown"),
            showsInputMessage: flag("showInputMessage"), showsErrorMessage: flag("showErrorMessage"),
            alertStyle: element.attribute("errorStyle").flatMap(DataValidation.AlertStyle.init(rawValue:)) ?? .stop,
            errorTitle: text("errorTitle"), errorMessage: text("error"),
            promptTitle: text("promptTitle"), promptMessage: text("prompt"), imeMode: text("imeMode")
        )
    }

    // MARK: - Writing

    /// The `<dataValidations>` element for a sheet's rules, or nil for none.
    static func element(for rules: [DataValidation]) -> String? {
        let rules = rules.filter { !$0.ranges.isEmpty }
        guard !rules.isEmpty else { return nil }
        var xml = "<dataValidations count=\"\(rules.count)\">"
        for rule in rules {
            xml += "<dataValidation"
            func attribute(_ name: String, _ value: String?) {
                guard let value, !value.isEmpty else { return }
                xml += " \(name)=\"\(XMLLite.escape(value))\""
            }
            if rule.kind != .any { attribute("type", rule.kind.rawValue) }
            if rule.alertStyle != .stop { attribute("errorStyle", rule.alertStyle.rawValue) }
            attribute("imeMode", rule.imeMode)
            if rule.kind.usesComparison, rule.comparison != .between { attribute("operator", rule.comparison.rawValue) }
            if rule.allowsBlank { attribute("allowBlank", "1") }
            if !rule.showsDropDown { attribute("showDropDown", "1") }
            if rule.showsInputMessage { attribute("showInputMessage", "1") }
            if rule.showsErrorMessage { attribute("showErrorMessage", "1") }
            attribute("errorTitle", rule.errorTitle)
            attribute("error", rule.errorMessage)
            attribute("promptTitle", rule.promptTitle)
            attribute("prompt", rule.promptMessage)
            attribute("sqref", rule.ranges.map(\.a1).joined(separator: " "))
            xml += ">"
            if let formula = rule.formula1, !formula.isEmpty {
                xml += "<formula1>\(XMLLite.escape(FormulaDialect.toFile(formula)))</formula1>"
            }
            if let formula = rule.formula2, !formula.isEmpty {
                xml += "<formula2>\(XMLLite.escape(FormulaDialect.toFile(formula)))</formula2>"
            }
            xml += "</dataValidation>"
        }
        return xml + "</dataValidations>"
    }
}
