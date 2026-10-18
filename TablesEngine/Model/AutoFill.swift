import Foundation

/// Dragging a selection's fill handle, as Excel and Numbers do it: the
/// selected cells are carried on into the cells dragged over, continuing
/// whatever series they make.
///
/// Each row or column along the drag is filled on its own. Two or more
/// numbers continue their trend; a day or month name, or text ending in a
/// number, counts on; a lone date steps a day at a time. Everything else —
/// text, a lone number, formulas — repeats, with a formula's relative
/// references moving as it goes, as a paste would move them.
public enum AutoFill {
    /// The way the handle was dragged, away from the source cells.
    public enum Direction: Sendable {
        case down, up, right, left

        var isVertical: Bool { self == .down || self == .up }
        var isForward: Bool { self == .down || self == .right }
    }

    /// The range a drag of the handle to `point` would fill: the source
    /// grown along whichever axis the point is further out on, or, dragged
    /// back inside, the part of it that stays.
    public static func target(extending source: CellRange, toward point: CellAddress) -> CellRange {
        let box = source.normalized
        let below = point.row - box.end.row
        let above = box.start.row - point.row
        let after = point.column - box.end.column
        let before = box.start.column - point.column
        let vertical = max(below, above)
        let horizontal = max(after, before)

        if vertical <= 0, horizontal <= 0 {
            // Back inside the selection: Excel shrinks the fill to clear the rest.
            let rows = box.end.row - box.start.row
            let columns = box.end.column - box.start.column
            if rows >= columns, rows > 0 {
                return CellRange(start: box.start, end: CellAddress(row: max(box.start.row, point.row), column: box.end.column))
            }
            if columns > 0 {
                return CellRange(start: box.start, end: CellAddress(row: box.end.row, column: max(box.start.column, point.column)))
            }
            return box
        }
        if vertical >= horizontal {
            return below > 0
                ? CellRange(start: box.start, end: CellAddress(row: point.row, column: box.end.column))
                : CellRange(start: CellAddress(row: point.row, column: box.start.column), end: box.end)
        }
        return after > 0
            ? CellRange(start: box.start, end: CellAddress(row: box.end.row, column: point.column))
            : CellRange(start: CellAddress(row: box.start.row, column: point.column), end: box.end)
    }

    /// The direction `target` lies in from `source`, or nil when it adds nothing.
    public static func direction(from source: CellRange, to target: CellRange) -> Direction? {
        let box = source.normalized
        let grown = target.normalized
        if grown.end.row > box.end.row { return .down }
        if grown.start.row < box.start.row { return .up }
        if grown.end.column > box.end.column { return .right }
        if grown.start.column < box.start.column { return .left }
        return nil
    }

    // MARK: - Series

    /// The cell `offset` steps along from the start of a lane of source
    /// cells: past its end going forward, before its start (negative) going back.
    static func cell(at offset: Int, in lane: [Cell], series: Series?, isVertical: Bool) -> Cell {
        let count = lane.count
        let position = ((offset % count) + count) % count
        var cell = lane[position]
        cell.isSpilled = false
        cell.arrayExtent = nil
        cell.savedResultInputs = nil

        if let series {
            cell.value = series.value(at: offset)
            cell.formula = nil
        } else if let formula = cell.formula {
            let delta = offset - position
            cell.formula = FormulaReferenceShifter.translated(
                formula, rowDelta: isVertical ? delta : 0, columnDelta: isVertical ? 0 : delta)
        }
        return cell
    }

    /// What a lane of source cells counts in, when it counts at all.
    enum Series {
        /// A straight-line trend through two or more numbers.
        case trend(intercept: Double, slope: Double)
        /// One date, stepping a day at a time.
        case days(start: Double)
        /// Names from a list that wraps, such as the days of the week.
        case list(names: [String], first: Int, step: Int)
        /// Text around a number that counts on, like "Week 1".
        case numbered(prefix: String, suffix: String, first: Int, step: Int, width: Int)

        init?(_ lane: [Cell]) {
            guard !lane.isEmpty, lane.allSatisfy({ $0.formula == nil }) else { return nil }

            let numbers = lane.compactMap { cell -> Double? in
                if case .number(let number) = cell.value { return number }
                return nil
            }
            if numbers.count == lane.count {
                if numbers.count == 1 {
                    guard CellFormatter.isDateFormat(lane[0].style.numberFormat) else { return nil }
                    self = .days(start: numbers[0])
                    return
                }
                self = Self.fitted(numbers)
                return
            }

            let texts = lane.compactMap { cell -> String? in
                if case .text(let text) = cell.value { return text }
                return nil
            }
            guard texts.count == lane.count else { return nil }

            if let list = Self.namedLists.first(where: { list in texts.allSatisfy { list.index(of: $0) != nil } }) {
                let indices = texts.compactMap { list.index(of: $0) }
                guard let step = Self.commonStep(indices) else { return nil }
                self = .list(names: list.names(styledLike: texts[0]), first: indices[0], step: step)
                return
            }

            let parts = texts.compactMap(Self.numberedParts)
            guard parts.count == texts.count,
                  let first = parts.first,
                  parts.allSatisfy({ $0.prefix == first.prefix && $0.suffix == first.suffix }),
                  let step = parts.count == 1 ? 1 : Self.commonStep(parts.map(\.number))
            else { return nil }
            self = .numbered(prefix: first.prefix, suffix: first.suffix, first: first.number, step: step, width: first.width)
        }

        func value(at offset: Int) -> CellValue {
            switch self {
            case .trend(let intercept, let slope):
                return .number(Self.tidied(intercept + slope * Double(offset)))
            case .days(let start):
                return .number(start + Double(offset))
            case .list(let names, let first, let step):
                let count = names.count
                return .text(names[(((first + step * offset) % count) + count) % count])
            case .numbered(let prefix, let suffix, let first, let step, let width):
                let number = first + step * offset
                // Counted back past zero, Excel counts up again rather than
                // writing "Week -1", and so do we.
                let magnitude = String(abs(number))
                let padded = String(repeating: "0", count: max(0, width - magnitude.count)) + magnitude
                return .text(prefix + padded + suffix)
            }
        }

        /// The least-squares line through the numbers at 0, 1, 2…, which is
        /// what Excel continues — exact for an even series, a trend otherwise.
        private static func fitted(_ numbers: [Double]) -> Series {
            let count = Double(numbers.count)
            let meanX = (count - 1) / 2
            let meanY = numbers.reduce(0, +) / count
            var covariance = 0.0
            var variance = 0.0
            for (index, number) in numbers.enumerated() {
                let dx = Double(index) - meanX
                covariance += dx * (number - meanY)
                variance += dx * dx
            }
            let slope = covariance / variance
            return .trend(intercept: meanY - slope * meanX, slope: slope)
        }

        /// Rounds off the noise a fitted line leaves, so 0.1, 0.2 goes on to
        /// 0.3 and not 0.30000000000000004.
        private static func tidied(_ value: Double) -> Double {
            let rounded = (value * 1e10).rounded() / 1e10
            return abs(rounded - value) < 1e-9 ? rounded : value
        }

        /// The one difference between each neighbour and the next, if there is one.
        private static func commonStep(_ values: [Int]) -> Int? {
            guard values.count > 1 else { return 1 }
            let step = values[1] - values[0]
            for index in 1..<values.count where values[index] - values[index - 1] != step { return nil }
            return step
        }

        /// Text split around the last run of digits in it.
        private static func numberedParts(_ text: String) -> (prefix: String, number: Int, suffix: String, width: Int)? {
            let characters = Array(text)
            guard let last = characters.lastIndex(where: \.isASCIIDigit) else { return nil }
            var first = last
            while first > 0, characters[first - 1].isASCIIDigit { first -= 1 }
            let digits = String(characters[first...last])
            guard digits.count <= 15, let number = Int(digits) else { return nil }
            return (String(characters[..<first]), number, String(characters[(last + 1)...]), digits.count)
        }

        /// The lists Excel ships with, in English and in the user's own language.
        static let namedLists: [NamedList] = {
            var lists: [NamedList] = []
            for identifier in ["en_US", Locale.current.identifier] {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: identifier)
                for symbols in [
                    formatter.weekdaySymbols, formatter.shortWeekdaySymbols,
                    formatter.monthSymbols, formatter.shortMonthSymbols,
                ] {
                    guard let symbols, !symbols.isEmpty else { continue }
                    let list = NamedList(names: symbols)
                    if !lists.contains(list) { lists.append(list) }
                }
            }
            return lists
        }()
    }

    /// A list of names that counts on from one to the next and wraps.
    struct NamedList: Equatable {
        var names: [String]

        func index(of text: String) -> Int? {
            names.firstIndex { $0.compare(text, options: .caseInsensitive) == .orderedSame }
        }

        /// The names written the way the first source cell writes its own.
        func names(styledLike sample: String) -> [String] {
            if sample == sample.uppercased(), sample != sample.lowercased() { return names.map { $0.uppercased() } }
            if sample == sample.lowercased(), sample != sample.uppercased() { return names.map { $0.lowercased() } }
            return names
        }
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

extension Worksheet {
    /// Fills `target` from the cells of `source` inside it, as dragging the
    /// fill handle does. A target smaller than the source clears the cells
    /// it left behind instead. Gives up on sources holding merged cells,
    /// which have no single shape to repeat.
    @discardableResult
    public mutating func autoFill(from source: CellRange, to target: CellRange) -> Bool {
        let box = source.normalized
        let grown = target.normalized
        guard !mergedRanges.contains(where: { $0.intersects(box) || $0.intersects(grown) }) else { return false }

        if box.contains(grown.start), box.contains(grown.end) {
            box.forEachAddress { address in
                guard !grown.contains(address) else { return }
                self[address] = Cell(style: self[address].style)
            }
            return grown != box
        }
        guard let direction = AutoFill.direction(from: box, to: grown) else { return false }

        let lanes = direction.isVertical ? box.columnRange : box.rowRange
        let along = direction.isVertical ? box.rowRange : box.columnRange
        let filled = direction.isVertical
            ? (direction.isForward ? (box.end.row + 1)...grown.end.row : grown.start.row...(box.start.row - 1))
            : (direction.isForward ? (box.end.column + 1)...grown.end.column : grown.start.column...(box.start.column - 1))

        for lane in lanes {
            let cells = along.map { position in
                self[direction.isVertical
                     ? CellAddress(row: position, column: lane)
                     : CellAddress(row: lane, column: position)]
            }
            let series = AutoFill.Series(cells)
            for position in filled {
                let address = direction.isVertical
                    ? CellAddress(row: position, column: lane)
                    : CellAddress(row: lane, column: position)
                guard contains(address) else { continue }
                self[address] = AutoFill.cell(
                    at: position - along.lowerBound, in: cells, series: series, isVertical: direction.isVertical)
            }
        }
        return true
    }
}
