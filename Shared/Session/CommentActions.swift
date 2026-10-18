import SwiftUI
import TablesEngine

/// The comment edits the UI makes, alongside the other document mutations.
extension EditorState {
    /// The name comments are signed with: the one the person gave, or the
    /// account's full name where the system has one.
    static var commentAuthor: String {
        let chosen = UserDefaults.standard.string(forKey: commentAuthorKey)?.trimmed ?? ""
        if !chosen.isEmpty { return chosen }
        #if os(macOS)
        let full = NSFullUserName().trimmed
        if !full.isEmpty { return full }
        #endif
        return String(localized: "Comment.Author.Unknown")
    }

    static let commentAuthorKey = "Comments.AuthorName"

    func comment(at address: CellAddress, in workbook: Workbook) -> CellComment? {
        activeSheet(in: workbook).comments[address]
    }

    /// Opens the comment panel on a cell, ready to start a note or a thread
    /// if it has neither.
    func showComment(at address: CellAddress, kind: CellComment.Kind, in workbook: Workbook) {
        select(address, in: activeSheet(in: workbook))
        newCommentKind = kind
        presentedPanel = .comment
    }

    func addComment(_ text: String, kind: CellComment.Kind, at address: CellAddress, in workbook: inout Workbook) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        let index = activeIndex(in: workbook)
        let author = Self.commentAuthor
        workbook.sheets[index].comments[address] = kind == .note
            ? .note(author: author, text: body)
            : .thread(author: author, text: body)
    }

    func reply(_ text: String, at address: CellAddress, in workbook: inout Workbook) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let index = activeIndex(in: workbook)
        guard !body.isEmpty, workbook.sheets[index].comments[address]?.kind == .thread else { return }
        workbook.sheets[index].comments[address]?.entries.append(
            CellComment.Entry(author: Self.commentAuthor, text: body, date: Date()))
    }

    func updateNote(_ text: String, at address: CellAddress, in workbook: inout Workbook) {
        let index = activeIndex(in: workbook)
        guard workbook.sheets[index].comments[address]?.kind == .note,
              workbook.sheets[index].comments[address]?.entries.first?.text != text else { return }
        workbook.sheets[index].comments[address]?.entries[0].text = text
    }

    func setNoteAlwaysVisible(_ visible: Bool, at address: CellAddress, in workbook: inout Workbook) {
        let index = activeIndex(in: workbook)
        workbook.sheets[index].comments[address]?.isAlwaysVisible = visible
    }

    func setResolved(_ resolved: Bool, at address: CellAddress, in workbook: inout Workbook) {
        let index = activeIndex(in: workbook)
        workbook.sheets[index].comments[address]?.isResolved = resolved
    }

    func deleteComment(at address: CellAddress, in workbook: inout Workbook) {
        let index = activeIndex(in: workbook)
        workbook.sheets[index].comments[address] = nil
    }

    /// Deletes every comment in the selection.
    func deleteComments(in workbook: inout Workbook) {
        let index = activeIndex(in: workbook)
        let ranges = selectedRanges.map(\.normalized)
        workbook.sheets[index].comments = workbook.sheets[index].comments.filter { address, _ in
            !ranges.contains { $0.contains(address) }
        }
    }
}
