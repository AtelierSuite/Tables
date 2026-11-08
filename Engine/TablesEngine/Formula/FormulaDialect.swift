import Foundation

/// Converts formula text between how a person writes it and how Excel stores it.
///
/// Functions added after the 2007 file format carry an `_xlfn.` prefix in the
/// file (`_xlfn._xlws.` for a few), LET and LAMBDA names carry `_xlpm.`, and the
/// `@` and `#` operators are stored as `_xlfn.SINGLE(…)` and
/// `_xlfn.ANCHORARRAY(…)`. Without them Excel reads the formula as calling an
/// unknown add-in and shows `#NAME?`.
///
/// Both directions splice the original text rather than reprinting a parse
/// tree, so spacing, casing and anything unrecognised survive untouched. Text
/// that does not parse is passed through as it is.
public enum FormulaDialect {
    /// Functions stored with `_xlfn.`, from Excel 2010 onwards.
    public static let futureFunctions: Set<String> = [
        // Excel 2010
        "AGGREGATE", "BETA.DIST", "BETA.INV", "BINOM.DIST", "BINOM.INV", "CEILING.PRECISE", "CHISQ.DIST",
        "CHISQ.DIST.RT", "CHISQ.INV", "CHISQ.INV.RT", "CHISQ.TEST", "CONFIDENCE.NORM", "CONFIDENCE.T",
        "COVARIANCE.P", "COVARIANCE.S", "ERF.PRECISE", "ERFC.PRECISE", "EXPON.DIST", "F.DIST", "F.DIST.RT",
        "F.INV", "F.INV.RT", "F.TEST", "FLOOR.PRECISE", "GAMMA.DIST", "GAMMA.INV", "GAMMALN.PRECISE",
        "HYPGEOM.DIST", "ISO.CEILING", "LOGNORM.DIST", "LOGNORM.INV", "MODE.MULT", "MODE.SNGL", "NEGBINOM.DIST",
        "NETWORKDAYS.INTL", "NORM.DIST", "NORM.INV", "NORM.S.DIST", "NORM.S.INV", "PERCENTILE.EXC",
        "PERCENTILE.INC", "PERCENTRANK.EXC", "PERCENTRANK.INC", "POISSON.DIST", "QUARTILE.EXC", "QUARTILE.INC",
        "RANK.AVG", "RANK.EQ", "STDEV.P", "STDEV.S", "T.DIST", "T.DIST.2T", "T.DIST.RT", "T.INV", "T.INV.2T",
        "T.TEST", "VAR.P", "VAR.S", "WEIBULL.DIST", "WORKDAY.INTL", "Z.TEST",
        // Excel 2013
        "ACOT", "ACOTH", "ARABIC", "BASE", "BINOM.DIST.RANGE", "BITAND", "BITLSHIFT", "BITOR", "BITRSHIFT",
        "BITXOR", "CEILING.MATH", "COMBINA", "COT", "COTH", "CSC", "CSCH", "DAYS", "DECIMAL", "ENCODEURL",
        "FILTERXML", "FLOOR.MATH", "FORMULATEXT", "GAMMA", "GAUSS", "IFNA", "IMCOSH", "IMCOT", "IMCSC",
        "IMCSCH", "IMSEC", "IMSECH", "IMSINH", "IMTAN", "ISFORMULA", "ISOWEEKNUM", "MUNIT", "NUMBERVALUE",
        "PDURATION", "PERMUTATIONA", "PHI", "RRI", "SEC", "SECH", "SHEET", "SHEETS", "SKEW.P", "UNICHAR",
        "UNICODE", "WEBSERVICE", "XOR",
        // Excel 2016 and 2019
        "FORECAST.ETS", "FORECAST.ETS.CONFINT", "FORECAST.ETS.SEASONALITY", "FORECAST.ETS.STAT",
        "FORECAST.LINEAR", "CONCAT", "IFS", "MAXIFS", "MINIFS", "SWITCH", "TEXTJOIN",
        // Microsoft 365
        "ANCHORARRAY", "ARRAYTOTEXT", "BYCOL", "BYROW", "CHOOSECOLS", "CHOOSEROWS", "DETECTLANGUAGE", "DROP",
        "EXPAND", "FILTER", "GROUPBY", "HSTACK", "IMAGE", "ISOMITTED", "LAMBDA", "LET", "MAKEARRAY", "MAP",
        "PERCENTOF", "PIVOTBY", "RANDARRAY", "REDUCE", "REGEXEXTRACT", "REGEXREPLACE", "REGEXTEST", "SCAN",
        "SEQUENCE", "SINGLE", "SORT", "SORTBY", "STOCKHISTORY", "TAKE", "TEXTAFTER", "TEXTBEFORE", "TEXTSPLIT",
        "TOCOL", "TOROW", "TRANSLATE", "TRIMRANGE", "UNIQUE", "VALUETOTEXT", "VSTACK", "WRAPCOLS", "WRAPROWS",
        "XLOOKUP", "XMATCH",
    ]

    /// Functions that take a LAMBDA, to which a function may be passed by name.
    public static let lambdaTakingFunctions: Set<String> = [
        "GROUPBY", "PIVOTBY", "MAP", "REDUCE", "SCAN", "BYROW", "BYCOL", "MAKEARRAY",
    ]

    /// The handful that also carry `_xlws.`, after `_xlfn.`.
    public static let worksheetFunctions: Set<String> = ["FILTER", "SORT"]

    // MARK: - Reading

    /// Rewrites a formula read from a file into the form a person types.
    public static func fromFile(_ formula: String) -> String {
        guard formula.localizedCaseInsensitiveContains("_xl"),
              let syntax = try? FormulaParser.parseSyntax(formula) else { return formula }
        let characters = Array(formula)
        var edits: [Edit] = []
        collectReadEdits(syntax, characters: characters, into: &edits)
        return apply(edits, to: characters)
    }

    private static func collectReadEdits(_ syntax: FormulaSyntax, characters: [Character], into edits: inout [Edit]) {
        if syntax.isGroup {
            for child in syntax.children { collectReadEdits(child, characters: characters, into: &edits) }
            return
        }
        switch syntax.node {
        case .call:
            // Strip the prefixes off a function we know; one we do not know
            // keeps them, so it goes back to the file exactly as it came.
            let word = leadingWord(in: characters, at: syntax.range.lowerBound)
            let name = FormulaParser.strippingFilePrefixes(word).uppercased()
            if word.count != name.count, FormulaFunctions.isKnown(name) {
                edits.append(Edit(range: syntax.range.lowerBound..<(syntax.range.lowerBound + word.count - name.count),
                                  replacement: ""))
            }
        case .intersect, .spill:
            // `_xlfn.SINGLE(x)` becomes `@x` and `_xlfn.ANCHORARRAY(x)` becomes
            // `x#`; the written forms already read as `@` and `#` and need nothing.
            let word = leadingWord(in: characters, at: syntax.range.lowerBound)
            let name = FormulaParser.strippingFilePrefixes(word).uppercased()
            if name == "SINGLE" || name == "ANCHORARRAY", let operand = syntax.children.first {
                let inner = fromFile(String(characters[operand.range]))
                let wrapped = isSimpleOperand(operand) ? inner : "(" + inner + ")"
                edits.append(Edit(range: syntax.range, replacement: name == "SINGLE" ? "@" + wrapped : wrapped + "#"))
                return
            }
        case .definedName:
            let word = String(characters[syntax.range]).lowercased()
            for prefix in ["_xlpm.", "_xleta."] where word.hasPrefix(prefix) {
                edits.append(Edit(range: syntax.range.lowerBound..<(syntax.range.lowerBound + prefix.count),
                                  replacement: ""))
            }
        default:
            break
        }
        for child in syntax.children { collectReadEdits(child, characters: characters, into: &edits) }
    }

    // MARK: - Writing

    /// Rewrites a formula as Excel stores it.
    ///
    /// `tableName` names the table a formula's cell sits in, which the file
    /// form of an unqualified reference such as `[@Price]` has to spell out.
    public static func toFile(_ formula: String, tableName: String? = nil) -> String {
        guard let syntax = try? FormulaParser.parseSyntax(formula) else { return formula }
        let characters = Array(formula)
        var edits: [Edit] = []
        collectWriteEdits(syntax, characters: characters, parameters: [], tableName: tableName, into: &edits)
        return apply(edits, to: characters)
    }

    /// A structured reference in the form the file format allows: always
    /// qualified, and with `@` spelled `[#This Row]`.
    private static func fileStructuredReference(table: String?, specifier: String, tableName: String?) -> String? {
        let trimmed = specifier.trimmingCharacters(in: .whitespaces)
        guard let name = table ?? tableName else { return nil }
        guard trimmed.hasPrefix("@") else { return table == nil ? name + "[" + specifier + "]" : nil }
        let rest = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
        if rest.isEmpty { return name + "[#This Row]" }
        let columns = rest.hasPrefix("[") ? rest : "[" + rest + "]"
        return name + "[[#This Row]," + columns + "]"
    }

    private static func collectWriteEdits(
        _ syntax: FormulaSyntax, characters: [Character], parameters: Set<String>, tableName: String?,
        into edits: inout [Edit]
    ) {
        var parameters = parameters
        if syntax.isGroup {
            for child in syntax.children {
                collectWriteEdits(child, characters: characters, parameters: parameters, tableName: tableName, into: &edits)
            }
            return
        }
        switch syntax.node {
        case .call(let name, let arguments):
            let word = leadingWord(in: characters, at: syntax.range.lowerBound)
            // Only bare names gain a prefix; one already written keeps its own.
            if !word.hasPrefix("_"), futureFunctions.contains(name) {
                let prefix = "_xlfn." + (worksheetFunctions.contains(name) ? "_xlws." : "")
                edits.append(Edit(range: syntax.range.lowerBound..<syntax.range.lowerBound, replacement: prefix))
            }
            // LET names its variables in every other argument; LAMBDA's are all
            // but the last. Both are visible to the arguments after them.
            if name == "LET" {
                for (position, argument) in arguments.enumerated() where position % 2 == 0 && position < arguments.count - 1 {
                    if case .definedName(nil, let variable) = argument { parameters.insert(variable.lowercased()) }
                }
            } else if name == "LAMBDA" {
                for argument in arguments.dropLast() {
                    if case .definedName(nil, let variable) = argument { parameters.insert(variable.lowercased()) }
                }
            }
            // A function passed by name to one that takes a LAMBDA is stored
            // with `_xleta.`; anywhere else the same word is a defined name.
            if lambdaTakingFunctions.contains(name) {
                for child in syntax.children where !child.isGroup {
                    guard case .definedName(nil, let passed) = child.node, FormulaFunctions.isKnown(passed),
                          !parameters.contains(passed.lowercased()),
                          !String(characters[child.range]).hasPrefix("_") else { continue }
                    edits.append(Edit(range: child.range.lowerBound..<child.range.lowerBound, replacement: "_xleta."))
                }
            }
        case .structured(let table, let specifier):
            if let written = fileStructuredReference(table: table, specifier: specifier, tableName: tableName) {
                edits.append(Edit(range: syntax.range, replacement: written))
            }
            return
        case .intersect:
            if characters[syntax.range.lowerBound] == "@", let operand = syntax.children.first {
                edits.append(Edit(range: syntax.range,
                                  replacement: "_xlfn.SINGLE(" + toFile(String(characters[operand.range]), tableName: tableName) + ")"))
                return
            }
        case .spill:
            if characters[syntax.range.upperBound - 1] == "#", let operand = syntax.children.first {
                edits.append(Edit(range: syntax.range,
                                  replacement: "_xlfn.ANCHORARRAY(" + toFile(String(characters[operand.range]), tableName: tableName) + ")"))
                return
            }
        case .definedName(nil, let variable) where parameters.contains(variable.lowercased()):
            if !String(characters[syntax.range]).lowercased().hasPrefix("_xlpm.") {
                edits.append(Edit(range: syntax.range.lowerBound..<syntax.range.lowerBound, replacement: "_xlpm."))
            }

        default:
            break
        }
        for child in syntax.children {
            collectWriteEdits(child, characters: characters, parameters: parameters, tableName: tableName, into: &edits)
        }
    }

    /// Whether `@` or `#` can sit against an operand without parentheses.
    private static func isSimpleOperand(_ syntax: FormulaSyntax) -> Bool {
        if syntax.isGroup || syntax.children.isEmpty { return true }
        if case .call = syntax.node { return true }
        return false
    }

    // MARK: - Implicit intersection

    /// Rewrites a formula saved by Excel before dynamic arrays into the
    /// equivalent dynamic-array formula, by putting `@` wherever the old
    /// engine would have intersected a range with the formula's own row or
    /// column. This is what Excel itself shows when it opens such a file.
    ///
    /// `isRangeName` says whether a defined name stands for more than one cell.
    public static func legacyToDynamic(_ formula: String, isRangeName: (String) -> Bool = { _ in false }) -> String {
        guard let syntax = try? FormulaParser.parseSyntax(formula) else { return formula }
        var edits: [Edit] = []
        collectIntersections(syntax, context: .value, isRangeName: isRangeName, into: &edits)
        return apply(edits, to: Array(formula))
    }

    /// The text to store for a formula in Excel's pre-dynamic-array form, or
    /// nil when it means something that form cannot say and has to be stored
    /// as a dynamic array.
    public static func legacyForm(_ formula: String, isRangeName: (String) -> Bool = { _ in false }) -> String? {
        guard let syntax = try? FormulaParser.parseSyntax(formula) else { return formula }
        let characters = Array(formula)
        var edits: [Edit] = []
        collectWrittenIntersections(syntax, characters: characters, into: &edits)
        let stripped = apply(edits, to: characters)
        return legacyToDynamic(stripped, isRangeName: isRangeName) == formula ? stripped : nil
    }

    private static func collectWrittenIntersections(
        _ syntax: FormulaSyntax, characters: [Character], into edits: inout [Edit]
    ) {
        if !syntax.isGroup, case .intersect = syntax.node, characters[syntax.range.lowerBound] == "@" {
            edits.append(Edit(range: syntax.range.lowerBound..<(syntax.range.lowerBound + 1), replacement: ""))
        }
        for child in syntax.children { collectWrittenIntersections(child, characters: characters, into: &edits) }
    }

    /// How the pre-dynamic-array engine evaluated an operand.
    private enum LegacyContext {
        /// One value was wanted, so a range was intersected down to one cell.
        case value
        /// A range was accepted as it was, but an expression was still worked
        /// out one value at a time.
        case reference
        /// Everything was worked out as arrays, as `SUMPRODUCT` does.
        case array
    }

    /// Parameters the old engine evaluated as whole arrays even without
    /// Ctrl+Shift+Enter.
    private static func isArrayParameter(_ name: String, _ index: Int) -> Bool {
        switch name {
        case "SUMPRODUCT", "MMULT", "MDETERM", "MINVERSE", "TRANSPOSE", "FREQUENCY", "TREND", "GROWTH", "LINEST",
             "LOGEST", "SUMX2MY2", "SUMX2PY2", "SUMXMY2", "CORREL", "PEARSON", "RSQ", "SLOPE", "INTERCEPT",
             "STEYX", "COVAR", "FORECAST", "PROB", "TTEST", "FTEST", "CHITEST":
            return true
        case "LOOKUP": return index >= 1
        case "AGGREGATE": return index >= 2
        default: return false
        }
    }

    /// Arguments that are the result in a value position, so they inherit it.
    private static func isResultParameter(_ name: String, _ index: Int, count: Int) -> Bool {
        switch name {
        case "IF": return index >= 1
        case "IFERROR", "IFNA": return true
        case "CHOOSE": return index >= 1
        case "IFS": return index % 2 == 1
        case "SWITCH": return index >= 2 && (index % 2 == 0 || index == count - 1)
        default: return false
        }
    }

    /// Functions whose answer can be a range, so `@` goes in front of the call.
    private static let referenceFunctions: Set<String> = ["OFFSET", "INDIRECT"]

    private static func collectIntersections(
        _ syntax: FormulaSyntax, context: LegacyContext, isRangeName: (String) -> Bool, into edits: inout [Edit]
    ) {
        func mark() { edits.append(Edit(range: syntax.range.lowerBound..<syntax.range.lowerBound, replacement: "@")) }
        func visitChildren(_ context: LegacyContext) {
            for child in syntax.children {
                collectIntersections(child, context: context, isRangeName: isRangeName, into: &edits)
            }
        }
        if syntax.isGroup { return visitChildren(context) }
        switch syntax.node {
        case .range(_, let start, let end) where start != end:
            if context == .value { mark() }
        case .definedName(_, let name):
            if context == .value, isRangeName(name) { mark() }
        case .structured(_, let specifier):
            // A column is a range, intersected like any other; `@` and
            // `#This Row` already name one cell.
            let lowered = specifier.lowercased()
            if context == .value, !lowered.hasPrefix("@"), !lowered.contains("#this row") { mark() }
        case .binary(":", _, _), .binary(" ", _, _), .union, .intersect, .spill, .array, .invoke, .sheetSpan:
            break
        case .binary, .unary, .postfixPercent:
            visitChildren(context == .array ? .array : .value)
        case .call(let name, let arguments):
            if context == .value, referenceFunctions.contains(name) { mark() }
            if context == .array { return visitChildren(.array) }
            let spec = FormulaFunctions.registry[name]
            for (index, child) in syntax.children.enumerated() {
                let parameter: LegacyContext
                if isArrayParameter(name, index) {
                    parameter = .array
                } else if context == .value, isResultParameter(name, index, count: arguments.count) {
                    parameter = .value
                } else if spec?.lifts.contains(index) == true {
                    parameter = .value
                } else {
                    parameter = .reference
                }
                collectIntersections(child, context: parameter, isRangeName: isRangeName, into: &edits)
            }
        default:
            break
        }
    }

    // MARK: - Splicing

    private struct Edit {
        var range: Range<Int>
        var replacement: String
    }

    /// Applies non-overlapping edits, last first so earlier offsets stay valid.
    private static func apply(_ edits: [Edit], to characters: [Character]) -> String {
        var result = characters
        for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            result.replaceSubrange(edit.range, with: Array(edit.replacement))
        }
        return String(result)
    }

    /// The identifier starting at `offset`, prefixes and all.
    private static func leadingWord(in characters: [Character], at offset: Int) -> String {
        var end = offset
        while end < characters.count,
              characters[end].isLetter || characters[end].isNumber || characters[end] == "_" || characters[end] == "." {
            end += 1
        }
        return String(characters[offset..<end])
    }
}
