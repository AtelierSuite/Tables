import Foundation

extension FormulaFunctions {
    public static let informationFunctions: [String: FunctionSpec] = [
        "ISBLANK": FunctionSpec(1...1) { call throws(CellError) in .boolean(call.scalar(0).isEmpty) },
        "ISERROR": FunctionSpec(1...1) { call throws(CellError) in .boolean(call.scalar(0).isError) },
        "ISNUMBER": FunctionSpec(1...1) { call throws(CellError) in .boolean(call.scalar(0).isNumber) },
        "ISTEXT": FunctionSpec(1...1) { call throws(CellError) in .boolean(call.scalar(0).isText) },
        "ISLOGICAL": FunctionSpec(1...1) { call throws(CellError) in .boolean(call.scalar(0).isBoolean) },
        "ISEVEN": FunctionSpec(1...1) { call throws(CellError) in
            .boolean(try FormulaInformation.parity(call) == 0)
        },
        "ISODD": FunctionSpec(1...1) { call throws(CellError) in
            .boolean(try FormulaInformation.parity(call) != 0)
        },
        "NA": .constant { .failure(.notAvailable) },
    ]
}

public enum FormulaInformation {
    /// Zero for even, one for odd. Booleans are refused, as Excel refuses them.
    public static func parity(_ call: FunctionCall) throws(CellError) -> Int {
        if call.scalar(0).isBoolean { throw .valueError }
        let number = try call.number(0).rounded(.towardZero)
        return Int(abs(number).truncatingRemainder(dividingBy: 2))
    }
}
