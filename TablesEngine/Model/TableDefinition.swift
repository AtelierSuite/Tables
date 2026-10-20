import Foundation

/// An Excel table (a ListObject): a named block of rows with a header row,
/// which formulas refer to by name, as in `Sales[Amount]` or `[@Price]`.
///
/// Tables are read from the file so their names resolve; the table parts
/// themselves are carried through a save untouched.
public struct TableDefinition: Hashable, Sendable {
    public var name: String
    public var sheetID: Worksheet.ID
    /// The whole table, header and totals rows included.
    public var range: CellRange
    public var headerRowCount: Int
    public var totalsRowCount: Int
    public var columns: [String]

    /// The rows between the header and the totals.
    public var dataRows: ClosedRange<Int>? {
        let first = range.start.row + headerRowCount
        let last = range.end.row - totalsRowCount
        return first <= last ? first...last : nil
    }

    public func columnIndex(named name: String) -> Int? {
        columns.firstIndex { $0.caseInsensitiveCompare(name) == .orderedSame }
    }
}

extension TableDefinition {
    /// The cells a structured reference's specifier names: `Amount`,
    /// `#Headers`, `@Price`, `[#Data],[Qty]:[Price]` and so on. `row` is the
    /// formula's own row, for `@` and `#This Row`. Nil when the specifier
    /// names something the table does not have.
    public func resolve(_ specifier: String, row: Int?) -> CellRange? {
        var text = specifier.trimmingCharacters(in: .whitespaces)
        var specials: Set<String> = []
        var names: [[String]] = []
        if text.hasPrefix("@") {
            specials.insert("#this row")
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        if !text.isEmpty {
            guard let items = Self.items(text) else { return nil }
            for item in items {
                let first = item[0].trimmingCharacters(in: .whitespaces)
                if item.count == 1, first.hasPrefix("#") {
                    specials.insert(first.lowercased())
                } else {
                    names.append(item)
                }
            }
        }

        // Rows.
        let data = dataRows
        let headerRows = headerRowCount > 0 ? range.start.row...(range.start.row + headerRowCount - 1) : nil
        let totalRows = totalsRowCount > 0 ? (range.end.row - totalsRowCount + 1)...range.end.row : nil
        var rows: ClosedRange<Int>?
        func include(_ span: ClosedRange<Int>?) -> Bool {
            guard let span else { return false }
            rows = rows.map { min($0.lowerBound, span.lowerBound)...max($0.upperBound, span.upperBound) } ?? span
            return true
        }
        if specials.isEmpty { guard include(data) else { return nil } }
        for special in specials {
            switch special {
            case "#all": _ = include(range.rowRange)
            case "#data": guard include(data) else { return nil }
            case "#headers": guard include(headerRows) else { return nil }
            case "#totals": guard include(totalRows) else { return nil }
            case "#this row":
                guard let row, data?.contains(row) == true else { return nil }
                _ = include(row...row)
            default: return nil
            }
        }
        guard let rows else { return nil }

        // Columns.
        var columnSpan = range.columnRange
        if !names.isEmpty {
            var indices: [Int] = []
            for item in names {
                for name in item {
                    guard let index = columnIndex(named: Self.unescaped(name.trimmingCharacters(in: .whitespaces)))
                    else { return nil }
                    indices.append(range.start.column + index)
                }
            }
            columnSpan = indices.min()!...indices.max()!
        }
        return CellRange(start: CellAddress(row: rows.lowerBound, column: columnSpan.lowerBound),
                         end: CellAddress(row: rows.upperBound, column: columnSpan.upperBound))
    }

    /// Splits a specifier into its comma-separated items, each a column name,
    /// a `#` keyword, or a `first:last` pair of columns.
    private static func items(_ text: String) -> [[String]]? {
        guard text.hasPrefix("[") else { return [[text]] }
        var result: [[String]] = []
        var current: [String] = []
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "[" {
                var depth = 1
                var piece = ""
                index += 1
                while index < characters.count {
                    let inner = characters[index]
                    if inner == "'", index + 1 < characters.count {
                        piece.append(inner)
                        piece.append(characters[index + 1])
                        index += 2
                        continue
                    }
                    if inner == "[" { depth += 1 }
                    if inner == "]" {
                        depth -= 1
                        if depth == 0 { break }
                    }
                    piece.append(inner)
                    index += 1
                }
                guard depth == 0 else { return nil }
                current.append(piece)
            } else if character == "," {
                if !current.isEmpty { result.append(current) }
                current = []
            } else if character != ":", !character.isWhitespace {
                return nil
            }
            index += 1
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// A column name with its `'` escapes removed.
    private static func unescaped(_ name: String) -> String {
        var result = ""
        var escaping = false
        for character in name {
            if !escaping, character == "'" {
                escaping = true
                continue
            }
            result.append(character)
            escaping = false
        }
        return result
    }
}
