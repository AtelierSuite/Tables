import Foundation
import TablesEngine

/// What the find panel on iOS and the find bar on the Mac share about Replace.
enum FindReplace {
    /// The match Replace changes: the selected cell when it is one, or else
    /// the first match after it, wrapping round to the first of all.
    static func target(
        in matches: [FindMatch], sheetID: Worksheet.ID, address: CellAddress, workbook: Workbook
    ) -> FindMatch? {
        if let selected = matches.first(where: { $0.sheetID == sheetID && $0.address == address }) {
            return selected
        }
        return next(after: sheetID, address, in: matches, workbook: workbook)
    }

    /// The first match after the cell, in the order Find lists them.
    static func next(
        after sheetID: Worksheet.ID, _ address: CellAddress, in matches: [FindMatch], workbook: Workbook
    ) -> FindMatch? {
        let order = Dictionary(uniqueKeysWithValues: workbook.sheets.enumerated().map { ($1.id, $0) })
        let position = { (sheetID: Worksheet.ID, address: CellAddress) in
            [order[sheetID] ?? 0, address.row, address.column]
        }
        let start = position(sheetID, address)
        return matches.first { start.lexicographicallyPrecedes(position($0.sheetID, $0.address)) } ?? matches.first
    }

    /// One line for how many cells were changed, then one for each reason
    /// cells were left alone.
    static func summary(of result: ReplaceResult) -> String {
        var lines = [String.localizedStringWithFormat(String(localized: "Find.Replaced"), result.replaced.count)]
        let reasons: [(ReplaceResult.SkipReason, String.LocalizationValue)] = [
            (.invalidFormula, "Find.Skipped.InvalidFormula"),
            (.formulaResult, "Find.Skipped.FormulaResult"),
            (.notANumber, "Find.Skipped.NotANumber"),
        ]
        for (reason, key) in reasons {
            let count = result.skippedCount(reason)
            if count > 0 { lines.append(String.localizedStringWithFormat(String(localized: key), count)) }
        }
        return lines.joined(separator: "\n")
    }
}

extension FindOptions.LookIn {
    var title: String {
        switch self {
        case .formulasAndValues: String(localized: "Find.LookIn.FormulasAndValues")
        case .formulas: String(localized: "Find.LookIn.Formulas")
        case .values: String(localized: "Find.LookIn.Values")
        }
    }
}
