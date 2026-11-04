import Foundation

/// A formula parsed once and moved from cell to cell as filling it would,
/// for when the same formula is wanted at a great many cells: parsing it
/// afresh for each is most of the cost of evaluating it.
///
/// A parsed reference no longer knows which of its parts were anchored with
/// `$`. Those are read off a second parse, of the formula filled one row down
/// and one column right: whatever moved between the two is relative. That
/// leaves `FormulaReferenceShifter` the one authority on what a fill moves.
struct FormulaFill {
    private let origin: FormulaNode
    private let probe: FormulaNode

    /// `probe` is `origin` filled one row down and one column right. Nil when
    /// the two differ in anything but where their references point.
    init?(origin: FormulaNode, probe: FormulaNode) {
        self.origin = origin
        self.probe = probe
        guard node(rowDelta: 0, columnDelta: 0) != nil else { return nil }
    }

    /// The formula as filled by these distances, exactly as parsing the filled
    /// text would give it. Nil where a reference lands somewhere it can't be
    /// worked out here, for the caller to go by way of the text.
    func node(rowDelta: Int, columnDelta: Int) -> FormulaNode? {
        Self.moved(origin, probe, rowDelta, columnDelta)
    }

    private static func moved(_ node: FormulaNode, _ probe: FormulaNode, _ rows: Int, _ columns: Int) -> FormulaNode? {
        func point(_ from: CellAddress, _ to: CellAddress) -> CellAddress? {
            let rowStep = to.row - from.row, columnStep = to.column - from.column
            guard (0...1).contains(rowStep), (0...1).contains(columnStep) else { return nil }
            let row = from.row + rowStep * rows, column = from.column + columnStep * columns
            guard row <= SheetLimits.maxRow, column <= SheetLimits.maxColumn else { return nil }
            return CellAddress(row: row, column: column)
        }
        /// A range's ends can pass one another, `$A1:A$5` filled far enough
        /// down, and parsing the text would put them back in order.
        func span(
            _ start: CellAddress, _ end: CellAddress, _ probeStart: CellAddress, _ probeEnd: CellAddress
        ) -> (start: CellAddress, end: CellAddress)? {
            guard let first = point(start, probeStart), let last = point(end, probeEnd),
                  first.row <= last.row, first.column <= last.column else { return nil }
            return (first, last)
        }
        func one(_ node: FormulaNode, _ probe: FormulaNode) -> FormulaNode? { moved(node, probe, rows, columns) }
        func all(_ nodes: [FormulaNode], _ probes: [FormulaNode]) -> [FormulaNode]? {
            guard nodes.count == probes.count else { return nil }
            var result: [FormulaNode] = []
            result.reserveCapacity(nodes.count)
            for (node, probe) in zip(nodes, probes) {
                guard let moved = one(node, probe) else { return nil }
                result.append(moved)
            }
            return result
        }

        switch (node, probe) {
        case let (.reference(sheet, address), .reference(probeSheet, probeAddress)) where sheet == probeSheet:
            return point(address, probeAddress).map { .reference(sheet: sheet, address: $0) }
        case let (.range(sheet, start, end), .range(probeSheet, probeStart, probeEnd)) where sheet == probeSheet:
            return span(start, end, probeStart, probeEnd).map { .range(sheet: sheet, start: $0.start, end: $0.end) }
        case let (.sheetSpan(first, last, start, end), .sheetSpan(probeFirst, probeLast, probeStart, probeEnd))
            where first == probeFirst && last == probeLast:
            return span(start, end, probeStart, probeEnd).map {
                .sheetSpan(first: first, last: last, start: $0.start, end: $0.end)
            }
        case let (.unary(symbol, operand), .unary(probeSymbol, probeOperand)) where symbol == probeSymbol:
            return one(operand, probeOperand).map { .unary(symbol, $0) }
        case let (.binary(symbol, lhs, rhs), .binary(probeSymbol, probeLHS, probeRHS)) where symbol == probeSymbol:
            guard let left = one(lhs, probeLHS), let right = one(rhs, probeRHS) else { return nil }
            return .binary(symbol, left, right)
        case let (.postfixPercent(operand), .postfixPercent(probeOperand)):
            return one(operand, probeOperand).map { .postfixPercent($0) }
        case let (.call(name, arguments), .call(probeName, probeArguments)) where name == probeName:
            return all(arguments, probeArguments).map { .call(name, $0) }
        case let (.invoke(target, arguments), .invoke(probeTarget, probeArguments)):
            guard let moved = one(target, probeTarget), let list = all(arguments, probeArguments) else { return nil }
            return .invoke(moved, list)
        case let (.array(rows), .array(probeRows)):
            guard rows.count == probeRows.count else { return nil }
            var result: [[FormulaNode]] = []
            for (row, probeRow) in zip(rows, probeRows) {
                guard let moved = all(row, probeRow) else { return nil }
                result.append(moved)
            }
            return .array(result)
        case let (.intersect(operand), .intersect(probeOperand)):
            return one(operand, probeOperand).map { .intersect($0) }
        case let (.spill(operand), .spill(probeOperand)):
            return one(operand, probeOperand).map { .spill($0) }
        case let (.union(parts), .union(probeParts)):
            return all(parts, probeParts).map { .union($0) }
        default:
            // Literals, names and the like: a fill leaves them as they are.
            return node == probe ? node : nil
        }
    }
}
