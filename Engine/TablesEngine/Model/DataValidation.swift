import Foundation

/// One data validation rule: what may be entered into the cells of its
/// ranges, and what to say before and after an entry.
public struct DataValidation: Hashable, Sendable {
    /// What an entry is tested as. The raw values are the file's.
    public enum Kind: String, Hashable, Sendable, CaseIterable {
        /// Anything goes: the rule is there for its input message alone.
        case any = "none"
        case whole, decimal, list, date, time, textLength, custom

        /// Whether the entry is compared with one or two values.
        public var usesComparison: Bool {
            switch self {
            case .whole, .decimal, .date, .time, .textLength: return true
            case .any, .list, .custom: return false
            }
        }
    }

    /// How firmly a failed entry is turned away. The raw values are the file's.
    public enum AlertStyle: String, Hashable, Sendable, CaseIterable {
        /// The entry is refused.
        case stop
        /// The entry is kept only if the person says so.
        case warning
        /// The entry is kept, and the person told.
        case information
    }

    public typealias Comparison = ConditionalRule.Comparison

    /// The comparisons in the order Excel lists them.
    public static let comparisons: [Comparison] = [
        .between, .notBetween, .equal, .notEqual, .greaterThan, .lessThan,
        .greaterThanOrEqual, .lessThanOrEqual,
    ]

    public var ranges: [CellRange]
    public var kind: Kind
    public var comparison: Comparison
    /// The first value, as a formula without its `=`, written for `base`:
    /// the list's source, the custom test, or what the entry is compared with.
    public var formula1: String?
    /// The upper bound of a "between" comparison.
    public var formula2: String?
    public var allowsBlank: Bool
    /// Whether a list rule shows its arrow in the cell.
    public var showsDropDown: Bool
    public var showsInputMessage: Bool
    /// Whether a failed entry is caught at all: Excel lets anything through
    /// a rule with its error alert switched off.
    public var showsErrorMessage: Bool
    public var alertStyle: AlertStyle
    public var errorTitle: String?
    public var errorMessage: String?
    public var promptTitle: String?
    public var promptMessage: String?
    /// The input method mode the file asks for, kept for the save.
    public var imeMode: String?

    public init(
        ranges: [CellRange], kind: Kind, comparison: Comparison = .between,
        formula1: String? = nil, formula2: String? = nil, allowsBlank: Bool = true,
        showsDropDown: Bool = true, showsInputMessage: Bool = true, showsErrorMessage: Bool = true,
        alertStyle: AlertStyle = .stop, errorTitle: String? = nil, errorMessage: String? = nil,
        promptTitle: String? = nil, promptMessage: String? = nil, imeMode: String? = nil
    ) {
        self.ranges = ranges
        self.kind = kind
        self.comparison = comparison
        self.formula1 = formula1
        self.formula2 = formula2
        self.allowsBlank = allowsBlank
        self.showsDropDown = showsDropDown
        self.showsInputMessage = showsInputMessage
        self.showsErrorMessage = showsErrorMessage
        self.alertStyle = alertStyle
        self.errorTitle = errorTitle
        self.errorMessage = errorMessage
        self.promptTitle = promptTitle
        self.promptMessage = promptMessage
        self.imeMode = imeMode
    }

    /// The cell the formulas are written for: the top-left corner of the ranges.
    public var base: CellAddress? { ConditionalRule.base(of: ranges) }

    public func covers(_ address: CellAddress) -> Bool {
        ranges.contains { $0.contains(address) }
    }

    /// Whether selecting a cell of the rule has something to show.
    public var hasInputMessage: Bool {
        showsInputMessage && !((promptTitle ?? "").isEmpty && (promptMessage ?? "").isEmpty)
    }

    /// A formula of the rule as it reads for one of its cells: relative
    /// references move with the cell, as a filled formula's do.
    public func formula(_ formula: String?, at address: CellAddress) -> String? {
        guard let formula, !formula.isEmpty, let base else { return nil }
        return FormulaReferenceShifter.translated(
            formula, rowDelta: address.row - base.row, columnDelta: address.column - base.column
        )
    }

    /// The entries of a list typed into the rule itself — `"Yes,No"` — or nil
    /// when the list is read from cells.
    public var literalItems: [String]? {
        guard kind == .list, let formula1, formula1.count >= 2,
              formula1.hasPrefix("\""), formula1.hasSuffix("\"") else { return nil }
        let body = formula1.dropFirst().dropLast().replacingOccurrences(of: "\"\"", with: "\"")
        return body.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The source of a list typed out entry by entry.
    public static func listFormula(items: [String]) -> String {
        "\"" + items.joined(separator: ",").replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// A value of the rule as a person types it into the rule's editor: a
    /// typed list as its entries, a number or text as itself, and anything
    /// else as a formula behind its `=`.
    public static func input(for formula: String?) -> String {
        guard let formula, !formula.isEmpty else { return "" }
        if Double(formula) != nil { return formula }
        if formula.count >= 2, formula.hasPrefix("\""), formula.hasSuffix("\"") {
            let body = String(formula.dropFirst().dropLast())
            // Text with a quote of its own inside is only safe as a formula.
            if !body.replacingOccurrences(of: "\"\"", with: "").contains("\"") {
                return body.replacingOccurrences(of: "\"\"", with: "\"")
            }
        }
        return "=" + formula
    }

    /// The formula for what was typed into the rule's editor, or nil for
    /// nothing: the reverse of `input(for:)`.
    public static func formula(fromInput input: String, kind: Kind) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("=") {
            let body = text.dropFirst().trimmingCharacters(in: .whitespaces)
            return body.isEmpty ? nil : body
        }
        if kind == .list {
            let items = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return items.isEmpty ? nil : listFormula(items: items)
        }
        if kind == .custom { return text }
        if case .number(let number) = CellInputParser.cell(from: text, inheriting: .default).value {
            return Double(text) != nil ? text : String(number)
        }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// The test an entry at `address` has to pass, as a formula reading the
    /// cell itself, or nil when the rule has nothing a formula can test.
    func testFormula(at address: CellAddress) -> String? {
        let first = formula(formula1, at: address)
        switch kind {
        case .any, .list: return nil
        case .custom: return first
        case .whole, .decimal, .date, .time, .textLength:
            guard let first else { return nil }
            let value = kind == .textLength ? "LEN(\(address.a1))" : "(\(address.a1))"
            let second = formula(formula2, at: address)
            switch comparison {
            case .lessThan: return "\(value)<(\(first))"
            case .lessThanOrEqual: return "\(value)<=(\(first))"
            case .equal: return "\(value)=(\(first))"
            case .notEqual: return "\(value)<>(\(first))"
            case .greaterThanOrEqual: return "\(value)>=(\(first))"
            case .greaterThan: return "\(value)>(\(first))"
            case .between:
                guard let second else { return nil }
                return "AND(\(value)>=(\(first)),\(value)<=(\(second)))"
            case .notBetween:
                guard let second else { return nil }
                return "OR(\(value)<(\(first)),\(value)>(\(second)))"
            }
        }
    }
}

// MARK: - The sheet's rules

extension Worksheet {
    /// The rule an entry into `address` answers to. Excel keeps rules from
    /// overlapping; in a file where they do, the first one wins.
    public func dataValidation(at address: CellAddress) -> DataValidation? {
        guard !dataValidations.isEmpty else { return nil }
        let target = mergedRange(containing: address)?.normalized.start ?? address
        return dataValidations.first { $0.covers(target) }
    }

    /// Gives `ranges` one rule, or none: whatever rules covered any of their
    /// cells let go of them first, keeping the rest of what they covered.
    public mutating func setDataValidation(_ rule: DataValidation?, for ranges: [CellRange]) {
        let cleared = ranges.map(\.normalized)
        dataValidations = dataValidations.compactMap { existing in
            var remaining = existing.ranges.map(\.normalized)
            for hole in cleared { remaining = remaining.flatMap { Self.pieces(of: $0, outside: hole) } }
            guard !remaining.isEmpty else { return nil }
            guard remaining != existing.ranges.map(\.normalized) else { return existing }
            var kept = existing
            kept.ranges = remaining
            // The formulas were written for the old corner; say the same
            // thing from the new one.
            if let before = existing.base, let after = kept.base, before != after {
                func moved(_ formula: String?) -> String? {
                    formula.map {
                        FormulaReferenceShifter.translated(
                            $0, rowDelta: after.row - before.row, columnDelta: after.column - before.column)
                    }
                }
                kept.formula1 = moved(existing.formula1)
                kept.formula2 = moved(existing.formula2)
            }
            return kept
        }
        guard var rule, !cleared.isEmpty else { return }
        rule.ranges = cleared
        dataValidations.append(rule)
    }

    /// What is left of `range` once `hole` is cut out of it, as rectangles.
    private static func pieces(of range: CellRange, outside hole: CellRange) -> [CellRange] {
        let top = max(range.start.row, hole.start.row), bottom = min(range.end.row, hole.end.row)
        let left = max(range.start.column, hole.start.column), right = min(range.end.column, hole.end.column)
        guard top <= bottom, left <= right else { return [range] }
        var pieces: [CellRange] = []
        func add(_ startRow: Int, _ startColumn: Int, _ endRow: Int, _ endColumn: Int) {
            guard startRow <= endRow, startColumn <= endColumn else { return }
            pieces.append(CellRange(
                start: CellAddress(row: startRow, column: startColumn),
                end: CellAddress(row: endRow, column: endColumn)))
        }
        add(range.start.row, range.start.column, top - 1, range.end.column)
        add(top, range.start.column, bottom, left - 1)
        add(top, right + 1, bottom, range.end.column)
        add(bottom + 1, range.start.column, range.end.row, range.end.column)
        return pieces
    }

    /// Moves the rules through rows or columns inserted or removed. A rule
    /// whose cells all went goes with them.
    ///
    /// `movesRanges` is false on a sheet whose own lines stayed where they
    /// were, where only the references `scope` covers follow.
    mutating func shiftDataValidations(
        _ operation: FormulaReferenceShifter.Operation, axis: FormulaReferenceShifter.Axis,
        scope: FormulaReferenceShifter.Scope, movesRanges: Bool = true
    ) {
        guard !dataValidations.isEmpty else { return }
        dataValidations = dataValidations.compactMap { rule in
            let ranges = movesRanges ? ConditionalRule.moved(rule.ranges, operation, axis: axis) : rule.ranges
            guard !ranges.isEmpty else { return nil }
            var moved = rule
            func follow(_ formula: String?) -> String? {
                formula.map {
                    ConditionalRule.moved(
                        formula: $0, from: rule.ranges, to: ranges, operation, axis: axis, scope: scope)
                }
            }
            moved.formula1 = follow(rule.formula1)
            moved.formula2 = follow(rule.formula2)
            moved.ranges = ranges
            return moved
        }
    }
}

// MARK: - Testing an entry

extension Workbook {
    /// What a list rule offers for the cell at `address`, as its drop-down
    /// shows them: typed entries as typed, cells as they display.
    public func dataValidationItems(
        for rule: DataValidation, at address: CellAddress, sheetIndex: Int
    ) -> [String] {
        listCells(for: rule, at: address, sheetIndex: sheetIndex)
            .map(CellFormatter.displayText(for:))
            .filter { !$0.isEmpty }
    }

    private func listCells(for rule: DataValidation, at address: CellAddress, sheetIndex: Int) -> [Cell] {
        guard rule.kind == .list else { return [] }
        if let items = rule.literalItems {
            return items.map { CellInputParser.cell(from: $0, inheriting: .default) }
        }
        guard let source = rule.formula(rule.formula1, at: address) else { return [] }
        return CalculationEngine.cells(namedBy: source, in: self, sheetIndex: sheetIndex, at: address)
    }

    /// The rule that turns `cell` away as an entry into `address`, or nil
    /// when the entry is fine or nothing checks it.
    ///
    /// A formula is judged by what it comes to, and a custom rule by the
    /// sheet as it would stand with the entry in place.
    public func dataValidationFailure(
        entering cell: Cell, at address: CellAddress, sheetIndex: Int
    ) -> DataValidation? {
        guard sheets.indices.contains(sheetIndex),
              let rule = sheets[sheetIndex].dataValidation(at: address),
              rule.showsErrorMessage, rule.kind != .any else { return nil }
        var trial = self
        trial.sheets[sheetIndex][address] = cell
        if cell.formula != nil || rule.kind == .custom { trial.recalculate() }
        let entered = trial.sheets[sheetIndex][address]
        if case .empty = entered.value { return nil }

        switch rule.kind {
        case .any:
            return nil
        case .list:
            let offered = trial.listCells(for: rule, at: address, sheetIndex: sheetIndex)
            // Excel matches a typed list to the letter, and cells without
            // regard to case.
            let exact = rule.literalItems != nil
            let text = CellFormatter.displayText(for: entered.value, format: NumberFormatPreset.general.code)
            let passes = offered.contains { item in
                if item.value == entered.value { return true }
                let other = CellFormatter.displayText(for: item)
                return exact ? other == text : other.caseInsensitiveCompare(text) == .orderedSame
            }
            return passes ? nil : rule
        case .whole, .decimal, .date, .time:
            guard case .number(let number) = entered.value else { return rule }
            if rule.kind == .whole, number != number.rounded() { return rule }
            fallthrough
        case .textLength, .custom:
            // A rule with nothing to compare against has nothing to refuse.
            guard let test = rule.testFormula(at: address) else { return nil }
            switch CalculationEngine.preview(formula: test, in: trial, sheetIndex: sheetIndex, at: address) {
            case .boolean(let flag): return flag ? nil : rule
            case .number(let result): return result != 0 ? nil : rule
            default: return rule
            }
        }
    }
}
