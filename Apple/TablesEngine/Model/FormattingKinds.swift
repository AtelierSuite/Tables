import Foundation

/// The kinds of formatting a document keeps, each offered only where it can
/// be saved.
public struct FormattingKinds: OptionSet, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let numberFormats = FormattingKinds(rawValue: 1 << 0)
    /// Bold, italic, underline, strikethrough, text sizes and colours, fills,
    /// alignment and wrapping.
    public static let styles = FormattingKinds(rawValue: 1 << 1)
    public static let borders = FormattingKinds(rawValue: 1 << 2)
    public static let indents = FormattingKinds(rawValue: 1 << 3)
    public static let rotation = FormattingKinds(rawValue: 1 << 4)
    public static let merging = FormattingKinds(rawValue: 1 << 5)

    public static let all: FormattingKinds = [.numberFormats, .styles, .borders, .indents, .rotation, .merging]
}
