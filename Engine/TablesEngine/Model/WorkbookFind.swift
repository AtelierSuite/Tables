import Foundation

/// A cell whose shown value or formula holds the text being looked for.
public struct FindMatch: Identifiable, Hashable, Sendable {
    public let sheetID: Worksheet.ID
    public let address: CellAddress
    /// What the cell shows, or its formula when only the formula matched.
    public let text: String

    public var id: String { "\(sheetID)-\(address.a1)" }
}

/// How Find compares a cell with the text being looked for.
public struct FindOptions: Hashable, Sendable {
    /// Which of a cell's texts Find looks at.
    public enum LookIn: String, CaseIterable, Hashable, Sendable {
        /// What the cell holds or what it shows, whichever matches.
        case formulasAndValues
        /// What the cell holds: its formula, or the value as it would be typed.
        case formulas
        /// What the cell shows.
        case values
    }

    public var matchesCase: Bool
    /// The whole text has to be the text looked for, not just contain it.
    public var matchesWholeCell: Bool
    public var lookIn: LookIn

    public init(matchesCase: Bool = false, matchesWholeCell: Bool = false, lookIn: LookIn = .formulasAndValues) {
        self.matchesCase = matchesCase
        self.matchesWholeCell = matchesWholeCell
        self.lookIn = lookIn
    }
}

/// What Replace did: the cells it changed, and those it found but left alone.
public struct ReplaceResult: Hashable, Sendable {
    /// Why a matching cell was left as it was.
    public enum SkipReason: Hashable, Sendable {
        /// The formula the replacement would leave isn't one.
        case invalidFormula
        /// The text matched is what a formula worked out, not what the cell holds.
        case formulaResult
        /// A number or date shown as text that would no longer read as one.
        case notANumber
    }

    public struct Skip: Hashable, Sendable {
        public let match: FindMatch
        public let reason: SkipReason
    }

    public var replaced: [FindMatch] = []
    public var skipped: [Skip] = []

    public init() { /* Starts empty. */ }

    /// How many matching cells were skipped for `reason`.
    public func skippedCount(_ reason: SkipReason) -> Int {
        skipped.filter { $0.reason == reason }.count
    }
}

extension Workbook {
    /// Every cell holding `query`, sheet by sheet in tab order and row by row
    /// within each. A cell matches on what it shows or on its formula, so a
    /// reference or function name can be found as well as a result.
    public func matches(for query: String, matchesCase: Bool = false) -> [FindMatch] {
        matches(for: query, options: FindOptions(matchesCase: matchesCase))
    }

    /// Every cell holding `query` as `options` compare it, sheet by sheet in
    /// tab order and row by row within each.
    public func matches(for query: String, options: FindOptions) -> [FindMatch] {
        guard !query.isEmpty else { return [] }
        return sheets.filter { !$0.isChartSheet }.flatMap { sheet in
            sheet.cells
                .compactMap { address, cell -> FindMatch? in
                    FindTarget(cell: cell, query: query, options: options).map {
                        FindMatch(sheetID: sheet.id, address: address, text: $0.listed)
                    }
                }
                .sorted { ($0.address.row, $0.address.column) < ($1.address.row, $1.address.column) }
        }
    }

    /// Replaces `query` with `replacement` in every matching cell, as one
    /// change to the workbook.
    @discardableResult
    public mutating func replaceAll(
        _ query: String, with replacement: String, options: FindOptions = FindOptions()
    ) -> ReplaceResult {
        replace(matches(for: query, options: options), query: query, with: replacement, options: options)
    }

    /// Replaces `query` with `replacement` in the cells of `matches`. Each is
    /// looked at again first, so a cell that no longer matches is left alone.
    /// A cell is changed only if what it would hold still makes sense: a
    /// formula has to stay a valid formula, and a number has to stay a
    /// number; the rest are skipped and reported.
    @discardableResult
    public mutating func replace(
        _ matches: [FindMatch], query: String, with replacement: String, options: FindOptions = FindOptions()
    ) -> ReplaceResult {
        var result = ReplaceResult()
        guard !query.isEmpty else { return result }
        for match in matches {
            guard let index = sheets.firstIndex(where: { $0.id == match.sheetID }), !sheets[index].isChartSheet,
                  let cell = sheets[index].cells[match.address],
                  let target = FindTarget(cell: cell, query: query, options: options) else { continue }
            switch target.replacing(query, with: replacement, in: cell, options: options) {
            case .success(let updated):
                sheets[index][match.address] = updated
                result.replaced.append(match)
            case .failure(let skip):
                result.skipped.append(ReplaceResult.Skip(match: match, reason: skip.reason))
            }
        }
        if !result.replaced.isEmpty { recalculate() }
        return result
    }
}

/// The text of one cell that a search matched.
private struct FindTarget {
    enum Source { case content, shown }

    let source: Source
    let text: String
    /// What the results list shows for the cell.
    let listed: String

    init?(cell: Cell, query: String, options: FindOptions) {
        let shown = CellFormatter.displayText(for: cell)
        // A spilled cell holds nothing of its own; what it shows is the formula's.
        let content: String? = cell.isSpilled ? nil : cell.editableText
        let contentMatches = options.lookIn != .values && content.map { Self.contains($0, query, options) } == true
        let shownMatches = options.lookIn != .formulas && Self.contains(shown, query, options)
        if contentMatches, let content {
            source = .content
            text = content
            listed = shownMatches ? shown : content
        } else if shownMatches {
            source = .shown
            text = shown
            listed = shown
        } else {
            return nil
        }
    }

    struct Skip: Error { let reason: ReplaceResult.SkipReason }

    /// The cell as it would be with the text replaced.
    func replacing(_ query: String, with replacement: String, in cell: Cell, options: FindOptions) -> Result<Cell, Skip> {
        let new = options.matchesWholeCell ? replacement
            : text.replacingOccurrences(of: query, with: replacement, options: Self.compareOptions(options))
        if source == .shown, cell.formula != nil || cell.isSpilled {
            return .failure(Skip(reason: .formulaResult))
        }
        let parsed = CellInputParser.cell(from: new, inheriting: cell.style)
        if cell.formula != nil || parsed.formula != nil {
            guard let formula = parsed.formula, (try? FormulaParser.parse(formula)) != nil else {
                return .failure(Skip(reason: .invalidFormula))
            }
        }
        if source == .shown, case .number = cell.value {
            guard case .number = parsed.value else { return .failure(Skip(reason: .notANumber)) }
        }
        var updated = cell
        updated.value = parsed.value
        updated.formula = parsed.formula
        updated.style = source == .shown ? cell.style : parsed.style
        updated.savedResultInputs = nil
        if parsed.formula == nil { updated.arrayExtent = nil }
        return .success(updated)
    }

    private static func compareOptions(_ options: FindOptions) -> String.CompareOptions {
        options.matchesCase ? [] : [.caseInsensitive]
    }

    private static func contains(_ text: String, _ query: String, _ options: FindOptions) -> Bool {
        let compare = compareOptions(options)
        if options.matchesWholeCell {
            return text.compare(query, options: compare) == .orderedSame
        }
        return text.range(of: query, options: compare) != nil
    }
}
