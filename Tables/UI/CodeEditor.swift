import SwiftUI
import TablesEngine

/// A plain-text editor for macro code: monospaced, coloured as VBA, and with
/// every typing aid that would corrupt code switched off — curly quotes
/// above all, which VBA does not accept as string delimiters.
struct CodeEditor {
    @Binding var text: String
    /// Off, long lines run on and the editor scrolls sideways, as the VBA
    /// editor's does; on, they wrap to the width of the screen.
    var wrapsLines = false

    fileprivate static let fontSize: CGFloat = 14

    fileprivate static func color(for kind: VBASyntaxHighlighter.Kind) -> PlatformColor {
        switch kind {
        case .keyword: return .systemBlue
        case .comment: return .systemGreen
        case .string: return .systemRed
        case .number: return .systemPurple
        }
    }

    fileprivate static var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: PlatformFont.monospacedSystemFont(ofSize: fontSize, weight: .regular), .foregroundColor: PlatformColor.label]
    }

    /// Recolours the whole text. Modules are small enough that this keeps
    /// up with typing, and it is never wrong about a span the edit changed.
    fileprivate static func highlight(_ storage: NSTextStorage) {
        let whole = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: whole)
        for span in VBASyntaxHighlighter.spans(in: storage.string) where NSMaxRange(span.range) <= storage.length {
            storage.addAttribute(.foregroundColor, value: color(for: span.kind), range: span.range)
        }
        storage.endEditing()
    }
}

#if os(iOS)
typealias PlatformColor = UIColor
typealias PlatformFont = UIFont

/// A text view that never scrolls itself, inside a scroll view that scrolls
/// both ways. UITextView cannot stop wrapping on its own, so when lines are
/// not to wrap the text view is simply made as wide as the longest line.
final class CodeScrollView: UIScrollView {
    let textView = UITextView(usingTextLayoutManager: false)

    var wrapsLines = true {
        didSet { if wrapsLines != oldValue { setNeedsLayout() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        alwaysBounceVertical = true
        keyboardDismissMode = .interactive
        addSubview(textView)
    }

    required init?(coder _: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let unbounded = CGFloat.greatestFiniteMagnitude
        var width = bounds.width
        if !wrapsLines {
            width = max(width, ceil(textView.sizeThatFits(CGSize(width: unbounded, height: unbounded)).width))
        }
        let height = max(bounds.height, ceil(textView.sizeThatFits(CGSize(width: width, height: unbounded)).height))
        let frame = CGRect(x: 0, y: 0, width: width, height: height)
        if textView.frame != frame { textView.frame = frame }
        if contentSize != frame.size { contentSize = frame.size }
    }

    /// Scrolls the caret into view, which a text view that does not scroll
    /// leaves to whatever holds it.
    func revealSelection() {
        layoutIfNeeded()
        guard let position = textView.selectedTextRange?.end else { return }
        let caret = textView.caretRect(for: position)
        scrollRectToVisible(textView.convert(caret, to: self).insetBy(dx: -24, dy: -24), animated: false)
    }
}

extension CodeEditor: UIViewRepresentable {
    func makeUIView(context: Context) -> CodeScrollView {
        let scrollView = CodeScrollView()
        let view = scrollView.textView
        view.delegate = context.coordinator
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.spellCheckingType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.inlinePredictionType = .no
        view.keyboardType = .asciiCapable
        view.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        view.typingAttributes = Self.baseAttributes
        view.accessibilityIdentifier = "codeEditor"
        view.text = text
        Self.highlight(view.textStorage)
        scrollView.wrapsLines = wrapsLines
        context.coordinator.scrollView = scrollView
        return scrollView
    }

    func updateUIView(_ scrollView: CodeScrollView, context _: Context) {
        scrollView.wrapsLines = wrapsLines
        let view = scrollView.textView
        guard view.text != text else { return }
        let selection = view.selectedRange
        view.text = text
        Self.highlight(view.textStorage)
        view.selectedRange = NSRange(location: min(selection.location, view.textStorage.length), length: 0)
        scrollView.setNeedsLayout()
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>
        weak var scrollView: CodeScrollView?

        init(text: Binding<String>) {
            self.text = text
        }

        func textViewDidChange(_ view: UITextView) {
            let selection = view.selectedRange
            CodeEditor.highlight(view.textStorage)
            view.selectedRange = selection
            view.typingAttributes = CodeEditor.baseAttributes
            text.wrappedValue = view.text
            scrollView?.setNeedsLayout()
            scrollView?.revealSelection()
        }

        func textViewDidChangeSelection(_: UITextView) {
            scrollView?.revealSelection()
        }

        /// Return indents the new line for the block it is in, and snaps a
        /// line that closes a block back to where the block began.
        func textView(_ view: UITextView, shouldChangeTextIn range: NSRange, replacementText replacement: String) -> Bool {
            guard replacement == "\n" else { return true }
            let edit = VBAIndenter.returnEdit(in: view.text, selection: range)
            guard let start = view.position(from: view.beginningOfDocument, offset: edit.range.location),
                  let end = view.position(from: start, offset: edit.range.length),
                  let textRange = view.textRange(from: start, to: end) else { return true }
            // Through the text input system, so the edit undoes like typing.
            view.replace(textRange, withText: edit.replacement)
            view.selectedRange = NSRange(location: edit.cursor, length: 0)
            textViewDidChange(view)
            return false
        }
    }
}
#else
typealias PlatformColor = NSColor
typealias PlatformFont = NSFont

private extension NSColor {
    static var label: NSColor { .labelColor }
}

extension CodeEditor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let view = scrollView.documentView as? NSTextView else { return scrollView }
        view.delegate = context.coordinator
        view.isRichText = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 8, height: 12)
        Self.applyWrapping(wrapsLines, to: view, in: scrollView)
        view.typingAttributes = Self.baseAttributes
        view.setAccessibilityIdentifier("codeEditor")
        view.string = text
        if let storage = view.textStorage { Self.highlight(storage) }
        scrollView.drawsBackground = false
        return scrollView
    }

    /// The usual AppKit arrangement for text that does not wrap: a container
    /// as wide as it likes, a view that grows to fit, and a horizontal scroller.
    private static func applyWrapping(_ wraps: Bool, to view: NSTextView, in scrollView: NSScrollView) {
        guard let container = view.textContainer, container.widthTracksTextView != wraps else { return }
        scrollView.hasHorizontalScroller = !wraps
        view.isHorizontallyResizable = !wraps
        view.autoresizingMask = wraps ? [.width] : [.width, .height]
        container.widthTracksTextView = wraps
        let unbounded = CGFloat.greatestFiniteMagnitude
        container.containerSize = NSSize(width: wraps ? scrollView.contentSize.width : unbounded, height: unbounded)
        view.maxSize = NSSize(width: unbounded, height: unbounded)
        if wraps { view.frame.size.width = scrollView.contentSize.width }
    }

    func updateNSView(_ scrollView: NSScrollView, context _: Context) {
        guard let view = scrollView.documentView as? NSTextView else { return }
        Self.applyWrapping(wrapsLines, to: view, in: scrollView)
        guard view.string != text else { return }
        view.string = text
        if let storage = view.textStorage { Self.highlight(storage) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            let selection = view.selectedRanges
            if let storage = view.textStorage { CodeEditor.highlight(storage) }
            view.selectedRanges = selection
            view.typingAttributes = CodeEditor.baseAttributes
            text.wrappedValue = view.string
        }

        func textView(_ view: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            let edit = VBAIndenter.returnEdit(in: view.string, selection: view.selectedRange())
            view.insertText(edit.replacement, replacementRange: edit.range)
            view.setSelectedRange(NSRange(location: edit.cursor, length: 0))
            return true
        }
    }
}
#endif
