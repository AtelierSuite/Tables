import AppKit
import TablesEngine

/// Reads, writes and answers the comment on the selected cell, in a popover
/// pointing at it.
///
/// A note is one editable block of text. A threaded comment is a
/// conversation, answered with replies and closed by resolving it.
@MainActor
final class CommentViewController: NSViewController, NSTextViewDelegate, NSTextFieldDelegate {
    weak var document: WorkbookDocument?
    private let stack = NSStackView()
    private var draft = NSTextView()
    private var noteText: NSTextView?
    private var address = CellAddress(row: 0, column: 0)
    /// The comment the popover was last built for, so typing in it does not
    /// rebuild it under the caret.
    private var shown: CellComment?
    private var isBuilt = false

    override func loadView() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: 320),
        ])
        view = root
    }

    /// Shows the comment on the selected cell, rebuilding only when the
    /// comment changed from outside the popover.
    func refresh(force: Bool = false) {
        guard let document else { return }
        let state = document.state
        let current = state.comment(at: state.selectedAddress, in: document.workbook)
        guard force || !isBuilt || state.selectedAddress != address || current != shown else { return }
        isBuilt = true
        address = state.selectedAddress
        shown = current
        rebuild(comment: current, state: state)
    }

    private func rebuild(comment: CellComment?, state: EditorState) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        noteText = nil
        switch comment?.kind {
        case .note?: buildNote(comment!)
        case .thread?: buildThread(comment!)
        case nil: buildNew(kind: state.newCommentKind)
        }
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(header(String(localized: "Comment.Author.Title")))
        let author = NSTextField(string: UserDefaults.standard.string(forKey: EditorState.commentAuthorKey) ?? "")
        author.placeholderString = String(localized: "Comment.Author.Placeholder")
        author.contentType = .name
        author.delegate = self
        author.identifier = NSUserInterfaceItemIdentifier("author")
        stack.addArrangedSubview(author)
        author.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        stack.addArrangedSubview(footnote(String(localized: "Comment.Author.Footer")))
        if comment != nil {
            let delete = NSButton(title: String(localized: "Comment.Delete"), target: self, action: #selector(deleteComment(_:)))
            delete.hasDestructiveAction = true
            stack.addArrangedSubview(delete)
        }
    }

    // MARK: - Sections

    private func buildNew(kind: CellComment.Kind) {
        stack.addArrangedSubview(header(String(format: String(localized: "Comment.Cell.Header"), address.a1)))
        let picker = NSSegmentedControl(
            labels: [String(localized: "Comment.Kind.Thread"), String(localized: "Comment.Kind.Note")],
            trackingMode: .selectOne, target: self, action: #selector(pickKind(_:))
        )
        picker.selectedSegment = kind == .thread ? 0 : 1
        stack.addArrangedSubview(picker)
        let (scroll, text) = textArea(height: 80)
        draft = text
        text.setAccessibilityIdentifier("comment.draft")
        stack.addArrangedSubview(scroll)
        let post = NSButton(
            title: String(localized: kind == .thread ? "Comment.Post" : "Comment.AddNote"),
            target: self, action: #selector(post(_:))
        )
        post.keyEquivalent = "\r"
        post.keyEquivalentModifierMask = .command
        post.setAccessibilityIdentifier("comment.post")
        stack.addArrangedSubview(post)
        DispatchQueue.main.async { [weak self] in self?.view.window?.makeFirstResponder(text) }
    }

    private func buildNote(_ note: CellComment) {
        stack.addArrangedSubview(header(String(format: String(localized: "Comment.Note.Header"), address.a1, note.author)))
        let (scroll, text) = textArea(height: 120)
        text.string = note.text
        text.delegate = self
        noteText = text
        stack.addArrangedSubview(scroll)
        let always = NSButton(checkboxWithTitle: String(localized: "Comment.Note.AlwaysShow"), target: self,
                              action: #selector(toggleAlwaysShow(_:)))
        always.state = note.isAlwaysVisible ? .on : .off
        stack.addArrangedSubview(always)
    }

    private func buildThread(_ thread: CellComment) {
        stack.addArrangedSubview(header(String(format: String(localized: "Comment.Cell.Header"), address.a1)))
        for entry in thread.entries {
            stack.addArrangedSubview(row(for: entry))
        }
        if thread.isResolved {
            stack.addArrangedSubview(footnote(String(localized: "Comment.Resolved.Footer")))
        } else {
            let (scroll, text) = textArea(height: 50)
            draft = text
            text.setAccessibilityIdentifier("comment.draft")
            stack.addArrangedSubview(scroll)
        }
        let buttons = NSStackView()
        buttons.orientation = .horizontal
        if !thread.isResolved {
            let reply = NSButton(title: String(localized: "Comment.Reply"), target: self, action: #selector(reply(_:)))
            reply.keyEquivalent = "\r"
            reply.keyEquivalentModifierMask = .command
            reply.setAccessibilityIdentifier("comment.reply")
            buttons.addArrangedSubview(reply)
        }
        buttons.addArrangedSubview(NSButton(
            title: String(localized: thread.isResolved ? "Comment.Reopen" : "Comment.Resolve"),
            target: self, action: #selector(toggleResolved(_:))
        ))
        stack.addArrangedSubview(buttons)
    }

    /// One message in a conversation: who, when, and what.
    private func row(for entry: CellComment.Entry) -> NSView {
        let author = NSTextField(labelWithString: entry.author.isEmpty ? String(localized: "Comment.Author.Unknown") : entry.author)
        author.font = .systemFont(ofSize: NSFont.smallSystemFontSize + 1, weight: .semibold)
        let date = NSTextField(labelWithString: entry.date.map {
            $0.formatted(.relative(presentation: .named))
        } ?? "")
        date.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        date.textColor = .secondaryLabelColor
        let top = NSStackView(views: [author, date])
        top.orientation = .horizontal
        let text = NSTextField(wrappingLabelWithString: entry.text)
        text.isSelectable = true
        text.preferredMaxLayoutWidth = 288
        let row = NSStackView(views: [top, text])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 2
        return row
    }

    // MARK: - Pieces

    private func header(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        return label
    }

    private func footnote(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 288
        return label
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func textArea(height: CGFloat) -> (NSScrollView, NSTextView) {
        let scroll = NSTextView.scrollableTextView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        let text = scroll.documentView as! NSTextView
        text.font = .systemFont(ofSize: NSFont.systemFontSize)
        text.isRichText = false
        text.allowsUndo = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: 288),
            scroll.heightAnchor.constraint(equalToConstant: height),
        ])
        return (scroll, text)
    }

    // MARK: - Actions

    private func edit(_ change: (EditorState, inout Workbook) -> Void) {
        guard let document else { return }
        let state = document.state
        document.edit { change(state, &$0) }
    }

    @objc private func pickKind(_ sender: NSSegmentedControl) {
        guard let state = document?.state else { return }
        state.newCommentKind = sender.selectedSegment == 0 ? .thread : .note
        refresh(force: true)
    }

    @objc private func post(_ sender: Any?) {
        let text = draft.string
        let address = address
        edit { state, workbook in state.addComment(text, kind: state.newCommentKind, at: address, in: &workbook) }
        refresh(force: true)
    }

    @objc private func reply(_ sender: Any?) {
        let text = draft.string
        let address = address
        edit { $0.reply(text, at: address, in: &$1) }
        refresh(force: true)
    }

    @objc private func toggleResolved(_ sender: Any?) {
        guard let document, let thread = document.state.comment(at: address, in: document.workbook) else { return }
        let address = address
        edit { $0.setResolved(!thread.isResolved, at: address, in: &$1) }
        refresh(force: true)
    }

    @objc private func toggleAlwaysShow(_ sender: NSButton) {
        let address = address
        edit { $0.setNoteAlwaysVisible(sender.state == .on, at: address, in: &$1) }
    }

    @objc private func deleteComment(_ sender: Any?) {
        let address = address
        edit { $0.deleteComment(at: address, in: &$1) }
        view.window?.performClose(nil)
    }

    func textDidChange(_ notification: Notification) {
        guard let noteText, (notification.object as? NSTextView) === noteText else { return }
        let text = noteText.string
        let address = address
        edit { $0.updateNote(text, at: address, in: &$1) }
        if let document { shown = document.state.comment(at: address, in: document.workbook) }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field.identifier?.rawValue == "author" else { return }
        UserDefaults.standard.set(field.stringValue, forKey: EditorState.commentAuthorKey)
    }
}
