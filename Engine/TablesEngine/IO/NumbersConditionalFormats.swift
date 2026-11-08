import Foundation

/// Conditional highlighting in a Numbers document.
///
/// A cell with highlighting keeps a key into its table's list of rule sets,
/// each a `TST.ConditionalStyleSetArchive`: an ordered list of rules, each a
/// formula testing the cell and the styles to draw it with when it passes.
/// Cells sharing a set share every rule in it.
///
/// Rules are a reading only. What a save writes is what the file had, since
/// each cell's storage keeps its key through any change to its value.
enum NumbersConditionalFormats {
    enum ObjectType {
        static let ruleSet = 6010
    }

    /// The field of a cell's storage holding its rule set's key.
    static let cellField: UInt32 = 0x80

    /// Fields of a rule set, and of each rule in it.
    private enum Number {
        static let rules = 2
        static let predicate = 1
        static let cellStyle = 2
        static let textStyle = 3
    }

    /// The rules of a table, whose cells are given by the rule set they use.
    ///
    /// In Numbers a cell passing several rules looks as the first of them
    /// says, so each rule stops the ones after it. A rule with a formula
    /// Tables can't read is left out, and the rules after it stand.
    static func rules(
        cells: [UInt64: [CellAddress]], archive: IWAArchive, hostTable: MergeOwners.UUID?,
        sheetNames: [MergeOwners.UUID: String]
    ) -> [ConditionalRule] {
        var result: [ConditionalRule] = []
        for (identifier, addresses) in cells.sorted(by: { $0.key < $1.key }) {
            guard let set = archive[identifier]?.message else { continue }
            let ranges = ranges(covering: addresses)
            guard let base = ConditionalRule.base(of: ranges) else { continue }
            let context = NumbersFormula.Context(
                host: base, hostTable: hostTable, sheetNames: sheetNames, readsRuleSubject: true
            )
            for rule in set.messages(Number.rules) {
                let nodes = rule.message(Number.predicate)?.message(1)?.message(1)?.messages(1) ?? []
                guard let formula = test(nodes, context: context) else { continue }
                result.append(ConditionalRule(
                    ranges: ranges, formulas: [formula], priority: result.count, stopsIfTrue: true,
                    style: style(
                        text: archive[rule.message(Number.textStyle)]?.message,
                        cell: archive[rule.message(Number.cellStyle)]?.message
                    )
                ))
            }
        }
        return result
    }

    /// A rule's test as a formula for the first of its cells.
    ///
    /// Numbers compares a cell with a value of its own kind only, so text
    /// fails a test against a number; the formula language would rank it
    /// above every number. A blank is 0, as it is in a formula.
    private static func test(_ nodes: [ProtobufMessage], context: NumbersFormula.Context) -> String? {
        guard let formula = NumbersFormula.formula(from: nodes, context: context) else { return nil }
        let comparisons = NumbersFormula.NodeType.greaterThan...NumbersFormula.NodeType.notEqual
        guard nodes.first?.int(1) == NumbersFormula.NodeType.ruleSubject,
              let last = nodes.last?.int(1), comparisons.contains(last),
              let operand = NumbersFormula.formula(from: Array(nodes.dropFirst().dropLast()), context: context)
        else { return formula }
        return "AND(ISTEXT(\(context.host.a1))=ISTEXT(\(operand)),\(formula))"
    }

    /// What a rule's styles change. They set only what the rule changes, so
    /// their parents aren't followed.
    static func style(text: ProtobufMessage?, cell: ProtobufMessage?) -> ConditionalStyle {
        var style = ConditionalStyle()
        if let fill = cell?.message(NumbersStyles.Number.cellProperties)?.message(NumbersStyles.Number.fill) {
            style.fillColorHex = fill.message(1).flatMap(NumbersStyles.color)
        }
        guard let character = text?.message(NumbersStyles.Number.characterProperties) else { return style }
        func flag(_ number: Int) -> Bool? { character.has(number) ? character.bool(number) : nil }
        func line(_ number: Int) -> Bool? { character.uint(number).map { $0 != 0 } }
        style.isBold = flag(NumbersStyles.Number.bold)
        style.isItalic = flag(NumbersStyles.Number.italic)
        style.isUnderlined = line(NumbersStyles.Number.underline)
        style.isStruckThrough = line(NumbersStyles.Number.strikethrough)
        style.textColorHex = character.message(NumbersStyles.Number.fontColor).flatMap(NumbersStyles.color)
            ?? character.message(NumbersStyles.Number.textFill)?.message(1).flatMap(NumbersStyles.color)
        return style
    }

    /// Few ranges covering exactly these cells: the runs along each row,
    /// joined with the same run in the row above.
    static func ranges(covering addresses: [CellAddress]) -> [CellRange] {
        var finished: [CellRange] = []
        var open: [ClosedRange<Int>: CellRange] = [:]
        let rows = Dictionary(grouping: addresses, by: \.row)
        for row in rows.keys.sorted() {
            var runs: [ClosedRange<Int>] = []
            for column in Set(rows[row, default: []].map(\.column)).sorted() {
                if let last = runs.last, last.upperBound + 1 == column {
                    runs[runs.count - 1] = last.lowerBound...column
                } else {
                    runs.append(column...column)
                }
            }
            var next: [ClosedRange<Int>: CellRange] = [:]
            for run in runs {
                if var range = open[run], range.end.row + 1 == row {
                    range.end.row = row
                    next[run] = range
                    open[run] = nil
                } else {
                    next[run] = CellRange(
                        start: CellAddress(row: row, column: run.lowerBound),
                        end: CellAddress(row: row, column: run.upperBound)
                    )
                }
            }
            finished += open.values
            open = next
        }
        return (finished + open.values).sorted {
            ($0.start.row, $0.start.column) < ($1.start.row, $1.start.column)
        }
    }
}
