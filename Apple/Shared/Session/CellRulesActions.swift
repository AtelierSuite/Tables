import Foundation
import TablesEngine

/// A conditional format being edited, kept apart by an id of its own so the
/// editor can follow it while the list around it changes.
struct DraftRule: Identifiable, Hashable {
    let id = UUID()
    var rule: ConditionalRule
}

/// A data validation rule being edited, with its values as they were typed.
struct ValidationDraft: Hashable {
    var rule: DataValidation
    var first: String
    var second: String

    init(rule: DataValidation) {
        self.rule = rule
        first = DataValidation.input(for: rule.formula1)
        second = DataValidation.input(for: rule.formula2)
    }

    var needsSecondValue: Bool {
        rule.kind.usesComparison && (rule.comparison == .between || rule.comparison == .notBetween)
    }

    /// The rule as edited, with what was typed turned into its formulas.
    var edited: DataValidation {
        var edited = rule
        edited.formula1 = DataValidation.formula(fromInput: first, kind: rule.kind)
        edited.formula2 = needsSecondValue ? DataValidation.formula(fromInput: second, kind: rule.kind) : nil
        if rule.kind == .any { edited.formula1 = nil }
        func kept(_ text: String?) -> String? { (text ?? "").isEmpty ? nil : text }
        edited.errorTitle = kept(rule.errorTitle)
        edited.errorMessage = kept(rule.errorMessage)
        edited.promptTitle = kept(rule.promptTitle)
        edited.promptMessage = kept(rule.promptMessage)
        return edited
    }

    /// A rule that tests something needs the thing to test against.
    var isComplete: Bool {
        if rule.kind == .any { return true }
        let edited = edited
        return edited.formula1 != nil && (!needsSecondValue || edited.formula2 != nil)
    }
}

/// Everything the cell rules editor changes, handed back on Done as one edit:
/// the sheet's conditional formats, and the validation rule of the selection.
struct CellRulesDraft: Hashable {
    /// Every rule of the sheet, highest priority first.
    var rules: [DraftRule]
    /// Nil when the selected cells are to have no validation rule.
    var validation: ValidationDraft?
    /// The selected ranges, which a new rule starts out covering.
    let selection: [CellRange]

    private let originalRules: [ConditionalRule]
    private let originalValidation: DataValidation?

    init(rules: [ConditionalRule], validation: DataValidation?, selection: [CellRange]) {
        self.rules = rules.map { DraftRule(rule: $0) }
        self.validation = validation.map(ValidationDraft.init(rule:))
        self.selection = selection
        originalRules = rules
        originalValidation = validation
    }

    var editedRules: [ConditionalRule] { rules.map(\.rule) }

    var formattingChanged: Bool {
        let edited = editedRules
        return edited.count != originalRules.count
            || zip(edited, originalRules).contains { lhs, rhs in
                var lhs = lhs, rhs = rhs
                (lhs.priority, rhs.priority) = (0, 0)
                return lhs != rhs
            }
    }

    var validationChanged: Bool {
        guard let validation else { return originalValidation != nil }
        guard let originalValidation else { return true }
        var edited = validation.edited
        edited.ranges = originalValidation.ranges
        return edited != originalValidation
    }

    var isComplete: Bool {
        (validation?.isComplete ?? true) && rules.allSatisfy { !$0.rule.ranges.isEmpty }
    }

    /// Whether a rule reaches any of the selected cells.
    func touchesSelection(_ rule: ConditionalRule) -> Bool {
        rule.ranges.contains { range in selection.contains { $0.intersects(range) } }
    }

    /// The workbook as it would stand with the draft applied, for previews:
    /// its rules on the sheet and its conditional formats worked out.
    func trial(of workbook: Workbook, sheetIndex: Int) -> Workbook {
        var trial = workbook
        guard trial.sheets.indices.contains(sheetIndex) else { return trial }
        trial.sheets[sheetIndex].conditionalRules = editedRules.enumerated().map { offset, rule in
            var numbered = rule
            numbered.priority = offset + 1
            return numbered
        }
        if validationChanged {
            trial.sheets[sheetIndex].setDataValidation(validation?.edited, for: selection)
        }
        trial.recalculate()
        return trial
    }
}

extension EditorState {
    /// The selected ranges, each grown to cover the merged cells it touches.
    func selectedRangesExpanded(in workbook: Workbook) -> [CellRange] {
        let sheet = activeSheet(in: workbook)
        return selectedRanges.map { sheet.expandedToMerges($0).normalized }
    }

    /// A draft of the active sheet's rules and the selection's validation.
    func cellRulesDraft(in workbook: Workbook) -> CellRulesDraft {
        CellRulesDraft(
            rules: activeSheet(in: workbook).conditionalRules,
            validation: selectedDataValidation(in: workbook),
            selection: selectedRangesExpanded(in: workbook))
    }

    /// Writes what the cell rules editor changed.
    func applyCellRules(_ draft: CellRulesDraft, in workbook: inout Workbook) {
        if draft.formattingChanged {
            workbook.setConditionalRules(draft.editedRules, sheetIndex: activeIndex(in: workbook))
        }
        if draft.validationChanged {
            setDataValidation(draft.validation?.edited, in: &workbook)
        }
    }
}
