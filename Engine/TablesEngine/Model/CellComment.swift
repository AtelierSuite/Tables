import Foundation

/// A comment attached to a cell.
///
/// Excel has two kinds. A note is a single block of text with an author,
/// drawn as a sticky note beside the cell. A threaded comment is a
/// conversation: the first entry and the replies under it, each with an
/// author and a time, which can be marked resolved.
public struct CellComment: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case note
        case thread
    }

    public struct Entry: Hashable, Sendable, Identifiable {
        /// A GUID in braces, as Excel writes them, so replies can name their parent.
        public var id: String
        public var author: String
        public var text: String
        public var date: Date?

        public init(id: String = CellComment.newIdentifier(), author: String, text: String, date: Date? = nil) {
            self.id = id
            self.author = author
            self.text = text
            self.date = date
        }
    }

    public var kind: Kind
    /// The comment itself, then any replies, oldest first. A note has one.
    public var entries: [Entry]
    public var isResolved = false
    /// Whether a note stays on show rather than appearing on hover.
    public var isAlwaysVisible = false

    public init(kind: Kind, entries: [Entry], isResolved: Bool = false, isAlwaysVisible: Bool = false) {
        self.kind = kind
        self.entries = entries
        self.isResolved = isResolved
        self.isAlwaysVisible = isAlwaysVisible
    }

    /// A new note.
    public static func note(author: String, text: String) -> CellComment {
        CellComment(kind: .note, entries: [Entry(author: author, text: text, date: Date())])
    }

    /// A new conversation.
    public static func thread(author: String, text: String) -> CellComment {
        CellComment(kind: .thread, entries: [Entry(author: author, text: text, date: Date())])
    }

    public var author: String { entries.first?.author ?? "" }
    public var text: String { entries.first?.text ?? "" }

    public static func newIdentifier() -> String {
        "{" + UUID().uuidString + "}"
    }
}
