import Foundation

extension FormulaFunctions {
    public static let logicalFunctions: [String: FunctionSpec] = [
        "TRUE": .constant { .boolean(true) },
        "FALSE": .constant { .boolean(false) },
        "NOT": FunctionSpec(1...1) { call throws(CellError) in .boolean(!(try call.boolean(0))) },
        "AND": FunctionSpec(1...255, lifts: .none) { call throws(CellError) in
            .boolean(try FormulaLogic.truths(call).allSatisfy { $0 })
        },
        "OR": FunctionSpec(1...255, lifts: .none) { call throws(CellError) in
            .boolean(try FormulaLogic.truths(call).contains(true))
        },
        "XOR": FunctionSpec(1...255, lifts: .none) { call throws(CellError) in
            .boolean(try FormulaLogic.truths(call).filter { $0 }.count % 2 == 1)
        },
        "IF": FunctionSpec(1...3, reference: { call throws(CellError) in
            let condition = try call.boolean(0)
            guard let reference = call.reference(condition ? 1 : 2) else { throw .valueError }
            return reference
        }, value: { call throws(CellError) in
            let condition = call.value(0)
            func branch(_ index: Int) -> FormulaValue {
                if index >= call.count { return .boolean(false) }
                return call.isMissing(index) ? .number(0) : call.value(index)
            }
            guard condition.isArray else {
                return try condition.single.coercedBoolean() ? branch(1) : branch(2)
            }
            // An array of conditions picks element by element.
            let chosen = [branch(1), branch(2)]
            return FormulaValue.lift([condition, chosen[0], chosen[1]]) { values in
                do throws(CellError) {
                    return try values[0].coercedBoolean() ? values[1] : values[2]
                } catch {
                    return .error(error)
                }
            }
        }),
        "IFS": FunctionSpec(2...254, lifts: .none) { call throws(CellError) in
            guard call.count % 2 == 0 else { throw .valueError }
            var index = 0
            while index + 1 < call.count {
                if try call.boolean(index) { return call.isMissing(index + 1) ? .number(0) : call.value(index + 1) }
                index += 2
            }
            throw .notAvailable
        },
        "SWITCH": FunctionSpec(3...254, lifts: .none) { call throws(CellError) in
            let subject = call.scalar(0)
            if let error = subject.errorValue { throw error }
            var index = 1
            while index + 1 < call.count {
                let candidate = call.scalar(index)
                if let error = candidate.errorValue { throw error }
                if FormulaComparison.equal(candidate, subject) { return call.value(index + 1) }
                index += 2
            }
            // A leftover trailing argument is the default result.
            guard call.count % 2 == 0 else { throw .notAvailable }
            return call.value(call.count - 1)
        },
        "LET": FunctionSpec(3...253, lifts: .none, reference: { call throws(CellError) in
            let (inner, body) = try FormulaLogic.letScope(call)
            guard let reference = inner.reference(body) else { throw .valueError }
            return reference
        }, value: { call throws(CellError) in
            let (inner, body) = try FormulaLogic.letScope(call)
            return inner.evaluate(body)
        }),
        "LAMBDA": FunctionSpec(1...254, lifts: .none) { call throws(CellError) in
            var parameters: [String] = []
            for node in call.nodes.dropLast() {
                guard case .definedName(nil, let name) = node else { throw .valueError }
                let lowered = name.lowercased()
                guard !parameters.contains(lowered) else { throw .valueError }
                parameters.append(lowered)
            }
            return .lambda(FormulaLambda(parameters: parameters, body: call.nodes[call.count - 1],
                                         captured: call.evaluator.scope))
        },
        "ISOMITTED": FunctionSpec(1...1, lifts: .none) { call throws(CellError) in
            guard case .definedName(nil, let name) = call.nodes[0] else { return .boolean(false) }
            return .boolean(call.evaluator.scope[name.lowercased()]?.isOmitted ?? false)
        },
        "MAP": FunctionSpec(2...254, lifts: .none) { call throws(CellError) in
            let lambda = try call.lambda(call.count - 1)
            let arrays = try (0..<(call.count - 1)).map { index throws(CellError) in try call.matrix(index) }
            let height = arrays.map(\.count).max() ?? 0
            let width = arrays.map { $0.first?.count ?? 0 }.max() ?? 0
            var rows: [[CellValue]] = []
            for row in 0..<height {
                var line: [CellValue] = []
                for column in 0..<width {
                    var arguments: [FormulaValue] = []
                    for array in arrays {
                        let r = array.count == 1 ? 0 : row
                        let c = (array.first?.count ?? 0) == 1 ? 0 : column
                        arguments.append(r < array.count && c < array[r].count ? .scalar(array[r][c]) : .failure(.notAvailable))
                    }
                    line.append(FormulaLogic.single(call.evaluator.invoke(lambda, values: arguments)))
                }
                rows.append(line)
            }
            return .block(rows)
        },
        "REDUCE": FunctionSpec(2...3, lifts: .none) { call throws(CellError) in
            let (initial, array, lambda) = try FormulaLogic.accumulation(call)
            var accumulator = initial
            for value in array.flatMap({ $0 }) {
                accumulator = call.evaluator.invoke(lambda, values: [accumulator, .scalar(value)])
            }
            return accumulator
        },
        "SCAN": FunctionSpec(2...3, lifts: .none) { call throws(CellError) in
            let (initial, array, lambda) = try FormulaLogic.accumulation(call)
            var accumulator = initial
            var rows: [[CellValue]] = []
            for line in array {
                rows.append(line.map { value -> CellValue in
                    accumulator = call.evaluator.invoke(lambda, values: [accumulator, .scalar(value)])
                    return FormulaLogic.single(accumulator)
                })
            }
            return .block(rows)
        },
        "BYROW": FunctionSpec(2...2, lifts: .none) { call throws(CellError) in
            let array = try call.matrix(0)
            let lambda = try call.lambda(1)
            return .block(array.map { [FormulaLogic.single(call.evaluator.invoke(lambda, values: [.block([$0])]))] })
        },
        "BYCOL": FunctionSpec(2...2, lifts: .none) { call throws(CellError) in
            let array = try call.matrix(0)
            let lambda = try call.lambda(1)
            let width = array.first?.count ?? 0
            return .block([(0..<width).map { column in
                FormulaLogic.single(call.evaluator.invoke(lambda, values: [.block(FormulaArrays.columns([column], of: array))]))
            }])
        },
        "MAKEARRAY": FunctionSpec(3...3, lifts: .none) { call throws(CellError) in
            let height = try call.integer(0)
            let width = try call.integer(1)
            let lambda = try call.lambda(2)
            guard height >= 1, width >= 1 else { throw .valueError }
            guard height * width <= FormulaLogic.maximumArrayCells else { throw .numberError }
            return .block(FormulaArrays.grid(rows: height, columns: width) { row, column in
                FormulaLogic.single(call.evaluator.invoke(lambda, values: [.number(Double(row + 1)),
                                                                          .number(Double(column + 1))]))
            })
        },
        "IFERROR": FunctionSpec(2...2, lifts: .none) { call throws(CellError) in
            FormulaLogic.trap(call) { _ in true }
        },
        "IFNA": FunctionSpec(2...2, lifts: .none) { call throws(CellError) in
            FormulaLogic.trap(call) { $0 == .notAvailable }
        },
    ]
}

public enum FormulaLogic {
    /// The most cells a generated array may have, Excel's own grid size.
    public static let maximumArrayCells = 1_048_576 * 16_384

    /// The evaluator `LET` runs its calculation in, with each name bound in
    /// turn so later values can use earlier names, and that calculation.
    public static func letScope(_ call: FunctionCall) throws(CellError) -> (FormulaEvaluator, FormulaNode) {
        guard call.count % 2 == 1 else { throw .valueError }
        var inner = call.evaluator
        var index = 0
        while index + 1 < call.count {
            guard case .definedName(nil, let name) = call.nodes[index] else { throw .valueError }
            let node = call.nodes[index + 1]
            let binding = FormulaBinding(value: inner.evaluate(node), reference: inner.reference(node))
            inner = inner.binding([name.lowercased(): binding])
            index += 2
        }
        return (inner, call.nodes[call.count - 1])
    }

    /// `REDUCE` and `SCAN`'s arguments: the starting value, which defaults to
    /// zero, the array, and the LAMBDA.
    public static func accumulation(_ call: FunctionCall) throws(CellError) -> (FormulaValue, [[CellValue]], FormulaLambda) {
        let hasInitial = call.count == 3
        let initial = hasInitial && !call.isMissing(0) ? call.value(0) : .number(0)
        let array = try call.matrix(hasInitial ? 1 : 0)
        let lambda = try call.lambda(hasInitial ? 2 : 1)
        return (initial, array, lambda)
    }

    /// A LAMBDA's answer for one element: arrays cannot nest inside arrays.
    public static func single(_ value: FormulaValue) -> CellValue {
        switch value {
        case .scalar(let cell): return cell
        case .matrix: return value.isArray ? .error(.calc) : value.single
        case .lambda: return .error(.calc)
        }
    }

    /// The truth values `AND`, `OR` and `XOR` combine. In ranges and arrays
    /// text and blanks are passed over; typed into the call, text must read
    /// as TRUE or FALSE. With nothing to combine the answer is `#VALUE!`.
    public static func truths(_ call: FunctionCall) throws(CellError) -> [Bool] {
        var result: [Bool] = []
        for index in 0..<call.count where !call.isMissing(index) {
            let value = call.value(index)
            if call.isReference(index) || value.isMatrix {
                for cell in value.flattened {
                    switch cell {
                    case .boolean(let flag): result.append(flag)
                    case .number(let number): result.append(number != 0)
                    case .error(let error): throw error
                    case .text, .empty: break
                    }
                }
            } else {
                result.append(try value.single.coercedBoolean())
            }
        }
        guard !result.isEmpty else { throw .valueError }
        return result
    }

    /// `IFERROR` and `IFNA`: the first argument, with the errors `catches`
    /// accepts replaced by the second, element by element over an array.
    public static func trap(_ call: FunctionCall, catches: (CellError) -> Bool) -> FormulaValue {
        let primary = call.value(0)
        let fallback = call.isMissing(1) ? FormulaValue.number(0) : call.value(1)
        guard primary.isArray else {
            if let error = primary.single.errorValue, catches(error) { return fallback }
            return primary
        }
        return FormulaValue.lift([primary, fallback]) { values in
            if let error = values[0].errorValue, catches(error) { return values[1] }
            return values[0]
        }
    }
}
