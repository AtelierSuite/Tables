import Foundation

private typealias F = FormulaFinance

extension FormulaFunctions {
    public static let financialFunctions: [String: FunctionSpec] = [
        // MARK: Time value of money
        "PV": FunctionSpec(3...5) { call throws(CellError) in
            .number(F.presentValue(rate: try call.number(0), periods: try call.number(1), payment: try call.number(2),
                                   future: try call.number(3, default: 0), due: try F.due(call, 4)))
        },
        "FV": FunctionSpec(3...5) { call throws(CellError) in
            .number(F.futureValue(rate: try call.number(0), periods: try call.number(1), payment: try call.number(2),
                                  present: try call.number(3, default: 0), due: try F.due(call, 4)))
        },
        "PMT": FunctionSpec(3...5) { call throws(CellError) in
            let periods = try call.number(1)
            guard periods != 0 else { throw .numberError }
            return .number(F.payment(rate: try call.number(0), periods: periods, present: try call.number(2),
                                     future: try call.number(3, default: 0), due: try F.due(call, 4)))
        },
        "NPER": FunctionSpec(3...5) { call throws(CellError) in
            let rate = try call.number(0)
            let payment = try call.number(1)
            let present = try call.number(2)
            let future = try call.number(3, default: 0)
            let due = try F.due(call, 4)
            if rate == 0 {
                guard payment != 0 else { throw .numberError }
                return .number(-(present + future) / payment)
            }
            let numerator = payment * (1 + rate * due) - future * rate
            let denominator = payment * (1 + rate * due) + present * rate
            guard denominator != 0, numerator / denominator > 0 else { throw .numberError }
            return .number(log(numerator / denominator) / log1p(rate))
        },
        "RATE": FunctionSpec(3...6) { call throws(CellError) in
            let periods = try call.number(0)
            let payment = try call.number(1)
            let present = try call.number(2)
            let future = try call.number(3, default: 0)
            let due = try F.due(call, 4)
            let guess = try call.number(5, default: 0.1)
            guard periods > 0, let rate = F.solve(guess: guess, { rate in
                F.futureValue(rate: rate, periods: periods, payment: payment, present: present, due: due) + future
            }) else { throw .numberError }
            return .number(rate)
        },
        "IPMT": FunctionSpec(4...6) { call throws(CellError) in
            .number(try F.interestPayment(call, period: try call.number(1)))
        },
        "PPMT": FunctionSpec(4...6) { call throws(CellError) in
            let rate = try call.number(0)
            let periods = try call.number(2)
            let payment = F.payment(rate: rate, periods: periods, present: try call.number(3),
                                    future: try call.number(4, default: 0), due: try F.due(call, 5))
            return .number(payment - (try F.interestPayment(call, period: try call.number(1))))
        },
        "CUMIPMT": FunctionSpec(6...6) { call throws(CellError) in
            try F.cumulative(call, principal: false)
        },
        "CUMPRINC": FunctionSpec(6...6) { call throws(CellError) in
            try F.cumulative(call, principal: true)
        },
        "ISPMT": FunctionSpec(4...4) { call throws(CellError) in
            let periods = try call.number(2)
            guard periods != 0 else { throw .divideByZero }
            return .number(try call.number(3) * call.number(0) * (try call.number(1) / periods - 1))
        },
        "EFFECT": FunctionSpec(2...2) { call throws(CellError) in
            let nominal = try call.number(0)
            let periods = try call.number(1).rounded(.towardZero)
            guard nominal > 0, periods >= 1 else { throw .numberError }
            return .number(pow(1 + nominal / periods, periods) - 1)
        },
        "NOMINAL": FunctionSpec(2...2) { call throws(CellError) in
            let effective = try call.number(0)
            let periods = try call.number(1).rounded(.towardZero)
            guard effective > 0, periods >= 1 else { throw .numberError }
            return .number(periods * (pow(1 + effective, 1 / periods) - 1))
        },
        "PDURATION": FunctionSpec(3...3) { call throws(CellError) in
            let rate = try call.number(0)
            let present = try call.number(1)
            let future = try call.number(2)
            guard rate > 0, present > 0, future > 0 else { throw .numberError }
            return .number((log(future) - log(present)) / log1p(rate))
        },
        "RRI": FunctionSpec(3...3) { call throws(CellError) in
            let periods = try call.number(0)
            let present = try call.number(1)
            let future = try call.number(2)
            guard periods > 0, present != 0 else { throw .numberError }
            return .number(pow(future / present, 1 / periods) - 1)
        },
        "FVSCHEDULE": FunctionSpec(2...2, lifts: .only([0])) { call throws(CellError) in
            var value = try call.number(0)
            for cell in try call.matrix(1).flatMap({ $0 }) {
                switch cell {
                case .number(let rate): value *= 1 + rate
                case .empty: continue
                case .error(let error): throw error
                default: throw .valueError
                }
            }
            return .number(value)
        },
        "DOLLARDE": FunctionSpec(2...2) { call throws(CellError) in
            let value = try call.number(0)
            let fraction = try call.number(1).rounded(.towardZero)
            guard fraction >= 0 else { throw .numberError }
            guard fraction > 0 else { throw .divideByZero }
            let whole = value.rounded(.towardZero)
            let scale = pow(10, ceil(log10(fraction)))
            return .number(whole + (value - whole) * scale / fraction)
        },
        "DOLLARFR": FunctionSpec(2...2) { call throws(CellError) in
            let value = try call.number(0)
            let fraction = try call.number(1).rounded(.towardZero)
            guard fraction >= 0 else { throw .numberError }
            guard fraction > 0 else { throw .divideByZero }
            let whole = value.rounded(.towardZero)
            let scale = pow(10, ceil(log10(fraction)))
            return .number(whole + (value - whole) * fraction / scale)
        },

        // MARK: Cash flows
        "NPV": FunctionSpec(2...255, lifts: .none) { call throws(CellError) in
            let rate = try call.number(0)
            guard rate != -1 else { throw .divideByZero }
            let values = try call.numbers(1..<call.count)
            var total = 0.0
            for (index, value) in values.enumerated() { total += value / pow(1 + rate, Double(index + 1)) }
            return .number(total)
        },
        "XNPV": FunctionSpec(3...3, lifts: .none) { call throws(CellError) in
            let rate = try call.number(0)
            let (values, dates) = try F.datedFlows(call, valuesIndex: 1, datesIndex: 2)
            guard rate > -1 else { throw .numberError }
            return .number(F.datedPresentValue(rate, values, dates))
        },
        "IRR": FunctionSpec(1...2, lifts: .none) { call throws(CellError) in
            let values = try call.numbers([0])
            guard values.contains(where: { $0 > 0 }), values.contains(where: { $0 < 0 }) else { throw .numberError }
            guard let rate = F.solve(guess: try call.number(1, default: 0.1), { rate in
                var total = 0.0
                for (index, value) in values.enumerated() { total += value / pow(1 + rate, Double(index)) }
                return total
            }) else { throw .numberError }
            return .number(rate)
        },
        "XIRR": FunctionSpec(2...3, lifts: .none) { call throws(CellError) in
            let (values, dates) = try F.datedFlows(call, valuesIndex: 0, datesIndex: 1)
            guard values.contains(where: { $0 > 0 }), values.contains(where: { $0 < 0 }) else { throw .numberError }
            guard let rate = F.solve(guess: try call.number(2, default: 0.1), { F.datedPresentValue($0, values, dates) }) else {
                throw .numberError
            }
            return .number(rate)
        },
        "MIRR": FunctionSpec(3...3, lifts: .none) { call throws(CellError) in
            let values = try call.numbers([0])
            let financeRate = try call.number(1)
            let reinvestRate = try call.number(2)
            let n = Double(values.count)
            guard values.count >= 2 else { throw .divideByZero }
            var negative = 0.0
            var positive = 0.0
            for (index, value) in values.enumerated() {
                if value < 0 {
                    negative += value / pow(1 + financeRate, Double(index))
                } else {
                    positive += value * pow(1 + reinvestRate, n - 1 - Double(index))
                }
            }
            guard negative != 0, positive != 0 else { throw .divideByZero }
            return .number(pow(-positive / negative, 1 / (n - 1)) - 1)
        },

        // MARK: Depreciation
        "SLN": FunctionSpec(3...3) { call throws(CellError) in
            let life = try call.number(2)
            guard life != 0 else { throw .divideByZero }
            return .number((try call.number(0) - call.number(1)) / life)
        },
        "SYD": FunctionSpec(4...4) { call throws(CellError) in
            let cost = try call.number(0)
            let salvage = try call.number(1)
            let life = try call.number(2)
            let period = try call.number(3)
            guard life > 0, period > 0, period <= life, salvage >= 0 else { throw .numberError }
            return .number((cost - salvage) * (life - period + 1) * 2 / (life * (life + 1)))
        },
        "DB": FunctionSpec(4...5) { call throws(CellError) in
            let cost = try call.number(0)
            let salvage = try call.number(1)
            let life = try call.number(2)
            let period = try call.number(3).rounded(.towardZero)
            let months = try call.number(4, default: 12).rounded(.towardZero)
            guard cost >= 0, salvage >= 0, life > 0, period >= 1, months >= 1, months <= 12,
                  period <= life + (months < 12 ? 1 : 0) else { throw .numberError }
            if cost == 0 { return .number(0) }
            let rate = FormulaMath.round(1 - pow(salvage / cost, 1 / life), digits: 3, rule: .toNearestOrAwayFromZero)
            var total = cost * rate * months / 12
            if period == 1 { return .number(total) }
            var depreciation = 0.0
            var current = 2.0
            while current <= period {
                depreciation = current == life + 1
                    ? (cost - total) * rate * (12 - months) / 12
                    : (cost - total) * rate
                total += depreciation
                current += 1
            }
            return .number(depreciation)
        },
        "DDB": FunctionSpec(4...5) { call throws(CellError) in
            let cost = try call.number(0)
            let salvage = try call.number(1)
            let life = try call.number(2)
            let period = try call.number(3)
            let factor = try call.number(4, default: 2)
            guard cost >= 0, salvage >= 0, life > 0, period > 0, period <= life, factor > 0 else { throw .numberError }
            return .number(F.decliningBalance(cost: cost, salvage: salvage, life: life, period: period, factor: factor))
        },
        "VDB": FunctionSpec(5...7) { call throws(CellError) in
            let cost = try call.number(0)
            let salvage = try call.number(1)
            let life = try call.number(2)
            let start = try call.number(3)
            let end = try call.number(4)
            let factor = try call.number(5, default: 2)
            let noSwitch = try call.boolean(6, default: false)
            guard cost >= 0, salvage >= 0, life > 0, start >= 0, end >= start, end <= life, factor >= 0 else {
                throw .numberError
            }
            let schedule = F.variableSchedule(cost: cost, salvage: salvage, life: life, factor: factor, switching: !noSwitch)
            return .number(F.accumulated(schedule, to: end) - F.accumulated(schedule, to: start))
        },
        "AMORLINC": FunctionSpec(6...7) { call throws(CellError) in
            let cost = try call.number(0)
            let purchased = try FormulaDates.serial(call, 1).rounded(.down)
            let firstPeriod = try FormulaDates.serial(call, 2).rounded(.down)
            let salvage = try call.number(3)
            let period = try call.number(4).rounded(.towardZero)
            let rate = try call.number(5)
            let basis = try F.basis(call, 6)
            guard cost > 0, salvage >= 0, salvage <= cost, rate > 0, period >= 0, purchased <= firstPeriod,
                  basis != 2 else { throw .numberError }
            let annual = cost * rate
            let first = FormulaDates.yearFraction(purchased, firstPeriod, basis: basis) * rate * cost
            let fullPeriods = ((cost - salvage - first) / annual).rounded(.down)
            if period == 0 { return .number(first) }
            if period <= fullPeriods { return .number(annual) }
            if period == fullPeriods + 1 { return .number(cost - salvage - annual * fullPeriods - first) }
            return .number(0)
        },
        "AMORDEGRC": FunctionSpec(6...7) { call throws(CellError) in
            var cost = try call.number(0)
            let purchased = try FormulaDates.serial(call, 1).rounded(.down)
            let firstPeriod = try FormulaDates.serial(call, 2).rounded(.down)
            let salvage = try call.number(3)
            let period = try call.number(4).rounded(.towardZero)
            var rate = try call.number(5)
            let basis = try F.basis(call, 6)
            guard cost > 0, salvage >= 0, salvage <= cost, rate > 0, period >= 0, purchased <= firstPeriod,
                  basis != 2 else { throw .numberError }
            // The French declining-balance coefficient depends on the asset's life.
            let usefulLife = 1 / rate
            let coefficient: Double = if usefulLife < 3 { 1 } else if usefulLife < 5 { 1.5 } else if usefulLife <= 6 { 2 } else { 2.5 }
            rate *= coefficient
            var depreciation = (FormulaDates.yearFraction(purchased, firstPeriod, basis: basis) * rate * cost).rounded()
            cost -= depreciation
            var rest = cost - salvage
            var n = 0.0
            while n < period {
                depreciation = (rate * cost).rounded()
                rest -= depreciation
                if rest < 0 {
                    return .number(period - n <= 1 ? (cost * 0.5).rounded() : 0)
                }
                cost -= depreciation
                n += 1
            }
            return .number(depreciation)
        },

        // MARK: Coupons
        "COUPDAYBS": FunctionSpec(3...4) { call throws(CellError) in
            let bond = try F.Bond(call, settlement: 0, maturity: 1, frequency: 2, basis: 3)
            return .number(bond.daysFromPreviousCoupon)
        },
        "COUPDAYS": FunctionSpec(3...4) { call throws(CellError) in
            .number(try F.Bond(call, settlement: 0, maturity: 1, frequency: 2, basis: 3).daysInPeriod)
        },
        "COUPDAYSNC": FunctionSpec(3...4) { call throws(CellError) in
            .number(try F.Bond(call, settlement: 0, maturity: 1, frequency: 2, basis: 3).daysToNextCoupon)
        },
        "COUPNCD": FunctionSpec(3...4) { call throws(CellError) in
            .number(try F.Bond(call, settlement: 0, maturity: 1, frequency: 2, basis: 3).nextCoupon)
        },
        "COUPPCD": FunctionSpec(3...4) { call throws(CellError) in
            .number(try F.Bond(call, settlement: 0, maturity: 1, frequency: 2, basis: 3).previousCoupon)
        },
        "COUPNUM": FunctionSpec(3...4) { call throws(CellError) in
            .number(Double(try F.Bond(call, settlement: 0, maturity: 1, frequency: 2, basis: 3).couponCount))
        },

        // MARK: Bonds
        "PRICE": FunctionSpec(6...7) { call throws(CellError) in
            let bond = try F.Bond(call, settlement: 0, maturity: 1, frequency: 5, basis: 6)
            let rate = try call.number(2)
            let yield = try call.number(3)
            let redemption = try call.number(4)
            guard rate >= 0, yield >= 0, redemption > 0 else { throw .numberError }
            return .number(bond.price(rate: rate, yield: yield, redemption: redemption))
        },
        "YIELD": FunctionSpec(6...7) { call throws(CellError) in
            let bond = try F.Bond(call, settlement: 0, maturity: 1, frequency: 5, basis: 6)
            let rate = try call.number(2)
            let price = try call.number(3)
            let redemption = try call.number(4)
            guard rate >= 0, price > 0, redemption > 0 else { throw .numberError }
            return .number(try bond.yield(rate: rate, price: price, redemption: redemption))
        },
        "DURATION": FunctionSpec(5...6) { call throws(CellError) in
            let bond = try F.Bond(call, settlement: 0, maturity: 1, frequency: 4, basis: 5)
            let coupon = try call.number(2)
            let yield = try call.number(3)
            guard coupon >= 0, yield >= 0 else { throw .numberError }
            return .number(bond.duration(coupon: coupon, yield: yield))
        },
        "MDURATION": FunctionSpec(5...6) { call throws(CellError) in
            let bond = try F.Bond(call, settlement: 0, maturity: 1, frequency: 4, basis: 5)
            let coupon = try call.number(2)
            let yield = try call.number(3)
            guard coupon >= 0, yield >= 0 else { throw .numberError }
            return .number(bond.duration(coupon: coupon, yield: yield) / (1 + yield / bond.frequency))
        },
        "ACCRINT": FunctionSpec(6...8) { call throws(CellError) in
            let issue = try FormulaDates.serial(call, 0).rounded(.down)
            let firstInterest = try FormulaDates.serial(call, 1).rounded(.down)
            let settlement = try FormulaDates.serial(call, 2).rounded(.down)
            let rate = try call.number(3)
            let par = try call.number(4, default: 1000)
            let frequency = try call.integer(5)
            let basis = try F.basis(call, 6)
            let fromIssue = try call.boolean(7, default: true)
            guard rate > 0, par > 0, [1, 2, 4].contains(frequency), issue < settlement else { throw .numberError }
            let start = fromIssue || settlement <= firstInterest ? issue : firstInterest
            return .number(par * rate * FormulaDates.yearFraction(start, settlement, basis: basis))
        },
        "ACCRINTM": FunctionSpec(3...5) { call throws(CellError) in
            let issue = try FormulaDates.serial(call, 0).rounded(.down)
            let settlement = try FormulaDates.serial(call, 1).rounded(.down)
            let rate = try call.number(2)
            let par = try call.number(3, default: 1000)
            let basis = try F.basis(call, 4)
            guard rate > 0, par > 0, issue < settlement else { throw .numberError }
            return .number(par * rate * FormulaDates.yearFraction(issue, settlement, basis: basis))
        },
        "DISC": FunctionSpec(4...5) { call throws(CellError) in
            let (fraction, _) = try F.term(call)
            let price = try call.number(2)
            let redemption = try call.number(3)
            guard price > 0, redemption > 0 else { throw .numberError }
            return .number((redemption - price) / redemption / fraction)
        },
        "INTRATE": FunctionSpec(4...5) { call throws(CellError) in
            let (fraction, _) = try F.term(call)
            let investment = try call.number(2)
            let redemption = try call.number(3)
            guard investment > 0, redemption > 0 else { throw .numberError }
            return .number((redemption - investment) / investment / fraction)
        },
        "RECEIVED": FunctionSpec(4...5) { call throws(CellError) in
            let (fraction, _) = try F.term(call)
            let investment = try call.number(2)
            let discount = try call.number(3)
            guard investment > 0, discount > 0, discount * fraction < 1 else { throw .numberError }
            return .number(investment / (1 - discount * fraction))
        },
        "PRICEDISC": FunctionSpec(4...5) { call throws(CellError) in
            let (fraction, _) = try F.term(call)
            let discount = try call.number(2)
            let redemption = try call.number(3)
            guard discount > 0, redemption > 0 else { throw .numberError }
            return .number(redemption * (1 - discount * fraction))
        },
        "YIELDDISC": FunctionSpec(4...5) { call throws(CellError) in
            let (fraction, _) = try F.term(call)
            let price = try call.number(2)
            let redemption = try call.number(3)
            guard price > 0, redemption > 0 else { throw .numberError }
            return .number((redemption / price - 1) / fraction)
        },
        "PRICEMAT": FunctionSpec(5...6) { call throws(CellError) in
            let (fractions, rate, yield) = try F.maturityTerms(call)
            guard yield >= 0 else { throw .numberError }
            let price = (1 + fractions.issueToMaturity * rate) / (1 + fractions.settlementToMaturity * yield)
                - fractions.issueToSettlement * rate
            return .number(price * 100)
        },
        "YIELDMAT": FunctionSpec(5...6) { call throws(CellError) in
            let (fractions, rate, price) = try F.maturityTerms(call)
            guard price > 0 else { throw .numberError }
            let value = (1 + fractions.issueToMaturity * rate) / (price / 100 + fractions.issueToSettlement * rate) - 1
            return .number(value / fractions.settlementToMaturity)
        },
        "TBILLPRICE": FunctionSpec(3...3) { call throws(CellError) in
            let days = try F.billDays(call)
            let discount = try call.number(2)
            guard discount > 0 else { throw .numberError }
            let price = 100 * (1 - discount * days / 360)
            guard price > 0 else { throw .numberError }
            return .number(price)
        },
        "TBILLYIELD": FunctionSpec(3...3) { call throws(CellError) in
            let days = try F.billDays(call)
            let price = try call.number(2)
            guard price > 0 else { throw .numberError }
            return .number((100 - price) / price * 360 / days)
        },
        "TBILLEQ": FunctionSpec(3...3) { call throws(CellError) in
            let days = try F.billDays(call)
            let discount = try call.number(2)
            guard discount > 0 else { throw .numberError }
            if days <= 182 { return .number(365 * discount / (360 - discount * days)) }
            let price = 1 - discount * days / 360
            guard price > 0 else { throw .numberError }
            let term = days / 365
            let root = term * term - (2 * term - 1) * (1 - 1 / price)
            guard root >= 0 else { throw .numberError }
            return .number((-2 * term + 2 * root.squareRoot()) / (2 * term - 1))
        },
        "ODDLPRICE": FunctionSpec(7...8) { call throws(CellError) in
            let odd = try F.OddLastPeriod(call)
            let yield = try call.number(4)
            guard yield >= 0 else { throw .numberError }
            return .number(odd.price(yield: yield))
        },
        "ODDLYIELD": FunctionSpec(7...8) { call throws(CellError) in
            let odd = try F.OddLastPeriod(call)
            let price = try call.number(4)
            guard price > 0 else { throw .numberError }
            return .number(odd.yield(price: price))
        },
        "ODDFPRICE": FunctionSpec(8...9) { call throws(CellError) in
            let odd = try F.OddFirstPeriod(call)
            let yield = try call.number(5)
            guard yield >= 0 else { throw .numberError }
            return .number(odd.price(yield: yield))
        },
        "ODDFYIELD": FunctionSpec(8...9) { call throws(CellError) in
            let odd = try F.OddFirstPeriod(call)
            let price = try call.number(5)
            guard price > 0 else { throw .numberError }
            guard let yield = F.solve(guess: odd.rate, { odd.price(yield: $0) - price }) else { throw .numberError }
            return .number(yield)
        },
    ]
}

/// The arithmetic behind the financial functions.
public enum FormulaFinance {
    /// The payment-timing argument: 0 at the end of each period, 1 at the start.
    public static func due(_ call: FunctionCall, _ index: Int) throws(CellError) -> Double {
        try call.number(index, default: 0) != 0 ? 1 : 0
    }

    public static func basis(_ call: FunctionCall, _ index: Int) throws(CellError) -> Int {
        let basis = try call.integer(index, default: 0)
        guard (0...4).contains(basis) else { throw .numberError }
        return basis
    }

    public static func presentValue(rate: Double, periods: Double, payment: Double, future: Double, due: Double) -> Double {
        if rate == 0 { return -(future + payment * periods) }
        // expm1/log1p preserve the annuity factor when the rate is near zero.
        let increment = rate > -1 ? expm1(periods * log1p(rate)) : pow(1 + rate, periods) - 1
        let growth = increment + 1
        return -(future + payment * (1 + rate * due) * increment / rate) / growth
    }

    public static func futureValue(rate: Double, periods: Double, payment: Double, present: Double, due: Double) -> Double {
        if rate == 0 { return -(present + payment * periods) }
        // expm1/log1p preserve the annuity factor when the rate is near zero.
        let increment = rate > -1 ? expm1(periods * log1p(rate)) : pow(1 + rate, periods) - 1
        let growth = increment + 1
        return -(present * growth + payment * (1 + rate * due) * increment / rate)
    }

    public static func payment(rate: Double, periods: Double, present: Double, future: Double, due: Double) -> Double {
        if rate == 0 { return -(present + future) / periods }
        // expm1/log1p preserve the annuity factor when the rate is near zero.
        let increment = rate > -1 ? expm1(periods * log1p(rate)) : pow(1 + rate, periods) - 1
        let growth = increment + 1
        return -(present * growth + future) * rate / ((1 + rate * due) * increment)
    }

    /// The interest part of one payment, arguments as `IPMT` takes them.
    public static func interestPayment(_ call: FunctionCall, period: Double) throws(CellError) -> Double {
        let rate = try call.number(0)
        let periods = try call.number(2)
        let present = try call.number(3)
        let future = try call.number(4, default: 0)
        let due = try due(call, 5)
        guard period >= 1, period <= periods else { throw .numberError }
        let payment = payment(rate: rate, periods: periods, present: present, future: future, due: due)
        if due == 1, period == 1 { return 0 }
        var interest = futureValue(rate: rate, periods: period - 1, payment: payment, present: present, due: due) * rate
        if due == 1 { interest /= 1 + rate }
        return interest
    }

    /// `CUMIPMT` and `CUMPRINC`: interest or principal summed over a run of periods.
    public static func cumulative(_ call: FunctionCall, principal: Bool) throws(CellError) -> FormulaValue {
        let rate = try call.number(0)
        let periods = try call.number(1).rounded(.towardZero)
        let present = try call.number(2)
        let first = try call.number(3).rounded(.towardZero)
        let last = try call.number(4).rounded(.towardZero)
        let dueValue = try call.number(5)
        guard rate > 0, periods > 0, present > 0, first >= 1, last >= first, last <= periods,
              dueValue == 0 || dueValue == 1 else { throw .numberError }
        let due = dueValue
        let payment = payment(rate: rate, periods: periods, present: present, future: 0, due: due)
        var total = 0.0
        var period = first
        while period <= last {
            var interest = 0.0
            if !(due == 1 && period == 1) {
                interest = futureValue(rate: rate, periods: period - 1, payment: payment, present: present, due: due) * rate
                if due == 1 { interest /= 1 + rate }
            }
            total += principal ? payment - interest : interest
            period += 1
        }
        return .number(total)
    }

    /// A root of `function` near `guess`, by Newton's method with a numeric
    /// derivative, falling back to bisection across a sign change.
    public static func solve(guess: Double, _ function: (Double) -> Double) -> Double? {
        var x = guess
        for _ in 0..<100 {
            let value = function(x)
            guard value.isFinite else { break }
            if abs(value) < 1e-10 { return x }
            let step = max(1e-7, abs(x) * 1e-7)
            let slope = (function(x + step) - function(x - step)) / (2 * step)
            guard slope != 0, slope.isFinite else { break }
            let next = x - value / slope
            if abs(next - x) < 1e-12 * max(1, abs(x)) { return next }
            x = next <= -1 ? (x - 1) / 2 : next
        }
        // Scan for a bracket and bisect.
        var low = -0.9999
        var lowValue = function(low)
        for high in stride(from: -0.99, through: 10.0, by: 0.01) {
            let highValue = function(high)
            if lowValue.isFinite, highValue.isFinite, lowValue.sign != highValue.sign {
                var a = low
                var b = high
                var fa = lowValue
                for _ in 0..<200 {
                    let middle = (a + b) / 2
                    let value = function(middle)
                    if abs(value) < 1e-12 || b - a < 1e-15 { return middle }
                    if value.sign == fa.sign { a = middle; fa = value } else { b = middle }
                }
                return (a + b) / 2
            }
            low = high
            lowValue = highValue
        }
        return nil
    }

    /// Values and dates for `XNPV` and `XIRR`, which must pair up, with no
    /// date before the first.
    public static func datedFlows(_ call: FunctionCall, valuesIndex: Int, datesIndex: Int) throws(CellError) -> ([Double], [Double]) {
        let values = try call.matrix(valuesIndex).flatMap { $0 }
        let dates = try call.matrix(datesIndex).flatMap { $0 }
        guard values.count == dates.count, !values.isEmpty else { throw .numberError }
        var amounts: [Double] = []
        var days: [Double] = []
        for (value, date) in zip(values, dates) {
            guard case .number(let amount) = value else { throw .valueError }
            let serial = try date.coercedNumber().rounded(.down)
            amounts.append(amount)
            days.append(serial)
        }
        guard let first = days.first, days.allSatisfy({ $0 >= first }) else { throw .numberError }
        return (amounts, days)
    }

    public static func datedPresentValue(_ rate: Double, _ values: [Double], _ dates: [Double]) -> Double {
        var total = 0.0
        for (value, date) in zip(values, dates) { total += value / pow(1 + rate, (date - dates[0]) / 365) }
        return total
    }

    // MARK: Depreciation

    /// Double-declining (or any factor) balance depreciation for a period,
    /// which may be fractional, never taking the value below salvage.
    public static func decliningBalance(cost: Double, salvage: Double, life: Double, period: Double, factor: Double) -> Double {
        let rate = min(1, factor / life)
        let firstPeriodOnly: Double = period <= 1 ? cost : 0
        let previous = rate >= 1 ? firstPeriodOnly : cost * pow(1 - rate, period - 1)
        let current = rate >= 1 ? 0 : cost * pow(1 - rate, period)
        let depreciation = current < salvage ? previous - salvage : previous - current
        return max(0, depreciation)
    }

    /// `VDB`'s schedule of depreciation for each whole period, switching to
    /// straight line once that is the larger, unless told not to.
    public static func variableSchedule(cost: Double, salvage: Double, life: Double, factor: Double, switching: Bool) -> [Double] {
        var schedule: [Double] = []
        var book = cost
        var period = 0.0
        var straightLine = false
        while period < life {
            let remaining = life - period
            let declining = min(book * factor / life, max(0, book - salvage))
            let linear = max(0, (book - salvage) / remaining)
            if switching, !straightLine, linear > declining { straightLine = true }
            let amount = straightLine ? linear : declining
            schedule.append(amount)
            book -= amount
            period += 1
        }
        return schedule
    }

    /// Depreciation accumulated up to a point in time, prorating a period
    /// that is only partly reached.
    public static func accumulated(_ schedule: [Double], to time: Double) -> Double {
        let whole = Int(time.rounded(.down))
        var total = schedule.prefix(whole).reduce(0, +)
        let fraction = time - Double(whole)
        if fraction > 0, whole < schedule.count { total += schedule[whole] * fraction }
        return total
    }

    // MARK: Securities

    /// Settlement-to-maturity as a year fraction, for the discount functions.
    public static func term(_ call: FunctionCall) throws(CellError) -> (Double, Int) {
        let settlement = try FormulaDates.serial(call, 0).rounded(.down)
        let maturity = try FormulaDates.serial(call, 1).rounded(.down)
        let basis = try basis(call, 4)
        guard settlement < maturity else { throw .numberError }
        return (FormulaDates.yearFraction(settlement, maturity, basis: basis), basis)
    }

    public struct MaturityFractions: Sendable {
        public var issueToMaturity: Double
        public var issueToSettlement: Double
        public var settlementToMaturity: Double
    }

    /// `PRICEMAT` and `YIELDMAT`'s dates as year fractions, the rate, and the
    /// fifth argument, which is the yield for one and the price for the other.
    public static func maturityTerms(_ call: FunctionCall) throws(CellError) -> (MaturityFractions, Double, Double) {
        let settlement = try FormulaDates.serial(call, 0).rounded(.down)
        let maturity = try FormulaDates.serial(call, 1).rounded(.down)
        let issue = try FormulaDates.serial(call, 2).rounded(.down)
        let rate = try call.number(3)
        let fifth = try call.number(4)
        let basis = try basis(call, 5)
        guard settlement < maturity, issue < settlement, rate >= 0 else { throw .numberError }
        return (MaturityFractions(
            issueToMaturity: FormulaDates.yearFraction(issue, maturity, basis: basis),
            issueToSettlement: FormulaDates.yearFraction(issue, settlement, basis: basis),
            settlementToMaturity: FormulaDates.yearFraction(settlement, maturity, basis: basis)
        ), rate, fifth)
    }

    /// Days to a Treasury bill's maturity, which may be at most a year away.
    public static func billDays(_ call: FunctionCall) throws(CellError) -> Double {
        let settlement = try FormulaDates.serial(call, 0).rounded(.down)
        let maturity = try FormulaDates.serial(call, 1).rounded(.down)
        let yearLater = FormulaDates.addingMonths(12, to: FormulaDates.components(fromSerial: settlement), endOfMonth: false)
        guard settlement < maturity, maturity <= yearLater else { throw .numberError }
        return maturity - settlement
    }

    /// Days between two dates by a day-count basis.
    public static func days(_ start: Double, _ end: Double, basis: Int) -> Double {
        switch basis {
        case 0:
            return Double(FormulaDates.days360(FormulaDates.components(fromSerial: start),
                                               FormulaDates.components(fromSerial: end), european: false))
        case 4:
            return Double(FormulaDates.days360(FormulaDates.components(fromSerial: start),
                                               FormulaDates.components(fromSerial: end), european: true))
        default:
            return end - start
        }
    }

    /// Coupon dates walk back from maturity in steps of 12 / frequency
    /// months, keeping to the month's end when maturity falls on one.
    public static func couponDate(maturity: Double, stepsBack: Int, frequency: Int) -> Double {
        let date = FormulaDates.components(fromSerial: maturity)
        return FormulaDates.addingMonths(-stepsBack * 12 / frequency, to: date,
                                         endOfMonth: FormulaDates.isLastDayOfMonth(date))
    }

    /// A coupon-paying security between settlement and maturity.
    public struct Bond: Sendable {
        public let settlement: Double
        public let maturity: Double
        public let frequency: Double
        public let basis: Int
        public let previousCoupon: Double
        public let nextCoupon: Double
        public let couponCount: Int

        public init(_ call: FunctionCall, settlement s: Int, maturity m: Int, frequency f: Int, basis b: Int) throws(CellError) {
            settlement = try FormulaDates.serial(call, s).rounded(.down)
            maturity = try FormulaDates.serial(call, m).rounded(.down)
            let periods = try call.integer(f)
            basis = try FormulaFinance.basis(call, b)
            guard settlement < maturity, [1, 2, 4].contains(periods) else { throw .numberError }
            frequency = Double(periods)
            var steps = 1
            while FormulaFinance.couponDate(maturity: maturity, stepsBack: steps, frequency: periods) > settlement {
                steps += 1
            }
            previousCoupon = FormulaFinance.couponDate(maturity: maturity, stepsBack: steps, frequency: periods)
            nextCoupon = FormulaFinance.couponDate(maturity: maturity, stepsBack: steps - 1, frequency: periods)
            couponCount = steps
        }

        public var daysInPeriod: Double {
            switch basis {
            case 1: return nextCoupon - previousCoupon
            case 3: return 365 / frequency
            default: return 360 / frequency
            }
        }

        public var daysFromPreviousCoupon: Double { FormulaFinance.days(previousCoupon, settlement, basis: basis) }

        public var daysToNextCoupon: Double {
            basis == 0 ? daysInPeriod - daysFromPreviousCoupon : FormulaFinance.days(settlement, nextCoupon, basis: basis)
        }

        public func price(rate: Double, yield: Double, redemption: Double) -> Double {
            let e = daysInPeriod
            let dsc = daysToNextCoupon
            let a = daysFromPreviousCoupon
            let coupon = 100 * rate / frequency
            let n = Double(couponCount)
            if couponCount == 1 {
                return (redemption + coupon) / (1 + dsc / e * yield / frequency) - coupon * a / e
            }
            let base = 1 + yield / frequency
            var total = redemption / pow(base, n - 1 + dsc / e)
            var k = 1.0
            while k <= n {
                total += coupon / pow(base, k - 1 + dsc / e)
                k += 1
            }
            return total - coupon * a / e
        }

        public func yield(rate: Double, price: Double, redemption: Double) throws(CellError) -> Double {
            if couponCount == 1 {
                let e = daysInPeriod
                let a = daysFromPreviousCoupon
                let dsr = e - a
                let coupon = rate / frequency
                let accrued = price / 100 + a / e * coupon
                return ((redemption / 100 + coupon) - accrued) / accrued * (frequency * e / dsr)
            }
            guard let result = FormulaFinance.solve(guess: rate == 0 ? 0.05 : rate, {
                self.price(rate: rate, yield: $0, redemption: redemption) - price
            }) else { throw .numberError }
            return result
        }

        /// Macaulay duration in years, each cash flow timed by the coupon
        /// schedule: the first falls `DSC/E` of a period away.
        public func duration(coupon: Double, yield: Double) -> Double {
            let n = Double(couponCount)
            let payment = 100 * coupon / frequency
            let base = 1 + yield / frequency
            let offset = daysToNextCoupon / daysInPeriod - 1
            var weighted = 0.0
            var value = 0.0
            var t = 1.0
            while t < n {
                weighted += (t + offset) * payment / pow(base, t + offset)
                value += payment / pow(base, t + offset)
                t += 1
            }
            weighted += (n + offset) * (payment + 100) / pow(base, n + offset)
            value += (payment + 100) / pow(base, n + offset)
            return weighted / value / frequency
        }
    }

    /// Quasi-coupon periods covering an odd period: the regular schedule's
    /// periods that the odd one overlaps, for the `ODD…` functions.
    public static func quasiPeriods(from start: Double, to end: Double, anchor: Double, frequency: Int, forward: Bool) -> [(Double, Double)] {
        var periods: [(Double, Double)] = []
        let date = FormulaDates.components(fromSerial: anchor)
        let endOfMonth = FormulaDates.isLastDayOfMonth(date)
        var step = 0
        while periods.count < 1000 {
            let months = (forward ? step : -step) * 12 / frequency
            let next = (forward ? step + 1 : -(step + 1)) * 12 / frequency
            let a = FormulaDates.addingMonths(months, to: date, endOfMonth: endOfMonth)
            let b = FormulaDates.addingMonths(next, to: date, endOfMonth: endOfMonth)
            let period = forward ? (a, b) : (b, a)
            if forward ? period.0 >= end : period.1 <= start { break }
            periods.append(period)
            step += 1
        }
        return forward ? periods : periods.reversed()
    }

    /// A security whose last coupon period is odd.
    /// Days in a quasi-coupon period: actual under basis 1, otherwise a
    /// fixed share of a 365- or 360-day year.
    public static func quasiPeriodLength(_ start: Double, _ end: Double, basis: Int, frequency: Double) -> Double {
        if basis == 1 { return end - start }
        return (basis == 3 ? 365 : 360) / frequency
    }

    public struct OddLastPeriod: Sendable {
        public let settlement: Double
        public let maturity: Double
        public let lastInterest: Double
        public let rate: Double
        public let redemption: Double
        public let frequency: Double
        public let basis: Int

        public init(_ call: FunctionCall) throws(CellError) {
            settlement = try FormulaDates.serial(call, 0).rounded(.down)
            maturity = try FormulaDates.serial(call, 1).rounded(.down)
            lastInterest = try FormulaDates.serial(call, 2).rounded(.down)
            rate = try call.number(3)
            redemption = try call.number(5)
            let periods = try call.integer(6)
            basis = try FormulaFinance.basis(call, 7)
            guard rate >= 0, redemption > 0, [1, 2, 4].contains(periods),
                  lastInterest < settlement, settlement < maturity else { throw .numberError }
            frequency = Double(periods)
        }

        /// For each quasi-coupon period: days of the odd period in it, days
        /// accrued before settlement, days from settlement on, and its normal length.
        private var sums: (counted: Double, accrued: Double, remaining: Double) {
            let periods = FormulaFinance.quasiPeriods(from: lastInterest, to: maturity, anchor: lastInterest,
                                                      frequency: Int(frequency), forward: true)
            var counted = 0.0
            var accrued = 0.0
            var remaining = 0.0
            for (start, end) in periods {
                let length = FormulaFinance.quasiPeriodLength(start, end, basis: basis, frequency: frequency)
                let from = max(start, lastInterest)
                let to = min(end, maturity)
                counted += FormulaFinance.days(from, to, basis: basis) / length
                if settlement > from {
                    accrued += FormulaFinance.days(from, min(settlement, to), basis: basis) / length
                }
                if settlement < to {
                    remaining += FormulaFinance.days(max(settlement, from), to, basis: basis) / length
                }
            }
            return (counted, accrued, remaining)
        }

        public func price(yield: Double) -> Double {
            let (counted, accrued, remaining) = sums
            let coupon = 100 * rate / frequency
            return (redemption + counted * coupon) / (1 + remaining * yield / frequency) - accrued * coupon
        }

        public func yield(price: Double) -> Double {
            let (counted, accrued, remaining) = sums
            let coupon = 100 * rate / frequency
            let paid = price + accrued * coupon
            return ((redemption + counted * coupon) - paid) / paid * (frequency / remaining)
        }
    }

    /// A security whose first coupon period is odd, short or long.
    public struct OddFirstPeriod: Sendable {
        public let settlement: Double
        public let maturity: Double
        public let issue: Double
        public let firstCoupon: Double
        public let rate: Double
        public let redemption: Double
        public let frequency: Double
        public let basis: Int

        public init(_ call: FunctionCall) throws(CellError) {
            settlement = try FormulaDates.serial(call, 0).rounded(.down)
            maturity = try FormulaDates.serial(call, 1).rounded(.down)
            issue = try FormulaDates.serial(call, 2).rounded(.down)
            firstCoupon = try FormulaDates.serial(call, 3).rounded(.down)
            rate = try call.number(4)
            redemption = try call.number(6)
            let periods = try call.integer(7)
            basis = try FormulaFinance.basis(call, 8)
            guard rate >= 0, redemption > 0, [1, 2, 4].contains(periods),
                  issue < settlement, settlement < firstCoupon, firstCoupon < maturity else { throw .numberError }
            frequency = Double(periods)
        }

        private func length(_ start: Double, _ end: Double) -> Double {
            FormulaFinance.quasiPeriodLength(start, end, basis: basis, frequency: frequency)
        }

        public func price(yield: Double) -> Double {
            let coupon = 100 * rate / frequency
            let base = 1 + yield / frequency
            // Regular coupons from the first real one to maturity.
            var regular = 0
            while FormulaFinance.couponDate(maturity: maturity, stepsBack: regular + 1, frequency: Int(frequency)) >= firstCoupon {
                regular += 1
            }
            let n = Double(regular + 1)
            let periods = FormulaFinance.quasiPeriods(from: issue, to: firstCoupon, anchor: firstCoupon,
                                                      frequency: Int(frequency), forward: false)
            if periods.count <= 1 {
                // Short first period: one quasi-coupon period holds it all.
                let (start, end) = periods.first ?? (issue, firstCoupon)
                let e = length(start, end)
                let dfc = FormulaFinance.days(issue, firstCoupon, basis: basis)
                let dsc = FormulaFinance.days(settlement, firstCoupon, basis: basis)
                let a = FormulaFinance.days(issue, settlement, basis: basis)
                var total = redemption / pow(base, n - 1 + dsc / e)
                total += coupon * dfc / e / pow(base, dsc / e)
                var k = 2.0
                while k <= n {
                    total += coupon / pow(base, k - 1 + dsc / e)
                    k += 1
                }
                return total - coupon * a / e
            }
            // Long first period: several quasi-coupon periods before the first coupon.
            var counted = 0.0
            var accrued = 0.0
            var wholeAfterSettlement = 0.0
            var dsn = 0.0
            var normal = 0.0
            for (start, end) in periods {
                let size = length(start, end)
                let from = max(start, issue)
                counted += FormulaFinance.days(from, end, basis: basis) / size
                if settlement > from {
                    accrued += FormulaFinance.days(from, min(settlement, end), basis: basis) / size
                }
                if settlement < start {
                    wholeAfterSettlement += 1
                } else if settlement < end {
                    dsn = FormulaFinance.days(settlement, end, basis: basis)
                    normal = size
                }
            }
            let offset = wholeAfterSettlement + (normal > 0 ? dsn / normal : 0)
            var total = redemption / pow(base, n - 1 + offset)
            total += coupon * counted / pow(base, offset)
            var k = 1.0
            while k < n {
                total += coupon / pow(base, k + offset)
                k += 1
            }
            return total - coupon * accrued
        }
    }
}
