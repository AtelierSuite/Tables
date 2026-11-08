import Foundation

/// A zero-based cell coordinate. `CellAddress(row: 0, column: 0)` is A1.
public struct CellAddress: Hashable, Comparable, Sendable, Codable {
    public var row: Int
    public var column: Int

    public init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }

    public static func < (lhs: CellAddress, rhs: CellAddress) -> Bool {
        lhs.row == rhs.row ? lhs.column < rhs.column : lhs.row < rhs.row
    }

    /// "A1"-style reference for this address.
    public var a1: String { "\(Self.columnName(column))\(row + 1)" }

    /// "A", "B", … "Z", "AA", … for a zero-based column index.
    public static func columnName(_ column: Int) -> String {
        var result = ""
        var value = column
        repeat {
            result = String(UnicodeScalar(UInt8(65 + value % 26))) + result
            value = value / 26 - 1
        } while value >= 0
        return result
    }

    /// Zero-based column index for "A", "AB", … Returns nil for non-letters.
    public static func columnIndex(_ name: String) -> Int? {
        guard !name.isEmpty else { return nil }
        var value = 0
        for scalar in name.uppercased().unicodeScalars {
            guard scalar.value >= 65, scalar.value <= 90 else { return nil }
            value = value * 26 + Int(scalar.value - 64)
        }
        return value - 1
    }

    /// Parses "A1", "$B$7" and similar into an address. Dollar anchors are ignored.
    public init?(a1 reference: String) {
        var letters = ""
        var digits = ""
        for character in reference {
            if character == "$" { continue }
            if character.isLetter {
                guard digits.isEmpty else { return nil }
                letters.append(character)
            } else if character.isNumber {
                digits.append(character)
            } else {
                return nil
            }
        }
        guard let column = Self.columnIndex(letters),
              let rowNumber = Int(digits), rowNumber > 0 else { return nil }
        self.init(row: rowNumber - 1, column: column)
    }
}

/// An inclusive rectangular span of cells.
public struct CellRange: Hashable, Sendable {
    public var start: CellAddress
    public var end: CellAddress

    public init(start: CellAddress, end: CellAddress) {
        self.start = start
        self.end = end
    }

    public init(_ single: CellAddress) {
        self.init(start: single, end: single)
    }

    public var normalized: CellRange {
        CellRange(
            start: CellAddress(row: min(start.row, end.row), column: min(start.column, end.column)),
            end: CellAddress(row: max(start.row, end.row), column: max(start.column, end.column))
        )
    }

    public var rowRange: ClosedRange<Int> { normalized.start.row...normalized.end.row }
    public var columnRange: ClosedRange<Int> { normalized.start.column...normalized.end.column }
    public var isSingleCell: Bool { start == end }

    public func contains(_ address: CellAddress) -> Bool {
        let box = normalized
        return address.row >= box.start.row && address.row <= box.end.row
            && address.column >= box.start.column && address.column <= box.end.column
    }

    /// How many cells the range covers. `Int` overflow is not a worry: a sheet
    /// is capped well below what the product could reach.
    public var cellCount: Int { rowRange.count * columnRange.count }

    /// Visits every address in the range without building an array of them.
    ///
    /// A whole-sheet selection is routine — the corner button makes one — and
    /// on an imported sheet that is millions of addresses. Materializing them
    /// costs more memory than the sheet's actual contents do, so callers that
    /// only need to walk the range walk it here instead.
    public func forEachAddress(_ body: (CellAddress) -> Void) {
        let box = normalized
        for row in box.rowRange {
            for column in box.columnRange {
                body(CellAddress(row: row, column: column))
            }
        }
    }

    public var addresses: [CellAddress] {
        var result: [CellAddress] = []
        result.reserveCapacity(cellCount)
        forEachAddress { result.append($0) }
        return result
    }

    public var a1: String {
        isSingleCell ? start.a1 : "\(normalized.start.a1):\(normalized.end.a1)"
    }
}
