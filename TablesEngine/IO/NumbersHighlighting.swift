import Foundation

/// Reads Numbers' conditional highlighting into conditional format rules.
///
/// A cell keeps a key into its table's list of rule sets, a list of
/// `TST.ConditionalStyleSetArchive`, so a set has no range of its own: it
/// applies wherever a cell names it. Each rule is a
/// `TST.FormulaPredicateArchive`, whose formula says what the rule tests, and
/// a cell style and text style holding only what the rule changes.
///
/// How the rules behave was read off documents Numbers saved, each cell of
/// which records the rule Numbers last applied to it. The first rule to pass
/// is the only one applied. A blank cell counts as 0, but a number rule never
/// passes on text, where the formulas here would say text is the greater.
///
/// The rules stay as Numbers wrote them in the document. These are a reading
/// of them, so nothing here is saved.
enum NumbersHighlighting {
    private enum Field {
        static let rules = 3
        static let rule = 1
        static let predicate = 1
        static let cellStyle = 2
        static let textStyle = 3
        static let target = 4
        static let operand = 5
        static let formula = 7
        static let argumentType = 1
        static let relativeReference = 4
        static let rowOffset = 1
        static let columnOffset = 2
    }

    /// The kinds of predicate argument, a `TST.FormulaPredArgArchive`'s type.
    private enum ArgumentType {
        static let number = 1
        static let cell = 4
    }

    /// A rule set's rules for the cells naming it, or none when any of them
    /// can't be read. Without one of its rules a set can't be followed at
    /// all: a cell that rule would have taken would go on to a later one,
    /// and show a style Numbers wouldn't give it.
    static func rules(
        of set: ProtobufMessage, at cells: [CellAddress], table: MergeOwners.UUID?,
        sheetNames: [MergeOwners.UUID: String], styles: NumbersStyles.Resolver
    ) -> [ConditionalRule] {
        // Single cells, as they are in the document: a row inserted among
        // them gets no highlighting there, so it gets none here.
        let ranges = cells.sorted().map { CellRange($0) }
        guard let base = ConditionalRule.base(of: ranges), let list = set.message(Field.rules) else { return [] }
        var context = NumbersFormula.Context(host: base, hostTable: table, sheetNames: sheetNames)
        context.readsLinkedCell = true

        var rules: [ConditionalRule] = []
        for (index, rule) in list.messages(Field.rule).enumerated() {
            guard let predicate = rule.message(Field.predicate),
                  let formula = formula(of: predicate, context: context) else { return [] }
            rules.append(ConditionalRule(
                ranges: ranges, formulas: [formula], priority: index, stopsIfTrue: true,
                style: styles.conditionalStyle(
                    text: rule.message(Field.textStyle)?.uint(1), cell: rule.message(Field.cellStyle)?.uint(1)
                )
            ))
        }
        return rules
    }

    /// What a predicate tests, as a formula for the context's host cell.
    private static func formula(of predicate: ProtobufMessage, context: NumbersFormula.Context) -> String? {
        // The cell tested is given relative to the one being highlighted,
        // which is the only way Tables has of reading it.
        guard let target = predicate.message(Field.target), target.int(Field.argumentType) == ArgumentType.cell,
              let reference = target.message(Field.relativeReference),
              reference.int(Field.rowOffset) ?? 0 == 0, reference.int(Field.columnOffset) ?? 0 == 0,
              let nodes = predicate.message(Field.formula)?.message(1)?.messages(1),
              let test = NumbersFormula.formula(from: nodes, context: context) else { return nil }
        guard predicate.message(Field.operand)?.int(Field.argumentType) == ArgumentType.number else { return test }
        return "IF(ISTEXT(\(context.host.a1)),FALSE,\(test))"
    }
}
