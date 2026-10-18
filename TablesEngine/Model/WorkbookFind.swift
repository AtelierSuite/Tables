import Foundation

/// A cell whose shown value or formula holds the text being looked for.
public struct FindMatch: Identifiable, Hashable, Sendable {
    public let sheetID: Worksheet.ID
    public let address: CellAddress
    /// What the cell shows, or its formula when only the formula matched.
    public let text: String

    public var id: String { "\(sheetID)-\(address.a1)" }
}

extension Workbook {
    /// Every cell holding `query`, sheet by sheet in tab order and row by row
    /// within each. A cell matches on what it shows or on its formula, so a
    /// reference or function name can be found as well as a result.
    public func matches(for query: String, matchesCase: Bool = false) -> [FindMatch] {
        guard !query.isEmpty else { return [] }
        let options: String.CompareOptions = matchesCase ? [] : [.caseInsensitive]
        return sheets.filter { !$0.isChartSheet }.flatMap { sheet in
            sheet.cells
                .compactMap { address, cell -> FindMatch? in
                    let shown = CellFormatter.displayText(for: cell)
                    if shown.range(of: query, options: options) != nil {
                        return FindMatch(sheetID: sheet.id, address: address, text: shown)
                    }
                    if let formula = cell.formula, formula.range(of: query, options: options) != nil {
                        return FindMatch(sheetID: sheet.id, address: address, text: "=" + formula)
                    }
                    return nil
                }
                .sorted { ($0.address.row, $0.address.column) < ($1.address.row, $1.address.column) }
        }
    }
}
