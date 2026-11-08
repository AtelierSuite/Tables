import AppKit
import TablesMacros

/// A text view for VBA: monospaced, coloured as it is typed, and indenting
/// a new line for the block it is in — as the iPhone and iPad editor does.
@MainActor
final class CodeTextView: NSTextView {
    /// Told when the code changes, after it has been coloured.
    var onChange: () -> Void = {}

    static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    static func makeScrollable() -> (NSScrollView, CodeTextView) {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .noBorder
        let text = CodeTextView(frame: .zero)
        text.minSize = NSSize(width: 0, height: 0)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = true
        text.autoresizingMask = [.width]
        // Long lines scroll sideways rather than wrap, so code keeps its shape.
        text.textContainer?.widthTracksTextView = false
        text.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainerInset = NSSize(width: 6, height: 8)
        scroll.documentView = text
        return (scroll, text)
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        configure()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func configure() {
        font = Self.font
        isRichText = false
        allowsUndo = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        smartInsertDeleteEnabled = false
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        typingAttributes = [.font: Self.font, .foregroundColor: NSColor.textColor]
        setAccessibilityIdentifier("codeEditor")
    }

    /// Replaces the code without leaving an undo step behind.
    func setCode(_ code: String) {
        string = code
        undoManager?.removeAllActions(withTarget: textStorage as Any)
        highlight()
    }

    override func didChangeText() {
        super.didChangeText()
        highlight()
        onChange()
    }

    /// Return opens a line indented for the block the caret is in, and
    /// out-dents the line it finishes when that line closes a block.
    override func insertNewline(_ sender: Any?) {
        let edit = VBAIndenter.returnEdit(in: string, selection: selectedRange())
        guard shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
        textStorage?.replaceCharacters(in: edit.range, with: edit.replacement)
        setSelectedRange(NSRange(location: edit.cursor, length: 0))
        didChangeText()
    }

    private func highlight() {
        guard let storage = textStorage else { return }
        let whole = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.addAttributes([.font: Self.font, .foregroundColor: NSColor.textColor], range: whole)
        for span in VBASyntaxHighlighter.spans(in: storage.string) where NSMaxRange(span.range) <= storage.length {
            storage.addAttribute(.foregroundColor, value: Self.color(for: span.kind), range: span.range)
        }
        storage.endEditing()
    }

    private static func color(for kind: VBASyntaxHighlighter.Kind) -> NSColor {
        switch kind {
        case .keyword: return .systemBlue
        case .comment: return .systemGreen
        case .string: return .systemRed
        case .number: return .systemPurple
        }
    }
}
