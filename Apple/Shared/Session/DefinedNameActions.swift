import Foundation
import TablesEngine

/// One thing that could finish the word being typed in a formula: a function
/// or a defined name.
struct FormulaSuggestion: Identifiable, Hashable {
    enum Kind: Hashable { case function, name }

    let kind: Kind
    /// As it is shown, and as a name is inserted.
    let text: String
    /// What it is: a function's summary, or what a name refers to.
    let detail: String

    var id: String { "\(kind)-\(text.lowercased())" }

    /// What replaces the word: a function opens its parentheses.
    var insertion: String { kind == .function ? text + "(" : text }
}

/// Managing a workbook's names from the UI, alongside the other edits.
extension EditorState {
    /// What a name made from the selection refers to: the selection, on the
    /// active sheet, anchored.
    func selectionFormula(in workbook: Workbook) -> String {
        "=" + DefinedName.formula(for: selection, onSheetNamed: activeSheet(in: workbook).name)
    }

    /// The name offered for the selection, from the label beside it.
    func suggestedName(in workbook: Workbook) -> String {
        workbook.suggestedDefinedName(for: selection, on: activeSheet(in: workbook).id)
    }

    /// Whether a name refers to a range that can be gone to.
    func canGo(to name: DefinedName, in workbook: Workbook) -> Bool {
        workbook.target(of: name, from: activeSheet(in: workbook).id) != nil
    }

    /// Brings the name's sheet up and selects its range, scrolled into view.
    @discardableResult
    func go(to name: DefinedName, in workbook: Workbook) -> Bool {
        guard let target = workbook.target(of: name, from: activeSheet(in: workbook).id),
              let sheet = workbook[target.sheetID] else { return false }
        if activeSheetID != target.sheetID { selectSheet(target.sheetID, in: workbook) }
        select(target.range.start, in: sheet)
        if !target.range.isSingleCell { select(target.range.end, extending: true, in: sheet) }
        scrollTarget = target.range.start
        return true
    }

    /// Where a name's scope is shown: "Workbook", or its sheet's name.
    static func scopeLabel(_ scope: Worksheet.ID?, in workbook: Workbook) -> String {
        guard let scope else { return String(localized: "Names.Scope.Workbook") }
        return workbook[scope]?.name ?? ""
    }

    /// Functions and names that finish the word being typed at `caret`, or
    /// at the end of the formula: names first, as they are the workbook's own.
    func formulaSuggestions(in workbook: Workbook, caret: Int? = nil, limit: Int = 12) -> [FormulaSuggestion] {
        guard isEnteringFormula, let word = FormulaCompletion.word(in: editingText, caret: caret) else { return [] }
        let names = workbook.definedNameCompletions(for: word.prefix, visibleFrom: activeSheet(in: workbook).id)
            .map { FormulaSuggestion(kind: .name, text: $0.name, detail: "=" + $0.formula) }
        let functions = FunctionReference.all
            .filter { $0.name.range(of: word.prefix, options: [.caseInsensitive, .anchored]) != nil }
            .sorted { $0.name < $1.name }
            .map { FormulaSuggestion(kind: .function, text: $0.name, detail: $0.summary) }
        // Nothing to offer once the word is typed out in full.
        let all = (names + functions).filter { $0.text.compare(word.prefix, options: .caseInsensitive) != .orderedSame }
        return Array(all.prefix(limit))
    }

    /// Puts a suggestion in place of the word being typed. Returns where the
    /// caret goes after it.
    @discardableResult
    func accept(_ suggestion: FormulaSuggestion, caret: Int? = nil) -> Int? {
        guard let word = FormulaCompletion.word(in: editingText, caret: caret) else { return nil }
        let result = FormulaCompletion.replacing(word, with: suggestion.insertion, in: editingText)
        editingText = result.text
        return result.caret
    }
}
