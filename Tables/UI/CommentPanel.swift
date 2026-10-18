import SwiftUI
import TablesEngine

/// Reads, writes and answers the comment on the selected cell.
///
/// A note is one editable block of text. A threaded comment is a
/// conversation, answered with replies and closed by resolving it.
struct CommentPanel: View {
    @Binding var workbook: Workbook
    @Bindable var state: EditorState

    @State private var draft = ""
    @AppStorage(EditorState.commentAuthorKey) private var authorName = ""
    @FocusState private var isDraftFocused: Bool

    private var address: CellAddress { state.selectedAddress }
    private var comment: CellComment? { state.comment(at: address, in: workbook) }

    var body: some View {
        Form {
            if let comment {
                switch comment.kind {
                case .note: noteSection(comment)
                case .thread: threadSection(comment)
                }
            } else {
                newSection
            }

            Section {
                TextField("Comment.Author.Placeholder", text: $authorName)
                    .textContentType(.name)
            } header: {
                Text("Comment.Author.Title")
            } footer: {
                Text("Comment.Author.Footer")
            }

            if comment != nil {
                Section {
                    Button("Comment.Delete", role: .destructive) {
                        state.deleteComment(at: address, in: &workbook)
                        state.presentedPanel = nil
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: address) { _, _ in draft = "" }
    }

    // MARK: - Sections

    private var newSection: some View {
        Section {
            Picker("Comment.Kind", selection: $state.newCommentKind) {
                Text("Comment.Kind.Thread").tag(CellComment.Kind.thread)
                Text("Comment.Kind.Note").tag(CellComment.Kind.note)
            }
            .pickerStyle(.segmented)
            TextField(
                state.newCommentKind == .thread ? "Comment.NewThread.Placeholder" : "Comment.NewNote.Placeholder",
                text: $draft, axis: .vertical
            )
            .lineLimit(3...10)
            .focused($isDraftFocused)
            Button(state.newCommentKind == .thread ? "Comment.Post" : "Comment.AddNote") {
                state.addComment(draft, kind: state.newCommentKind, at: address, in: &workbook)
                draft = ""
            }
            .disabled(draft.trimmed.isEmpty)
            .accessibilityIdentifier("comment.post")
        } header: {
            Text(String(format: String(localized: "Comment.Cell.Header"), address.a1))
        }
        .onAppear { isDraftFocused = true }
    }

    private func noteSection(_ note: CellComment) -> some View {
        Section {
            TextField("Comment.NewNote.Placeholder", text: Binding(
                get: { note.text },
                set: { state.updateNote($0, at: address, in: &workbook) }
            ), axis: .vertical)
            .lineLimit(3...12)
            Toggle("Comment.Note.AlwaysShow", isOn: Binding(
                get: { note.isAlwaysVisible },
                set: { state.setNoteAlwaysVisible($0, at: address, in: &workbook) }
            ))
        } header: {
            Text(String(format: String(localized: "Comment.Note.Header"), address.a1, note.author))
        }
    }

    private func threadSection(_ thread: CellComment) -> some View {
        Group {
            Section {
                ForEach(thread.entries) { entry in
                    CommentEntryRow(entry: entry)
                }
            } header: {
                Text(String(format: String(localized: "Comment.Cell.Header"), address.a1))
            } footer: {
                if thread.isResolved { Text("Comment.Resolved.Footer") }
            }

            Section {
                if !thread.isResolved {
                    TextField("Comment.Reply.Placeholder", text: $draft, axis: .vertical)
                        .lineLimit(1...8)
                    Button("Comment.Reply") {
                        state.reply(draft, at: address, in: &workbook)
                        draft = ""
                    }
                    .disabled(draft.trimmed.isEmpty)
                    .accessibilityIdentifier("comment.reply")
                }
                Button(thread.isResolved ? "Comment.Reopen" : "Comment.Resolve") {
                    state.setResolved(!thread.isResolved, at: address, in: &workbook)
                }
            }
        }
    }
}

/// One message in a conversation: who, when, and what.
private struct CommentEntryRow: View {
    let entry: CellComment.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.author.isEmpty ? String(localized: "Comment.Author.Unknown") : entry.author)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let date = entry.date {
                    Text(date, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(entry.text)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
