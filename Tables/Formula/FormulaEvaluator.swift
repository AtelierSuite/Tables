import Foundation

/// A rectangle of cells on one sheet, as a formula names it before anything is
/// read out of it. Functions such as `OFFSET`, `ROWS` and `SUBTOTAL` work on
/// this rather than on the values, which is why references stay unresolved
/// until something asks for their contents.
struct FormulaReference: Hashable, Sendable {
    /// `nil` means the sheet the formula is evaluated on.
    var sheet: String?
    var range: CellRange

    init(sheet: String?, range: CellRange) {
        self.sheet = sheet
        self.range = range.normalized
    }

    init(sheet: String?, address: CellAddress) {
        self.init(sheet: sheet, range: CellRange(address))
    }

    var rowCount: Int { range.rowRange.count }
    var columnCount: Int { range.columnRange.count }
}

/// A LAMBDA, with the LET and LAMBDA names it could see where it was written.
struct FormulaLambda: Hashable, Sendable {
    /// Lowercased, as names match without regard to case.
    var parameters: [String]
    var body: FormulaNode
    var captured: [String: FormulaBinding]
}

/// What a LET or LAMBDA name stands for.
struct FormulaBinding: Hashable, Sendable {
    var value: FormulaValue
    /// Set when the name was bound to a reference, so `ROWS(r)` still sees one.
    var reference: FormulaReference?
    /// A LAMBDA parameter the caller left out, for `ISOMITTED`.
    var isOmitted = false
}

/// A value flowing through evaluation. Ranges stay rectangular so lookup
/// functions can index them by row and column.
enum FormulaValue: Hashable, Sendable {
    case scalar(CellValue)
    case matrix([[CellValue]])
    case lambda(FormulaLambda)

    var flattened: [CellValue] {
        switch self {
        case .scalar(let value): return [value]
        case .matrix(let rows): return rows.flatMap { $0 }
        case .lambda: return [.error(.calc)]
        }
    }

    /// Collapses a range to a single value, as an operator would.
    var single: CellValue {
        switch self {
        case .scalar(let value): return value
        case .matrix(let rows): return rows.first?.first ?? .empty
        case .lambda: return .error(.calc)
        }
    }

    var firstError: CellError? {
        flattened.compactMap(\.errorValue).first
    }

    /// The value as rows of cells; a scalar is a 1×1 block.
    var rows: [[CellValue]] {
        switch self {
        case .scalar(let value): return [[value]]
        case .matrix(let rows): return rows
        case .lambda: return [[.error(.calc)]]
        }
    }

    var rowCount: Int { rows.count }
    var columnCount: Int { rows.first?.count ?? 0 }

    /// A 1×1 matrix is a plain value; anything larger stays a matrix.
    static func block(_ rows: [[CellValue]]) -> FormulaValue {
        guard let first = rows.first, !first.isEmpty else { return .failure(.calc) }
        if rows.count == 1, first.count == 1 { return .scalar(first[0]) }
        return .matrix(rows)
    }

    static func number(_ value: Double) -> FormulaValue {
        value.isFinite ? .scalar(.number(value)) : .failure(.numberError)
    }
    static func text(_ value: String) -> FormulaValue { .scalar(.text(value)) }
    static func boolean(_ value: Bool) -> FormulaValue { .scalar(.boolean(value)) }
    static func failure(_ error: CellError) -> FormulaValue { .scalar(.error(error)) }
}

/// Read access to a workbook for the evaluator, plus recursion tracking.
protocol FormulaContext: AnyObject {
    /// The sheet a formula without an explicit sheet qualifier refers to.
    var currentSheetName: String { get }
    /// The already-evaluated value of a cell, computing it on demand.
    func value(at address: CellAddress, sheetName: String?) -> CellValue
    /// The extent of a sheet, so open-ended ranges can be clamped.
    func bounds(forSheetNamed name: String?) -> (rows: Int, columns: Int)?
    /// The value a defined name stands for, or `nil` when the workbook declares
    /// no such name so the caller can report `#NAME?`. A name standing for a
    /// range answers with the whole matrix, which is what makes `SUM(Sales)`
    /// behave like `SUM(Sheet1!$A$2:$A$10)`.
    func resolveDefinedName(_ name: String, sheetName: String?) -> FormulaValue?
    /// The reference a defined name stands for, when it stands for one.
    func definedNameReference(_ name: String, sheetName: String?) -> FormulaReference?
    func sheetNames(from first: String, to last: String) -> [String]?
    /// The stored cell, formula and style included, for functions that look
    /// past the value: `FORMULATEXT`, `ISFORMULA`, `CELL`.
    func cell(at address: CellAddress, sheetName: String?) -> Cell?
    /// Whether a row is hidden, for `SUBTOTAL` and `AGGREGATE`.
    func isRowHidden(_ row: Int, sheetName: String?) -> Bool
    /// The one-based position of a sheet in the workbook, for `SHEET`.
    func sheetNumber(named name: String?) -> Int?
    var sheetCount: Int { get }
    /// The range the formula in `address` spilled into, for `A1#`.
    func spillRange(anchoredAt address: CellAddress, sheetName: String?) -> CellRange?
    /// A column's width in characters of the default font, for `CELL("width")`.
    func columnWidth(_ column: Int, sheetName: String?) -> Double?
    /// The cells a structured reference names. A nil table means the table
    /// holding the formula's own cell.
    func structuredReference(table: String?, specifier: String, at address: CellAddress?) -> FormulaReference?
    /// The header and footer rows and header columns a whole column or row
    /// of the sheet leaves out, for a table read from Numbers.
    func tableEdges(forSheetNamed name: String?) -> TableEdges?
}

extension FormulaContext {
    /// A context with no workbook behind it has no names to resolve.
    func resolveDefinedName(_ name: String, sheetName: String?) -> FormulaValue? { nil }
    func definedNameReference(_: String, sheetName _: String?) -> FormulaReference? { nil }

    /// The sheets a 3-D reference spans, in tab order, or nil when either end
    /// does not exist.
    func sheetNames(from _: String, to _: String) -> [String]? { nil }
    func cell(at _: CellAddress, sheetName _: String?) -> Cell? { nil }
    func isRowHidden(_: Int, sheetName _: String?) -> Bool { false }
    func sheetNumber(named name: String?) -> Int? { name == nil ? 1 : nil }
    var sheetCount: Int { 1 }
    func spillRange(anchoredAt _: CellAddress, sheetName _: String?) -> CellRange? { nil }
    func columnWidth(_: Int, sheetName _: String?) -> Double? { nil }
    func structuredReference(table _: String?, specifier _: String, at _: CellAddress?) -> FormulaReference? { nil }
    func tableEdges(forSheetNamed _: String?) -> TableEdges? { nil }
}

struct FormulaEvaluator {
    /// How deeply LAMBDAs may call one another before the chain is cut off.
    static let maximumLambdaDepth = 128

    let context: any FormulaContext
    /// The cell whose formula is being evaluated, so `ROW()` and `COLUMN()` can
    /// report their own position when called without a reference. `nil` when the
    /// caller evaluates an expression that belongs to no particular cell.
    var currentAddress: CellAddress? = nil
    /// LET and LAMBDA names in effect, lowercased.
    var scope: [String: FormulaBinding] = [:]
    var lambdaDepth = 0

    init(context: any FormulaContext, currentAddress: CellAddress? = nil) {
        self.context = context
        self.currentAddress = currentAddress
    }

    /// A copy that also sees `bindings`.
    func binding(_ bindings: [String: FormulaBinding]) -> FormulaEvaluator {
        var copy = self
        copy.scope.merge(bindings) { _, new in new }
        return copy
    }

    func evaluate(_ node: FormulaNode) -> FormulaValue {
        switch node {
        case .number(let value):
            return .number(value)
        case .text(let value):
            return .text(value)
        case .boolean(let value):
            return .boolean(value)
        case .errorLiteral(let error):
            return .failure(error)
        case .missing:
            return .scalar(.empty)

        case .reference(let sheet, let address):
            return .scalar(context.value(at: address, sheetName: sheet))

        case .range(let sheet, let start, let end):
            let range = bodyRange(sheet: sheet, CellRange(start: start, end: end))
            return matrix(sheet: sheet, start: range.start, end: range.end)

        case .sheetSpan(let first, let last, let start, let end):
            guard let sheets = context.sheetNames(from: first, to: last) else { return .failure(.referenceError) }
            var rows: [[CellValue]] = []
            for sheet in sheets {
                guard case .matrix(let block) = matrix(sheet: sheet, start: start, end: end) else {
                    rows += [[context.value(at: start, sheetName: sheet)]]
                    continue
                }
                rows += block
            }
            return rows.isEmpty ? .failure(.referenceError) : .block(rows)

        case .unary(let symbol, let operand):
            return FormulaValue.lift([evaluate(operand)]) { values in
                let value = values[0]
                if let error = value.errorValue { return .error(error) }
                guard symbol == "-" else { return value }
                guard let number = try? value.coercedNumber() else { return .error(.valueError) }
                return .number(-number)
            }

        case .postfixPercent(let operand):
            return FormulaValue.lift([evaluate(operand)]) { values in
                guard let number = try? values[0].coercedNumber() else {
                    return .error(values[0].errorValue ?? .valueError)
                }
                return .number(number / 100)
            }

        case .intersect(let operand):
            // A range out of line with the formula has nothing to give.
            guard let whole = reference(operand) else { return .scalar(evaluate(operand).single) }
            guard let cell = intersection(of: whole) else { return .failure(.valueError) }
            return materialize(cell)

        case .binary(":", _, _), .spill, .structured:
            guard let reference = reference(node) else { return .failure(.referenceError) }
            return materialize(reference)

        case .binary(" ", _, _):
            // References that do not overlap have nothing in common.
            guard let reference = reference(node) else { return .failure(.nullError) }
            return materialize(reference)

        case .union:
            guard let areas = areas(node) else { return .failure(.valueError) }
            if areas.count == 1 { return materialize(areas[0]) }
            // Several areas read as one run of values, which is how the
            // functions that accept unions use them.
            return .block([areas.flatMap { materialize($0).flattened }])

        case .binary(let symbol, let lhs, let rhs):
            return FormulaValue.lift([evaluate(lhs), evaluate(rhs)]) { values in
                FormulaOperators.apply(symbol, values[0], values[1])
            }

        case .array(let rows):
            let resolved = rows.map { row in row.map { evaluate($0).single } }
            return resolved.isEmpty ? .scalar(.empty) : .block(resolved)

        case .call(let name, let arguments):
            if let binding = scope[name.lowercased()], case .lambda(let lambda) = binding.value {
                return invoke(lambda, arguments: arguments)
            }
            if FormulaFunctions.isKnown(name) {
                return FormulaFunctions.call(name, arguments: arguments, evaluator: self)
            }
            // A workbook name holding a LAMBDA is called like a function.
            if case .lambda(let lambda)? = context.resolveDefinedName(name, sheetName: nil) {
                return invoke(lambda, arguments: arguments)
            }
            return .failure(.nameError)

        case .invoke(let target, let arguments):
            guard case .lambda(let lambda) = evaluate(target) else { return .failure(.valueError) }
            return invoke(lambda, arguments: arguments)

        case .definedName(let sheet, let name):
            if sheet == nil, let binding = scope[name.lowercased()] {
                if let reference = binding.reference { return materialize(reference) }
                return binding.value
            }
            if let reference = context.definedNameReference(name, sheetName: sheet) {
                return materialize(reference)
            }
            if let value = context.resolveDefinedName(name, sheetName: sheet) { return value }
            // A table's name alone stands for its data rows.
            if sheet == nil, let table = context.structuredReference(table: name, specifier: "", at: currentAddress) {
                return materialize(table)
            }
            // A built-in function named without a call is a LAMBDA wrapping it,
            // as in `GROUPBY(A2:A9, B2:B9, SUM)`.
            if sheet == nil, let spec = FormulaFunctions.registry[name.uppercased()] {
                let count = max(1, spec.arity.lowerBound)
                let parameters = (1...count).map { "_eta\($0)" }
                return .lambda(FormulaLambda(
                    parameters: parameters,
                    body: .call(name.uppercased(), parameters.map { .definedName(sheet: nil, name: $0) }),
                    captured: [:]))
            }
            return .failure(.nameError)
        }
    }

    // MARK: - References

    /// The reference a node stands for, or nil when it evaluates to a value
    /// rather than to cells.
    func reference(_ node: FormulaNode) -> FormulaReference? {
        switch node {
        case .reference(let sheet, let address):
            return FormulaReference(sheet: sheet, address: address)
        case .range(let sheet, let start, let end):
            return FormulaReference(sheet: sheet, range: bodyRange(sheet: sheet, CellRange(start: start, end: end)))
        case .definedName(let sheet, let name):
            if sheet == nil, let binding = scope[name.lowercased()] { return binding.reference }
            if let named = context.definedNameReference(name, sheetName: sheet) { return named }
            return sheet == nil ? context.structuredReference(table: name, specifier: "", at: currentAddress) : nil
        case .structured(let table, let specifier):
            return context.structuredReference(table: table, specifier: specifier, at: currentAddress)
        case .binary(" ", let lhs, let rhs):
            guard let first = reference(lhs), let second = reference(rhs),
                  sameSheet(first.sheet, second.sheet) else { return nil }
            let top = max(first.range.start.row, second.range.start.row)
            let bottom = min(first.range.end.row, second.range.end.row)
            let left = max(first.range.start.column, second.range.start.column)
            let right = min(first.range.end.column, second.range.end.column)
            guard top <= bottom, left <= right else { return nil }
            return FormulaReference(sheet: first.sheet ?? second.sheet, range: CellRange(
                start: CellAddress(row: top, column: left), end: CellAddress(row: bottom, column: right)))
        case .union(let parts) where parts.count == 1:
            return reference(parts[0])
        case .binary(":", let lhs, let rhs):
            // The smallest range covering both ends, which must share a sheet.
            guard let first = reference(lhs), let second = reference(rhs),
                  sameSheet(first.sheet, second.sheet) else { return nil }
            let box = CellRange(
                start: CellAddress(row: min(first.range.start.row, second.range.start.row),
                                   column: min(first.range.start.column, second.range.start.column)),
                end: CellAddress(row: max(first.range.end.row, second.range.end.row),
                                 column: max(first.range.end.column, second.range.end.column))
            )
            return FormulaReference(sheet: first.sheet ?? second.sheet, range: box)
        case .spill(let operand):
            guard let anchor = reference(operand) else { return nil }
            let range = context.spillRange(anchoredAt: anchor.range.start, sheetName: anchor.sheet)
                ?? CellRange(anchor.range.start)
            return FormulaReference(sheet: anchor.sheet, range: range)
        case .intersect(let operand):
            guard let whole = reference(operand) else { return nil }
            return intersection(of: whole)
        case .call(let name, let arguments):
            if scope[name.lowercased()] != nil { return nil }
            return FormulaFunctions.reference(name, arguments: arguments, evaluator: self)
        default:
            return nil
        }
    }

    /// Every area a node names: one for a plain reference, several for a
    /// union. Nil when any part is not a reference.
    func areas(_ node: FormulaNode) -> [FormulaReference]? {
        if case .union(let parts) = node {
            var result: [FormulaReference] = []
            for part in parts {
                guard let found = areas(part) else { return nil }
                result += found
            }
            return result
        }
        return reference(node).map { [$0] }
    }

    /// The one cell of `reference` in line with the formula's own cell: same
    /// row for a column, same column for a row. This is what a range collapses
    /// to wherever a single value is wanted, and what `@` asks for.
    func intersection(of reference: FormulaReference) -> FormulaReference? {
        let box = reference.range
        if box.isSingleCell { return reference }
        guard let here = currentAddress else { return nil }
        let row: Int
        let column: Int
        if box.start.row == box.end.row {
            row = box.start.row
        } else if box.rowRange.contains(here.row) {
            row = here.row
        } else {
            return nil
        }
        if box.start.column == box.end.column {
            column = box.start.column
        } else if box.columnRange.contains(here.column) {
            column = here.column
        } else {
            return nil
        }
        return FormulaReference(sheet: reference.sheet, address: CellAddress(row: row, column: column))
    }

    private func sameSheet(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return true }
        return lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }

    /// Reads a reference's cells.
    func materialize(_ reference: FormulaReference) -> FormulaValue {
        if reference.range.isSingleCell {
            return .scalar(context.value(at: reference.range.start, sheetName: reference.sheet))
        }
        return matrix(sheet: reference.sheet, start: reference.range.start, end: reference.range.end)
    }

    /// A range as its sheet means it. On a table read from Numbers a whole
    /// column covers the body rows alone, below the header rows and above
    /// the footer rows, and a whole row the columns after the header
    /// columns, as they do in Numbers; anywhere else a range is as written.
    func bodyRange(sheet: String?, _ range: CellRange) -> CellRange {
        let box = range.normalized
        guard let edges = context.tableEdges(forSheetNamed: sheet),
              let extent = context.bounds(forSheetNamed: sheet) else { return range }
        var body = box
        if box.start.row == 0, box.end.row == SheetLimits.maxRow {
            body.start.row = edges.headerRows
            body.end.row = max(edges.headerRows, extent.rows - 1 - edges.footerRows)
        }
        if box.start.column == 0, box.end.column == SheetLimits.maxColumn {
            body.start.column = edges.headerColumns
            body.end.column = max(edges.headerColumns, extent.columns - 1)
        }
        return body == box ? range : body
    }

    /// Materializes a range.
    ///
    /// Only whole columns and whole rows are cut down to the sheet: an explicit
    /// range keeps the shape it was written with, empty cells and all, the way
    /// Excel's grid would read it.
    func matrix(sheet: String?, start: CellAddress, end: CellAddress) -> FormulaValue {
        let box = CellRange(start: start, end: end).normalized
        guard let extent = context.bounds(forSheetNamed: sheet) else { return .failure(.referenceError) }
        let wholeColumns = box.start.row == 0 && box.end.row == SheetLimits.maxRow
        let wholeRows = box.start.column == 0 && box.end.column == SheetLimits.maxColumn
        // Past this many cells even an explicit range is read only as far as the
        // sheet goes, so a stray `A1:Z1000000` cannot exhaust memory.
        let oversized = box.cellCount > 1_000_000
        let lastRow = wholeColumns || oversized ? min(box.end.row, max(0, extent.rows - 1)) : box.end.row
        let lastColumn = wholeRows || oversized ? min(box.end.column, max(0, extent.columns - 1)) : box.end.column
        guard box.start.row <= lastRow, box.start.column <= lastColumn else {
            return .matrix([[.empty]])
        }
        var rows: [[CellValue]] = []
        rows.reserveCapacity(lastRow - box.start.row + 1)
        for row in box.start.row...lastRow {
            var line: [CellValue] = []
            line.reserveCapacity(lastColumn - box.start.column + 1)
            for column in box.start.column...lastColumn {
                line.append(context.value(at: CellAddress(row: row, column: column), sheetName: sheet))
            }
            rows.append(line)
        }
        return .matrix(rows)
    }

    // MARK: - LAMBDA

    /// Calls a LAMBDA with unevaluated argument nodes from the caller.
    func invoke(_ lambda: FormulaLambda, arguments: [FormulaNode]) -> FormulaValue {
        guard arguments.count <= lambda.parameters.count else { return .failure(.valueError) }
        var bindings: [String: FormulaBinding] = [:]
        for (position, parameter) in lambda.parameters.enumerated() {
            if position < arguments.count, arguments[position] != .missing {
                let node = arguments[position]
                bindings[parameter] = FormulaBinding(value: evaluate(node), reference: reference(node))
            } else {
                bindings[parameter] = FormulaBinding(value: .scalar(.empty), isOmitted: true)
            }
        }
        return call(lambda, with: bindings)
    }

    /// Calls a LAMBDA with values already in hand, as `MAP` and `REDUCE` do.
    func invoke(_ lambda: FormulaLambda, values: [FormulaValue]) -> FormulaValue {
        guard values.count == lambda.parameters.count else { return .failure(.valueError) }
        var bindings: [String: FormulaBinding] = [:]
        for (parameter, value) in zip(lambda.parameters, values) {
            bindings[parameter] = FormulaBinding(value: value)
        }
        return call(lambda, with: bindings)
    }

    private func call(_ lambda: FormulaLambda, with bindings: [String: FormulaBinding]) -> FormulaValue {
        guard lambdaDepth < Self.maximumLambdaDepth else { return .failure(.numberError) }
        var inner = self
        inner.scope = lambda.captured.merging(bindings) { _, new in new }
        inner.lambdaDepth += 1
        return inner.evaluate(lambda.body)
    }
}

// MARK: - Element-wise evaluation

extension FormulaValue {
    /// Applies `operation` across values, element by element.
    ///
    /// Excel's broadcasting rules: a single value meets every element, a single
    /// row is repeated down and a single column across, and where two arrays
    /// differ in size the cells past the smaller one are `#N/A`.
    static func lift(_ values: [FormulaValue], _ operation: ([CellValue]) -> CellValue) -> FormulaValue {
        if values.allSatisfy({ if case .scalar = $0 { return true }; return false }) {
            return .scalar(operation(values.map(\.single)))
        }
        let blocks = values.map(\.rows)
        let height = blocks.map(\.count).max() ?? 1
        let width = blocks.map { $0.first?.count ?? 0 }.max() ?? 1
        var result: [[CellValue]] = []
        result.reserveCapacity(height)
        for row in 0..<height {
            var line: [CellValue] = []
            line.reserveCapacity(width)
            for column in 0..<width {
                var arguments: [CellValue] = []
                arguments.reserveCapacity(blocks.count)
                var outside = false
                for block in blocks {
                    let rows = block.count
                    let columns = block.first?.count ?? 0
                    let r = rows == 1 ? 0 : row
                    let c = columns == 1 ? 0 : column
                    guard r < rows, c < columns else { outside = true; break }
                    arguments.append(block[r][c])
                }
                line.append(outside ? .error(.notAvailable) : operation(arguments))
            }
            result.append(line)
        }
        return .block(result)
    }
}

/// The arithmetic, text and comparison operators.
enum FormulaOperators {
    static func apply(_ symbol: String, _ left: CellValue, _ right: CellValue) -> CellValue {
        if let error = left.errorValue ?? right.errorValue { return .error(error) }

        if symbol == "&" {
            guard let lhs = try? left.coercedText(), let rhs = try? right.coercedText() else {
                return .error(.valueError)
            }
            return .text(lhs + rhs)
        }

        if ["=", "<>", "<", ">", "<=", ">="].contains(symbol) {
            let ordering = FormulaComparison.compare(left, right)
            switch symbol {
            case "=": return .boolean(ordering == .orderedSame)
            case "<>": return .boolean(ordering != .orderedSame)
            case "<": return .boolean(ordering == .orderedAscending)
            case ">": return .boolean(ordering == .orderedDescending)
            case "<=": return .boolean(ordering != .orderedDescending)
            default: return .boolean(ordering != .orderedAscending)
            }
        }

        guard let a = try? left.coercedNumber(), let b = try? right.coercedNumber() else {
            return .error(.valueError)
        }
        let result: Double
        switch symbol {
        case "+": result = FormulaComparison.snapped(a + b, a, b)
        case "-": result = FormulaComparison.snapped(a - b, a, b)
        case "*": result = a * b
        case "/":
            guard b != 0 else { return .error(.divideByZero) }
            result = a / b
        case "^":
            if a == 0, b == 0 { return .error(.numberError) }
            if a == 0, b < 0 { return .error(.divideByZero) }
            result = pow(a, b)
        default:
            return .error(.valueError)
        }
        return result.isFinite ? .number(result) : .error(.numberError)
    }
}
