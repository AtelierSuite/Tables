import Foundation

/// Where a sheet's rows and columns were in the file it came from, for a file
/// saved by patching it — a Numbers document — where everything Tables
/// doesn't read about a cell has to follow it as rows and columns are
/// inserted and deleted.
public struct SheetOrigins: Hashable, Sendable {
    /// Each row's index in the file, or nil for one inserted since. Nil
    /// while no row has moved, when rows past the file's last are new.
    public private(set) var rows: [Int?]?
    public private(set) var columns: [Int?]?

    public var hasMoved: Bool { rows != nil || columns != nil }

    public func row(_ index: Int) -> Int? {
        rows.map { index < $0.count ? $0[index] : nil } ?? index
    }

    public func column(_ index: Int) -> Int? {
        columns.map { index < $0.count ? $0[index] : nil } ?? index
    }

    public mutating func insertRows(_ count: Int, at index: Int, rowCount: Int) {
        Self.insert(count, at: index, into: &rows, total: rowCount)
    }

    public mutating func insertColumns(_ count: Int, at index: Int, columnCount: Int) {
        Self.insert(count, at: index, into: &columns, total: columnCount)
    }

    public mutating func removeRows(_ range: ClosedRange<Int>, rowCount: Int) {
        Self.remove(range, from: &rows, total: rowCount)
    }

    public mutating func removeColumns(_ range: ClosedRange<Int>, columnCount: Int) {
        Self.remove(range, from: &columns, total: columnCount)
    }

    /// Rows added at the end, which are new wherever the rest have moved.
    public mutating func appendRows(_ count: Int) {
        rows?.append(contentsOf: [Int?](repeating: nil, count: count))
    }

    public mutating func appendColumns(_ count: Int) {
        columns?.append(contentsOf: [Int?](repeating: nil, count: count))
    }

    private static func insert(_ count: Int, at index: Int, into origins: inout [Int?]?, total: Int) {
        var list = origins ?? (0..<total).map { $0 }
        list.insert(contentsOf: [Int?](repeating: nil, count: count), at: min(index, list.count))
        origins = list
    }

    private static func remove(_ range: ClosedRange<Int>, from origins: inout [Int?]?, total: Int) {
        var list = origins ?? (0..<total).map { $0 }
        list.removeSubrange(range.clamped(to: 0...max(0, list.count - 1)))
        origins = list
    }
}
