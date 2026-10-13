import Foundation

extension FormulaFunctions {
    static let dateExtendedFunctions: [String: FunctionSpec] = [
        "DATEVALUE": FunctionSpec(1...1) { call throws(CellError) in
            guard case .text(let text) = call.scalar(0) else {
                if let error = call.scalar(0).errorValue { throw error }
                throw .valueError
            }
            guard let serial = FormulaValueParser.dateTime(from: text), serial >= 1 else { throw .valueError }
            return .number(serial.rounded(.down))
        },
        "TIMEVALUE": FunctionSpec(1...1) { call throws(CellError) in
            guard case .text(let text) = call.scalar(0) else {
                if let error = call.scalar(0).errorValue { throw error }
                throw .valueError
            }
            guard let serial = FormulaValueParser.dateTime(from: text) else { throw .valueError }
            return .number(serial - serial.rounded(.down))
        },
        "DAYS": FunctionSpec(2...2) { call throws(CellError) in
            let end = try FormulaDates.serial(call, 0).rounded(.down)
            let start = try FormulaDates.serial(call, 1).rounded(.down)
            return .number(end - start)
        },
        "DAYS360": FunctionSpec(2...3) { call throws(CellError) in
            let start = FormulaDates.components(fromSerial: try FormulaDates.serial(call, 0))
            let end = FormulaDates.components(fromSerial: try FormulaDates.serial(call, 1))
            let european = try call.boolean(2, default: false)
            return .number(Double(FormulaDates.days360(start, end, european: european)))
        },
        "DATEDIF": FunctionSpec(3...3) { call throws(CellError) in
            let startSerial = try FormulaDates.serial(call, 0).rounded(.down)
            let endSerial = try FormulaDates.serial(call, 1).rounded(.down)
            guard startSerial <= endSerial else { throw .numberError }
            return .number(Double(try FormulaDates.dateDifference(startSerial, endSerial, unit: try call.text(2))))
        },
        "EDATE": FunctionSpec(2...2) { call throws(CellError) in
            let start = FormulaDates.components(fromSerial: try FormulaDates.serial(call, 0))
            let months = try call.integer(1)
            let serial = FormulaDates.addingMonths(months, to: start, endOfMonth: false)
            guard serial >= 0, serial <= FormulaDates.maximumSerial else { throw .numberError }
            return .number(serial)
        },
        "EOMONTH": FunctionSpec(2...2) { call throws(CellError) in
            let start = FormulaDates.components(fromSerial: try FormulaDates.serial(call, 0))
            let months = try call.integer(1)
            let serial = FormulaDates.addingMonths(months, to: start, endOfMonth: true)
            guard serial >= 0, serial <= FormulaDates.maximumSerial else { throw .numberError }
            return .number(serial)
        },
        "WEEKNUM": FunctionSpec(1...2) { call throws(CellError) in
            let serial = try FormulaDates.serial(call, 0).rounded(.down)
            let type = try call.integer(1, default: 1)
            if type == 21 { return .number(Double(FormulaDates.isoWeek(serial))) }
            let firstWeekday: Int
            switch type {
            case 1, 17: firstWeekday = 1
            case 2, 11: firstWeekday = 2
            case 12...16: firstWeekday = type - 9
            default: throw .numberError
            }
            let year = FormulaDates.components(fromSerial: serial).year
            let januaryFirst = FormulaDates.serial(year: year, month: 1, day: 1)
            let offset = (FormulaDates.weekday(ofSerial: januaryFirst) - firstWeekday + 7) % 7
            return .number(((serial - januaryFirst + Double(offset)) / 7).rounded(.down) + 1)
        },
        "ISOWEEKNUM": FunctionSpec(1...1) { call throws(CellError) in
            .number(Double(FormulaDates.isoWeek(try FormulaDates.serial(call, 0).rounded(.down))))
        },
        "NETWORKDAYS": FunctionSpec(2...3, lifts: .only([0, 1])) { call throws(CellError) in
            try FormulaDates.networkDays(call, weekendIndex: nil, holidaysIndex: 2)
        },
        "NETWORKDAYS.INTL": FunctionSpec(2...4, lifts: .only([0, 1])) { call throws(CellError) in
            try FormulaDates.networkDays(call, weekendIndex: 2, holidaysIndex: 3)
        },
        "WORKDAY": FunctionSpec(2...3, lifts: .only([0, 1])) { call throws(CellError) in
            try FormulaDates.workday(call, weekendIndex: nil, holidaysIndex: 2)
        },
        "WORKDAY.INTL": FunctionSpec(2...4, lifts: .only([0, 1])) { call throws(CellError) in
            try FormulaDates.workday(call, weekendIndex: 2, holidaysIndex: 3)
        },
        "YEARFRAC": FunctionSpec(2...3) { call throws(CellError) in
            let first = try FormulaDates.serial(call, 0).rounded(.down)
            let second = try FormulaDates.serial(call, 1).rounded(.down)
            let basis = try call.integer(2, default: 0)
            guard (0...4).contains(basis) else { throw .numberError }
            return .number(FormulaDates.yearFraction(min(first, second), max(first, second), basis: basis))
        },
        // Numbers' `DURATION`, under a name of its own as Excel's `DURATION`
        // is a bond's: weeks, days, hours, minutes, seconds and milliseconds,
        // any left out, added up into a length of time in days.
        "DURATION.TIME": FunctionSpec(1...6) { call throws(CellError) in
            let days: [Double] = [7, 1, 1.0 / 24, 1.0 / 1440, 1.0 / 86_400, 1.0 / 86_400_000]
            var total = 0.0
            for (index, unit) in days.enumerated() where index < call.count {
                total += try call.number(index, default: 0) * unit
            }
            return .number(total)
        },
    ]
}

extension FormulaDates {
    static func isLastDayOfMonth(_ date: Components) -> Bool {
        date.day == daysInMonth(date.year, date.month)
    }

    /// Days between two dates on a 360-day year, by the US (NASD) or the
    /// European rule.
    static func days360(_ start: Components, _ end: Components, european: Bool) -> Int {
        var startDay = start.day
        var endDay = end.day
        var endMonth = end.month
        var endYear = end.year
        if european {
            startDay = min(startDay, 30)
            endDay = min(endDay, 30)
        } else {
            if isLastDayOfMonth(start) { startDay = 30 }
            if isLastDayOfMonth(end) {
                if startDay < 30 {
                    endDay = 1
                    endMonth += 1
                    if endMonth > 12 { endMonth = 1; endYear += 1 }
                } else {
                    endDay = 30
                }
            }
        }
        return (endYear - start.year) * 360 + (endMonth - start.month) * 30 + (endDay - startDay)
    }

    /// `DATEDIF`, units and quirks included: `MD` counts back into the month
    /// before the end date when the days do not line up.
    static func dateDifference(_ startSerial: Double, _ endSerial: Double, unit raw: String) throws(CellError) -> Int {
        let start = components(fromSerial: startSerial)
        let end = components(fromSerial: endSerial)
        var months = (end.year - start.year) * 12 + (end.month - start.month)
        if end.day < start.day { months -= 1 }
        switch raw.uppercased() {
        case "Y": return months / 12
        case "M": return months
        case "D": return Int(endSerial - startSerial)
        case "YM": return months % 12
        case "MD":
            var days = end.day - start.day
            if days < 0 {
                let previousMonth = end.month == 1 ? 12 : end.month - 1
                let previousYear = end.month == 1 ? end.year - 1 : end.year
                days += daysInMonth(previousYear, previousMonth)
            }
            return days
        case "YD":
            var anniversary = serial(year: end.year, month: start.month, day: min(start.day, daysInMonth(end.year, start.month)))
            if anniversary > endSerial {
                anniversary = serial(year: end.year - 1, month: start.month,
                                     day: min(start.day, daysInMonth(end.year - 1, start.month)))
            }
            return Int(endSerial - anniversary)
        default:
            throw .numberError
        }
    }

    /// A date moved by whole months, its day held within the new month, or
    /// pinned to the month's end.
    static func addingMonths(_ months: Int, to date: Components, endOfMonth: Bool) -> Double {
        let total = date.year * 12 + (date.month - 1) + months
        let year = total >= 0 ? total / 12 : (total - 11) / 12
        let month = total - year * 12 + 1
        let length = daysInMonth(year, month)
        return serial(year: year, month: month, day: endOfMonth ? length : min(date.day, length))
    }

    /// The ISO 8601 week number: weeks start on Monday and week 1 holds the
    /// year's first Thursday.
    static func isoWeek(_ serial: Double) -> Int {
        let mondayBased = (weekday(ofSerial: serial) + 5) % 7  // Monday 0 … Sunday 6
        let thursday = serial - Double(mondayBased) + 3
        let year = components(fromSerial: thursday).year
        let firstDay = Self.serial(year: year, month: 1, day: 1)
        return Int(((thursday - firstDay) / 7).rounded(.down)) + 1
    }

    /// Which days of the week are the weekend, Monday first, from a weekend
    /// code or a seven-character mask such as `"0000011"`.
    static func weekendMask(_ call: FunctionCall, _ index: Int?) throws(CellError) -> [Bool] {
        guard let index, !call.isMissing(index) else { return [false, false, false, false, false, true, true] }
        if case .text(let text) = call.scalar(index) {
            guard text.count == 7, text.allSatisfy({ $0 == "0" || $0 == "1" }), text != "1111111" else {
                throw .valueError
            }
            return text.map { $0 == "1" }
        }
        let code = try call.integer(index)
        var mask = [Bool](repeating: false, count: 7)
        switch code {
        case 1...7:
            // 1 is Saturday and Sunday, 2 Sunday and Monday, through 7 Friday and Saturday.
            mask[(code + 4) % 7] = true
            mask[(code + 5) % 7] = true
        case 11...17:
            // 11 is Sunday alone, 12 Monday, through 17 Saturday.
            mask[(code - 11 + 6) % 7] = true
        default:
            throw .numberError
        }
        return mask
    }

    static func holidays(_ call: FunctionCall, _ index: Int) throws(CellError) -> Set<Double> {
        guard !call.isMissing(index) else { return [] }
        var result: Set<Double> = []
        for cell in try call.matrix(index).flatMap({ $0 }) {
            switch cell {
            case .number(let serial): result.insert(serial.rounded(.down))
            case .text(let text):
                guard let serial = FormulaValueParser.dateTime(from: text) else { throw .valueError }
                result.insert(serial.rounded(.down))
            case .error(let error): throw error
            case .empty: continue
            case .boolean: throw .valueError
            }
        }
        return result
    }

    private static func isWorkday(_ serial: Double, weekend: [Bool], holidays: Set<Double>) -> Bool {
        let mondayBased = (weekday(ofSerial: serial) + 5) % 7
        return !weekend[mondayBased] && !holidays.contains(serial)
    }

    static func networkDays(_ call: FunctionCall, weekendIndex: Int?, holidaysIndex: Int) throws(CellError) -> FormulaValue {
        let start = try serial(call, 0).rounded(.down)
        let end = try serial(call, 1).rounded(.down)
        let weekend = try weekendMask(call, weekendIndex)
        let holidays = try holidays(call, holidaysIndex)
        let low = min(start, end)
        let high = max(start, end)
        // Whole weeks in bulk, the remainder a day at a time.
        let workdaysPerWeek = weekend.filter { !$0 }.count
        let span = Int(high - low) + 1
        var count = (span / 7) * workdaysPerWeek
        var day = low + Double((span / 7) * 7)
        while day <= high {
            if isWorkday(day, weekend: weekend, holidays: []) { count += 1 }
            day += 1
        }
        count -= holidays.filter { $0 >= low && $0 <= high && isWorkday($0, weekend: weekend, holidays: []) }.count
        return .number(Double(start <= end ? count : -count))
    }

    static func workday(_ call: FunctionCall, weekendIndex: Int?, holidaysIndex: Int) throws(CellError) -> FormulaValue {
        var day = try serial(call, 0).rounded(.down)
        let count = try call.integer(1)
        let weekend = try weekendMask(call, weekendIndex)
        let holidays = try holidays(call, holidaysIndex)
        let step: Double = count >= 0 ? 1 : -1
        var remaining = abs(count)
        while remaining > 0 {
            day += step
            guard day >= 0, day <= maximumSerial else { throw .numberError }
            if isWorkday(day, weekend: weekend, holidays: holidays) { remaining -= 1 }
        }
        return .number(day)
    }

    /// The fraction of a year between two dates under one of Excel's five
    /// day-count conventions.
    static func yearFraction(_ startSerial: Double, _ endSerial: Double, basis: Int) -> Double {
        let start = components(fromSerial: startSerial)
        let end = components(fromSerial: endSerial)
        switch basis {
        case 0:
            var d1 = start.day
            var d2 = end.day
            let startIsFebruaryEnd = start.month == 2 && isLastDayOfMonth(start)
            let endIsFebruaryEnd = end.month == 2 && isLastDayOfMonth(end)
            if (d1 == 31 && d2 == 31) || (startIsFebruaryEnd && endIsFebruaryEnd) {
                d1 = 30
                d2 = 30
            } else if d1 == 31 || startIsFebruaryEnd {
                d1 = 30
            } else if d1 == 30, d2 == 31 {
                d2 = 30
            }
            let days = (end.year - start.year) * 360 + (end.month - start.month) * 30 + (d2 - d1)
            return Double(days) / 360
        case 1:
            let days = endSerial - startSerial
            if start.year == end.year {
                return days / (isLeapYear(start.year) ? 366 : 365)
            }
            let anniversary = addingMonths(12, to: start, endOfMonth: false)
            if endSerial <= anniversary {
                let startsBeforeLeapDay = isLeapYear(start.year) && startSerial <= serial(year: start.year, month: 2, day: 29)
                let endsAfterLeapDay = isLeapYear(end.year) && endSerial >= serial(year: end.year, month: 2, day: 29)
                return days / (startsBeforeLeapDay || endsAfterLeapDay ? 366 : 365)
            }
            let years = Double(end.year - start.year + 1)
            let total = serial(year: end.year + 1, month: 1, day: 1) - serial(year: start.year, month: 1, day: 1)
            return days / (total / years)
        case 2:
            return (endSerial - startSerial) / 360
        case 3:
            return (endSerial - startSerial) / 365
        default:
            return Double(days360(start, end, european: true)) / 360
        }
    }
}
