/// How the rows or the columns of a sheet are grouped — Excel's outline.
///
/// Each line has an outline level, zero for none. A group is a run of
/// neighbouring lines at one level or deeper, and its button sits on the
/// summary line just past it (or just before it, when the sheet puts
/// summaries first). A collapsed group's lines are hidden, and its summary
/// line carries the collapsed mark, which is what the file keeps.
public struct LineOutline: Hashable, Sendable {
    /// Excel allows eight levels in all: none and seven of grouping.
    public static let deepestLevel = 7

    /// Outline levels by line, leaving out lines at level zero.
    public var levels: [Int: Int] = [:]
    /// Summary lines whose group is collapsed.
    public var collapsed: Set<Int> = []
    /// Whether a group's summary line comes after it, as by default, or
    /// before it. OOXML's `summaryBelow` for rows and `summaryRight` for columns.
    public var summaryAfter = true

    public init() {}

    public var isEmpty: Bool { levels.isEmpty }

    /// How deep the deepest group goes, zero when nothing is grouped.
    public var maximumLevel: Int { levels.values.max() ?? 0 }

    public func level(of line: Int) -> Int { levels[line] ?? 0 }

    public mutating func setLevel(_ level: Int, of line: Int) {
        let level = min(max(0, level), Self.deepestLevel)
        levels[line] = level == 0 ? nil : level
    }

    public struct Group: Hashable, Sendable {
        public var lines: ClosedRange<Int>
        public var level: Int
        /// Where the group's button sits. It may lie outside the sheet, before
        /// the first line or past the last.
        public var summary: Int
    }

    public func summary(of lines: ClosedRange<Int>) -> Int {
        summaryAfter ? lines.upperBound + 1 : lines.lowerBound - 1
    }

    /// Every group, shallowest first and in line order within a level.
    public func groups() -> [Group] {
        guard !levels.isEmpty else { return [] }
        let sorted = levels.sorted { $0.key < $1.key }
        var result: [Group] = []
        for level in 1...maximumLevel {
            var run: ClosedRange<Int>?
            for (line, lineLevel) in sorted where lineLevel >= level {
                if let current = run, current.upperBound + 1 == line {
                    run = current.lowerBound...line
                } else {
                    if let current = run { result.append(Group(lines: current, level: level, summary: summary(of: current))) }
                    run = line...line
                }
            }
            if let current = run { result.append(Group(lines: current, level: level, summary: summary(of: current))) }
        }
        return result
    }

    /// Keeps only the collapsed marks that sit on a group's summary line.
    mutating func pruneCollapsed() {
        guard !collapsed.isEmpty else { return }
        let summaries = Set(groups().map(\.summary))
        collapsed = collapsed.filter { summaries.contains($0) }
    }

    // MARK: - Structural edits

    mutating func insert(_ count: Int, at index: Int) {
        // Lines inserted inside a group join it, as in Excel: they take the
        // level of the line before them when the line after shares it.
        let joined = index > 0 ? min(level(of: index - 1), level(of: index)) : 0
        var moved: [Int: Int] = [:]
        for (line, level) in levels { moved[line >= index ? line + count : line] = level }
        if joined > 0 { for line in index..<(index + count) { moved[line] = joined } }
        levels = moved
        collapsed = Set(collapsed.map { $0 >= index ? $0 + count : $0 })
    }

    mutating func remove(_ range: ClosedRange<Int>) {
        let count = range.count
        var moved: [Int: Int] = [:]
        for (line, level) in levels where !range.contains(line) {
            moved[line > range.upperBound ? line - count : line] = level
        }
        levels = moved
        collapsed = Set(collapsed.filter { !range.contains($0) }.map { $0 > range.upperBound ? $0 - count : $0 })
    }
}

/// The two outlines a sheet has.
public enum OutlineAxis: Sendable {
    case row, column
}

extension Worksheet {
    private static func outlinePath(_ axis: OutlineAxis) -> WritableKeyPath<Worksheet, LineOutline> {
        axis == .row ? \.rowOutline : \.columnOutline
    }

    private static func hiddenPath(_ axis: OutlineAxis) -> WritableKeyPath<Worksheet, Set<Int>> {
        axis == .row ? \.hiddenRows : \.hiddenColumns
    }

    public func outline(_ axis: OutlineAxis) -> LineOutline {
        self[keyPath: Self.outlinePath(axis)]
    }

    /// Whether a group's lines are folded away: its summary line says so, or
    /// every line of it is hidden.
    public func isCollapsed(_ group: LineOutline.Group, axis: OutlineAxis) -> Bool {
        let hidden = self[keyPath: Self.hiddenPath(axis)]
        return outline(axis).collapsed.contains(group.summary) || group.lines.allSatisfy { hidden.contains($0) }
    }

    /// Hides a group's lines and marks its summary line collapsed.
    public mutating func collapse(_ group: LineOutline.Group, axis: OutlineAxis) {
        self[keyPath: Self.hiddenPath(axis)].formUnion(group.lines)
        self[keyPath: Self.outlinePath(axis)].collapsed.insert(group.summary)
    }

    /// Shows a group's lines again, leaving groups inside it that are
    /// collapsed of their own folded, as Excel does.
    public mutating func expand(_ group: LineOutline.Group, axis: OutlineAxis) {
        self[keyPath: Self.outlinePath(axis)].collapsed.remove(group.summary)
        reveal(group.lines, level: group.level, axis: axis)
    }

    private mutating func reveal(_ lines: ClosedRange<Int>, level: Int, axis: OutlineAxis) {
        let outline = outline(axis)
        var line = lines.lowerBound
        while line <= lines.upperBound {
            guard outline.level(of: line) > level else {
                self[keyPath: Self.hiddenPath(axis)].remove(line)
                line += 1
                continue
            }
            var end = line
            while end + 1 <= lines.upperBound, outline.level(of: end + 1) > level { end += 1 }
            let inner = line...end
            if !outline.collapsed.contains(outline.summary(of: inner)) {
                reveal(inner, level: level + 1, axis: axis)
            }
            line = end + 1
        }
    }

    /// Collapses or expands every group so that only lines above `level`
    /// show — the numbered buttons beside Excel's outline: 1 leaves only
    /// the ungrouped lines, one past the deepest level shows everything.
    public mutating func showOutlineLevels(_ level: Int, axis: OutlineAxis) {
        for group in outline(axis).groups().reversed() {
            if group.level >= level {
                collapse(group, axis: axis)
            } else {
                expand(group, axis: axis)
            }
        }
    }

    /// Puts the lines one level deeper into the outline.
    public mutating func group(_ lines: ClosedRange<Int>, axis: OutlineAxis) {
        var outline = outline(axis)
        for line in lines { outline.setLevel(outline.level(of: line) + 1, of: line) }
        outline.pruneCollapsed()
        self[keyPath: Self.outlinePath(axis)] = outline
    }

    /// Takes the lines one level out of the outline. A collapsed group they
    /// leave is expanded first, so that nothing stays hidden without a button
    /// to show it again.
    public mutating func ungroup(_ lines: ClosedRange<Int>, axis: OutlineAxis) {
        for group in outline(axis).groups() where group.lines.overlaps(lines) && isCollapsed(group, axis: axis) {
            let level = group.lines.clamped(to: lines).map { outline(axis).level(of: $0) }.max() ?? 0
            if level == group.level { expand(group, axis: axis) }
        }
        var outline = outline(axis)
        for line in lines { outline.setLevel(outline.level(of: line) - 1, of: line) }
        outline.pruneCollapsed()
        self[keyPath: Self.outlinePath(axis)] = outline
    }
}
