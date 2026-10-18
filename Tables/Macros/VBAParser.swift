import Foundation
import TablesEngine

/// Turns the source of one module into its syntax tree.
struct VBAParser {
    private var tokens: [VBASourceToken]
    private var index = 0

    static func parse(module name: String, source: String) throws -> VBAModuleSyntax {
        var parser = VBAParser(tokens: try VBALexer.tokenize(VBAPreprocessor.process(source)))
        return try parser.parseModule(named: name)
    }

    /// Parses statements on their own, as the immediate window would.
    static func parseStatements(_ source: String) throws -> [VBAStatement] {
        var parser = VBAParser(tokens: try VBALexer.tokenize(source))
        let body = try parser.parseBlock(until: [])
        guard parser.current == .end else { throw parser.error(VBASyntaxError.text("Macro.Syntax.Unexpected", parser.describe(parser.current))) }
        return body
    }

    private init(tokens: [VBASourceToken]) {
        self.tokens = tokens
    }

    // MARK: - Token helpers

    private var current: VBAToken { tokens[index].token }
    private var line: Int { tokens[index].line }

    private func peek(_ offset: Int) -> VBAToken {
        index + offset < tokens.count ? tokens[index + offset].token : .end
    }

    private func error(_ message: String) -> VBASyntaxError {
        VBASyntaxError(message: message, line: line)
    }

    private func describe(_ token: VBAToken) -> String {
        switch token {
        case .identifier(let name): return name
        case .integer(let value): return String(value)
        case .double(let value): return String(value)
        case .string(let text): return "\"\(text)\""
        case .date: return "#date#"
        case .symbol(let symbol): return symbol
        case .newline: return String(localized: "Macro.EndOfLine")
        case .end: return String(localized: "Macro.EndOfModule")
        }
    }

    private func isKeyword(_ keyword: String, _ token: VBAToken? = nil) -> Bool {
        if case .identifier(let name) = token ?? current { return name.caseInsensitiveCompare(keyword) == .orderedSame }
        return false
    }

    private func isSymbol(_ symbol: String) -> Bool { current == .symbol(symbol) }

    private mutating func advance() { if index < tokens.count - 1 { index += 1 } }

    @discardableResult
    private mutating func accept(_ keyword: String) -> Bool {
        guard isKeyword(keyword) else { return false }
        advance()
        return true
    }

    @discardableResult
    private mutating func acceptSymbol(_ symbol: String) -> Bool {
        guard isSymbol(symbol) else { return false }
        advance()
        return true
    }

    private mutating func expect(_ keyword: String) throws {
        guard accept(keyword) else { throw error(VBASyntaxError.text("Macro.Syntax.ExpectedFound", keyword, describe(current))) }
    }

    private mutating func expectSymbol(_ symbol: String) throws {
        guard acceptSymbol(symbol) else { throw error(VBASyntaxError.text("Macro.Syntax.ExpectedFound", "“\(symbol)”", describe(current))) }
    }

    private mutating func identifier() throws -> String {
        guard case .identifier(let name) = current else {
            throw error(VBASyntaxError.text("Macro.Syntax.ExpectedName", describe(current)))
        }
        advance()
        return name
    }

    private var atEndOfStatement: Bool {
        current == .newline || current == .end || isSymbol(":") || isKeyword("Else")
    }

    private mutating func skipNewlines() {
        while current == .newline || isSymbol(":") { advance() }
    }

    private mutating func skipToEndOfLine() {
        while current != .newline, current != .end { advance() }
    }

    // MARK: - Module

    private mutating func parseModule(named name: String) throws -> VBAModuleSyntax {
        var module = VBAModuleSyntax(name: name)
        while true {
            skipNewlines()
            if current == .end { break }
            let startLine = line

            if accept("Option") {
                if accept("Explicit") { module.optionExplicit = true }
                else if accept("Base") {
                    guard case .integer(let base) = current else { throw error(VBASyntaxError.text("Macro.Syntax.OptionBase")) }
                    module.optionBase = base
                    advance()
                } else if accept("Compare") {
                    module.optionCompareText = isKeyword("Text")
                    advance()
                } else {
                    skipToEndOfLine()
                }
                continue
            }
            if isKeyword("Attribute") || isKeyword("Implements") || isKeyword("DefInt") || isKeyword("DefLng")
                || isKeyword("DefStr") || isKeyword("DefDbl") || isKeyword("DefBool") || isKeyword("DefVar") {
                skipToEndOfLine()
                continue
            }

            var isPrivate = false
            var sawVisibility = false
            if accept("Private") { isPrivate = true; sawVisibility = true }
            else if accept("Public") || accept("Global") || accept("Friend") { sawVisibility = true }
            let isStatic = accept("Static")

            if isKeyword("Sub") || isKeyword("Function") || isKeyword("Property") {
                module.procedures.append(try parseProcedure(isPrivate: isPrivate, isStatic: isStatic, line: startLine))
            } else if accept("Declare") {
                accept("PtrSafe")
                guard accept("Sub") || accept("Function") else { throw error(VBASyntaxError.text("Macro.Syntax.ExpectedSubOrFunction")) }
                module.externalProcedures.insert(try identifier().lowercased())
                skipToEndOfLine()
            } else if accept("Type") {
                module.types.append(try parseUserType())
            } else if accept("Enum") {
                module.enums.append(try parseEnum())
            } else if accept("Event") {
                module.events.insert(try identifier().lowercased())
                skipToEndOfLine()
            } else if accept("Const") {
                for (constantName, value) in try parseConstants() {
                    module.constants.append((constantName, value, isPrivate))
                }
            } else if accept("Dim") || sawVisibility || isStatic {
                for declaration in try parseDeclarations() {
                    module.variables.append((declaration, isPrivate))
                }
            } else {
                throw error(VBASyntaxError.text("Macro.Syntax.DeclarationsOnly", describe(current)))
            }
        }
        return module
    }

    private mutating func parseProcedure(isPrivate: Bool, isStatic: Bool, line startLine: Int) throws -> VBAProcedure {
        let kind: VBAProcedure.Kind
        let terminator: String
        if accept("Sub") {
            kind = .sub
            terminator = "Sub"
        } else if accept("Function") {
            kind = .function
            terminator = "Function"
        } else {
            try expect("Property")
            if accept("Get") { kind = .propertyGet }
            else if accept("Let") { kind = .propertyLet }
            else { try expect("Set"); kind = .propertySet }
            terminator = "Property"
        }
        let name = try identifier()
        var parameters: [VBAParameter] = []
        if acceptSymbol("(") {
            if !isSymbol(")") {
                repeat { parameters.append(try parseParameter()) } while acceptSymbol(",")
            }
            try expectSymbol(")")
        }
        var returnType: VBATypeName?
        if accept("As") { returnType = try parseTypeName() }
        let body = try parseBlock(until: ["End " + terminator])
        try expect("End")
        try expect(terminator)
        return VBAProcedure(
            name: name, kind: kind, isPrivate: isPrivate, isStatic: isStatic, parameters: parameters,
            returnType: returnType, body: body, line: startLine
        )
    }

    private mutating func parseParameter() throws -> VBAParameter {
        let isOptional = accept("Optional")
        var isByVal = false
        if accept("ByVal") { isByVal = true } else { accept("ByRef") }
        let isParamArray = accept("ParamArray")
        let name = try identifier()
        var isArray = false
        if acceptSymbol("(") {
            try expectSymbol(")")
            isArray = true
        }
        var type: VBATypeName?
        if accept("As") { type = try parseTypeName() }
        var defaultValue: VBAExpression?
        if acceptSymbol("=") { defaultValue = try parseExpression() }
        return VBAParameter(
            name: name, type: type, isByVal: isByVal, isOptional: isOptional || isParamArray,
            isParamArray: isParamArray, isArray: isArray || isParamArray, defaultValue: defaultValue
        )
    }

    private mutating func parseTypeName() throws -> VBATypeName {
        let isNew = accept("New")
        var name = try identifier()
        // `Excel.Range`, `Scripting.Dictionary`: the library prefix adds nothing.
        while acceptSymbol(".") { name = try identifier() }
        // `String * 20`, a fixed-length string, is treated as any string.
        if acceptSymbol("*") { _ = try parseUnary() }
        return VBATypeName(name: name, isNew: isNew)
    }

    private mutating func parseUserType() throws -> VBAUserType {
        let name = try identifier()
        var fields: [VBAVariableDeclaration] = []
        while true {
            skipNewlines()
            if accept("End") {
                try expect("Type")
                break
            }
            guard current != .end else { throw error(VBASyntaxError.text("Macro.Syntax.MissingEnd", "Type \(name)", "End Type")) }
            fields.append(try parseDeclarator())
        }
        return VBAUserType(name: name, fields: fields)
    }

    private mutating func parseEnum() throws -> (name: String, members: [(String, VBAExpression?)]) {
        let name = try identifier()
        var members: [(String, VBAExpression?)] = []
        while true {
            skipNewlines()
            if accept("End") {
                try expect("Enum")
                break
            }
            guard current != .end else { throw error(VBASyntaxError.text("Macro.Syntax.MissingEnd", "Enum \(name)", "End Enum")) }
            let member = try identifier()
            members.append((member, acceptSymbol("=") ? try parseExpression() : nil))
        }
        return (name, members)
    }

    private mutating func parseConstants() throws -> [(String, VBAExpression)] {
        var constants: [(String, VBAExpression)] = []
        repeat {
            let name = try identifier()
            if accept("As") { _ = try parseTypeName() }
            try expectSymbol("=")
            constants.append((name, try parseExpression()))
        } while acceptSymbol(",")
        return constants
    }

    private mutating func parseDeclarations() throws -> [VBAVariableDeclaration] {
        var declarations: [VBAVariableDeclaration] = []
        repeat { declarations.append(try parseDeclarator()) } while acceptSymbol(",")
        return declarations
    }

    private mutating func parseDeclarator() throws -> VBAVariableDeclaration {
        let isWithEvents = accept("WithEvents")
        let name = try identifier()
        var bounds: [VBABound]?
        if acceptSymbol("(") {
            bounds = isSymbol(")") ? [] : try parseBounds()
            try expectSymbol(")")
        }
        var type: VBATypeName?
        if accept("As") { type = try parseTypeName() }
        var declaration = VBAVariableDeclaration(name: name, type: type, bounds: bounds)
        declaration.isWithEvents = isWithEvents
        return declaration
    }

    private mutating func parseBounds() throws -> [VBABound] {
        var bounds: [VBABound] = []
        repeat {
            let first = try parseExpression()
            if accept("To") {
                bounds.append(VBABound(lower: first, upper: try parseExpression()))
            } else {
                bounds.append(VBABound(lower: nil, upper: first))
            }
        } while acceptSymbol(",")
        return bounds
    }

    // MARK: - Blocks

    /// Statements up to, but not including, a line opening with one of
    /// `terminators` — each one or two keywords, such as `"End If"` or `"Next"`.
    private mutating func parseBlock(until terminators: [String]) throws -> [VBAStatement] {
        var statements: [VBAStatement] = []
        while true {
            skipNewlines()
            if current == .end {
                guard terminators.isEmpty else { throw error(VBASyntaxError.text("Macro.Syntax.ExpectedBeforeEnd", terminators[0])) }
                return statements
            }
            if terminators.contains(where: atTerminator) { return statements }
            // A label: a name and a colon opening the line, or a line number.
            let startsLine = index == 0 || tokens[index - 1].token == .newline
            if startsLine, case .identifier(let name) = current, peek(1) == .symbol(":") {
                statements.append(VBAStatement(kind: .label(name.lowercased()), line: line))
                advance()
                advance()
                continue
            }
            if startsLine, case .integer(let number) = current {
                statements.append(VBAStatement(kind: .label(String(number)), line: line))
                advance()
                continue
            }
            statements.append(contentsOf: try parseStatement())
        }
    }

    private func atTerminator(_ terminator: String) -> Bool {
        let words = terminator.split(separator: " ").map(String.init)
        for (offset, word) in words.enumerated() where !isKeyword(word, peek(offset)) { return false }
        return true
    }

    /// One statement, or the several of a single-line `If`.
    private mutating func parseStatement() throws -> [VBAStatement] {
        let startLine = line
        func statement(_ kind: VBAStatement.Kind) -> [VBAStatement] { [VBAStatement(kind: kind, line: startLine)] }

        if accept("Dim") { return statement(.declare(try parseDeclarations(), isStatic: false)) }
        if accept("Static") { return statement(.declare(try parseDeclarations(), isStatic: true)) }
        if accept("Const") {
            return try parseConstants().map { VBAStatement(kind: .constant($0.0, $0.1), line: startLine) }
        }
        if (isKeyword("Private") || isKeyword("Public")) && isKeyword("Const", peek(1)) {
            advance()
            advance()
            return try parseConstants().map { VBAStatement(kind: .constant($0.0, $0.1), line: startLine) }
        }
        if accept("ReDim") {
            let preserve = accept("Preserve")
            var targets: [(VBAExpression, [VBABound])] = []
            repeat {
                let name = try identifier()
                try expectSymbol("(")
                let bounds = try parseBounds()
                try expectSymbol(")")
                if accept("As") { _ = try parseTypeName() }
                targets.append((.identifier(name), bounds))
            } while acceptSymbol(",")
            return statement(.redim(preserve: preserve, targets))
        }
        if accept("Set") {
            let target = try parsePostfix(statementStart: false)
            try expectSymbol("=")
            return statement(.assign(target: target, value: try parseExpression(), isSet: true))
        }
        if accept("Let") {
            let target = try parsePostfix(statementStart: false)
            try expectSymbol("=")
            return statement(.assign(target: target, value: try parseExpression(), isSet: false))
        }
        if accept("Call") {
            let target = try parsePostfix(statementStart: false)
            return statement(.call(target))
        }
        if accept("If") { return try parseIf(line: startLine) }
        if accept("Select") {
            try expect("Case")
            return statement(try parseSelect())
        }
        if accept("For") { return statement(try parseFor()) }
        if accept("Do") { return statement(try parseDo()) }
        if accept("While") {
            let condition = try parseExpression()
            let body = try parseBlock(until: ["Wend", "End While"])
            if !accept("Wend") { try expect("End"); try expect("While") }
            return statement(.doLoop(condition: condition, isUntil: false, testsFirst: true, body: body))
        }
        if accept("With") {
            let object = try parseExpression()
            let body = try parseBlock(until: ["End With"])
            try expect("End")
            try expect("With")
            return statement(.with(object, body))
        }
        if accept("Exit") {
            let word = try identifier()
            guard let kind = VBAExitKind.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(word) == .orderedSame })
            else { throw error(VBASyntaxError.text("Macro.Syntax.CannotExit", word)) }
            return statement(.exit(kind))
        }
        if accept("GoTo") { return statement(.goTo(try labelName())) }
        if accept("GoSub") { return statement(.goSub(try labelName())) }
        if accept("Return") { return statement(.returnFromGoSub) }
        if isKeyword("On"), isKeyword("Error", peek(1)) {
            advance()
            advance()
            if accept("Resume") {
                try expect("Next")
                return statement(.onError(.resumeNext))
            }
            try expect("GoTo")
            if case .integer(0) = current {
                advance()
                return statement(.onError(.disabled))
            }
            if isSymbol("-") {
                // `On Error GoTo -1` clears the current error; close enough.
                advance()
                advance()
                return statement(.onError(.disabled))
            }
            return statement(.onError(.goTo(try labelName())))
        }
        if accept("Resume") {
            if accept("Next") { return statement(.resume(.next)) }
            if atEndOfStatement { return statement(.resume(.same)) }
            if case .integer(0) = current {
                advance()
                return statement(.resume(.same))
            }
            return statement(.resume(.label(try labelName())))
        }
        if accept("Erase") {
            var targets: [VBAExpression] = []
            repeat { targets.append(try parsePostfix(statementStart: false)) } while acceptSymbol(",")
            return statement(.erase(targets))
        }
        if accept("Stop") { return statement(.stop) }
        if isKeyword("End"), atEndOfStatementAfterOne { advance(); return statement(.end) }
        if isKeyword("Debug"), peek(1) == .symbol("."), isKeyword("Print", peek(2)) {
            advance()
            advance()
            advance()
            return statement(.debugPrint(try parsePrintList()))
        }
        if isKeyword("Debug"), peek(1) == .symbol("."), isKeyword("Assert", peek(2)) {
            advance()
            advance()
            advance()
            return statement(.call(.call(.identifier("__DebugAssert"), [VBAArgument(value: try parseExpression())])))
        }
        // Statements with syntax of their own. A name followed by `=` or `.`
        // is a variable or object that happens to share the word.
        if case .identifier(let word) = current, peek(1) != .symbol("="), peek(1) != .symbol("."),
           let kind = try parseKeywordStatement(word.lowercased()) {
            return statement(kind)
        }

        // An assignment, or a call written without `Call` and without
        // parentheses around its arguments.
        let target = try parsePostfix(statementStart: true)
        if acceptSymbol("=") {
            return statement(.assign(target: target, value: try parseExpression(), isSet: false))
        }
        if atEndOfStatement { return statement(.call(target)) }
        let arguments = try parseArgumentList(closing: nil)
        return statement(.call(.call(target, arguments)))
    }

    /// The statements whose syntax is not that of a call: file I/O with its
    /// `#` numbers, `LSet`/`RSet`, `RaiseEvent`. Nil for any other word.
    private mutating func parseKeywordStatement(_ word: String) throws -> VBAStatement.Kind? {
        switch word {
        case "open":
            advance()
            let path = try parseExpression()
            try expect("For")
            let modeWord = try identifier().lowercased()
            guard let mode = VBAFileMode(rawValue: modeWord) else {
                throw error(VBASyntaxError.text("Macro.Syntax.ExpectedFound", "Input, Output, Append, Binary, Random", modeWord))
            }
            // Access and locking are accepted and ignored: nothing else
            // shares the working folder while a macro runs.
            if accept("Access") {
                if accept("Read") { accept("Write") } else { try expect("Write") }
            }
            if !accept("Shared"), accept("Lock") {
                if accept("Read") { accept("Write") } else { try expect("Write") }
            }
            try expect("As")
            let number = try parseFileNumber()
            var recordLength: VBAExpression?
            if accept("Len") {
                try expectSymbol("=")
                recordLength = try parseExpression()
            }
            return .file(.open(path: path, mode: mode, number: number, recordLength: recordLength))
        case "close":
            advance()
            var numbers: [VBAExpression] = []
            while !atEndOfStatement {
                numbers.append(try parseFileNumber())
                if !acceptSymbol(",") { break }
            }
            return .file(.close(numbers))
        case "print":
            advance()
            let number = try parseFileNumber()
            if !atEndOfStatement { try expectSymbol(",") }
            return .file(.print(number: number, items: try parsePrintList()))
        case "write":
            advance()
            let number = try parseFileNumber()
            var items: [VBAExpression?] = []
            if !atEndOfStatement {
                try expectSymbol(",")
                while !atEndOfStatement {
                    if isSymbol(",") || isSymbol(";") {
                        advance()
                        continue
                    }
                    items.append(try parseExpression())
                }
            }
            return .file(.write(number: number, items: items))
        case "input":
            guard peek(1) == .symbol("#") else { return nil }
            advance()
            let number = try parseFileNumber()
            try expectSymbol(",")
            var targets: [VBAExpression] = []
            repeat { targets.append(try parsePostfix(statementStart: false)) } while acceptSymbol(",")
            return .file(.input(number: number, targets: targets))
        case "line":
            guard isKeyword("Input", peek(1)) else { return nil }
            advance()
            advance()
            let number = try parseFileNumber()
            try expectSymbol(",")
            return .file(.lineInput(number: number, target: try parsePostfix(statementStart: false)))
        case "get", "put":
            advance()
            let number = try parseFileNumber()
            try expectSymbol(",")
            let record = isSymbol(",") ? nil : try parseExpression()
            try expectSymbol(",")
            if word == "get" {
                return .file(.get(number: number, record: record, target: try parsePostfix(statementStart: false)))
            }
            return .file(.put(number: number, record: record, value: try parseExpression()))
        case "seek":
            advance()
            let number = try parseFileNumber()
            try expectSymbol(",")
            return .file(.seek(number: number, position: try parseExpression()))
        case "lock", "unlock":
            advance()
            let number = try parseFileNumber()
            // An optional record or `start To end`, which changes nothing here.
            if acceptSymbol(",") {
                _ = try parseExpression()
                if accept("To") { _ = try parseExpression() }
            }
            return .file(.lock(number: number))
        case "width":
            advance()
            let number = try parseFileNumber()
            try expectSymbol(",")
            return .file(.width(number: number, width: try parseExpression()))
        case "name":
            advance()
            let from = try parseExpression()
            try expect("As")
            return .file(.rename(from: from, to: try parseExpression()))
        case "lset", "rset":
            advance()
            let target = try parsePostfix(statementStart: false)
            try expectSymbol("=")
            return .alignedAssign(target: target, value: try parseExpression(), isRight: word == "rset")
        case "raiseevent":
            advance()
            let name = try identifier()
            var arguments: [VBAArgument] = []
            if acceptSymbol("(") {
                arguments = try parseArgumentList(closing: ")")
                try expectSymbol(")")
            }
            return .raiseEvent(name, arguments)
        case "load", "unload":
            advance()
            while !atEndOfStatement { advance() }
            return .unsupported(String(localized: "Macro.Unavailable.UserForms"))
        default:
            return nil
        }
    }

    /// A file number, with or without the `#` VBA lets it carry.
    private mutating func parseFileNumber() throws -> VBAExpression {
        acceptSymbol("#")
        return try parseExpression()
    }

    private var atEndOfStatementAfterOne: Bool {
        let next = peek(1)
        return next == .newline || next == .end || next == .symbol(":")
    }

    private mutating func labelName() throws -> String {
        if case .integer(let number) = current {
            advance()
            return String(number)
        }
        return try identifier().lowercased()
    }

    private mutating func parsePrintList() throws -> [VBAPrintItem] {
        var items: [VBAPrintItem] = []
        while !atEndOfStatement {
            if isSymbol(";") || isSymbol(",") {
                items.append(.separator(isSymbol(";") ? ";" : ","))
                advance()
            } else if isKeyword("Spc"), peek(1) == .symbol("(") {
                advance()
                advance()
                items.append(.spaces(try parseExpression()))
                try expectSymbol(")")
            } else if isKeyword("Tab") {
                advance()
                if acceptSymbol("(") {
                    items.append(.tab(try parseExpression()))
                    try expectSymbol(")")
                } else {
                    items.append(.tab(nil))
                }
            } else {
                items.append(.value(try parseExpression()))
            }
        }
        return items
    }

    private mutating func parseIf(line startLine: Int) throws -> [VBAStatement] {
        let condition = try parseExpression()
        try expect("Then")

        // The single-line form: everything to the end of the line.
        if current != .newline {
            let thenPart = try parseInlineStatements()
            var elsePart: [VBAStatement]?
            if accept("Else") { elsePart = try parseInlineStatements() }
            return [VBAStatement(kind: .ifBlock(branches: [(condition, thenPart)], otherwise: elsePart), line: startLine)]
        }

        var branches = [(condition, try parseBlock(until: ["ElseIf", "Else", "End If"]))]
        var otherwise: [VBAStatement]?
        while true {
            if accept("ElseIf") {
                let next = try parseExpression()
                try expect("Then")
                branches.append((next, try parseBlock(until: ["ElseIf", "Else", "End If"])))
            } else if accept("Else") {
                otherwise = try parseBlock(until: ["End If"])
            } else {
                try expect("End")
                try expect("If")
                break
            }
        }
        return [VBAStatement(kind: .ifBlock(branches: branches, otherwise: otherwise), line: startLine)]
    }

    /// The statements of a single-line `If`, separated by colons.
    private mutating func parseInlineStatements() throws -> [VBAStatement] {
        var statements: [VBAStatement] = []
        while current != .newline, current != .end, !isKeyword("Else") {
            if acceptSymbol(":") { continue }
            if case .integer(let number) = current, statements.isEmpty {
                // `If x Then 100` jumps to line 100.
                advance()
                statements.append(VBAStatement(kind: .goTo(String(number)), line: line))
                continue
            }
            statements.append(contentsOf: try parseStatement())
        }
        return statements
    }

    private mutating func parseSelect() throws -> VBAStatement.Kind {
        let subject = try parseExpression()
        var clauses: [VBACaseClause] = []
        var otherwise: [VBAStatement]?
        skipNewlines()
        while accept("Case") {
            if accept("Else") {
                otherwise = try parseBlock(until: ["Case", "End Select"])
                continue
            }
            var conditions: [VBACaseCondition] = []
            repeat {
                if accept("Is") {
                    guard case .symbol(let comparison) = current,
                          ["=", "<>", "<", ">", "<=", ">="].contains(comparison) else {
                        throw error(VBASyntaxError.text("Macro.Syntax.ExpectedCaseComparison"))
                    }
                    advance()
                    conditions.append(.comparison(comparison, try parseExpression()))
                } else if case .symbol(let comparison) = current, ["<", ">", "<=", ">=", "<>"].contains(comparison) {
                    advance()
                    conditions.append(.comparison(comparison, try parseExpression()))
                } else {
                    let low = try parseExpression()
                    if accept("To") {
                        conditions.append(.range(low, try parseExpression()))
                    } else {
                        conditions.append(.value(low))
                    }
                }
            } while acceptSymbol(",")
            clauses.append(VBACaseClause(conditions: conditions, body: try parseBlock(until: ["Case", "End Select"])))
        }
        try expect("End")
        try expect("Select")
        return .select(subject, clauses, otherwise: otherwise)
    }

    private mutating func parseFor() throws -> VBAStatement.Kind {
        if accept("Each") {
            let variable = try parsePostfix(statementStart: false)
            try expect("In")
            let collection = try parseExpression()
            let body = try parseLoopBody()
            return .forEach(variable: variable, collection: collection, body: body)
        }
        let variable = try parsePostfix(statementStart: false)
        try expectSymbol("=")
        let start = try parseExpression()
        try expect("To")
        let end = try parseExpression()
        let step = accept("Step") ? try parseExpression() : nil
        let body = try parseLoopBody()
        return .forNext(variable: variable, start: start, end: end, step: step, body: body)
    }

    /// A `For` body up to its `Next`. `Next j, i` closes two loops at once, so
    /// a `Next` naming more than one variable leaves a `Next` behind for the
    /// enclosing loop to find.
    private mutating func parseLoopBody() throws -> [VBAStatement] {
        let body = try parseBlock(until: ["Next"])
        try expect("Next")
        if case .identifier = current, !atEndOfStatement {
            advance()
            // The comma of `Next j, i` becomes the `Next` the outer loop expects.
            if isSymbol(",") { tokens[index].token = .identifier("Next") }
        }
        return body
    }

    private mutating func parseDo() throws -> VBAStatement.Kind {
        var condition: VBAExpression?
        var isUntil = false
        var testsFirst = false
        if accept("While") {
            condition = try parseExpression()
            testsFirst = true
        } else if accept("Until") {
            condition = try parseExpression()
            isUntil = true
            testsFirst = true
        }
        let body = try parseBlock(until: ["Loop"])
        try expect("Loop")
        if !testsFirst {
            if accept("While") {
                condition = try parseExpression()
            } else if accept("Until") {
                condition = try parseExpression()
                isUntil = true
            }
        }
        return .doLoop(condition: condition, isUntil: isUntil, testsFirst: testsFirst, body: body)
    }

    // MARK: - Arguments

    /// A comma-separated argument list, up to `closing` or the end of the
    /// statement. Empty slots are omitted arguments.
    private mutating func parseArgumentList(closing: String?) throws -> [VBAArgument] {
        var arguments: [VBAArgument] = []
        func atEnd() -> Bool { closing.map { isSymbol($0) } ?? atEndOfStatement }
        if atEnd() { return arguments }
        while true {
            if isSymbol(",") {
                arguments.append(VBAArgument(name: nil, value: nil))
                advance()
                if atEnd() {
                    arguments.append(VBAArgument(name: nil, value: nil))
                    break
                }
                continue
            }
            var name: String?
            if case .identifier(let candidate) = current, peek(1) == .symbol(":=") {
                name = candidate
                advance()
                advance()
            }
            // `ByVal` in a call is legal and means nothing here.
            accept("ByVal")
            arguments.append(VBAArgument(name: name, value: try parseExpression()))
            if atEnd() { break }
            try expectSymbol(",")
            if atEnd() {
                arguments.append(VBAArgument(name: nil, value: nil))
                break
            }
        }
        return arguments
    }

    // MARK: - Expressions

    private static let binaryLevels: [[String]] = [
        ["Imp"], ["Eqv"], ["Xor"], ["Or"], ["And"],
        // Not sits here, handled as a prefix between And and the comparisons.
        ["=", "<>", "<", ">", "<=", ">=", "Like", "Is"],
        ["&"], ["+", "-"], ["Mod"], ["\\"], ["*", "/"],
    ]

    private mutating func parseExpression() throws -> VBAExpression {
        try parseBinary(level: 0)
    }

    private func binaryOperator(in level: [String]) -> String? {
        switch current {
        case .symbol(let symbol) where level.contains(symbol):
            return symbol
        case .identifier(let name):
            return level.first { $0.first!.isLetter && $0.caseInsensitiveCompare(name) == .orderedSame }
        default:
            return nil
        }
    }

    private mutating func parseBinary(level: Int) throws -> VBAExpression {
        if level == Self.binaryLevels.count { return try parseUnary() }
        // Logical Not binds more loosely than comparison: `Not a = b` is `Not (a = b)`.
        if level == 5, accept("Not") {
            return .unary("Not", try parseBinary(level: 5))
        }
        var left = try parseBinary(level: level + 1)
        while let op = binaryOperator(in: Self.binaryLevels[level]) {
            advance()
            if op == "Is", accept("Nothing") {
                left = .binary("Is", left, .literal(.nothing))
                continue
            }
            let right = level == 5 && isKeyword("Not") ? try parseBinary(level: 5) : try parseBinary(level: level + 1)
            left = .binary(op, left, right)
        }
        return left
    }

    private mutating func parseUnary() throws -> VBAExpression {
        if acceptSymbol("-") { return .unary("-", try parseUnary()) }
        if acceptSymbol("+") { return try parseUnary() }
        if accept("Not") { return .unary("Not", try parseUnary()) }
        return try parsePower()
    }

    /// `^` binds tighter than negation: `-2 ^ 2` is -4.
    private mutating func parsePower() throws -> VBAExpression {
        var base = try parsePostfix(statementStart: false)
        while acceptSymbol("^") {
            let exponent: VBAExpression = acceptSymbol("-") ? .unary("-", try parsePostfix(statementStart: false))
                : try parsePostfix(statementStart: false)
            base = .binary("^", base, exponent)
        }
        return base
    }

    /// A primary followed by any run of `.member`, `(arguments)` and `!name`.
    /// At the start of a statement, a `(` after a space opens the argument
    /// list of a call written without `Call`, so it is left alone.
    private mutating func parsePostfix(statementStart: Bool) throws -> VBAExpression {
        var expression = try parsePrimary()
        while true {
            if isSymbol("."), !tokens[index].followsSpace || !statementStart {
                advance()
                expression = .member(expression, try memberName())
            } else if isSymbol("("), !(statementStart && tokens[index].followsSpace) {
                advance()
                let arguments = try parseArgumentList(closing: ")")
                try expectSymbol(")")
                expression = .call(expression, arguments)
            } else if isSymbol("!"), case .identifier(let name) = peek(1) {
                advance()
                advance()
                expression = .call(expression, [VBAArgument(value: .literal(.string(name)))])
            } else {
                return expression
            }
        }
    }

    /// After a dot any word is a member name, keywords included: `.End`, `.Select`, `.Print`.
    private mutating func memberName() throws -> String {
        guard case .identifier(let name) = current else {
            throw error(VBASyntaxError.text("Macro.Syntax.ExpectedMember", describe(current)))
        }
        advance()
        return name
    }

    private mutating func parsePrimary() throws -> VBAExpression {
        let token = current
        switch token {
        case .integer(let value):
            advance()
            return .literal(.integer(value))
        case .double(let value):
            advance()
            return .literal(.double(value))
        case .string(let text):
            advance()
            return .literal(.string(text))
        case .date(let serial):
            advance()
            return .literal(.date(serial))
        case .symbol("#"):
            // A file number inside an argument list: `Input(10, #1)`, `EOF(#1)`.
            advance()
            return try parsePrimary()
        case .symbol("("):
            advance()
            let inner = try parseExpression()
            try expectSymbol(")")
            return .parenthesized(inner)
        case .symbol("."):
            // A member of the `With` object.
            advance()
            return .member(nil, try memberName())
        case .symbol("!"):
            advance()
            return .call(.member(nil, "_Default"), [VBAArgument(value: .literal(.string(try memberName())))])
        case .identifier(let name):
            switch name.lowercased() {
            case "true": advance(); return .literal(.boolean(true))
            case "false": advance(); return .literal(.boolean(false))
            case "nothing": advance(); return .literal(.nothing)
            case "empty": advance(); return .literal(.empty)
            case "null": advance(); return .literal(.null)
            case "me": advance(); return .me
            case "new":
                advance()
                var className = try identifier()
                while acceptSymbol(".") { className = try identifier() }
                return .new(className)
            case "typeof":
                advance()
                let subject = try parsePostfix(statementStart: false)
                try expect("Is")
                var className = try identifier()
                while acceptSymbol(".") { className = try identifier() }
                return .typeOfIs(subject, className)
            case "addressof":
                advance()
                return .addressOf(try identifier())
            default:
                if Self.reservedWords.contains(name.lowercased()) {
                    throw error(VBASyntaxError.text("Macro.Syntax.Unexpected", name))
                }
                advance()
                return .identifier(name)
            }
        default:
            throw error(VBASyntaxError.text("Macro.Syntax.Unexpected", describe(token)))
        }
    }

    /// Words that can never start an operand, so meeting one mid-expression
    /// is a syntax error rather than a reference to a variable.
    private static let reservedWords: Set<String> = [
        "and", "or", "xor", "eqv", "imp", "mod", "like", "is", "then", "else", "elseif", "to", "step",
        "end", "next", "loop", "wend", "dim", "as", "case",
    ]
}

/// Handles `#If … #Else … #End If`, the conditional compilation most often
/// seen choosing between 32- and 64-bit `Declare` statements. Lines in a
/// branch not taken become blank, so line numbers stay true.
enum VBAPreprocessor {
    /// Constants as a 64-bit Office for Windows would define them: that is
    /// what most code is written and tested against.
    private static let constants: [String: Bool] = [
        "vba7": true, "vba6": true, "win64": true, "win32": true, "win16": false, "mac": false,
    ]

    static func process(_ source: String) -> String {
        var output: [String] = []
        /// For each open `#If`: whether the current branch is live, and
        /// whether any branch has been taken yet.
        var stack: [(active: Bool, taken: Bool)] = []
        var defined = constants
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parentActive = stack.allSatisfy(\.active)
            guard trimmed.hasPrefix("#") else {
                output.append(parentActive ? line : "")
                continue
            }
            let words = trimmed.dropFirst().split(separator: " ", maxSplits: 1).map(String.init)
            let keyword = words.first?.lowercased() ?? ""
            let rest = words.count > 1 ? words[1] : ""
            switch keyword {
            case "if":
                let value = parentActive && evaluate(rest, defined)
                stack.append((value, value))
            case "elseif":
                guard var top = stack.popLast() else { break }
                let outer = stack.allSatisfy(\.active)
                top.active = outer && !top.taken && evaluate(rest, defined)
                top.taken = top.taken || top.active
                stack.append(top)
            case "else":
                guard var top = stack.popLast() else { break }
                top.active = stack.allSatisfy(\.active) && !top.taken
                top.taken = true
                stack.append(top)
            case "end":
                _ = stack.popLast()
            case "const":
                let parts = rest.split(separator: "=", maxSplits: 1)
                if parentActive, parts.count == 2 {
                    defined[parts[0].trimmingCharacters(in: .whitespaces).lowercased()] = evaluate(String(parts[1]), defined)
                }
            default:
                // Not a directive after all, a date literal at the start of a line, say.
                output.append(parentActive ? line : "")
                continue
            }
            output.append("")
        }
        return output.joined(separator: "\n")
    }

    /// Conditions are names joined by `Not`, `And`, `Or` and compared with
    /// `= True`/`= False`, which covers what real projects write.
    private static func evaluate(_ condition: String, _ defined: [String: Bool]) -> Bool {
        var text = condition.lowercased()
        if let then = text.range(of: " then", options: .backwards) { text = String(text[..<then.lowerBound]) }
        let orParts = text.components(separatedBy: " or ")
        return orParts.contains { part in
            part.components(separatedBy: " and ").allSatisfy { term in
                var term = term.trimmingCharacters(in: .whitespaces)
                var negate = false
                while term.hasPrefix("not ") {
                    negate.toggle()
                    term = String(term.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                }
                term = term.trimmingCharacters(in: CharacterSet(charactersIn: "() "))
                var value: Bool
                if let equals = term.firstIndex(of: "=") {
                    let name = term[..<equals].trimmingCharacters(in: .whitespaces)
                    let compared = term[term.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                    value = (defined[name] ?? false) == (compared == "true" || compared == "-1" || compared == "1")
                } else {
                    value = defined[term] ?? (term == "true" || term == "1" || term == "-1")
                }
                if negate { value.toggle() }
                return value
            }
        }
    }
}
