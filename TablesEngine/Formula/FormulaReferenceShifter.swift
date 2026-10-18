import Foundation

/// Rewrites A1-style references inside formula text when rows or columns are
/// inserted or removed. Operates on the raw text so `$` anchors, spacing and
/// unrecognized syntax survive untouched.
public enum FormulaReferenceShifter {
    public enum Axis: Sendable { case row, column }

    public enum Operation: Sendable {
        /// `count` lines were inserted starting at zero-based `index`.
        case insert(index: Int, count: Int)
        /// The inclusive zero-based `range` of lines was deleted.
        case remove(range: ClosedRange<Int>)
        /// Every unanchored reference moves by `delta`, as when a formula is
        /// filled from one cell to another.
        case translate(delta: Int)
    }

    /// Rewrites a formula as if it had been filled from one cell to another:
    /// relative references move with it, `$`-anchored ones stay put.
    ///
    /// This is what expands the shared formulas Excel writes for a filled-down
    /// column, where only the first cell carries the text.
    public static func translated(
        _ formula: String, rowDelta: Int, columnDelta: Int
    ) -> String {
        var result = formula
        if rowDelta != 0 {
            result = rewrite(result, operation: .translate(delta: rowDelta), axis: .row)
        }
        if columnDelta != 0 {
            result = rewrite(result, operation: .translate(delta: columnDelta), axis: .column)
        }
        return result
    }

    /// The sheet whose rows or columns moved, so only references into it
    /// follow: those naming it, and, in formulas on it, those naming no
    /// sheet.
    public struct Scope: Sendable {
        public var sheet: String
        /// The sheet the formulas are on.
        public var host: String

        public func covers(_ name: String?) -> Bool {
            (name ?? host).caseInsensitiveCompare(sheet) == .orderedSame
        }
    }

    /// Applies an operation to every formula in a cell table, or to the
    /// references `scope` covers.
    public static func apply(_ operation: Operation, axis: Axis, to cells: inout [CellAddress: Cell], scope: Scope? = nil) {
        for (address, cell) in cells {
            guard let formula = cell.formula else { continue }
            let rewritten = rewrite(formula, operation: operation, axis: axis, scope: scope)
            guard rewritten != formula else { continue }
            var updated = cell
            updated.formula = rewritten
            cells[address] = updated
        }
    }

    public static func rewrite(_ formula: String, operation: Operation, axis: Axis, scope: Scope? = nil) -> String {
        let characters = Array(formula)
        var result = ""
        var index = 0
        var quote: Character?
        /// Where the last reference ended and the sheet it named.
        var last: (end: Int, sheet: String?)?
        func sheet(at start: Int) -> String? {
            if let name = sheetName(before: start, in: characters) { return name }
            // A range's far end is on the sheet its near end names.
            if start > 0, characters[start - 1] == ":", let last, last.end == start - 1 { return last.sheet }
            return nil
        }

        while index < characters.count {
            let character = characters[index]

            if let open = quote {
                result.append(character)
                if character == open { quote = nil }
                index += 1
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                result.append(character)
                index += 1
                continue
            }
            // A table's column names in brackets are names, not references,
            // however much `[Q1]` looks like a cell.
            if character == "[" {
                var depth = 0
                while index < characters.count {
                    let inner = characters[index]
                    result.append(inner)
                    index += 1
                    if inner == "'", index < characters.count {
                        result.append(characters[index])
                        index += 1
                        continue
                    }
                    if inner == "[" { depth += 1 }
                    if inner == "]" {
                        depth -= 1
                        if depth == 0 { break }
                    }
                }
                continue
            }

            if let span = scanLineSpan(characters, from: index) {
                let name = sheet(at: index)
                result += scope?.covers(name) ?? true
                    ? transform(span, operation: operation, axis: axis) : String(characters[index..<span.endIndex])
                last = (span.endIndex, name)
                index = span.endIndex
                continue
            }

            if let token = scanReference(characters, from: index) {
                // A word immediately followed by "(" is a function name, not a reference.
                var lookahead = token.end
                while lookahead < characters.count, characters[lookahead] == " " { lookahead += 1 }
                let isFunctionName = lookahead < characters.count && characters[lookahead] == "("
                // A reference must not be glued to a preceding identifier character.
                let previous = index > 0 ? characters[index - 1] : " "
                let isSuffixOfWord = previous.isLetter || previous.isNumber || previous == "_"

                if !isFunctionName, !isSuffixOfWord {
                    let name = sheet(at: index)
                    // A range loses the lines removed from it, as Excel's
                    // does, breaking only once every one has gone.
                    if case .remove(let removed) = operation, scope?.covers(name) ?? true,
                       token.end < characters.count, characters[token.end] == ":",
                       let end = scanReference(characters, from: token.end + 1) {
                        result += transform(token, end, removing: removed, axis: axis)
                        last = (end.end, name)
                        index = end.end
                        continue
                    }
                    result += scope?.covers(name) ?? true
                        ? transform(token, operation: operation, axis: axis) : String(characters[index..<token.end])
                    last = (token.end, name)
                    index = token.end
                    continue
                }
                result += String(characters[index..<token.end])
                index = token.end
                continue
            }

            result.append(character)
            index += 1
        }
        return result
    }

    // MARK: - Reference scanning

    /// The sheet named in front of a reference starting at `start`, as in
    /// `Sheet1!A1` or `'Q1 Sales'!A1`.
    private static func sheetName(before start: Int, in characters: [Character]) -> String? {
        guard start > 1, characters[start - 1] == "!" else { return nil }
        var index = start - 2
        var name: [Character] = []
        if characters[index] == "'" {
            index -= 1
            while index >= 0 {
                if characters[index] == "'" {
                    // A quote inside the name is written twice.
                    guard index > 0, characters[index - 1] == "'" else { return String(name.reversed()) }
                    index -= 1
                }
                name.append(characters[index])
                index -= 1
            }
            return nil
        }
        while index >= 0, characters[index].isLetter || characters[index].isNumber || "_.".contains(characters[index]) {
            name.append(characters[index])
            index -= 1
        }
        return name.isEmpty ? nil : String(name.reversed())
    }

    private struct ReferenceToken {
        var columnAnchored: Bool
        var columnLetters: String
        var rowAnchored: Bool
        var rowDigits: String
        var end: Int
    }

    private static func scanReference(_ characters: [Character], from start: Int) -> ReferenceToken? {
        var index = start
        var columnAnchored = false
        if index < characters.count, characters[index] == "$" {
            columnAnchored = true
            index += 1
        }
        var letters = ""
        while index < characters.count, characters[index].isLetter {
            letters.append(characters[index])
            index += 1
        }
        guard !letters.isEmpty, letters.count <= 3, CellAddress.columnIndex(letters) != nil else { return nil }

        var rowAnchored = false
        if index < characters.count, characters[index] == "$" {
            rowAnchored = true
            index += 1
        }
        var digits = ""
        while index < characters.count, characters[index].isNumber {
            digits.append(characters[index])
            index += 1
        }
        guard !digits.isEmpty, Int(digits) != nil else { return nil }
        // Anything glued on after the digits means this wasn't a plain reference.
        if index < characters.count, characters[index].isLetter || characters[index] == "_" { return nil }

        return ReferenceToken(
            columnAnchored: columnAnchored, columnLetters: letters,
            rowAnchored: rowAnchored, rowDigits: digits, end: index
        )
    }

    /// A whole-column (`A:C`) or whole-row (`1:3`) reference.
    private struct LineSpanToken {
        enum Kind { case columns, rows }
        var kind: Kind
        var startAnchored: Bool
        var start: String
        var endAnchored: Bool
        var end: String
        /// Offset just past the token.
        var endIndex: Int
    }

    private static func scanLineSpan(_ characters: [Character], from start: Int) -> LineSpanToken? {
        // Glued to a preceding word, this is part of a name or a sheet-qualified
        // 3-D span, not a span of its own.
        if start > 0 {
            let previous = characters[start - 1]
            if previous.isLetter || previous.isNumber || previous == "_" || previous == "." || previous == "$" {
                return nil
            }
        }
        func side(at position: Int, _ accepts: (Character) -> Bool) -> (anchored: Bool, text: String, end: Int)? {
            var index = position
            var anchored = false
            if index < characters.count, characters[index] == "$" {
                anchored = true
                index += 1
            }
            var text = ""
            while index < characters.count, accepts(characters[index]) {
                text.append(characters[index])
                index += 1
            }
            return text.isEmpty ? nil : (anchored, text, index)
        }
        for kind in [LineSpanToken.Kind.columns, .rows] {
            let accepts: (Character) -> Bool = kind == .columns ? { $0.isLetter } : { $0.isNumber }
            guard let first = side(at: start, accepts),
                  first.end < characters.count, characters[first.end] == ":",
                  let second = side(at: first.end + 1, accepts) else { continue }
            // Anything glued on after means this was a cell range or a name.
            if second.end < characters.count {
                let next = characters[second.end]
                if next.isLetter || next.isNumber || next == "_" || next == "." || next == "(" || next == "!" { continue }
            }
            if kind == .columns {
                guard first.text.count <= 3, second.text.count <= 3,
                      CellAddress.columnIndex(first.text) != nil, CellAddress.columnIndex(second.text) != nil else { continue }
            } else {
                guard Int(first.text) != nil, Int(second.text) != nil else { continue }
            }
            return LineSpanToken(kind: kind, startAnchored: first.anchored, start: first.text,
                                 endAnchored: second.anchored, end: second.text, endIndex: second.end)
        }
        return nil
    }

    private static func transform(_ token: LineSpanToken, operation: Operation, axis: Axis) -> String {
        func render(_ anchored: Bool, _ text: String) -> String { (anchored ? "$" : "") + text }
        let original = render(token.startAnchored, token.start) + ":" + render(token.endAnchored, token.end)
        // Rows never move a column span, and columns never move a row span.
        guard (token.kind == .columns) == (axis == .column) else { return original }

        func line(_ text: String) -> Int? {
            token.kind == .columns ? CellAddress.columnIndex(text) : Int(text).map { $0 - 1 }
        }
        func name(_ line: Int) -> String {
            token.kind == .columns ? CellAddress.columnName(line) : String(line + 1)
        }
        func moved(_ anchored: Bool, _ text: String) -> String? {
            guard let index = line(text) else { return render(anchored, text) }
            if case .translate = operation, anchored { return render(anchored, text) }
            switch shift(index, operation: operation) {
            case .broken: return nil
            case .same: return render(anchored, text)
            case .moved(let updated): return render(anchored, name(updated))
            }
        }
        if case .remove(let removed) = operation, let start = line(token.start), let end = line(token.end), start <= end {
            guard let span = Worksheet.span(start...end, removing: removed) else { return CellError.referenceError.rawValue }
            return render(token.startAnchored, name(span.lowerBound)) + ":" + render(token.endAnchored, name(span.upperBound))
        }
        guard let first = moved(token.startAnchored, token.start),
              let last = moved(token.endAnchored, token.end) else { return CellError.referenceError.rawValue }
        return first + ":" + last
    }

    /// A range of cells once lines are removed: shrunk by those inside it,
    /// and broken only when it loses every one.
    private static func transform(
        _ start: ReferenceToken, _ end: ReferenceToken, removing removed: ClosedRange<Int>, axis: Axis
    ) -> String {
        func line(_ token: ReferenceToken) -> Int? {
            axis == .row ? Int(token.rowDigits).map { $0 - 1 } : CellAddress.columnIndex(token.columnLetters)
        }
        func placed(_ token: ReferenceToken, at line: Int) -> String {
            var token = token
            if axis == .row {
                token.rowDigits = String(line + 1)
            } else {
                token.columnLetters = CellAddress.columnName(line)
            }
            return render(token)
        }
        guard let first = line(start), let last = line(end), first <= last else {
            let operation = Operation.remove(range: removed)
            return transform(start, operation: operation, axis: axis) + ":" + transform(end, operation: operation, axis: axis)
        }
        guard let span = Worksheet.span(first...last, removing: removed) else { return CellError.referenceError.rawValue }
        return placed(start, at: span.lowerBound) + ":" + placed(end, at: span.upperBound)
    }

    private static func transform(_ token: ReferenceToken, operation: Operation, axis: Axis) -> String {
        guard let column = CellAddress.columnIndex(token.columnLetters),
              let rowNumber = Int(token.rowDigits) else {
            return render(token)
        }
        let row = rowNumber - 1
        let subject = axis == .row ? row : column

        // Filling a formula leaves anchored references where they are. Inserting
        // and deleting lines moves them regardless, so only translation cares.
        if case .translate = operation {
            let isAnchored = axis == .row ? token.rowAnchored : token.columnAnchored
            if isAnchored { return render(token) }
        }

        switch shift(subject, operation: operation) {
        case .broken:
            return CellError.referenceError.rawValue
        case .same:
            return render(token)
        case .moved(let updated):
            var token = token
            if axis == .row {
                token.rowDigits = String(updated + 1)
            } else {
                token.columnLetters = CellAddress.columnName(updated)
            }
            return render(token)
        }
    }

    private enum ShiftOutcome {
        case same
        case moved(Int)
        case broken
    }

    private static func shift(_ line: Int, operation: Operation) -> ShiftOutcome {
        switch operation {
        case .insert(let index, let count):
            return line >= index ? .moved(line + count) : .same
        case .remove(let range):
            if range.contains(line) { return .broken }
            return line > range.upperBound ? .moved(line - range.count) : .same
        case .translate(let delta):
            let moved = line + delta
            // Falling off the top or left edge is a genuine broken reference.
            return moved < 0 ? .broken : .moved(moved)
        }
    }

    private static func render(_ token: ReferenceToken) -> String {
        (token.columnAnchored ? "$" : "") + token.columnLetters
            + (token.rowAnchored ? "$" : "") + token.rowDigits
    }
}
