import Foundation

/// The kinds of formatting a document keeps, each offered only where it can
/// be saved.
struct FormattingKinds: OptionSet, Hashable, Sendable {
    let rawValue: Int

    static let numberFormats = FormattingKinds(rawValue: 1 << 0)
    /// Bold, italic, underline, strikethrough, text sizes and colours, fills,
    /// alignment and wrapping.
    static let styles = FormattingKinds(rawValue: 1 << 1)
    static let borders = FormattingKinds(rawValue: 1 << 2)
    static let indents = FormattingKinds(rawValue: 1 << 3)
    static let rotation = FormattingKinds(rawValue: 1 << 4)
    static let merging = FormattingKinds(rawValue: 1 << 5)

    static let all: FormattingKinds = [.numberFormats, .styles, .borders, .indents, .rotation, .merging]
}
