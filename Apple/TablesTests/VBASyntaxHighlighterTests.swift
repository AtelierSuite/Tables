import Foundation
import Testing
@testable import Tables
@testable import TablesEngine
@testable import TablesMacros

@Suite("VBA syntax highlighting")
struct VBASyntaxHighlighterTests {
    /// The coloured pieces of `text`, as the text they cover.
    private func spans(_ text: String) -> [(String, VBASyntaxHighlighter.Kind)] {
        VBASyntaxHighlighter.spans(in: text).map { ((text as NSString).substring(with: $0.range), $0.kind) }
    }

    @Test("Keywords, strings, numbers and comments are found")
    func kinds() {
        let found = spans("If x > 10 Then MsgBox \"It's \"\"big\"\"\" ' check")
        #expect(found.map(\.0) == ["If", "10", "Then", "\"It's \"\"big\"\"\"", "' check"])
        #expect(found.map(\.1) == [.keyword, .number, .keyword, .string, .comment])
    }

    @Test("A quote inside a string does not start a comment, and member names are not keywords")
    func context() {
        let found = spans("s = \"a'b\": Range(\"A1\").End(xlUp).Select")
        #expect(found.map(\.1) == [.string, .string])
    }

    @Test("Rem comments only at the start of a statement; half-typed code never fails")
    func forgiving() {
        #expect(spans("Rem note").map(\.1) == [.comment])
        #expect(spans("x = Remainder").isEmpty)
        #expect(spans("MsgBox \"unterminated").map(\.1) == [.string])
        #expect(spans("Dim é As Long").map(\.0) == ["Dim", "As", "Long"])
    }
}
