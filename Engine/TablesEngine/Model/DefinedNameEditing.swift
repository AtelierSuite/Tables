import Foundation

/// Why a name, or what it refers to, was refused.
public enum DefinedNameError: Error, Hashable, Sendable {
    case empty
    case tooLong
    /// A space, or a character Excel does not allow in a name.
    case invalidCharacters
    /// The first character is not a letter, an underscore or a backslash.
    case invalidStart
    /// The name reads as a cell reference — `A1`, `R1C1`, `R`, `C` — or as
    /// `TRUE` or `FALSE`, so a formula could never reach it.
    case looksLikeReference
    /// Excel's own `_xlnm.` names, which are not the user's to make.
    case reserved
    /// Another name in the same scope is already spelled this way.
    case duplicate
    /// What the name refers to is not a formula.
    case invalidFormula
    /// The name to change is no longer in the workbook.
    case notFound

    /// What to tell someone whose name was refused.
    public var message: String {
        switch self {
        case .empty: return String(localized: "DefinedName.Error.Empty", bundle: .engine)
        case .tooLong: return String(localized: "DefinedName.Error.TooLong", bundle: .engine)
        case .invalidCharacters: return String(localized: "DefinedName.Error.InvalidCharacters", bundle: .engine)
        case .invalidStart: return String(localized: "DefinedName.Error.InvalidStart", bundle: .engine)
        case .looksLikeReference: return String(localized: "DefinedName.Error.LooksLikeReference", bundle: .engine)
        case .reserved: return String(localized: "DefinedName.Error.Reserved", bundle: .engine)
        case .duplicate: return String(localized: "DefinedName.Error.Duplicate", bundle: .engine)
        case .invalidFormula: return String(localized: "DefinedName.Error.InvalidFormula", bundle: .engine)
        case .notFound: return String(localized: "DefinedName.Error.NotFound", bundle: .engine)
        }
    }
}

extension DefinedName {
    /// Excel's limit on a name's length.
    public static let maximumLength = 255

    /// Whether the user may change or delete the name: Excel's own entries
    /// and hidden names are kept as they are.
    public var isEditable: Bool { !isBuiltIn && !isHidden }

    /// Which name this is: names are unique by spelling, ignoring case,
    /// within a scope.
    public func matches(_ name: String, scope: Worksheet.ID?) -> Bool {
        self.scope == scope && self.name.compare(name, options: .caseInsensitive) == .orderedSame
    }

    /// Checks a name against Excel's rules for its spelling, leaving aside
    /// whether it is already taken.
    public static func spellingError(of name: String) -> DefinedNameError? {
        guard !name.isEmpty else { return .empty }
        guard name.count <= maximumLength else { return .tooLong }
        if name.lowercased().hasPrefix(builtInPrefix) { return .reserved }
        guard let first = name.first, first.isLetter || first == "_" || first == "\\" else {
            return name.contains(where: \.isWhitespace) ? .invalidCharacters : .invalidStart
        }
        let allowed = name.allSatisfy { character in
            character.isLetter || character.isNumber || character == "_" || character == "."
                || character == "\\" || character == "?"
        }
        guard allowed else { return .invalidCharacters }
        if looksLikeReference(name) { return .looksLikeReference }
        return nil
    }

    /// `A1`-style addresses inside the sheet's bounds, every `R1C1`-style
    /// shape, and the two words a formula reads as values.
    private static func looksLikeReference(_ name: String) -> Bool {
        let upper = name.uppercased()
        if upper == "TRUE" || upper == "FALSE" { return true }
        if let address = CellAddress(a1: name), !name.contains("$"),
           address.row <= SheetLimits.maxRow, address.column <= SheetLimits.maxColumn {
            return true
        }
        // R, C, R1, C1, RC, R1C, RC1, R1C1.
        var rest = Substring(upper)
        func digits() { rest = rest.drop { $0.isASCII && $0.isNumber } }
        if rest.first == "R" {
            rest = rest.dropFirst()
            digits()
            if rest.first == "C" {
                rest = rest.dropFirst()
                digits()
            }
            return rest.isEmpty
        }
        if rest.first == "C" {
            rest = rest.dropFirst()
            digits()
            return rest.isEmpty
        }
        return false
    }

    /// An absolute, sheet-qualified reference to a range, as a name made from
    /// a selection refers to it: `Sheet1!$A$1:$B$4`.
    public static func formula(for range: CellRange, onSheetNamed sheetName: String) -> String {
        let box = range.normalized
        let start = "$\(CellAddress.columnName(box.start.column))$\(box.start.row + 1)"
        let end = "$\(CellAddress.columnName(box.end.column))$\(box.end.row + 1)"
        let body = box.isSingleCell ? start : "\(start):\(end)"
        return "\(ChartReference.quotedSheetName(sheetName))!\(body)"
    }
}

/// Where a name's range is, for going to it.
public struct DefinedNameTarget: Hashable, Sendable {
    public var sheetID: Worksheet.ID
    public var range: CellRange
}

extension Workbook {
    /// The names the user can see and change, by scope (the workbook's first,
    /// then each sheet's in sheet order) and then by name.
    public var editableDefinedNames: [DefinedName] {
        let order = Dictionary(uniqueKeysWithValues: sheets.enumerated().map { ($0.element.id, $0.offset) })
        return definedNames
            .filter { $0.isEditable && ($0.scope == nil || order[$0.scope!] != nil) }
            .sorted { lhs, rhs in
                let left = lhs.scope.flatMap { order[$0] } ?? -1
                let right = rhs.scope.flatMap { order[$0] } ?? -1
                if left != right { return left < right }
                return lhs.name.lowercased() < rhs.name.lowercased()
            }
    }

    public func definedName(named name: String, scope: Worksheet.ID?) -> DefinedName? {
        definedNames.first { $0.matches(name, scope: scope) }
    }

    /// Why `name` cannot be used in `scope`, or nil when it can. A name
    /// being renamed is passed as `replacing`, so keeping its spelling, or
    /// changing only its case, is not a clash with itself.
    public func definedNameError(
        for name: String, scope: Worksheet.ID?, replacing existing: DefinedName? = nil
    ) -> DefinedNameError? {
        if let error = DefinedName.spellingError(of: name) { return error }
        let clash = definedNames.contains { other in
            other.matches(name, scope: scope)
                && !(existing.map { other.matches($0.name, scope: $0.scope) } ?? false)
        }
        return clash ? .duplicate : nil
    }

    /// Checks what a name is to refer to, which may be typed with or without
    /// a leading `=`, and returns it as stored.
    public static func definedNameFormula(from text: String) throws(DefinedNameError) -> String {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("=") { body.removeFirst() }
        body = body.trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty, (try? FormulaParser.parse(body)) != nil else { throw .invalidFormula }
        return body
    }

    /// Adds a name. `formula` is checked as `definedNameFormula(from:)` does.
    public mutating func addDefinedName(
        _ name: String, refersTo formula: String, scope: Worksheet.ID?
    ) throws(DefinedNameError) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let error = definedNameError(for: name, scope: scope) { throw error }
        let body = try Self.definedNameFormula(from: formula)
        definedNames.append(DefinedName(name: name, formula: body, scope: scope))
        recalculate()
    }

    /// Renames a name, and every formula that uses it with it, so they go on
    /// working: cells, conditional formatting, and other names.
    public mutating func renameDefinedName(
        _ name: String, scope: Worksheet.ID?, to newName: String
    ) throws(DefinedNameError) {
        guard let index = definedNames.firstIndex(where: { $0.matches(name, scope: scope) }),
              definedNames[index].isEditable else { throw .notFound }
        let target = definedNames[index]
        let newName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let error = definedNameError(for: newName, scope: scope, replacing: target) { throw error }
        guard newName != target.name else { return }

        // Every use is found against the workbook as it was, before the
        // rename changes what resolves to what.
        let snapshot = self
        func rewrite(_ formula: String, from sheetID: Worksheet.ID?) -> String {
            snapshot.renamingUses(of: target, to: newName, in: formula, from: sheetID)
        }
        for sheet in sheets.indices {
            let sheetID = sheets[sheet].id
            for (address, cell) in sheets[sheet].cells {
                guard let formula = cell.formula else { continue }
                let rewritten = rewrite(formula, from: sheetID)
                if rewritten != formula { sheets[sheet].cells[address]?.formula = rewritten }
            }
            for rule in sheets[sheet].conditionalRules.indices {
                sheets[sheet].conditionalRules[rule].formulas = sheets[sheet].conditionalRules[rule].formulas
                    .map { rewrite($0, from: sheetID) }
            }
        }
        for other in definedNames.indices {
            // A workbook-scoped definition is read from wherever it is used;
            // only another workbook-scoped name can be meant unqualified.
            definedNames[other].formula = rewrite(definedNames[other].formula, from: definedNames[other].scope)
        }
        definedNames[index].name = newName
        recalculate()
    }

    /// Points a name at something else.
    public mutating func setDefinedNameFormula(
        _ name: String, scope: Worksheet.ID?, to formula: String
    ) throws(DefinedNameError) {
        guard let index = definedNames.firstIndex(where: { $0.matches(name, scope: scope) }),
              definedNames[index].isEditable else { throw .notFound }
        let body = try Self.definedNameFormula(from: formula)
        guard body != definedNames[index].formula else { return }
        definedNames[index].formula = body
        recalculate()
    }

    /// Deletes a name. Formulas using it are left as they are, and show
    /// `#NAME?`, as they do in Excel.
    public mutating func removeDefinedName(_ name: String, scope: Worksheet.ID?) throws(DefinedNameError) {
        guard let index = definedNames.firstIndex(where: { $0.matches(name, scope: scope) }),
              definedNames[index].isEditable else { throw .notFound }
        definedNames.remove(at: index)
        recalculate()
    }

    /// The range a name refers to, for going to it: a single rectangle on a
    /// sheet of this workbook. Nil for a constant, an expression or a union.
    /// An unqualified reference is on the name's own sheet, or else on
    /// `sheetID`, the sheet being looked at.
    public func target(of name: DefinedName, from sheetID: Worksheet.ID?) -> DefinedNameTarget? {
        guard let node = try? FormulaParser.parse(name.formula) else { return nil }
        let sheetName: String?
        let range: CellRange
        switch node {
        case .reference(let sheet, let address):
            sheetName = sheet
            range = CellRange(address)
        case .range(let sheet, let start, let end):
            sheetName = sheet
            range = CellRange(start: start, end: end).normalized
        default:
            return nil
        }
        let sheet: Worksheet.ID?
        if let sheetName {
            sheet = self.sheet(named: sheetName)?.id
        } else {
            sheet = name.scope ?? sheetID
        }
        guard let sheet, let worksheet = self[sheet] else { return nil }
        // Whole rows and columns reach past the sheet; keep to what it has.
        let clamped = CellRange(
            start: range.start,
            end: CellAddress(
                row: min(range.end.row, max(range.start.row, worksheet.rowCount - 1)),
                column: min(range.end.column, max(range.start.column, worksheet.columnCount - 1))
            )
        )
        return DefinedNameTarget(sheetID: sheet, range: clamped)
    }

    /// A name for a selection: the text of the cell above it, or else the
    /// one to its left, as Excel suggests, made into a name Excel accepts.
    /// Empty when neither gives a name that is free.
    public func suggestedDefinedName(for range: CellRange, on sheetID: Worksheet.ID) -> String {
        guard let sheet = self[sheetID] else { return "" }
        let box = range.normalized
        var labels: [CellAddress] = []
        if box.start.row > 0 { labels.append(CellAddress(row: box.start.row - 1, column: box.start.column)) }
        if box.start.column > 0 { labels.append(CellAddress(row: box.start.row, column: box.start.column - 1)) }
        for address in labels {
            guard case .text(let text) = sheet[address].value else { continue }
            var candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
                .map { $0.isWhitespace ? "_" : $0 }
                .filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }
                .reduce(into: "") { $0.append($1) }
            if let first = candidate.first, !(first.isLetter || first == "_") { candidate = "_" + candidate }
            candidate = String(candidate.prefix(DefinedName.maximumLength))
            if definedNameError(for: candidate, scope: nil) == nil { return candidate }
        }
        return ""
    }

    /// The names a formula on `sheetID` can use whose spelling starts with
    /// `prefix`, for offering while one is typed: the sheet's own first,
    /// then the workbook's, without hidden ones or Excel's own.
    public func definedNameCompletions(for prefix: String, visibleFrom sheetID: Worksheet.ID?) -> [DefinedName] {
        guard !prefix.isEmpty else { return [] }
        let visible = definedNames.filter { name in
            !name.isBuiltIn && !name.isHidden
                && (name.scope == nil || name.scope == sheetID)
                && name.name.range(of: prefix, options: [.caseInsensitive, .anchored]) != nil
        }
        // A sheet's own name hides the workbook's one spelled the same way.
        var seen = Set<String>()
        return visible
            .sorted { ($0.scope != nil ? 0 : 1, $0.name.lowercased()) < ($1.scope != nil ? 0 : 1, $1.name.lowercased()) }
            .filter { seen.insert($0.name.lowercased()).inserted }
    }

    /// `formula` with each use of `name` — as a formula on `sheetID` would
    /// resolve it — spelled `newName`. Anything that does not lex is left
    /// alone: a formula Tables cannot read is kept as the file had it.
    func renamingUses(
        of name: DefinedName, to newName: String, in formula: String, from sheetID: Worksheet.ID?
    ) -> String {
        guard formula.range(of: name.name, options: .caseInsensitive) != nil,
              let tokens = try? FormulaLexer.tokenizeWithOffsets(formula) else { return formula }
        var replacements: [Range<Int>] = []
        for (position, entry) in tokens.enumerated() {
            guard case .identifier(let word) = entry.token,
                  word.compare(name.name, options: .caseInsensitive) == .orderedSame else { continue }
            // A function, or a table's columns, not a name.
            if position + 1 < tokens.count {
                switch tokens[position + 1].token {
                case .leftParenthesis, .bracket: continue
                default: break
                }
            }
            var scope = sheetID
            if position >= 2, tokens[position - 1].token == .bang {
                switch tokens[position - 2].token {
                case .identifier(let sheetName), .quotedName(let sheetName):
                    guard let qualified = sheet(named: sheetName) else { continue }
                    scope = qualified.id
                default:
                    continue
                }
            }
            guard let resolved = definedName(word, visibleFrom: scope),
                  resolved.matches(name.name, scope: name.scope) else { continue }
            replacements.append(entry.range)
        }
        guard !replacements.isEmpty else { return formula }
        var characters = Array(formula)
        for range in replacements.reversed() {
            characters.replaceSubrange(range, with: Array(newName))
        }
        return String(characters)
    }
}

/// The word being typed at the caret in a formula, for offering functions
/// and names that complete it.
public enum FormulaCompletion {
    public struct Word: Hashable, Sendable {
        /// What has been typed of it so far.
        public var prefix: String
        /// Its character offsets in the text, the `=` included.
        public var range: Range<Int>
    }

    /// The function or name being typed just before `caret` (a character
    /// offset; the end of the text when nil). Nil outside a formula, inside a
    /// string or a quoted sheet name, after a sheet's `!`, or where what is
    /// typed cannot start a name.
    public static func word(in text: String, caret: Int? = nil) -> Word? {
        let characters = Array(text)
        let end = min(caret ?? characters.count, characters.count)
        guard characters.first == "=", end > 1 else { return nil }
        // An open string or quoted sheet name is not the place.
        var inString = false, inQuote = false
        for character in characters[1..<end] {
            if character == "\"", !inQuote { inString.toggle() }
            if character == "'", !inString { inQuote.toggle() }
        }
        guard !inString, !inQuote else { return nil }

        var start = end
        while start > 1 {
            let character = characters[start - 1]
            guard character.isLetter || character.isNumber || character == "_" || character == "."
                || character == "\\" else { break }
            start -= 1
        }
        guard start < end else { return nil }
        let first = characters[start]
        guard first.isLetter || first == "_" || first == "\\" else { return nil }
        // `Sheet1!Na…` names a sheet's cell or name; `[…` a table's column.
        if start > 1, characters[start - 1] == "!" || characters[start - 1] == "[" || characters[start - 1] == "$" {
            return nil
        }
        return Word(prefix: String(characters[start..<end]), range: start..<end)
    }

    /// `text` with `word` replaced by `completion`, and the caret's offset
    /// after it.
    public static func replacing(_ word: Word, with completion: String, in text: String) -> (text: String, caret: Int) {
        var characters = Array(text)
        guard word.range.upperBound <= characters.count else { return (text, characters.count) }
        characters.replaceSubrange(word.range, with: Array(completion))
        return (String(characters), word.range.lowerBound + completion.count)
    }
}
