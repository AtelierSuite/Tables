import Foundation

/// Recalculates every formula in a workbook, memoizing per-cell results,
/// detecting circular references, and spilling array results into the cells
/// beside them.
final class CalculationEngine: FormulaContext {
    /// What a recursion guard tracks: a cell, or a defined name being expanded.
    private enum Key: Hashable {
        case cell(sheet: Int, address: CellAddress)
        /// Lowercased, because Excel matches defined names case-insensitively,
        /// paired with the scope the lookup landed in so the same name on two
        /// sheets counts as two definitions.
        case definedName(String, scope: Worksheet.ID?)
    }

    private typealias SpillMap = [Int: [CellAddress: CellRange]]

    private let workbook: Workbook
    private var sheetIndicesByName: [String: Int] = [:]
    /// Each formula's whole result, array and all.
    private var results: [Key: FormulaValue] = [:]
    private var blockedSpills: [Key: Bool] = [:]
    private var evaluating: Set<Key> = []
    private var parseCache: [String: Result<FormulaNode, FormulaParseFailure>] = [:]
    private var activeSheetIndex = 0
    /// Where arrays are taken to have spilled while this pass runs, so a cell
    /// in a spilled range can be read before its formula has been.
    private let hints: SpillMap
    /// For each cell inside a hinted spill, the formula that spills into it.
    private var owners: [Int: [CellAddress: CellAddress]] = [:]

    private struct FormulaParseFailure: Error { var message: String }

    private init(workbook: Workbook, hints: SpillMap) {
        self.workbook = workbook
        self.hints = hints
        for (index, sheet) in workbook.sheets.enumerated() {
            sheetIndicesByName[sheet.name.lowercased()] = index
        }
        for (sheet, spills) in hints {
            var map: [CellAddress: CellAddress] = [:]
            // Where two hinted spills overlap, the earlier formula owns the cell.
            for (anchor, range) in spills.sorted(by: { $0.key < $1.key }) {
                range.forEachAddress { address in
                    if address != anchor, map[address] == nil { map[address] = anchor }
                }
            }
            owners[sheet] = map
        }
    }

    convenience init(workbook: Workbook) {
        self.init(workbook: workbook, hints: Self.storedSpills(of: workbook))
    }

    private static func storedSpills(of workbook: Workbook) -> SpillMap {
        var map: SpillMap = [:]
        for (index, sheet) in workbook.sheets.enumerated() where !sheet.spills.isEmpty {
            map[index] = sheet.spills
        }
        return map
    }

    /// Returns a copy of the workbook with every formula cell's cached value
    /// refreshed and every array spilled.
    ///
    /// Spilling is settled by repetition: a pass that discovers a new or
    /// resized spill runs again with it known, so formulas reading the
    /// spilled cells see them. A sheet without arrays takes one pass.
    static func recalculated(_ workbook: Workbook) -> Workbook {
        withLargeStack { recalculatedInPlace(workbook) }
    }

    private static func recalculatedInPlace(_ workbook: Workbook) -> Workbook {
        var hints = storedSpills(of: workbook)
        var engine = CalculationEngine(workbook: workbook, hints: hints)
        for _ in 0..<4 {
            engine.evaluateAllFormulas()
            let actual = engine.actualSpills()
            if actual == hints { break }
            hints = actual
            engine = CalculationEngine(workbook: workbook, hints: hints)
        }
        engine.evaluateAllFormulas()
        return engine.apply(to: workbook)
    }

    /// Evaluates a formula body in the context of a sheet without storing anything.
    static func preview(formula body: String, in workbook: Workbook, sheetIndex: Int) -> CellValue {
        withLargeStack {
            let engine = CalculationEngine(workbook: workbook)
            engine.activeSheetIndex = sheetIndex
            return engine.evaluate(body: body, sheetIndex: sheetIndex, at: nil).single
        }
    }

    /// Evaluation recurses once per cell in a chain of references and several
    /// times per LAMBDA call, so it runs on a thread whose stack is sized for
    /// that rather than on whichever thread asked: a secondary thread's half
    /// megabyte runs out a few hundred levels deep.
    private static func withLargeStack<Result: Sendable>(_ body: @escaping @Sendable () -> Result) -> Result {
        let outcome = LargeStackOutcome<Result>()
        let finished = DispatchSemaphore(value: 0)
        let thread = Thread {
            outcome.value = body()
            finished.signal()
        }
        thread.stackSize = 256 << 20
        thread.qualityOfService = QualityOfService.userInitiated
        thread.start()
        finished.wait()
        return outcome.value!
    }

    private func evaluateAllFormulas() {
        for (sheetIndex, sheet) in workbook.sheets.enumerated() {
            activeSheetIndex = sheetIndex
            for (address, cell) in sheet.cells where cell.formula != nil {
                _ = value(at: address, sheetIndex: sheetIndex)
            }
        }
    }

    // MARK: - Writing results back

    private func apply(to workbook: Workbook) -> Workbook {
        var result = workbook
        let layouts = actualSpills()
        for (sheetIndex, sheet) in workbook.sheets.enumerated() {
            for (address, cell) in sheet.cells where cell.formula != nil {
                let value = value(at: address, sheetIndex: sheetIndex)
                let fingerprint = inputFingerprints[.cell(sheet: sheetIndex, address: address)]
                let fingerprintChanged = fingerprint.map { $0 != cell.savedResultInputs } ?? false
                // Most of a recalculation lands on the value already there.
                // Writing it back anyway would copy the sheet's whole cell
                // dictionary for nothing and tell the view every cell moved.
                guard value != cell.value || fingerprintChanged else { continue }
                var updated = cell
                updated.value = value
                if let fingerprint { updated.savedResultInputs = fingerprint }
                result.sheets[sheetIndex].cells[address] = updated
            }

            let spills = layouts[sheetIndex] ?? [:]
            var covered: [CellAddress: CellValue] = [:]
            for (anchor, range) in spills {
                range.forEachAddress { address in
                    guard address != anchor else { return }
                    covered[address] = spilledValue(sheetIndex: sheetIndex, owner: anchor, at: address)
                }
            }
            for (address, cell) in sheet.cells where cell.isSpilled && covered[address] == nil {
                var cleared = cell
                cleared.value = .empty
                cleared.isSpilled = false
                result.sheets[sheetIndex][address] = cleared
            }
            for (address, value) in covered {
                var cell = sheet[address]
                guard cell.formula == nil, !(cell.isSpilled && cell.value == value) else { continue }
                cell.value = value
                cell.isSpilled = true
                result.sheets[sheetIndex][address] = cell
                // The grid grows to hold a spill, as Excel's would already be big enough.
                if address.row >= result.sheets[sheetIndex].rowCount {
                    result.sheets[sheetIndex].rowCount = min(Worksheet.maximumRowCount, address.row + 1)
                }
                if address.column >= result.sheets[sheetIndex].columnCount {
                    result.sheets[sheetIndex].columnCount = min(Worksheet.maximumColumnCount, address.column + 1)
                }
            }
            if result.sheets[sheetIndex].spills != spills { result.sheets[sheetIndex].spills = spills }
        }
        return result
    }

    // MARK: - Spilling

    /// Where every formula evaluated so far spills, by sheet.
    private func actualSpills() -> SpillMap {
        var map: SpillMap = [:]
        for key in results.keys {
            guard case .cell(let sheet, let address) = key,
                  let range = spillRange(sheetIndex: sheet, anchor: address) else { continue }
            map[sheet, default: [:]][address] = range
        }
        return map
    }

    /// The block a formula's result occupies, or nil when it is a single value
    /// or has no room to spill.
    private func spillRange(sheetIndex: Int, anchor: CellAddress) -> CellRange? {
        guard let cell = workbook.sheets[sheetIndex].cells[anchor], cell.formula != nil,
              let result = results[.cell(sheet: sheetIndex, address: anchor)] else { return nil }
        if let extent = cell.arrayExtent {
            return CellRange(start: anchor, end: CellAddress(row: anchor.row + extent.rows - 1,
                                                             column: anchor.column + extent.columns - 1))
        }
        guard result.isArray else { return nil }
        let range = CellRange(start: anchor, end: CellAddress(row: anchor.row + result.rowCount - 1,
                                                              column: anchor.column + result.columnCount - 1))
        return isBlocked(sheetIndex: sheetIndex, anchor: anchor, range: range) ? nil : range
    }

    /// Whether anything stands in a spill's way: a formula, a value someone
    /// typed, a merged region, an earlier formula's spill, or the sheet's edge.
    private func isBlocked(sheetIndex: Int, anchor: CellAddress, range: CellRange) -> Bool {
        let key = Key.cell(sheet: sheetIndex, address: anchor)
        if let known = blockedSpills[key] { return known }
        let sheet = workbook.sheets[sheetIndex]
        var blocked = range.end.row >= Worksheet.maximumRowCount || range.end.column >= Worksheet.maximumColumnCount
        if !blocked {
            blocked = sheet.storedAddresses(in: range).contains { address in
                guard address != anchor, let cell = sheet.cells[address] else { return false }
                return cell.formula != nil || (!cell.isSpilled && !cell.value.isEmpty)
            }
        }
        if !blocked {
            blocked = sheet.mergedRanges.contains { merge in
                let box = merge.normalized
                return box.start.row <= range.end.row && box.end.row >= range.start.row
                    && box.start.column <= range.end.column && box.end.column >= range.start.column
            }
        }
        if !blocked, let owned = owners[sheetIndex], !owned.isEmpty {
            func takenByEarlier(_ address: CellAddress) -> Bool {
                guard let owner = owned[address] else { return false }
                return owner != anchor && owner < anchor
            }
            if range.cellCount <= owned.count {
                var found = false
                range.forEachAddress { if !found, takenByEarlier($0) { found = true } }
                blocked = found
            } else {
                blocked = owned.keys.contains { range.contains($0) && takenByEarlier($0) }
            }
        }
        blockedSpills[key] = blocked
        return blocked
    }

    /// The value a spilled-into cell shows, read from the formula spilling there.
    private func spilledValue(sheetIndex: Int, owner: CellAddress, at address: CellAddress) -> CellValue {
        guard let cell = workbook.sheets[sheetIndex].cells[owner], cell.formula != nil else { return .empty }
        let result = formulaResult(sheetIndex: sheetIndex, address: owner, formula: cell.formula ?? "")
        let row = address.row - owner.row
        let column = address.column - owner.column
        guard row >= 0, column >= 0 else { return .empty }
        if let extent = cell.arrayExtent {
            guard row < extent.rows, column < extent.columns else { return .empty }
            return Self.fitted(result, row: row, column: column)
        }
        guard let range = spillRange(sheetIndex: sheetIndex, anchor: owner), range.contains(address) else {
            return .empty
        }
        return result.rows[row][column]
    }

    /// A legacy array formula's value at a position in its fixed block: a
    /// single row or column repeats, and anything past the result is `#N/A`.
    private static func fitted(_ result: FormulaValue, row: Int, column: Int) -> CellValue {
        if case .lambda = result { return .error(.calc) }
        let rows = result.rows
        let r = rows.count == 1 ? 0 : row
        let c = (rows.first?.count ?? 0) == 1 ? 0 : column
        guard r < rows.count, c < rows[r].count else { return .error(.notAvailable) }
        return rows[r][c]
    }

    // MARK: - FormulaContext

    var currentSheetName: String {
        workbook.sheets.indices.contains(activeSheetIndex) ? workbook.sheets[activeSheetIndex].name : ""
    }

    func value(at address: CellAddress, sheetName: String?) -> CellValue {
        guard let index = resolveSheetIndex(sheetName) else { return .error(.referenceError) }
        return value(at: address, sheetIndex: index)
    }

    func bounds(forSheetNamed name: String?) -> (rows: Int, columns: Int)? {
        guard let index = resolveSheetIndex(name) else { return nil }
        let sheet = workbook.sheets[index]
        var rows = sheet.rowCount
        var columns = sheet.columnCount
        // A spill can run past the grid until the grid grows to hold it.
        for range in (hints[index] ?? [:]).values {
            rows = max(rows, range.end.row + 1)
            columns = max(columns, range.end.column + 1)
        }
        return (rows, columns)
    }

    func tableEdges(forSheetNamed name: String?) -> TableEdges? {
        resolveSheetIndex(name).flatMap { workbook.sheets[$0].tableEdges }
    }

    func spillRange(anchoredAt address: CellAddress, sheetName: String?) -> CellRange? {
        guard let index = resolveSheetIndex(sheetName),
              workbook.sheets[index].cells[address]?.formula != nil else { return nil }
        _ = value(at: address, sheetIndex: index)
        return spillRange(sheetIndex: index, anchor: address)
    }

    func resolveDefinedName(_ name: String, sheetName: String?) -> FormulaValue? {
        guard let scopeIndex = resolveSheetIndex(sheetName) else { return nil }
        let scopeID = workbook.sheets[scopeIndex].id
        guard let definition = workbook.definedName(name, visibleFrom: scopeID) else { return nil }

        // A definition is a formula in its own right and may name others, so it
        // gets the same guard cells do rather than a second mechanism.
        let key = Key.definedName(name.lowercased(), scope: definition.scope)
        guard !evaluating.contains(key) else { return .failure(.circularReference) }
        evaluating.insert(key)
        defer { evaluating.remove(key) }

        // Unqualified references inside a sheet-scoped definition belong to the
        // sheet it is scoped to; a workbook-scoped one reads from wherever it
        // was used.
        let previousSheet = activeSheetIndex
        activeSheetIndex = definition.scope.flatMap { workbook.index(of: $0) } ?? scopeIndex
        defer { activeSheetIndex = previousSheet }

        switch parsed(definition.formula) {
        case .failure:
            return .failure(.nameError)
        case .success(let node):
            return FormulaEvaluator(context: self).evaluate(node)
        }
    }

    func definedNameReference(_ name: String, sheetName: String?) -> FormulaReference? {
        guard let scopeIndex = resolveSheetIndex(sheetName) else { return nil }
        let scopeID = workbook.sheets[scopeIndex].id
        guard let definition = workbook.definedName(name, visibleFrom: scopeID),
              case .success(let node) = parsed(definition.formula) else { return nil }
        let key = Key.definedName(name.lowercased(), scope: definition.scope)
        guard !evaluating.contains(key) else { return nil }
        evaluating.insert(key)
        defer { evaluating.remove(key) }

        let previousSheet = activeSheetIndex
        activeSheetIndex = definition.scope.flatMap { workbook.index(of: $0) } ?? scopeIndex
        defer { activeSheetIndex = previousSheet }
        guard var reference = FormulaEvaluator(context: self).reference(node) else { return nil }
        // Pin the sheet, so the reference still means the same cells once it
        // is read from wherever the name was used.
        if reference.sheet == nil { reference.sheet = workbook.sheets[activeSheetIndex].name }
        return reference
    }

    func cell(at address: CellAddress, sheetName: String?) -> Cell? {
        guard let index = resolveSheetIndex(sheetName) else { return nil }
        return workbook.sheets[index][address]
    }

    func isRowHidden(_ row: Int, sheetName: String?) -> Bool {
        guard let index = resolveSheetIndex(sheetName) else { return false }
        return workbook.sheets[index].hiddenRows.contains(row)
    }

    func sheetNumber(named name: String?) -> Int? {
        resolveSheetIndex(name).map { $0 + 1 }
    }

    var sheetCount: Int { workbook.sheets.count }

    func structuredReference(table name: String?, specifier: String, at address: CellAddress?) -> FormulaReference? {
        let table: TableDefinition?
        if let name {
            table = workbook.tables.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        } else {
            let sheetID = workbook.sheets.indices.contains(activeSheetIndex) ? workbook.sheets[activeSheetIndex].id : nil
            table = workbook.tables.first { table in
                table.sheetID == sheetID && address.map { table.range.contains($0) } == true
            }
        }
        guard let table, let sheetIndex = workbook.index(of: table.sheetID),
              let range = table.resolve(specifier, row: address?.row) else { return nil }
        return FormulaReference(sheet: workbook.sheets[sheetIndex].name, range: range)
    }

    func columnWidth(_ column: Int, sheetName: String?) -> Double? {
        guard let index = resolveSheetIndex(sheetName) else { return nil }
        return Worksheet.columnWidthCharacters(points: workbook.sheets[index].width(ofColumn: column))
    }

    func sheetNames(from first: String, to last: String) -> [String]? {
        guard let start = sheetIndicesByName[first.lowercased()],
              let end = sheetIndicesByName[last.lowercased()] else { return nil }
        return workbook.sheets[min(start, end)...max(start, end)].map(\.name)
    }

    // MARK: - Evaluation

    private func resolveSheetIndex(_ name: String?) -> Int? {
        guard let name else { return workbook.sheets.indices.contains(activeSheetIndex) ? activeSheetIndex : nil }
        return sheetIndicesByName[name.lowercased()]
    }

    private func value(at address: CellAddress, sheetIndex: Int) -> CellValue {
        guard workbook.sheets.indices.contains(sheetIndex) else { return .error(.referenceError) }
        let sheet = workbook.sheets[sheetIndex]
        let cell = sheet.cells[address]

        if let cell, let formula = cell.formula {
            let result = formulaResult(sheetIndex: sheetIndex, address: address, formula: formula)
            if cell.arrayExtent != nil { return Self.fitted(result, row: 0, column: 0) }
            if case .lambda = result { return .error(.calc) }
            guard result.isArray else { return result.single }
            return spillRange(sheetIndex: sheetIndex, anchor: address) == nil ? .error(.spill) : result.rows[0][0]
        }
        // A cell another formula spills into, unless someone typed over it.
        if let owner = owners[sheetIndex]?[address], cell == nil || cell?.isSpilled == true || cell?.isBlank == true {
            return spilledValue(sheetIndex: sheetIndex, owner: owner, at: address)
        }
        guard let cell, sheet.contains(address), !cell.isSpilled else { return .empty }
        return cell.value
    }

    /// A formula cell's whole result, computed once.
    private func formulaResult(sheetIndex: Int, address: CellAddress, formula: String) -> FormulaValue {
        let key = Key.cell(sheet: sheetIndex, address: address)
        if let cached = results[key] { return cached }
        if let saved = savedResult(sheetIndex: sheetIndex, address: address, formula: formula) {
            results[key] = saved
            return saved
        }
        if let kept = keptApproximation(sheetIndex: sheetIndex, address: address, formula: formula) {
            results[key] = kept
            return kept
        }
        guard !evaluating.contains(key) else { return .failure(.circularReference) }
        evaluating.insert(key)
        defer { evaluating.remove(key) }

        let previousSheet = activeSheetIndex
        activeSheetIndex = sheetIndex
        let result = evaluate(body: formula, sheetIndex: sheetIndex, at: address)
        activeSheetIndex = previousSheet

        results[key] = result
        return result
    }

    /// For a formula Tables cannot calculate — one calling a web or cube
    /// function, an add-in or something newer than this version, or one it
    /// cannot read at all — the result
    /// the file was saved with, spill and all. Without one there is nothing
    /// better than `#NAME?`, which is what evaluating it gives.
    private func savedResult(sheetIndex: Int, address: CellAddress, formula: String) -> FormulaValue? {
        let sheet = workbook.sheets[sheetIndex]
        guard let cell = sheet.cells[address], !cell.value.isEmpty, cell.value != .error(.nameError) else { return nil }
        // A formula Tables cannot read, such as a link into another workbook,
        // keeps its result just as one calling an unknown function does.
        switch parsed(formula) {
        case .failure: break
        case .success(let node): guard callsUnknownFunction(formula, node) else { return nil }
        }
        let block: CellRange?
        if let extent = cell.arrayExtent {
            block = CellRange(start: address, end: CellAddress(row: address.row + extent.rows - 1,
                                                              column: address.column + extent.columns - 1))
        } else {
            block = hints[sheetIndex]?[address]
        }
        guard let block, !block.isSingleCell else { return .scalar(cell.value) }
        return .block(block.rowRange.map { row in
            block.columnRange.map { column in
                let here = CellAddress(row: row, column: column)
                return here == address ? cell.value : (sheet.cells[here]?.value ?? .empty)
            }
        })
    }

    /// Fingerprints to store on cells once this pass is written back: the
    /// inputs a kept result stands for, or nil where it was recalculated.
    private var inputFingerprints: [Key: Int?] = [:]

    /// A file's saved result for a formula Tables can only approximate, while
    /// the values it reads are the ones it was saved with.
    private func keptApproximation(sheetIndex: Int, address: CellAddress, formula: String) -> FormulaValue? {
        let key = Key.cell(sheet: sheetIndex, address: address)
        guard let cell = workbook.sheets[sheetIndex].cells[address], let recorded = cell.savedResultInputs,
              case .success(let node) = parsed(formula) else { return nil }
        // Fingerprint everything the approximated calls read.
        let previousSheet = activeSheetIndex
        activeSheetIndex = sheetIndex
        let evaluator = FormulaEvaluator(context: self, currentAddress: address)
        var hasher = Hasher()
        hasher.combine(formula)
        for arguments in FormulaFunctions.approximatedCalls(in: node) {
            for argument in arguments { hasher.combine(evaluator.evaluate(argument)) }
        }
        activeSheetIndex = previousSheet
        let fingerprint = hasher.finalize()
        guard recorded == Cell.unverifiedInputs || recorded == fingerprint else {
            inputFingerprints[key] = .some(nil)
            return nil
        }
        inputFingerprints[key] = .some(fingerprint)
        let block = hints[sheetIndex]?[address] ?? CellRange(address)
        let sheet = workbook.sheets[sheetIndex]
        return .block(block.rowRange.map { row in
            block.columnRange.map { column in
                let here = CellAddress(row: row, column: column)
                return here == address ? cell.value : (sheet.cells[here]?.value ?? .empty)
            }
        })
    }

    private var unknownCallCache: [String: Bool] = [:]

    private func callsUnknownFunction(_ formula: String, _ node: FormulaNode) -> Bool {
        if let known = unknownCallCache[formula] { return known }
        let names = Set(workbook.definedNames.map { $0.name.lowercased() })
        let found = Self.unknownCalls(in: node, bound: [], definedNames: names)
        unknownCallCache[formula] = found
        return found
    }

    /// Whether anything in `node` calls a name that is neither a built-in
    /// function, a defined name, nor a LET or LAMBDA name in reach.
    private static func unknownCalls(in node: FormulaNode, bound: Set<String>, definedNames: Set<String>) -> Bool {
        func visit(_ child: FormulaNode, _ bound: Set<String>) -> Bool {
            unknownCalls(in: child, bound: bound, definedNames: definedNames)
        }
        switch node {
        case .call(let name, let arguments):
            let lowered = name.lowercased()
            if !FormulaFunctions.isKnown(name), !bound.contains(lowered), !definedNames.contains(lowered) {
                return true
            }
            var inner = bound
            if name == "LET" {
                for (index, argument) in arguments.enumerated() where index % 2 == 0 && index < arguments.count - 1 {
                    if case .definedName(nil, let variable) = argument { inner.insert(variable.lowercased()) }
                }
            } else if name == "LAMBDA" {
                for argument in arguments.dropLast() {
                    if case .definedName(nil, let variable) = argument { inner.insert(variable.lowercased()) }
                }
            }
            return arguments.contains { visit($0, inner) }
        case .invoke(let target, let arguments):
            return visit(target, bound) || arguments.contains { visit($0, bound) }
        case .unary(_, let operand), .postfixPercent(let operand), .intersect(let operand), .spill(let operand):
            return visit(operand, bound)
        case .binary(_, let lhs, let rhs):
            return visit(lhs, bound) || visit(rhs, bound)
        case .array(let rows):
            return rows.contains { $0.contains { visit($0, bound) } }
        case .union(let parts):
            return parts.contains { visit($0, bound) }
        default:
            return false
        }
    }

    /// `address` is the cell the formula lives in, which `ROW()` and `COLUMN()`
    /// report when called with no argument.
    private func evaluate(body: String, sheetIndex: Int, at address: CellAddress?) -> FormulaValue {
        switch parsed(body) {
        case .failure:
            return .failure(.nameError)
        case .success(let node):
            let previousSheet = activeSheetIndex
            activeSheetIndex = sheetIndex
            defer { activeSheetIndex = previousSheet }
            return FormulaEvaluator(context: self, currentAddress: address).evaluate(node)
        }
    }

    private func parsed(_ body: String) -> Result<FormulaNode, FormulaParseFailure> {
        if let cached = parseCache[body] { return cached }
        let outcome: Result<FormulaNode, FormulaParseFailure>
        do {
            outcome = .success(try FormulaParser.parse(body))
        } catch let error as FormulaParseError {
            outcome = .failure(FormulaParseFailure(message: error.message))
        } catch let error as FormulaLexError {
            outcome = .failure(FormulaParseFailure(message: error.message))
        } catch {
            outcome = .failure(FormulaParseFailure(message: "Invalid formula"))
        }
        parseCache[body] = outcome
        return outcome
    }
}

/// Carries a result back from the evaluation thread, which hands it over
/// before signalling and never touches it again.
private final class LargeStackOutcome<Value>: @unchecked Sendable {
    var value: Value?
}

extension Workbook {
    /// Refreshes every cached formula result in place.
    mutating func recalculate() {
        self = CalculationEngine.recalculated(self)
    }
}

// MARK: - Parsing user input

enum CellInputParser {
    /// Interprets raw text typed into a cell: formulas, numbers, percentages,
    /// booleans, and everything else as text.
    static func cell(from input: String, inheriting style: CellStyle) -> Cell {
        var cell = Cell(value: .empty, formula: nil, style: style)
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty { return cell }

        if trimmed.hasPrefix("=") {
            cell.formula = String(trimmed.dropFirst())
            cell.value = .empty
            return cell
        }

        // Explicitly text-formatted cells never coerce.
        if style.numberFormat == NumberFormatPreset.text.code {
            cell.value = .text(input)
            return cell
        }

        if trimmed.caseInsensitiveCompare("TRUE") == .orderedSame {
            cell.value = .boolean(true)
            return cell
        }
        if trimmed.caseInsensitiveCompare("FALSE") == .orderedSame {
            cell.value = .boolean(false)
            return cell
        }
        if let error = CellError.allCases.first(where: { $0.rawValue == trimmed.uppercased() }) {
            cell.value = .error(error)
            return cell
        }
        if let number = number(from: trimmed) {
            cell.value = .number(number.value)
            if let format = number.impliedFormat, cell.style.numberFormat == NumberFormatPreset.general.code {
                cell.style.numberFormat = format
            }
            return cell
        }
        cell.value = .text(input)
        return cell
    }

    private struct ParsedNumber {
        var value: Double
        var impliedFormat: String?
    }

    private static func number(from text: String) -> ParsedNumber? {
        if let plain = Double(text) { return ParsedNumber(value: plain, impliedFormat: nil) }

        var working = text
        var impliedFormat: String?

        if working.hasSuffix("%") {
            working.removeLast()
            guard let value = Double(working.replacingOccurrences(of: ",", with: "")) else { return nil }
            return ParsedNumber(value: value / 100, impliedFormat: NumberFormatPreset.percent.code)
        }

        // A leading currency symbol implies currency formatting.
        if let first = working.first, "$€£¥".contains(first) {
            working.removeFirst()
            impliedFormat = NumberFormatPreset.currency.code
        }

        let stripped = working.replacingOccurrences(of: ",", with: "")
        guard stripped.rangeOfCharacter(from: CharacterSet(charactersIn: "0123456789")) != nil,
              let value = Double(stripped) else { return nil }
        if impliedFormat == nil, working.contains(",") {
            impliedFormat = NumberFormatPreset.thousands.code
        }
        return ParsedNumber(value: value, impliedFormat: impliedFormat)
    }
}
