import Foundation

extension FormulaFunctions {
    public static let dateFunctions: [String: FunctionSpec] = [
        "TODAY": .constant { .number(FormulaDates.today()) },
        "NOW": .constant { .number(FormulaDates.now()) },
        "DATE": FunctionSpec(3...3) { call throws(CellError) in
            var year = try call.integer(0)
            let month = try call.integer(1)
            let day = try call.integer(2)
            // Years 0–1899 are read as offsets from 1900, as Excel does.
            if (0...1899).contains(year) { year += 1900 }
            guard (1900...9999).contains(year) else { throw .numberError }
            let serial = FormulaDates.serial(year: year, month: month, day: day)
            guard serial >= 0, serial <= FormulaDates.maximumSerial else { throw .numberError }
            return .number(serial)
        },
        "TIME": FunctionSpec(3...3) { call throws(CellError) in
            let seconds = Double(try call.integer(0)) * 3600 + Double(try call.integer(1)) * 60
                + Double(try call.integer(2))
            guard seconds >= 0, seconds < 32_768 * 3600 else { throw .numberError }
            return .number((seconds / 86_400).truncatingRemainder(dividingBy: 1))
        },
        "YEAR": FunctionSpec(1...1) { call throws(CellError) in
            .number(Double(FormulaDates.components(fromSerial: try FormulaDates.serial(call, 0)).year))
        },
        "MONTH": FunctionSpec(1...1) { call throws(CellError) in
            .number(Double(FormulaDates.components(fromSerial: try FormulaDates.serial(call, 0)).month))
        },
        "DAY": FunctionSpec(1...1) { call throws(CellError) in
            .number(Double(FormulaDates.components(fromSerial: try FormulaDates.serial(call, 0)).day))
        },
        "HOUR": FunctionSpec(1...1) { call throws(CellError) in
            .number(Double(FormulaDates.secondOfDay(try FormulaDates.serial(call, 0)) / 3600))
        },
        "MINUTE": FunctionSpec(1...1) { call throws(CellError) in
            .number(Double(FormulaDates.secondOfDay(try FormulaDates.serial(call, 0)) / 60 % 60))
        },
        "SECOND": FunctionSpec(1...1) { call throws(CellError) in
            .number(Double(FormulaDates.secondOfDay(try FormulaDates.serial(call, 0)) % 60))
        },
        "WEEKDAY": FunctionSpec(1...2) { call throws(CellError) in
            let serial = try FormulaDates.serial(call, 0)
            let sundayBased = FormulaDates.weekday(ofSerial: serial)
            let type = try call.integer(1, default: 1)
            switch type {
            case 1: return .number(Double(sundayBased))
            case 2: return .number(Double((sundayBased + 5) % 7 + 1))
            case 3: return .number(Double((sundayBased + 5) % 7))
            case 11...17:
                // 11 starts the week on Monday, 12 on Tuesday, through 17 on Sunday.
                let first = type - 9
                return .number(Double((sundayBased - first + 14) % 7 + 1))
            default: throw .numberError
            }
        },
    ]
}

extension FormulaDates {
    /// 31 December 9999, the last date Excel represents.
    public static let maximumSerial = 2_958_465.0

    /// A date argument as a serial. Text dates are read; negative serials and
    /// serials past 9999 are refused.
    public static func serial(_ call: FunctionCall, _ index: Int) throws(CellError) -> Double {
        let serial = try call.number(index)
        guard serial >= 0, serial <= maximumSerial + 1 else { throw .numberError }
        return serial
    }

    /// The second of the day a serial falls in, rounded to the nearest second.
    public static func secondOfDay(_ serial: Double) -> Int {
        let fraction = serial - serial.rounded(.down)
        let seconds = Int((fraction * 86_400).rounded())
        return seconds >= 86_400 ? 0 : seconds
    }
}
