#if canImport(SwiftUI)
import SwiftUI
#else
import Foundation
#endif

/// The merged regions of a sheet, filed by the block of the grid they fall in
/// so that asking about one address or one tile reads a handful of them
/// rather than every merge the sheet has.
public struct MergeIndex: Sendable {
    /// The side of a block, in lines. A tile is a few blocks at most, and a
    /// merge as wide as a column a few hundred.
    private static let block = 64

    private struct Block: Hashable {
        var row: Int
        var column: Int
    }

    /// Every merge, normalized, in the order the sheet keeps them.
    public let ranges: [CellRange]
    private let blocks: [Block: [Int]]

    public init(_ ranges: [CellRange]) {
        let ranges = ranges.map(\.normalized)
        var blocks: [Block: [Int]] = [:]
        for (index, range) in ranges.enumerated() {
            for row in Self.blocks(range.start.row...range.end.row) {
                for column in Self.blocks(range.start.column...range.end.column) {
                    blocks[Block(row: row, column: column), default: []].append(index)
                }
            }
        }
        self.ranges = ranges
        self.blocks = blocks
    }

    private static func blocks(_ lines: ClosedRange<Int>) -> ClosedRange<Int> {
        (max(0, lines.lowerBound) / block)...(max(0, lines.upperBound) / block)
    }

    /// The merge covering an address, if any.
    public func range(containing address: CellAddress) -> CellRange? {
        guard !ranges.isEmpty, address.row >= 0, address.column >= 0,
              let candidates = blocks[Block(row: address.row / Self.block, column: address.column / Self.block)]
        else { return nil }
        for index in candidates where ranges[index].contains(address) { return ranges[index] }
        return nil
    }

    /// Whether a merge covers an address.
    public func contains(_ address: CellAddress) -> Bool {
        range(containing: address) != nil
    }

    /// The merges meeting a range, normalized, in the order the sheet keeps them.
    public func ranges(intersecting area: CellRange) -> [CellRange] {
        guard !ranges.isEmpty else { return [] }
        let area = area.normalized
        let rows = Self.blocks(area.start.row...area.end.row)
        let columns = Self.blocks(area.start.column...area.end.column)
        // An area wider than the merges are many is quicker to test against them all.
        guard rows.count * columns.count < ranges.count else {
            return ranges.filter { $0.intersects(area) }
        }
        var found = Set<Int>()
        for row in rows {
            for column in columns {
                for index in blocks[Block(row: row, column: column)] ?? [] where ranges[index].intersects(area) {
                    found.insert(index)
                }
            }
        }
        return found.sorted().map { ranges[$0] }
    }
}

/// What drawing a sheet keeps asking of it, worked out once for a version of
/// the sheet: where its merges are, which rows carry comments, and whether
/// its author made it dark.
///
/// Each of those is a walk over the whole sheet when asked of the sheet
/// itself, and a renderer asks them for every tile, or every cell, of every
/// frame. Built from one version of a sheet, a lookup answers for that
/// version only: `SheetLookupCache` builds a new one once the sheet changes.
public struct SheetLookup: Sendable {
    public let merges: MergeIndex
    /// The commented cells of each row.
    private let commentedCells: [Int: [CellAddress]]
    /// `Worksheet.isAuthoredDark`, which samples thousands of cells.
    public let isAuthoredDark: Bool

    public init(_ sheet: Worksheet) {
        merges = MergeIndex(sheet.mergedRanges)
        var commented: [Int: [CellAddress]] = [:]
        for address in sheet.comments.keys { commented[address.row, default: []].append(address) }
        commentedCells = commented
        isAuthoredDark = sheet.isAuthoredDark
    }

    /// `Worksheet.colorScheme(for:)`, without sampling the cells again.
    public func colorScheme(for viewer: ColorScheme) -> ColorScheme {
        viewer == .dark && isAuthoredDark ? .light : viewer
    }

    /// The commented cells in `rows`.
    func commentedCells(in rows: Range<Int>) -> [CellAddress] {
        // Fewer rows with comments than rows asked about: read those instead.
        if commentedCells.count < rows.count {
            return commentedCells.filter { rows.contains($0.key) }.flatMap(\.value)
        }
        return rows.flatMap { commentedCells[$0] ?? [] }
    }
}

/// The parts of a sheet its cells are drawn from: their contents, styles and
/// conditional styles, the styles of whole rows and columns, merges, comments,
/// hidden lines, size and page colour.
///
/// Two keys are equal when the sheet would draw the same, so a key kept from
/// the last frame tells whether anything drawn from the sheet is still good.
/// That covers every edit, undo and redo, whichever way it reached the
/// sheet, with no revision number to keep in step. Comparing is cheap: the
/// parts of a sheet that did not change still share their storage with the
/// key's, and collections sharing storage compare equal without being walked.
///
/// Line sizes and zoom are not part of it: they are in `SheetMetrics`.
public struct SheetDrawingKey: Equatable, Sendable {
    private let id: Worksheet.ID
    private let cells: [CellAddress: Cell]
    private let conditionalStyles: [CellAddress: ConditionalStyle]
    private let mergedRanges: [CellRange]
    private let comments: [CellAddress: CellComment]
    private let hiddenRows: Set<Int>
    private let hiddenColumns: Set<Int>
    private let columnStyles: [Int: CellStyle]
    private let rowStyles: [Int: CellStyle]
    private let rowCount: Int
    private let columnCount: Int
    private let backgroundColorHex: String?
    private let autoFilter: AutoFilter?

    public init(_ sheet: Worksheet) {
        autoFilter = sheet.autoFilter
        id = sheet.id
        cells = sheet.cells
        conditionalStyles = sheet.conditionalStyles
        mergedRanges = sheet.mergedRanges
        comments = sheet.comments
        hiddenRows = sheet.hiddenRows
        hiddenColumns = sheet.hiddenColumns
        columnStyles = sheet.columnStyles
        rowStyles = sheet.rowStyles
        rowCount = sheet.rowCount
        columnCount = sheet.columnCount
        backgroundColorHex = sheet.backgroundColorHex
    }
}

/// Keeps each sheet's `SheetLookup` from one draw to the next, building a
/// new one only once the sheet has changed.
///
/// Holds on to the sheets it last saw, so it belongs to whatever draws them
/// and goes away with it.
public final class SheetLookupCache {
    private var entries: [Worksheet.ID: (key: SheetDrawingKey, lookup: SheetLookup)] = [:]

    public init() {}

    public func lookup(for sheet: Worksheet) -> SheetLookup {
        let key = SheetDrawingKey(sheet)
        if let entry = entries[sheet.id], entry.key == key { return entry.lookup }
        let lookup = SheetLookup(sheet)
        // Sheets come and go with the workbook; there are never many.
        if entries.count >= 32 { entries.removeAll() }
        entries[sheet.id] = (key, lookup)
        return lookup
    }
}

extension Worksheet {
    /// `commentMarks(rows:columns:)`, finding the comments and merges through
    /// a lookup built from this version of the sheet rather than walking them.
    public func commentMarks(
        rows: Range<Int>, columns: Range<Int>, lookup: SheetLookup
    ) -> [(address: CellAddress, comment: CellComment, range: CellRange)] {
        commentMarks(at: lookup.commentedCells(in: rows), columns: columns, merges: lookup.merges.range(containing:))
    }
}
