import Foundation
import TablesEngine

/// What pressing Return does in macro code: the line being finished snaps
/// to its block's indentation if it closes one — `End Sub` under `Sub`,
/// `Next` under `For`, `Else` under `If` — and the new line starts one step
/// in from a line that opens a block, level with anything else. Opening a
/// block that has nothing to close it also writes its `End` line beneath.
enum VBAIndenter {
    static let step = "    "

    struct Edit: Hashable, Sendable {
        /// The range to replace, in UTF-16 offsets.
        var range: NSRange
        var replacement: String
        /// Where the cursor goes afterwards.
        var cursor: Int
    }

    enum LineKind: Hashable, Sendable {
        case opener, middle, closer, other
    }

    static func returnEdit(in text: String, selection: NSRange) -> Edit {
        let source = text as NSString
        let lineStart = source.lineRange(for: NSRange(location: selection.location, length: 0)).location
        let head = source.substring(with: NSRange(location: lineStart, length: selection.location - lineStart))
        // The rest of the line moves down, without the spaces that led it.
        var tailEnd = NSMaxRange(selection)
        while tailEnd < source.length, [0x20, 0x09].contains(source.character(at: tailEnd)) { tailEnd += 1 }

        let indent = leadingWhitespace(head)
        let content = String(head.dropFirst(indent.count))
        let kind = classify(content)
        var lineIndent = indent
        if kind == .closer || kind == .middle,
           let opener = enclosingOpener(before: lineStart, in: source) {
            lineIndent = opener.indent
            // `Case` sits a step inside its `Select`; the statements under it a step further.
            if kind == .middle, firstWord(opener.content) == "select", firstWord(content) == "case" {
                lineIndent += step
            }
        }
        let nextIndent = kind == .opener || kind == .middle ? lineIndent + step : lineIndent
        var replacement = lineIndent + content + "\n" + nextIndent
        let cursor = lineStart + replacement.utf16.count
        // Finishing the line that opens a block writes the line that closes
        // it too, unless the code already has one waiting for it.
        let lineEnd = NSMaxRange(source.lineRange(for: NSRange(location: tailEnd, length: 0)))
        let restOfLine = source.substring(with: NSRange(location: tailEnd, length: lineEnd - tailEnd))
        if kind == .opener, restOfLine.trimmingCharacters(in: .newlines).isEmpty,
           let closer = closingStatement(for: content), isUnclosed(closer, in: source, replacing: lineStart) {
            replacement += "\n" + lineIndent + closer
        }
        return Edit(range: NSRange(location: lineStart, length: tailEnd - lineStart), replacement: replacement,
                    cursor: cursor)
    }

    /// The statement that ends the block a line opens, as it should be written.
    static func closingStatement(for line: String) -> String? {
        guard classify(line) == .opener else { return nil }
        let words = stripComment(line).lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "(" || $0 == ":" })
            .map(String.init)
            .drop { ["public", "private", "friend", "static", "global"].contains($0) }
        switch words.first {
        case "sub": return "End Sub"
        case "function": return "End Function"
        case "property": return "End Property"
        case "type": return "End Type"
        case "enum": return "End Enum"
        case "if": return "End If"
        case "with": return "End With"
        case "select": return "End Select"
        case "for": return "Next"
        case "do": return "Loop"
        case "while": return "Wend"
        default: return nil
        }
    }

    /// Whether the code holds more blocks ending in `closer` than lines that
    /// end them, counting the line at `lineStart` as one of the blocks however
    /// much of it has been typed. Counting rather than looking at the next
    /// line is what stops a second Return on `Sub Main()` writing a second
    /// `End Sub`.
    private static func isUnclosed(_ closer: String, in source: NSString, replacing lineStart: Int) -> Bool {
        let key = closer.lowercased()
        var balance = 1
        var location = 0
        while location < source.length {
            let range = source.lineRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(range)
            guard range.location != lineStart else { continue }
            let line = source.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            if closingStatement(for: line)?.lowercased() == key {
                balance += 1
            } else if classify(line) == .closer, closingKey(line) == key {
                balance -= 1
            }
        }
        return balance > 0
    }

    /// A closing line's statement, lowercased and with single spaces: `end sub`, `next`.
    private static func closingKey(_ line: String) -> String {
        let words = stripComment(line).lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard let first = words.first else { return "" }
        return first == "end" && words.count > 1 ? "end \(words[1])" : String(first)
    }

    /// The nearest line above `location` that opens the block it is in.
    private static func enclosingOpener(before location: Int, in source: NSString) -> (indent: String, content: String)? {
        var depth = 0
        var end = location
        while end > 0 {
            let range = source.lineRange(for: NSRange(location: end - 1, length: 0))
            let line = source.substring(with: range).trimmingCharacters(in: .newlines)
            end = range.location
            let indent = leadingWhitespace(line)
            let content = String(line.dropFirst(indent.count))
            switch classify(content) {
            case .closer:
                depth += 1
            case .opener:
                if depth == 0 { return (indent, content) }
                depth -= 1
            case .middle, .other:
                continue
            }
        }
        return nil
    }

    static func classify(_ line: String) -> LineKind {
        let code = stripComment(line).trimmingCharacters(in: .whitespaces).lowercased()
        guard !code.isEmpty else { return .other }
        let words = code.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "(" || $0 == ":" }).map(String.init)
        guard let first = words.first else { return .other }
        let second = words.count > 1 ? words[1] : ""
        switch first {
        case "end":
            return ["sub", "function", "property", "if", "with", "select", "type", "enum"].contains(second) ? .closer : .other
        case "next", "loop", "wend":
            return .closer
        case "else", "elseif", "case":
            return .middle
        case "if", "#if":
            // Only the block form: `Then` with nothing after it.
            return code.hasSuffix(" then") || code == "if" ? .opener : .other
        case "for", "do", "while", "with":
            return .opener
        case "select":
            return second == "case" ? .opener : .other
        case "sub", "function", "property", "type", "enum":
            return .opener
        case "public", "private", "friend", "static", "global":
            let rest = words.dropFirst().drop { ["static", "public", "private", "friend"].contains($0) }
            guard let keyword = rest.first else { return .other }
            return ["sub", "function", "property", "type", "enum"].contains(keyword) ? .opener : .other
        default:
            return .other
        }
    }

    private static func firstWord(_ line: String) -> String {
        String(line.lowercased().prefix { $0.isLetter })
    }

    private static func leadingWhitespace(_ line: String) -> String {
        String(line.prefix { $0 == " " || $0 == "\t" })
    }

    /// The line without its `'` comment, quotes inside strings excepted.
    private static func stripComment(_ line: String) -> String {
        var inString = false
        for index in line.indices {
            switch line[index] {
            case "\"": inString.toggle()
            case "'" where !inString: return String(line[..<index])
            default: continue
            }
        }
        return line
    }
}
