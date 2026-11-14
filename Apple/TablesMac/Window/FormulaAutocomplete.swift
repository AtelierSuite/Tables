import AppKit
import TablesEngine

/// Offers functions and defined names while a formula is typed, in the
/// formula bar or in a cell, through the text system's own completion list:
/// arrow keys pick one, Return or Tab puts it in, Escape puts the list away.
@MainActor
enum FormulaAutocomplete {
    /// Set while the list is being asked for, so the text it puts in does
    /// not ask again.
    private static var isCompleting = false

    /// After the text changed: opens the list when a letter of a function or
    /// name has just been typed and something finishes it.
    static func textDidChange(in textView: NSTextView, document: WorkbookDocument) {
        guard !isCompleting, !textView.hasMarkedText(), document.state.isEnteringFormula,
              let event = NSApp.currentEvent, event.type == .keyDown,
              let typed = event.characters?.unicodeScalars.last,
              CharacterSet.alphanumerics.contains(typed) || typed == "_" || typed == "." else { return }
        guard !document.state.formulaSuggestions(in: document.workbook, caret: caret(in: textView)).isEmpty else {
            return
        }
        isCompleting = true
        textView.complete(nil)
        isCompleting = false
    }

    /// What the list shows for the word the text system found. Its idea of a
    /// word stops at a period, where a name's does not, so the part of a
    /// suggestion before the text system's word is left off.
    static func completions(
        in textView: NSTextView, partialWordRange range: NSRange, document: WorkbookDocument,
        indexOfSelectedItem index: UnsafeMutablePointer<Int>
    ) -> [String] {
        let caret = caret(in: textView)
        guard let word = FormulaCompletion.word(in: textView.string, caret: caret) else { return [] }
        let partial = (textView.string as NSString).substring(with: range)
        guard word.prefix.lowercased().hasSuffix(partial.lowercased()) else { return [] }
        let extra = word.prefix.count - partial.count
        index.pointee = -1
        return document.state.formulaSuggestions(in: document.workbook, caret: caret, limit: 20)
            .map { String($0.insertion.dropFirst(extra)) }
    }

    /// The caret as a character offset, which is how the engine counts.
    private static func caret(in textView: NSTextView) -> Int {
        let location = min(textView.selectedRange().location, (textView.string as NSString).length)
        return (textView.string as NSString).substring(to: location).count
    }
}
