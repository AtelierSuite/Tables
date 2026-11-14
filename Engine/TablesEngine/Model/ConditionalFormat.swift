import Foundation

/// What a conditional format changes about a cell. An absent value leaves the
/// cell's own, so several rules can each settle a part of the same cell.
public struct ConditionalStyle: Hashable, Sendable {
    public var fillColorHex: String?
    public var textColorHex: String?
    public var isBold: Bool?
    public var isItalic: Bool?
    public var isUnderlined: Bool?
    public var isStruckThrough: Bool?
    /// A data bar behind the cell's value, and an icon beside it.
    public var dataBar: ConditionalBar?
    public var icon: ConditionalIcon?
    /// Set by a bar or icon that stands in for the value instead of joining it.
    public var hidesValue: Bool?

    public init(
        fillColorHex: String? = nil, textColorHex: String? = nil, isBold: Bool? = nil,
        isItalic: Bool? = nil, isUnderlined: Bool? = nil, isStruckThrough: Bool? = nil
    ) {
        self.fillColorHex = fillColorHex
        self.textColorHex = textColorHex
        self.isBold = isBold
        self.isItalic = isItalic
        self.isUnderlined = isUnderlined
        self.isStruckThrough = isStruckThrough
    }

    /// Takes whatever `other` sets and this does not. Rules are met highest
    /// priority first, and in Excel the first to settle a property keeps it.
    public mutating func adopt(_ other: ConditionalStyle) {
        fillColorHex = fillColorHex ?? other.fillColorHex
        textColorHex = textColorHex ?? other.textColorHex
        isBold = isBold ?? other.isBold
        isItalic = isItalic ?? other.isItalic
        isUnderlined = isUnderlined ?? other.isUnderlined
        isStruckThrough = isStruckThrough ?? other.isStruckThrough
        dataBar = dataBar ?? other.dataBar
        icon = icon ?? other.icon
        hidesValue = hidesValue ?? other.hidesValue
    }

    public func applied(to style: CellStyle) -> CellStyle {
        var result = style
        // A rule's fill is solid, and covers any pattern or gradient of the cell's own.
        if let fillColorHex { result.setSolidFill(fillColorHex) }
        if let textColorHex { result.textColorHex = textColorHex }
        if let isBold { result.isBold = isBold }
        if let isItalic { result.isItalic = isItalic }
        if let isUnderlined { result.isUnderlined = isUnderlined }
        if let isStruckThrough { result.isStruckThrough = isStruckThrough }
        return result
    }
}

/// One rule that styles the cells of its ranges when its test passes.
///
/// Rules are a reading of what the file holds, which remains what a save
/// writes: the `<conditionalFormatting>` kept in
/// `Worksheet.preservedElements`, or a Numbers document's rule sets.
public struct ConditionalRule: Hashable, Sendable {
    /// How a cell's own value is compared with a rule's formulas.
    public enum Comparison: String, Hashable, Sendable {
        case lessThan, lessThanOrEqual, equal, notEqual, greaterThanOrEqual, greaterThan
        case between, notBetween

        var operandCount: Int { self == .between || self == .notBetween ? 2 : 1 }
    }

    public var ranges: [CellRange]
    /// Whether the cell is tested on its own or measured against its range.
    public var kind: Kind
    /// Compares the cell's value with `formulas`; nil when the first of them
    /// is the whole test.
    public var comparison: Comparison?
    /// Written as they apply to `base`. Elsewhere in the ranges their relative
    /// references move with the cell, as a filled formula's do.
    public var formulas: [String]
    /// Lower numbers come first.
    public var priority: Int
    /// Keeps rules of lower priority from applying to a cell this one passes.
    public var stopsIfTrue: Bool
    public var style: ConditionalStyle

    public init(
        ranges: [CellRange], kind: Kind = .test, comparison: Comparison? = nil, formulas: [String] = [],
        priority: Int, stopsIfTrue: Bool = false, style: ConditionalStyle = ConditionalStyle()
    ) {
        self.ranges = ranges
        self.kind = kind
        self.comparison = comparison
        self.formulas = formulas
        self.priority = priority
        self.stopsIfTrue = stopsIfTrue
        self.style = style
    }

    /// The cell `formulas` are written for: the top-left corner of the ranges.
    public var base: CellAddress? { Self.base(of: ranges) }

    static func base(of ranges: [CellRange]) -> CellAddress? {
        let boxes = ranges.map(\.normalized)
        guard let row = boxes.map(\.start.row).min(),
              let column = boxes.map(\.start.column).min() else { return nil }
        return CellAddress(row: row, column: column)
    }

    /// The test as a formula for one cell. A comparison goes through the
    /// formula language so that blanks, text and errors compare as they do in
    /// a cell: a blank is 0 to "less than 5", and an error passes nothing.
    public func testFormula(at address: CellAddress) -> String? {
        guard let base else { return nil }
        let operands = formulas.map {
            FormulaReferenceShifter.translated(
                $0, rowDelta: address.row - base.row, columnDelta: address.column - base.column
            )
        }
        guard let comparison else { return operands.first }
        guard operands.count >= comparison.operandCount else { return nil }
        let value = "(\(address.a1))"
        switch comparison {
        case .lessThan: return "\(value)<(\(operands[0]))"
        case .lessThanOrEqual: return "\(value)<=(\(operands[0]))"
        case .equal: return "\(value)=(\(operands[0]))"
        case .notEqual: return "\(value)<>(\(operands[0]))"
        case .greaterThanOrEqual: return "\(value)>=(\(operands[0]))"
        case .greaterThan: return "\(value)>(\(operands[0]))"
        case .between: return "AND(\(value)>=(\(operands[0])),\(value)<=(\(operands[1])))"
        case .notBetween: return "OR(\(value)<(\(operands[0])),\(value)>(\(operands[1])))"
        }
    }
}

// MARK: - Structural edits

extension ConditionalRule {
    /// The last row and column a file may name. Tables' own sheets stop well
    /// short, but Excel writes a whole column as running to this row, and a
    /// reference past it is one Excel refuses.
    private static let lastFileRow = 1_048_575
    private static let lastFileColumn = 16_383

    /// Where ranges land through an insertion or removal, less any it took away.
    static func moved(
        _ ranges: [CellRange], _ operation: FormulaReferenceShifter.Operation,
        axis: FormulaReferenceShifter.Axis
    ) -> [CellRange] {
        let line: WritableKeyPath<CellAddress, Int> = axis == .row ? \.row : \.column
        let last = axis == .row ? lastFileRow : lastFileColumn
        return ranges.compactMap { range in
            let box = range.normalized
            let span = box.start[keyPath: line]...box.end[keyPath: line]
            let landed: ClosedRange<Int>?
            switch operation {
            case .insert(let index, let count): landed = Worksheet.span(span, insertingAt: index, count: count)
            case .remove(let removed): landed = Worksheet.span(span, removing: removed)
            case .translate: landed = span
            }
            guard let landed, landed.lowerBound <= last else { return nil }
            var moved = box
            moved.start[keyPath: line] = landed.lowerBound
            moved.end[keyPath: line] = min(landed.upperBound, last)
            return moved
        }
    }

    /// A rule's formula through the same edit as its ranges.
    ///
    /// Removing the line `base` stood on leaves the formula written for a
    /// cell that is gone, its own references to it broken, so it is first
    /// rewritten for the cell that takes over.
    static func moved(
        formula: String, from old: [CellRange], to new: [CellRange],
        _ operation: FormulaReferenceShifter.Operation, axis: FormulaReferenceShifter.Axis,
        scope: FormulaReferenceShifter.Scope
    ) -> String {
        var text = formula
        if case .remove(let removed) = operation, new != old, let before = base(of: old), let after = base(of: new) {
            let line: KeyPath<CellAddress, Int> = axis == .row ? \.row : \.column
            let landed = after[keyPath: line]
            let successor = landed >= removed.lowerBound ? landed + removed.count : landed
            let delta = successor - before[keyPath: line]
            if delta != 0 {
                text = FormulaReferenceShifter.translated(
                    text, rowDelta: axis == .row ? delta : 0, columnDelta: axis == .column ? delta : 0
                )
            }
        }
        return FormulaReferenceShifter.rewrite(text, operation: operation, axis: axis, scope: scope)
    }

    /// Parses an `sqref`: ranges separated by spaces.
    static func ranges(sqref: String) -> [CellRange] {
        sqref.split(whereSeparator: \.isWhitespace).compactMap { part in
            let text = String(part)
            return CellRange(a1Range: text) ?? CellAddress(a1: text).map { CellRange($0) }
        }
    }
}

extension Worksheet {
    /// The cell as it is drawn: its own, under whatever its conditional
    /// formats settled on. A blank cell can be styled by a rule, so this
    /// answers for every address.
    ///
    /// The sheet's view options have their say too: with formulas shown, a
    /// formula is drawn as its text in place of its result, and with zeros
    /// hidden, a zero is drawn as nothing at all.
    public func displayedCell(at address: CellAddress) -> Cell {
        var cell = self[address]
        if let table = tableFormat(at: address) { cell.style = table.applied(to: cell.style, at: address) }
        if let conditional = conditionalStyles[address] {
            cell.style = conditional.applied(to: cell.style)
            // A bar or icon shown in place of the value: nothing is left to draw as text.
            if conditional.hidesValue == true { (cell.value, cell.formula) = (.empty, nil) }
        }
        if showsFormulas, let formula = self[address].formula {
            cell.value = .text("=" + formula)
            cell.style.numberFormat = NumberFormatPreset.general.code
        }
        if !showsZeros, case .number(let number) = cell.value, number == 0 { cell.value = .empty }
        return cell
    }

    /// Moves conditional formats through rows or columns inserted or removed,
    /// in the rules and in the XML a save writes, so the two stay in step.
    ///
    /// `movesRanges` is false on a sheet whose own lines stayed where they
    /// were, where only the references `scope` covers follow.
    mutating func shiftConditionalFormats(
        _ operation: FormulaReferenceShifter.Operation, axis: FormulaReferenceShifter.Axis,
        scope: FormulaReferenceShifter.Scope, movesRanges: Bool = true
    ) {
        func landing(of ranges: [CellRange]) -> [CellRange] {
            movesRanges ? ConditionalRule.moved(ranges, operation, axis: axis) : ranges
        }
        func follow(_ formula: String, from old: [CellRange], to new: [CellRange]) -> String {
            ConditionalRule.moved(formula: formula, from: old, to: new, operation, axis: axis, scope: scope)
        }

        conditionalRules = conditionalRules.compactMap { rule in
            let ranges = landing(of: rule.ranges)
            guard !ranges.isEmpty else { return nil }
            var moved = rule
            moved.formulas = rule.formulas.map { follow($0, from: rule.ranges, to: ranges) }
            moved.ranges = ranges
            return moved
        }

        preservedElements = preservedElements.compactMap { element in
            guard element.name == "conditionalFormatting",
                  let root = try? XMLLite.parse(Data(element.xml.utf8)),
                  let sqref = root.attribute("sqref") else { return element }
            let old = ConditionalRule.ranges(sqref: sqref)
            guard !old.isEmpty else { return element }
            let new = landing(of: old)
            guard !new.isEmpty else { return nil }

            // Untouched by the edit, the fragment stays exactly as the file had it.
            var changed = new != old
            if changed { root.setAttribute("sqref", new.map(\.a1).joined(separator: " ")) }
            for rule in root.children(named: "cfRule") {
                for formula in rule.children(named: "formula") {
                    let text = follow(formula.text, from: old, to: new)
                    guard text != formula.text else { continue }
                    formula.setText(text)
                    changed = true
                }
            }
            guard changed, let xml = XMLLite.serialize(root) else { return element }
            return PreservedElement(name: element.name, xml: xml)
        }
    }
}
