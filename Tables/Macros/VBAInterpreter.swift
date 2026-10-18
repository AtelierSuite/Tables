import Foundation
import TablesEngine

/// A storage location: a variable, a parameter, a function's return value.
/// Passing one `ByRef` hands the callee this same box.
final class VBAVariable {
    var value: VBAValue
    let type: VBAType

    init(type: VBAType, value: VBAValue? = nil) {
        self.type = type
        self.value = value ?? type.defaultValue
    }

    func assign(_ newValue: VBAValue) throws {
        value = try type.coerce(VBAInterpreter.copyingRecords(newValue))
    }
}

/// What the interpreter needs from whoever runs it: the application's
/// object model, and a way to talk to the user.
protocol VBAHost: AnyObject {
    /// A member of the global namespace — `Range`, `Cells`, `ActiveSheet`,
    /// `Application` — or nil when the host has no such name.
    func globalMember(_ name: String, _ arguments: VBAArguments, in interpreter: VBAInterpreter) throws -> VBAValue?
    /// Assigns a global property, returning false when there is none by that name.
    func setGlobalMember(_ name: String, _ arguments: VBAArguments, to value: VBAValue,
                         in interpreter: VBAInterpreter) throws -> Bool
    /// The object a document module stands for: `ThisWorkbook`, `Sheet1`.
    func documentObject(codeName: String, in interpreter: VBAInterpreter) -> (any VBAObject)?
    /// The application's named constants: `xlUp`, `xlCalculationManual`.
    func constant(named name: String) -> VBAValue?
    /// `CreateObject` and `New` for classes the host provides.
    func createObject(_ className: String, in interpreter: VBAInterpreter) -> (any VBAObject)?

    func messageBox(prompt: String, buttons: Int, title: String?) -> Int
    func inputBox(prompt: String, title: String?, defaultText: String) -> String?
    func debugPrint(_ text: String)
    /// Asks the user, then opens a link a macro gave `Shell`; true when opened.
    func openURL(_ url: URL) -> Bool
    /// Shows the keys a macro tried to send with `SendKeys`.
    func showSendKeys(_ keys: String)
}

extension VBAHost {
    func openURL(_: URL) -> Bool { false }
    func showSendKeys(_: String) { /* Hosts with nowhere to show keys drop them. */ }
}

/// Control flow that unwinds through Swift's error propagation.
enum VBAControl: Error {
    case exitProcedure
    case exitFor
    case exitDo
    case goTo(String)
    case resume(VBAResumeTarget)
    /// `Return`, back to the statement after the `GoSub` that got here.
    case returnFromGoSub
    /// The `End` statement: stop everything, successfully.
    case end
    case cancelled
}

/// Runs the macros of one project against a host.
final class VBAInterpreter {
    // MARK: - Program

    final class Module {
        let syntax: VBAModuleSyntax
        let kind: VBAProject.Module.Kind
        var name: String { syntax.name }
        /// Module-level variables. A class module's are a template, copied
        /// fresh into each instance.
        var variables: [String: VBAVariable] = [:]
        var constants: [String: VBAValue] = [:]
        var procedures: [String: [VBAProcedure]] = [:]
        var types: [String: VBAUserType] = [:]
        var staticLocals: [String: [String: VBAVariable]] = [:]
        var isInitialized = false

        init(syntax: VBAModuleSyntax, kind: VBAProject.Module.Kind) {
            self.syntax = syntax
            self.kind = kind
            for procedure in syntax.procedures {
                procedures[procedure.name.lowercased(), default: []].append(procedure)
            }
            for type in syntax.types { types[type.name.lowercased()] = type }
        }

        func procedure(_ name: String, kinds: Set<VBAProcedure.Kind>) -> VBAProcedure? {
            procedures[name.lowercased()]?.first { kinds.contains($0.kind) }
        }

        func isPublicVariable(_ name: String) -> Bool {
            syntax.variables.contains { !$0.isPrivate && $0.declaration.name.caseInsensitiveCompare(name) == .orderedSame }
        }
    }

    /// One activation of a procedure.
    final class Frame {
        let module: Module
        let instance: VBAClassInstance?
        let procedure: VBAProcedure
        var locals: [String: VBAVariable] = [:]
        var withStack: [VBAValue] = []
        var errorHandling: VBAErrorHandling = .disabled
        var inHandler = false
        /// How many `GoSub`s deep this activation is, for `Return` to check.
        var goSubDepth = 0

        init(module: Module, instance: VBAClassInstance?, procedure: VBAProcedure) {
            self.module = module
            self.instance = instance
            self.procedure = procedure
        }
    }

    private(set) var modules: [Module] = []
    weak var host: (any VBAHost)?
    /// The workbook's working folder, where file statements read and write.
    /// Without one they report that files are unavailable.
    var fileSystem: VBAFileSystem?
    /// Instances alive somewhere, weakly: the ones `RaiseEvent` may need to
    /// tell through their `WithEvents` variables.
    private var liveInstances: [WeakInstance] = []

    private struct WeakInstance {
        weak var instance: VBAClassInstance?
    }
    /// Checked between statements; returning true stops the macro.
    var isCancelled: () -> Bool = { false }

    /// The state behind the `Err` object.
    var lastError: VBAError?
    private var errorObject: VBAErrObject?
    private var callDepth = 0
    private var statementCount = 0
    private static let maximumCallDepth = 400

    convenience init(project: VBAProject, host: (any VBAHost)?) throws {
        try self.init(modules: project.modules.map { ($0.name, $0.kind, $0.source) }, host: host)
    }

    init(modules sources: [(name: String, kind: VBAProject.Module.Kind, source: String)], host: (any VBAHost)?) throws {
        self.host = host
        for source in sources {
            do {
                modules.append(Module(syntax: try VBAParser.parse(module: source.name, source: source.source),
                                      kind: source.kind))
            } catch var error as VBASyntaxError {
                error.module = source.name
                throw error
            }
        }
    }

    func module(named name: String) -> Module? {
        modules.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// The macros a user can run: public parameterless `Sub`s in standard
    /// and document modules, by module.
    var runnableMacros: [(module: String, procedure: String)] {
        modules.filter { $0.kind == .standard || $0.kind == .document }.flatMap { module in
            module.syntax.procedures.filter(\.isRunnableMacro).map { (module.name, $0.name) }
        }
    }

    // MARK: - Running

    /// Runs a procedure from the outside, as the Macros dialog would.
    func run(_ procedureName: String, in moduleName: String? = nil, arguments: [VBAValue] = []) throws -> VBAValue {
        let candidates = moduleName.flatMap(module(named:)).map { [$0] } ?? modules
        for module in candidates {
            guard let procedure = module.procedure(procedureName, kinds: [.sub, .function]) else { continue }
            do {
                return try invoke(procedure, in: module, instance: nil,
                                  arguments: arguments.map { .value($0) }, named: [])
            } catch VBAControl.end {
                return .empty
            }
        }
        throw VBAError.notDefined(procedureName)
    }

    private func initialize(_ module: Module) throws {
        guard !module.isInitialized else { return }
        module.isInitialized = true
        let context = try moduleFrame(for: module)
        for constant in module.syntax.constants {
            module.constants[constant.name.lowercased()] = try evaluate(constant.value, context)
        }
        for enumeration in module.syntax.enums {
            var next = 0
            for (member, expression) in enumeration.members {
                if let expression { next = try evaluate(expression, context).asInteger() }
                module.constants[member.lowercased()] = .integer(next)
                next += 1
            }
        }
        guard module.kind != .classModule else {
            // A class's variables belong to its instances.
            return
        }
        for (declaration, _) in module.syntax.variables {
            module.variables[declaration.name.lowercased()] = try makeVariable(declaration, context)
        }
    }

    /// A frame for evaluating module-level declarations, outside any procedure.
    private func moduleFrame(for module: Module) throws -> Frame {
        Frame(module: module, instance: nil,
              procedure: VBAProcedure(name: "", kind: .sub, isPrivate: true, isStatic: false, parameters: [],
                                      returnType: nil, body: [], line: 0))
    }

    private func ensureInitialized() throws {
        for module in modules { try initialize(module) }
    }

    // MARK: - Variables

    func type(of name: VBATypeName?, in module: Module) -> VBAType {
        guard let name else { return .variant }
        let resolved = VBAType.named(name.name)
        if case .object(let className) = resolved, userType(named: className, from: module) != nil {
            return .userType(className)
        }
        return resolved
    }

    private func userType(named name: String, from module: Module) -> VBAUserType? {
        module.types[name.lowercased()] ?? modules.lazy.compactMap { $0.types[name.lowercased()] }.first
    }

    func makeVariable(_ declaration: VBAVariableDeclaration, _ frame: Frame) throws -> VBAVariable {
        let elementType = type(of: declaration.type, in: frame.module)
        if let bounds = declaration.bounds {
            guard !bounds.isEmpty else { return VBAVariable(type: .array(elementType)) }
            var array = try allocate(bounds, elementType: elementType, frame)
            array.isFixed = true
            return VBAVariable(type: .array(elementType), value: .array(array))
        }
        let variable = VBAVariable(type: elementType)
        if case .userType(let name) = elementType, let definition = userType(named: name, from: frame.module) {
            variable.value = .object(try makeRecord(definition, frame))
        }
        if declaration.type?.isNew == true, case .object(let className) = elementType {
            // `As New`: VBA creates it on first use; creating it now is
            // indistinguishable unless the macro tests it for Nothing.
            variable.value = .object(try instantiate(className))
        }
        return variable
    }

    private func allocate(_ bounds: [VBABound], elementType: VBAType, _ frame: Frame) throws -> VBAArray {
        var lower: [Int] = []
        var upper: [Int] = []
        for bound in bounds {
            lower.append(try bound.lower.map { try evaluate($0, frame).asInteger() } ?? frame.module.syntax.optionBase)
            upper.append(try evaluate(bound.upper, frame).asInteger())
        }
        var array = VBAArray(lowerBounds: lower, upperBounds: upper, elementType: elementType)
        if case .userType(let name) = elementType, let definition = userType(named: name, from: frame.module) {
            for index in array.elements.indices { array.elements[index] = .object(try makeRecord(definition, frame)) }
        }
        return array
    }

    private func makeRecord(_ definition: VBAUserType, _ frame: Frame) throws -> VBARecord {
        let record = VBARecord(typeName: definition.name)
        for field in definition.fields {
            record.fields[field.name.lowercased()] = try makeVariable(field, frame)
            record.order.append(field.name.lowercased())
        }
        return record
    }

    /// User-defined types copy on assignment, unlike objects.
    static func copyingRecords(_ value: VBAValue) -> VBAValue {
        if case .object(let object) = value, let record = object as? VBARecord { return .object(record.copy()) }
        return value
    }

    // MARK: - Calling procedures

    /// An argument on its way into a procedure: a value, or a variable
    /// passed by reference.
    enum Argument {
        case value(VBAValue)
        case reference(VBAVariable)
        case missing

        var value: VBAValue {
            switch self {
            case .value(let value): return value
            case .reference(let variable): return variable.value
            case .missing: return .missing
            }
        }
    }

    func invoke(
        _ procedure: VBAProcedure, in module: Module, instance: VBAClassInstance?,
        arguments: [Argument], named: [(String, Argument)], propertyValue: VBAValue? = nil
    ) throws -> VBAValue {
        try ensureInitialized()
        guard callDepth < Self.maximumCallDepth else { throw VBAError(number: 28, "Out of stack space") }
        callDepth += 1
        defer { callDepth -= 1 }

        let frame = Frame(module: module, instance: instance, procedure: procedure)

        // A Property Let or Set takes the assigned value as its last parameter.
        var parameters = procedure.parameters
        var valueParameter: VBAParameter?
        if propertyValue != nil, procedure.kind == .propertyLet || procedure.kind == .propertySet,
           let last = parameters.popLast() {
            valueParameter = last
        }

        var positional = arguments
        for (index, parameter) in parameters.enumerated() {
            let key = parameter.name.lowercased()
            if parameter.isParamArray {
                let rest = index < positional.count ? positional[index...].map(\.value) : []
                frame.locals[key] = VBAVariable(type: .variant, value: .array(VBAArray(Array(rest))))
                positional = Array(positional.prefix(index))
                break
            }
            var argument: Argument = index < positional.count ? positional[index] : .missing
            if let match = named.first(where: { $0.0.caseInsensitiveCompare(parameter.name) == .orderedSame }) {
                argument = match.1
            }
            if case .value(.missing) = argument { argument = .missing }
            let declared = parameter.isArray ? .array(type(of: parameter.type, in: module)) : type(of: parameter.type, in: module)
            switch argument {
            case .missing:
                guard parameter.isOptional else { throw VBAError(number: 449, "Argument not optional (\(parameter.name))") }
                if let defaultValue = parameter.defaultValue {
                    frame.locals[key] = VBAVariable(type: declared, value: try declared.coerce(try evaluate(defaultValue, frame)))
                } else {
                    frame.locals[key] = declared == .variant
                        ? VBAVariable(type: .variant, value: .missing) : VBAVariable(type: declared)
                }
            case .reference(let variable) where !parameter.isByVal:
                frame.locals[key] = variable
            default:
                let variable = VBAVariable(type: declared)
                try variable.assign(argument.value)
                frame.locals[key] = variable
            }
        }
        if positional.count > parameters.count, !(parameters.last?.isParamArray ?? false) {
            throw VBAError.wrongArgumentCount
        }
        if let valueParameter, let propertyValue {
            let variable = VBAVariable(type: type(of: valueParameter.type, in: module))
            try variable.assign(propertyValue)
            frame.locals[valueParameter.name.lowercased()] = variable
        }

        var result: VBAVariable?
        if procedure.kind == .function || procedure.kind == .propertyGet {
            let returnType = type(of: procedure.returnType, in: module)
            let variable = VBAVariable(type: returnType)
            if case .userType(let name) = returnType, let definition = userType(named: name, from: module) {
                variable.value = .object(try makeRecord(definition, frame))
            }
            frame.locals[procedure.name.lowercased()] = variable
            result = variable
        }

        do {
            try run(procedure.body, from: 0, frame)
        } catch VBAControl.exitProcedure {
            // Normal return.
        } catch VBAControl.goTo(let label) {
            throw annotate(VBAError(number: 0, "Label not defined (\(label))"), frame, line: procedure.line)
        } catch VBAControl.resume {
            throw annotate(VBAError(number: 20, "Resume without error"), frame, line: procedure.line)
        }
        return result?.value ?? .empty
    }

    private func annotate(_ error: VBAError, _ frame: Frame, line: Int) -> VBAError {
        var error = error
        if error.module == nil {
            error.module = frame.module.name
            error.line = line
        }
        return error
    }

    // MARK: - Statements

    private func labelIndex(_ label: String, in block: [VBAStatement]) -> Int? {
        block.firstIndex { if case .label(let name) = $0.kind { return name == label } else { return false } }
    }

    func run(_ block: [VBAStatement], from start: Int, _ frame: Frame) throws {
        var position = start
        while position < block.count {
            let statement = block[position]
            do {
                try execute(statement, frame)
                position += 1
            } catch VBAControl.goTo(let label) {
                guard let target = labelIndex(label, in: block) else { throw VBAControl.goTo(label) }
                position = target + 1
            } catch let error as VBAError {
                let error = annotate(error, frame, line: statement.line)
                if frame.inHandler { throw error }
                switch frame.errorHandling {
                case .disabled:
                    throw error
                case .resumeNext:
                    setError(error)
                    position += 1
                case .goTo(let label):
                    setError(error)
                    frame.inHandler = true
                    let target = try runHandler(label, frame)
                    frame.inHandler = false
                    switch target {
                    case .same:
                        continue
                    case .next:
                        position += 1
                    case .label(let resumeLabel):
                        guard let index = labelIndex(resumeLabel, in: block) else { throw VBAControl.goTo(resumeLabel) }
                        position = index + 1
                    }
                }
            }
        }
    }

    /// Runs an `On Error GoTo` handler, from its label in the procedure body
    /// up to the `Resume` that says where to carry on. A handler that runs
    /// off the end of the procedure, or exits it, ends the procedure there.
    private func runHandler(_ label: String, _ frame: Frame) throws -> VBAResumeTarget {
        guard let index = labelIndex(label, in: frame.procedure.body) else {
            throw VBAError(number: 0, "Label not defined (\(label))")
        }
        do {
            try run(frame.procedure.body, from: index + 1, frame)
        } catch VBAControl.resume(let target) {
            clearError()
            return target
        }
        throw VBAControl.exitProcedure
    }

    func setError(_ error: VBAError) {
        lastError = error
    }

    func clearError() {
        lastError = nil
    }

    private func checkpoint() throws {
        statementCount += 1
        if statementCount % 512 == 0, isCancelled() { throw VBAControl.cancelled }
    }

    private func execute(_ statement: VBAStatement, _ frame: Frame) throws {
        try checkpoint()
        switch statement.kind {
        case .declare(let declarations, let isStatic):
            for declaration in declarations {
                let key = declaration.name.lowercased()
                guard isStatic || frame.procedure.isStatic else {
                    frame.locals[key] = try makeVariable(declaration, frame)
                    continue
                }
                // A static variable is made once and outlives the call.
                let procedureKey = frame.procedure.name.lowercased()
                if let kept = frame.module.staticLocals[procedureKey]?[key] {
                    frame.locals[key] = kept
                } else {
                    let variable = try makeVariable(declaration, frame)
                    frame.module.staticLocals[procedureKey, default: [:]][key] = variable
                    frame.locals[key] = variable
                }
            }

        case .constant(let name, let expression):
            frame.locals[name.lowercased()] = VBAVariable(type: .variant, value: try evaluate(expression, frame))

        case .redim(let preserve, let targets):
            for (target, bounds) in targets {
                guard case .identifier(let name) = target else { throw VBAError.typeMismatch }
                let variable = try variableForAssignment(name, frame, creating: true)
                var elementType = VBAType.variant
                if case .array(let declared) = variable.type { elementType = declared }
                if case .array(let existing) = variable.value {
                    if existing.isFixed { throw VBAError(number: 10, "This array is fixed or temporarily locked") }
                    elementType = existing.elementType
                }
                let fresh = try allocate(bounds, elementType: elementType, frame)
                if preserve, case .array(let existing) = variable.value {
                    variable.value = .array(try existing.resizedPreserving(lowerBounds: fresh.lowerBounds,
                                                                            upperBounds: fresh.lowerBounds.indices.map(fresh.upperBound)))
                } else {
                    variable.value = .array(fresh)
                }
            }

        case .assign(let target, let valueExpression, let isSet):
            var value = try evaluate(valueExpression, frame)
            if isSet {
                guard value.isObjectLike else { throw VBAError.objectRequired }
            } else {
                value = try letValue(value)
            }
            try assignValue(value, to: target, isSet: isSet, frame)

        case .call(let expression):
            try callStatement(expression, frame)

        case .ifBlock(let branches, let otherwise):
            for (condition, body) in branches where try isTrue(evaluate(condition, frame)) {
                try run(body, from: 0, frame)
                return
            }
            if let otherwise { try run(otherwise, from: 0, frame) }

        case .select(let subjectExpression, let clauses, let otherwise):
            let subject = try letValue(evaluate(subjectExpression, frame))
            let textCompare = frame.module.syntax.optionCompareText
            for clause in clauses {
                for condition in clause.conditions {
                    let matched: Bool
                    switch condition {
                    case .value(let expression):
                        let value = try letValue(evaluate(expression, frame))
                        matched = try isTrue(VBAOperators.binary("=", subject, value, textCompare: textCompare))
                    case .range(let low, let high):
                        let lower = try letValue(evaluate(low, frame))
                        let upper = try letValue(evaluate(high, frame))
                        matched = try isTrue(VBAOperators.binary(">=", subject, lower, textCompare: textCompare))
                            && isTrue(VBAOperators.binary("<=", subject, upper, textCompare: textCompare))
                    case .comparison(let op, let expression):
                        let value = try letValue(evaluate(expression, frame))
                        matched = try isTrue(VBAOperators.binary(op, subject, value, textCompare: textCompare))
                    }
                    if matched {
                        try run(clause.body, from: 0, frame)
                        return
                    }
                }
            }
            if let otherwise { try run(otherwise, from: 0, frame) }

        case .forNext(let variableExpression, let startExpression, let endExpression, let stepExpression, let body):
            let start = try letValue(evaluate(startExpression, frame))
            let end = try letValue(evaluate(endExpression, frame))
            let step = try stepExpression.map { try letValue(evaluate($0, frame)) } ?? .integer(1)
            try assignValue(start, to: variableExpression, isSet: false, frame)
            let stepValue = try step.asDouble()
            let limit = try end.asDouble()
            while true {
                let current = try letValue(evaluate(variableExpression, frame)).asDouble()
                if stepValue >= 0 ? current > limit : current < limit { break }
                try checkpoint()
                do {
                    try run(body, from: 0, frame)
                } catch VBAControl.exitFor {
                    break
                }
                let next = try VBAOperators.binary("+", evaluate(variableExpression, frame), step, textCompare: false)
                try assignValue(next, to: variableExpression, isSet: false, frame)
            }

        case .forEach(let variableExpression, let collectionExpression, let body):
            let collection = try evaluate(collectionExpression, frame)
            let items: [VBAValue]
            switch collection {
            case .array(let array): items = array.elements
            case .object(let object): items = try object.elements(in: self)
            case .nothing: throw VBAError.objectNotSet
            default: throw VBAError(number: 92, "For loop not initialized")
            }
            for item in items {
                try assignValue(item, to: variableExpression, isSet: item.isObjectLike, frame)
                do {
                    try run(body, from: 0, frame)
                } catch VBAControl.exitFor {
                    break
                }
            }

        case .doLoop(let condition, let isUntil, let testsFirst, let body):
            func shouldContinue() throws -> Bool {
                guard let condition else { return true }
                let value = try isTrue(evaluate(condition, frame))
                return isUntil ? !value : value
            }
            if testsFirst, try !shouldContinue() { return }
            while true {
                // An empty body runs no statements, so the loop checks in itself.
                try checkpoint()
                do {
                    try run(body, from: 0, frame)
                } catch VBAControl.exitDo {
                    break
                }
                if try !shouldContinue() { break }
            }

        case .with(let expression, let body):
            let object = try evaluate(expression, frame)
            frame.withStack.append(object)
            defer { frame.withStack.removeLast() }
            try run(body, from: 0, frame)

        case .exit(let kind):
            switch kind {
            case .sub, .function, .property: throw VBAControl.exitProcedure
            case .forLoop: throw VBAControl.exitFor
            case .doLoop: throw VBAControl.exitDo
            }

        case .goTo(let label):
            throw VBAControl.goTo(label)

        case .goSub(let label):
            // The subroutine runs from its label until `Return`, then this
            // statement is done and the next one follows. Running off the
            // end of the procedure ends the procedure, as in VBA.
            guard let index = labelIndex(label, in: frame.procedure.body) else {
                throw VBAError(number: 0, "Label not defined (\(label))")
            }
            frame.goSubDepth += 1
            defer { frame.goSubDepth -= 1 }
            do {
                try run(frame.procedure.body, from: index + 1, frame)
            } catch VBAControl.returnFromGoSub {
                return
            }
            throw VBAControl.exitProcedure

        case .returnFromGoSub:
            guard frame.goSubDepth > 0 else { throw VBAError(number: 3, "Return without GoSub") }
            throw VBAControl.returnFromGoSub

        case .file(let fileStatement):
            try execute(fileStatement, frame)

        case .alignedAssign(let target, let valueExpression, let isRight):
            // The variable keeps its length; the new text is padded with
            // spaces or cut to fit, against the left or the right.
            let width = try letValue(evaluate(target, frame)).asString().count
            let text = String(try letValue(evaluate(valueExpression, frame)).asString().prefix(width))
            let padding = String(repeating: " ", count: width - text.count)
            try assignValue(.string(isRight ? padding + text : text + padding), to: target, isSet: false, frame)

        case .raiseEvent(let name, let argumentExpressions):
            try raiseEvent(name, argumentExpressions, frame)

        case .label:
            break

        case .onError(let handling):
            frame.errorHandling = handling
            if handling == .disabled { clearError() }

        case .resume(let target):
            guard frame.inHandler else { throw VBAError(number: 20, "Resume without error") }
            throw VBAControl.resume(target)

        case .erase(let targets):
            for target in targets {
                guard case .identifier(let name) = target else { continue }
                let variable = try variableForAssignment(name, frame, creating: false)
                guard case .array(var array) = variable.value else { throw VBAError.typeMismatch }
                if array.isFixed {
                    array.elements = Array(repeating: array.elementType.defaultValue, count: array.elements.count)
                    variable.value = .array(array)
                } else {
                    variable.value = .array(.unallocated(array.elementType))
                }
            }

        case .debugPrint(let items):
            var formatter = VBAPrintFormatter(column: 0)
            let (text, _) = try formatter.format(items) { try self.letValue(self.evaluate($0, frame)) }
            host?.debugPrint(text)

        case .end:
            throw VBAControl.end

        case .stop:
            throw VBAControl.end

        case .unsupported(let message):
            throw VBAError(number: 445, message)
        }
    }

    func isTrue(_ value: VBAValue) throws -> Bool {
        if case .null = value { return false }
        return try letValue(value).asBoolean()
    }

    /// A call written as a statement. Unlike in an expression, a bare name
    /// here calls the procedure even with no arguments.
    private func callStatement(_ expression: VBAExpression, _ frame: Frame) throws {
        switch expression {
        case .identifier, .member:
            _ = try call(expression, arguments: [], frame)
        case .call(let target, let arguments):
            _ = try call(target, arguments: arguments, frame)
        default:
            _ = try evaluate(expression, frame)
        }
    }

    // MARK: - Assignment

    func variableForAssignment(_ name: String, _ frame: Frame, creating: Bool) throws -> VBAVariable {
        let key = name.lowercased()
        if let local = frame.locals[key] { return local }
        if let instance = frame.instance, let field = instance.variables[key] { return field }
        if let variable = frame.module.variables[key] { return variable }
        for module in modules where module.kind == .standard && module.isPublicVariable(name) {
            try initialize(module)
            if let variable = module.variables[key] { return variable }
        }
        guard creating else { throw VBAError(number: 0, "Variable not defined (\(name))") }
        if frame.module.syntax.optionExplicit { throw VBAError(number: 0, "Variable not defined (\(name))") }
        let variable = VBAVariable(type: .variant)
        frame.locals[key] = variable
        return variable
    }

    /// The variable a name refers to, when it refers to one.
    func existingVariable(_ name: String, _ frame: Frame) -> VBAVariable? {
        let key = name.lowercased()
        if let local = frame.locals[key] { return local }
        if let instance = frame.instance, let field = instance.variables[key] { return field }
        if let variable = frame.module.variables[key] { return variable }
        for module in modules where module.kind == .standard && module.isPublicVariable(name) {
            try? initialize(module)
            if let variable = module.variables[key] { return variable }
        }
        return nil
    }

    func assignValue(_ value: VBAValue, to target: VBAExpression, isSet: Bool, _ frame: Frame) throws {
        switch target {
        case .identifier(let name):
            if let variable = existingVariable(name, frame) {
                try store(value, in: variable, isSet: isSet)
                return
            }
            // A Property Let in this module or class, assigned by bare name.
            if let (procedure, module) = findProcedure(name, kinds: [isSet ? .propertySet : .propertyLet], frame) {
                _ = try invoke(procedure, in: module, instance: frame.instance, arguments: [], named: [], propertyValue: value)
                return
            }
            if let host, try host.setGlobalMember(name, .none, to: value, in: self) { return }
            try store(value, in: try variableForAssignment(name, frame, creating: true), isSet: isSet)

        case .member(let baseExpression, let name):
            let base = try evaluateBase(baseExpression, frame)
            try setMember(of: base, name, .none, to: value)

        case .call(let callee, let argumentExpressions):
            let arguments = try evaluateArguments(argumentExpressions, frame)
            switch callee {
            case .identifier(let name):
                if let variable = existingVariable(name, frame) {
                    switch variable.value {
                    case .array(var array):
                        let indices = try arguments.positional.map { try ($0 ?? .empty).asInteger() }
                        try array.set(indices, isSet ? value : VBAInterpreter.copyingRecords(value))
                        variable.value = .array(array)
                        return
                    case .object(let object):
                        try object.setMember("", arguments, to: value, in: self)
                        return
                    default:
                        break
                    }
                }
                if let (procedure, module) = findProcedure(name, kinds: [isSet ? .propertySet : .propertyLet], frame) {
                    _ = try invoke(procedure, in: module, instance: frame.instance,
                                   arguments: arguments.positional.map { $0.map(Argument.value) ?? .missing },
                                   named: [], propertyValue: value)
                    return
                }
                if let host, try host.setGlobalMember(name, arguments, to: value, in: self) { return }
                let object = try evaluate(target, frame)
                guard case .object(let resolved) = object else { throw VBAError(number: 0, "Cannot assign to \(name)") }
                try resolved.setMember("", .none, to: value, in: self)
            case .member(let baseExpression, let name):
                let base = try evaluateBase(baseExpression, frame)
                try setMember(of: base, name, arguments, to: value)
            default:
                let object = try evaluate(callee, frame)
                guard case .object(let resolved) = object else { throw VBAError.objectRequired }
                try resolved.setMember("", arguments, to: value, in: self)
            }

        case .parenthesized(let inner):
            try assignValue(value, to: inner, isSet: isSet, frame)

        default:
            throw VBAError(number: 0, "This cannot be assigned to")
        }
    }

    private func store(_ value: VBAValue, in variable: VBAVariable, isSet: Bool) throws {
        if isSet, !variable.type.isObject, variable.type != .variant { throw VBAError.typeMismatch }
        try variable.assign(value)
    }

    private func setMember(of base: VBAValue, _ name: String, _ arguments: VBAArguments, to value: VBAValue) throws {
        switch base {
        case .object(let object):
            do {
                try object.setMember(name, arguments, to: value, in: self)
            } catch let error as VBAError where error.number == 438 {
                // `ws.Cells(1, 1) = 5`: the member returns an object whose
                // default property takes the value.
                let result = try object.member(name, arguments, in: self)
                guard case .object(let target) = result else { throw error }
                try target.setMember("", .none, to: value, in: self)
            }
        case .nothing:
            throw VBAError.objectNotSet
        default:
            throw VBAError.objectRequired
        }
    }

    // MARK: - Expressions

    /// The value an object stands for when used as a plain value: its
    /// default property, followed until it is not an object.
    func letValue(_ value: VBAValue) throws -> VBAValue {
        var current = value
        var hops = 0
        while case .object(let object) = current, !(object is VBARecord) {
            current = try object.member("", .none, in: self)
            hops += 1
            if hops > 8 { throw VBAError.typeMismatch }
        }
        return current
    }

    private func evaluateBase(_ expression: VBAExpression?, _ frame: Frame) throws -> VBAValue {
        guard let expression else {
            guard let object = frame.withStack.last else {
                throw VBAError(number: 0, "Invalid or unqualified reference")
            }
            return object
        }
        return try evaluate(expression, frame)
    }

    func evaluateArguments(_ expressions: [VBAArgument], _ frame: Frame) throws -> VBAArguments {
        var arguments = VBAArguments()
        for argument in expressions {
            let value = try argument.value.map { try evaluate($0, frame) }
            if let name = argument.name {
                arguments.named.append((name, value ?? .missing))
            } else {
                arguments.positional.append(value)
            }
        }
        return arguments
    }

    func evaluate(_ expression: VBAExpression, _ frame: Frame) throws -> VBAValue {
        switch expression {
        case .literal(let literal):
            switch literal {
            case .integer(let value): return .integer(value)
            case .double(let value): return .double(value)
            case .string(let text): return .string(text)
            case .date(let serial): return .date(serial)
            case .boolean(let flag): return .boolean(flag)
            case .nothing: return .nothing
            case .empty: return .empty
            case .null: return .null
            }
        case .identifier, .member:
            return try call(expression, arguments: [], frame)
        case .call(let target, let arguments):
            return try call(target, arguments: arguments, frame)
        case .parenthesized(let inner):
            return try evaluate(inner, frame)
        case .unary(let op, let operand):
            let value = try letValue(evaluate(operand, frame))
            return op == "-" ? try VBAOperators.negate(value) : try VBAOperators.not(value)
        case .binary(let op, let lhs, let rhs):
            if op.lowercased() == "is" {
                return try VBAOperators.binary("Is", evaluate(lhs, frame), evaluate(rhs, frame), textCompare: false)
            }
            let left = try letValue(evaluate(lhs, frame))
            let right = try letValue(evaluate(rhs, frame))
            return try VBAOperators.binary(op, left, right, textCompare: frame.module.syntax.optionCompareText)
        case .new(let className):
            return .object(try instantiate(className))
        case .me:
            guard let instance = frame.instance else {
                if frame.module.kind == .document, let object = host?.documentObject(codeName: frame.module.name, in: self) {
                    return .object(object)
                }
                throw VBAError(number: 0, "Invalid use of Me keyword")
            }
            return .object(instance)
        case .addressOf:
            throw VBAError(number: 445, String(localized: "Macro.Unavailable.AddressOf"))
        case .typeOfIs(let subject, let className):
            let value = try evaluate(subject, frame)
            guard case .object(let object) = value else { return .boolean(false) }
            let name = className.lowercased()
            return .boolean(object.typeName.lowercased() == name || name == "object")
        }
    }

    // MARK: - Name resolution and calls

    func findProcedure(_ name: String, kinds: Set<VBAProcedure.Kind>, _ frame: Frame) -> (VBAProcedure, Module)? {
        if let procedure = frame.module.procedure(name, kinds: kinds) { return (procedure, frame.module) }
        for module in modules where module.kind == .standard {
            if let procedure = module.procedure(name, kinds: kinds), !procedure.isPrivate { return (procedure, module) }
        }
        return nil
    }

    private func constant(_ name: String, _ frame: Frame) -> VBAValue? {
        let key = name.lowercased()
        if let value = frame.module.constants[key] { return value }
        for module in modules {
            if let value = module.constants[key],
               module.syntax.constants.first(where: { $0.name.lowercased() == key }).map({ !$0.isPrivate }) ?? true {
                return value
            }
        }
        return nil
    }

    /// Turns argument expressions into arguments for a user procedure,
    /// passing plain variable names and array elements by reference.
    private func procedureArguments(_ expressions: [VBAArgument], _ frame: Frame)
        throws -> (positional: [Argument], named: [(String, Argument)], writeBacks: [() throws -> Void]) {
        var positional: [Argument] = []
        var named: [(String, Argument)] = []
        var writeBacks: [() throws -> Void] = []
        for argument in expressions {
            var passed: Argument = .missing
            if let expression = argument.value {
                switch expression {
                case .identifier(let name) where existingVariable(name, frame) != nil:
                    passed = .reference(existingVariable(name, frame)!)
                case .call(.identifier(let name), let indexExpressions):
                    if let variable = existingVariable(name, frame), case .array(let array) = variable.value {
                        let indices = try indexExpressions.map { try letValue(evaluate($0.value ?? .literal(.empty), frame)).asInteger() }
                        let temporary = VBAVariable(type: array.elementType, value: try array[indices])
                        passed = .reference(temporary)
                        writeBacks.append {
                            guard case .array(var current) = variable.value else { return }
                            try current.set(indices, temporary.value)
                            variable.value = .array(current)
                        }
                    } else {
                        passed = .value(try evaluate(expression, frame))
                    }
                default:
                    passed = .value(try evaluate(expression, frame))
                }
            }
            if let name = argument.name { named.append((name, passed)) } else { positional.append(passed) }
        }
        return (positional, named, writeBacks)
    }

    private func invokeWithReferences(
        _ procedure: VBAProcedure, in module: Module, instance: VBAClassInstance?,
        _ expressions: [VBAArgument], _ frame: Frame
    ) throws -> VBAValue {
        let (positional, named, writeBacks) = try procedureArguments(expressions, frame)
        let result = try invoke(procedure, in: module, instance: instance, arguments: positional, named: named)
        for writeBack in writeBacks { try writeBack() }
        return result
    }

    /// Indexes or calls a value with arguments: an array element, or an
    /// object's default member.
    private func apply(_ value: VBAValue, _ arguments: VBAArguments) throws -> VBAValue {
        guard !arguments.isEmpty else { return value }
        switch value {
        case .array(let array):
            return try array[arguments.positional.map { try letValue($0 ?? .empty).asInteger() }]
        case .object(let object):
            return try object.member("", arguments, in: self)
        case .nothing:
            throw VBAError.objectNotSet
        default:
            throw VBAError.typeMismatch
        }
    }

    private func call(_ target: VBAExpression, arguments argumentExpressions: [VBAArgument],
                      _ frame: Frame) throws -> VBAValue {
        switch target {
        case .identifier(let name):
            return try callName(name, argumentExpressions, frame)
        case .member(let baseExpression, let name):
            // `Module1.Helper`: a module name qualifies a procedure or variable.
            if case .identifier(let qualifier)? = baseExpression, existingVariable(qualifier, frame) == nil,
               let module = module(named: qualifier), module.kind == .standard {
                try initialize(module)
                if let procedure = module.procedure(name, kinds: [.sub, .function, .propertyGet]) {
                    return try invokeWithReferences(procedure, in: module, instance: nil, argumentExpressions, frame)
                }
                if let variable = module.variables[name.lowercased()] {
                    return try apply(variable.value, evaluateArguments(argumentExpressions, frame))
                }
                if let value = module.constants[name.lowercased()] { return value }
                throw VBAError.notDefined("\(qualifier).\(name)")
            }
            let base = try evaluateBase(baseExpression, frame)
            switch base {
            case .object(let object):
                if let instance = object as? VBAClassInstance {
                    return try instance.call(name, argumentExpressions, frame, interpreter: self)
                }
                if let record = object as? VBARecord {
                    guard let field = record.fields[name.lowercased()] else { throw VBAError.unsupportedMember(name) }
                    return try apply(field.value, evaluateArguments(argumentExpressions, frame))
                }
                return try object.member(name, evaluateArguments(argumentExpressions, frame), in: self)
            case .nothing:
                throw VBAError.objectNotSet
            default:
                throw VBAError.objectRequired
            }
        default:
            let value = try evaluate(target, frame)
            return try apply(value, evaluateArguments(argumentExpressions, frame))
        }
    }

    private func callName(_ name: String, _ argumentExpressions: [VBAArgument], _ frame: Frame) throws -> VBAValue {
        let key = name.lowercased()

        // A variable, unless it is a scalar being called with arguments —
        // a function's return value shadows the function, but a recursive
        // call still names the function.
        if let variable = existingVariable(name, frame) {
            let isScalar: Bool
            switch variable.value {
            case .array, .object, .nothing: isScalar = false
            default: isScalar = true
            }
            if argumentExpressions.isEmpty || !isScalar || frame.procedure.name.lowercased() != key {
                return try apply(variable.value, evaluateArguments(argumentExpressions, frame))
            }
        }
        if let value = constant(name, frame) { return value }

        // A member of the current class instance or document module.
        if let instance = frame.instance,
           instance.module.procedure(name, kinds: [.sub, .function, .propertyGet]) != nil {
            return try instance.call(name, argumentExpressions, frame, interpreter: self)
        }
        if let (procedure, module) = findProcedure(name, kinds: [.sub, .function, .propertyGet], frame) {
            let instance = module === frame.module ? frame.instance : nil
            return try invokeWithReferences(procedure, in: module, instance: instance, argumentExpressions, frame)
        }
        if key == "err" {
            let object = errorObject ?? VBAErrObject()
            errorObject = object
            return try apply(.object(object), evaluateArguments(argumentExpressions, frame))
        }
        // A document module by its code name.
        if let module = module(named: name), module.kind == .document {
            let object = VBADocumentModuleObject(module: module, base: host?.documentObject(codeName: module.name, in: self))
            return try apply(.object(object), evaluateArguments(argumentExpressions, frame))
        }
        // A sheet's code name works even where the project has no module for it.
        if let object = host?.documentObject(codeName: name, in: self) {
            return try apply(.object(object), evaluateArguments(argumentExpressions, frame))
        }

        let arguments = try evaluateArguments(argumentExpressions, frame)
        if frame.module.syntax.externalProcedures.contains(key)
            || modules.contains(where: { $0.syntax.externalProcedures.contains(key) }) {
            throw VBAError(number: 445, String(format: String(localized: "Macro.Unavailable.Declare"), name))
        }
        if let value = try VBALibrary.call(name, arguments, interpreter: self, frame: frame) { return value }
        if let host, let value = try host.globalMember(name, arguments, in: self) { return value }
        if let value = host?.constant(named: name) ?? VBALibrary.constant(named: name) { return value }

        if frame.module.syntax.optionExplicit || !arguments.isEmpty {
            throw arguments.isEmpty ? VBAError(number: 0, "Variable not defined (\(name))") : VBAError.notDefined(name)
        }
        // Undeclared and not Option Explicit: a fresh, empty Variant.
        let variable = VBAVariable(type: .variant)
        frame.locals[key] = variable
        return variable.value
    }

    // MARK: - Events

    /// `RaiseEvent`: every `WithEvents` variable holding the object raising
    /// it — in a document module or another class's instance — has its
    /// `variable_Event` procedure called. Arguments pass by reference, so a
    /// handler can set a `Cancel` flag the raiser then reads.
    private func raiseEvent(_ name: String, _ argumentExpressions: [VBAArgument], _ frame: Frame) throws {
        guard let source = frame.instance else { return }
        guard frame.module.syntax.events.contains(name.lowercased()) else {
            throw VBAError(number: 0, "Event not found (\(name))")
        }
        var subscribers: [(Module, VBAClassInstance?, String)] = []
        for module in modules where module.kind != .classModule {
            for (declaration, _) in module.syntax.variables where declaration.isWithEvents {
                if case .object(let object)? = module.variables[declaration.name.lowercased()]?.value,
                   object === source {
                    subscribers.append((module, nil, declaration.name))
                }
            }
        }
        for instance in liveInstances.compactMap(\.instance) {
            for (declaration, _) in instance.module.syntax.variables where declaration.isWithEvents {
                if case .object(let object)? = instance.variables[declaration.name.lowercased()]?.value,
                   object === source {
                    subscribers.append((instance.module, instance, declaration.name))
                }
            }
        }
        for (module, instance, variable) in subscribers {
            guard let handler = module.procedure("\(variable)_\(name)", kinds: [.sub]) else { continue }
            let (positional, named, writeBacks) = try procedureArguments(argumentExpressions, frame)
            _ = try invoke(handler, in: module, instance: instance, arguments: positional, named: named)
            for writeBack in writeBacks { try writeBack() }
        }
    }

    // MARK: - Objects

    func instantiate(_ className: String) throws -> any VBAObject {
        if let module = module(named: className), module.kind == .classModule {
            try ensureInitialized()
            let instance = VBAClassInstance(module: module)
            liveInstances.removeAll { $0.instance == nil }
            liveInstances.append(WeakInstance(instance: instance))
            let context = try moduleFrame(for: module)
            for (declaration, _) in module.syntax.variables {
                instance.variables[declaration.name.lowercased()] = try makeVariable(declaration, context)
            }
            if let initializer = module.procedure("Class_Initialize", kinds: [.sub]) {
                _ = try invoke(initializer, in: module, instance: instance, arguments: [], named: [])
            }
            return instance
        }
        if let object = VBALibrary.createObject(className) ?? host?.createObject(className, in: self) {
            return object
        }
        throw VBAError(number: 429, "ActiveX component can't create object (\(className))")
    }
}

// MARK: - Runtime objects

/// An instance of one of the project's class modules.
final class VBAClassInstance: VBAObject {
    let module: VBAInterpreter.Module
    var variables: [String: VBAVariable] = [:]

    init(module: VBAInterpreter.Module) {
        self.module = module
    }

    var typeName: String { module.name }

    func call(_ name: String, _ argumentExpressions: [VBAArgument], _ frame: VBAInterpreter.Frame,
              interpreter: VBAInterpreter) throws -> VBAValue {
        let arguments = try interpreter.evaluateArguments(argumentExpressions, frame)
        return try member(name, arguments, in: interpreter)
    }

    func member(_ name: String, _ arguments: VBAArguments, in interpreter: VBAInterpreter) throws -> VBAValue {
        let lookup = name.isEmpty ? defaultMemberName : name
        if let procedure = module.procedure(lookup, kinds: [.function, .propertyGet, .sub]), !procedure.isPrivate {
            return try interpreter.invoke(
                procedure, in: module, instance: self,
                arguments: arguments.positional.map { $0.map(VBAInterpreter.Argument.value) ?? .missing },
                named: arguments.named.map { ($0.name, .value($0.value)) }
            )
        }
        if let variable = variables[lookup.lowercased()], module.isPublicVariable(lookup) {
            guard !arguments.isEmpty else { return variable.value }
            guard case .array(let array) = variable.value else { throw VBAError.typeMismatch }
            return try array[arguments.positional.map { try ($0 ?? .empty).asInteger() }]
        }
        if name.isEmpty { throw VBAError(number: 438, "Object doesn't support this property or method (\(typeName))") }
        throw VBAError.unsupportedMember(name)
    }

    func setMember(_ name: String, _ arguments: VBAArguments, to value: VBAValue,
                   in interpreter: VBAInterpreter) throws {
        let lookup = name.isEmpty ? defaultMemberName : name
        let kinds: Set<VBAProcedure.Kind> = value.isObjectLike ? [.propertySet, .propertyLet] : [.propertyLet, .propertySet]
        if let procedure = module.procedure(lookup, kinds: kinds), !procedure.isPrivate {
            _ = try interpreter.invoke(
                procedure, in: module, instance: self,
                arguments: arguments.positional.map { $0.map(VBAInterpreter.Argument.value) ?? .missing },
                named: [], propertyValue: value
            )
            return
        }
        if let variable = variables[lookup.lowercased()], module.isPublicVariable(lookup) {
            if arguments.isEmpty {
                try variable.assign(value)
            } else {
                guard case .array(var array) = variable.value else { throw VBAError.typeMismatch }
                try array.set(arguments.positional.map { try ($0 ?? .empty).asInteger() }, value)
                variable.value = .array(array)
            }
            return
        }
        throw VBAError.unsupportedMember(name)
    }

    /// A class marks its default member with `Attribute X.VB_UserMemId = 0`,
    /// which the parser skips; `Item` and `Value` are the usual choices.
    private var defaultMemberName: String {
        for candidate in ["Item", "Value", "Default"] where module.procedures[candidate.lowercased()] != nil {
            return candidate
        }
        return "Item"
    }

    func elements(in interpreter: VBAInterpreter) throws -> [VBAValue] {
        // A class wrapping a collection exposes it through NewEnum.
        if module.procedure("NewEnum", kinds: [.function, .propertyGet]) != nil,
           case .object(let inner) = try member("NewEnum", .none, in: interpreter) {
            return try inner.elements(in: interpreter)
        }
        throw VBAError(number: 438, "Object doesn't support this property or method")
    }
}

/// A value of a user-defined `Type`: fields by name, copied on assignment.
final class VBARecord: VBAObject {
    let typeName: String
    var fields: [String: VBAVariable] = [:]
    var order: [String] = []

    init(typeName: String) {
        self.typeName = typeName
    }

    func copy() -> VBARecord {
        let copy = VBARecord(typeName: typeName)
        copy.order = order
        for (name, field) in fields {
            copy.fields[name] = VBAVariable(type: field.type, value: VBAInterpreter.copyingRecords(field.value))
        }
        return copy
    }

    func member(_ name: String, _: VBAArguments, in _: VBAInterpreter) throws -> VBAValue {
        guard let field = fields[name.lowercased()] else { throw VBAError.unsupportedMember(name) }
        return field.value
    }

    func setMember(_ name: String, _ arguments: VBAArguments, to value: VBAValue,
                   in _: VBAInterpreter) throws {
        guard let field = fields[name.lowercased()] else { throw VBAError.unsupportedMember(name) }
        if arguments.isEmpty {
            try field.assign(value)
        } else {
            guard case .array(var array) = field.value else { throw VBAError.typeMismatch }
            try array.set(arguments.positional.map { try ($0 ?? .empty).asInteger() }, value)
            field.value = .array(array)
        }
    }
}

/// `Sheet1` or `ThisWorkbook` used as an object: the module's own public
/// procedures and variables first, then the sheet or workbook behind it.
final class VBADocumentModuleObject: VBAObject {
    let module: VBAInterpreter.Module
    let base: (any VBAObject)?

    init(module: VBAInterpreter.Module, base: (any VBAObject)?) {
        self.module = module
        self.base = base
    }

    var typeName: String { base?.typeName ?? module.name }

    func member(_ name: String, _ arguments: VBAArguments, in interpreter: VBAInterpreter) throws -> VBAValue {
        if !name.isEmpty, let procedure = module.procedure(name, kinds: [.sub, .function, .propertyGet]),
           !procedure.isPrivate {
            return try interpreter.invoke(
                procedure, in: module, instance: nil,
                arguments: arguments.positional.map { $0.map(VBAInterpreter.Argument.value) ?? .missing },
                named: arguments.named.map { ($0.name, .value($0.value)) }
            )
        }
        if !name.isEmpty, let variable = module.variables[name.lowercased()], module.isPublicVariable(name) {
            return variable.value
        }
        guard let base else { throw VBAError.unsupportedMember(name) }
        return try base.member(name, arguments, in: interpreter)
    }

    func setMember(_ name: String, _ arguments: VBAArguments, to value: VBAValue,
                   in interpreter: VBAInterpreter) throws {
        if let variable = module.variables[name.lowercased()], module.isPublicVariable(name) {
            try variable.assign(value)
            return
        }
        guard let base else { throw VBAError.unsupportedMember(name) }
        try base.setMember(name, arguments, to: value, in: interpreter)
    }

    func elements(in interpreter: VBAInterpreter) throws -> [VBAValue] {
        guard let base else { throw VBAError(number: 438, "Object doesn't support this property or method") }
        return try base.elements(in: interpreter)
    }
}

/// The `Err` object.
final class VBAErrObject: VBAObject {
    var typeName: String { "ErrObject" }

    func member(_ name: String, _ arguments: VBAArguments, in interpreter: VBAInterpreter) throws -> VBAValue {
        let error = interpreter.lastError
        switch name.lowercased() {
        case "", "number": return .integer(error?.number ?? 0)
        case "description": return .string(error?.description ?? "")
        case "source": return .string(error?.module ?? "")
        case "helpfile": return .string("")
        case "helpcontext": return .integer(0)
        case "lastdllerror": return .integer(0)
        case "clear":
            interpreter.clearError()
            return .empty
        case "raise":
            let number = try arguments.required(0, "Number").asInteger()
            let description = try arguments.value(2, "Description")?.asString()
                ?? VBALibrary.standardErrorDescription(number)
            var raised = VBAError(number: number, description)
            if let source = try arguments.value(1, "Source")?.asString() { raised.module = source }
            throw raised
        default:
            throw VBAError.unsupportedMember(name)
        }
    }

    func setMember(_ name: String, _: VBAArguments, to value: VBAValue,
                   in interpreter: VBAInterpreter) throws {
        var error = interpreter.lastError ?? VBAError(number: 0, "")
        switch name.lowercased() {
        case "", "number":
            error.number = try value.asInteger()
            if error.description.isEmpty { error.description = VBALibrary.standardErrorDescription(error.number) }
        case "description": error.description = try value.asString()
        case "source": error.module = try value.asString()
        default: throw VBAError.unsupportedMember(name)
        }
        interpreter.lastError = error.number == 0 && error.description.isEmpty ? nil : error
    }
}
