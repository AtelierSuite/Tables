import Foundation
import Testing
@testable import Tables
@testable import TablesEngine

/// These functions have no fixed current answer. Their contracts are executed
/// below, rather than counted as covered because their names occur in a file.
let nondeterministicFormulaFunctions: Set<String> = ["RAND", "RANDARRAY", "TODAY", "NOW"]

@Suite("Formula contracts")
struct FormulaContractTests {
    @Test("Each nondeterministic coverage exception executes its contract", arguments: nondeterministicFormulaFunctions.sorted())
    func nondeterministicContract(_ name: String) throws {
        switch name {
        case "RAND", "RANDARRAY": try random()
        case "TODAY", "NOW": try clock()
        default: Issue.record("No nondeterministic contract for \(name)")
        }
    }

    @Test("Every function rejects argument counts outside its declared contract", arguments: FormulaFunctions.names)
    func arity(_ name: String) {
        let limits = FormulaFunctions.registry[name]!.arity
        if limits.lowerBound > 0 {
            let arguments = Array(repeating: "1", count: limits.lowerBound - 1).joined(separator: ",")
            #expect(evaluate("=\(name)(\(arguments))") == .error(.valueError), "Too few arguments: \(name)")
        }
        let arguments = Array(repeating: "1", count: limits.upperBound + 1).joined(separator: ",")
        #expect(evaluate("=\(name)(\(arguments))") == .error(.valueError), "Too many arguments: \(name)")
    }

    func random() throws {
        var fractions: Set<Double> = []
        var integers: Set<Double> = []
        for _ in 0..<64 {
            let fraction = try #require(evaluate("=RAND()").numericValue)
            #expect(fraction.isFinite && fraction >= 0 && fraction < 1)
            fractions.insert(fraction)
            let integer = try #require(evaluate("=RANDBETWEEN(-3,6)").numericValue)
            #expect(integer.isFinite && integer >= -3 && integer <= 6 && integer == integer.rounded())
            integers.insert(integer)
        }
        // Chance of a correct RANDBETWEEN returning one value 64 times: 10^-63.
        #expect(fractions.count > 1)
        #expect(integers.count > 1)
        #expect(evaluate("=RANDBETWEEN(2,1)") == .error(.numberError))
        #expect(evaluate("=RANDBETWEEN(2.1,2.9)") == .error(.numberError))
        #expect(evaluate("=RANDBETWEEN(-3,-3)") == .number(-3))
        var arrayValues: Set<Double> = []
        for whole in [false, true] {
            let sheet = evaluateSheet(["A1": "=RANDARRAY(4,5,-3,6,\(whole ? "TRUE" : "FALSE"))"])
            for r in 0..<4 {
                for c in 0..<5 {
                    let value = try #require(sheet(CellAddress(row: r, column: c).a1).numericValue)
                    #expect(value.isFinite && value >= -3 && value <= 6)
                    if whole { #expect(value == value.rounded()) }
                    arrayValues.insert(value)
                }
            }
            #expect(sheet("F1") == .empty)
            #expect(sheet("A5") == .empty)
        }
        #expect(arrayValues.count > 1)
        #expect(evaluate("=RANDARRAY(0,2)") == .error(.valueError))
        #expect(evaluate("=RANDARRAY(1,1,2,1)") == .error(.valueError))
        #expect(evaluate("=RANDARRAY(1,1,2,2)") == .number(2))
    }

    func clock() throws {
        let before = Date()
        let today = try #require(evaluate("=TODAY()").numericValue)
        let now = try #require(evaluate("=NOW()").numericValue)
        let after = Date()
        func excelSerial(_ date: Date) -> Double {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
            // Gregorian day arithmetic in UTC is independent of FormulaDates,
            // with 1899-12-30 as the modern Excel epoch.
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(secondsFromGMT: 0)!
            let day = utc.date(from: DateComponents(year: parts.year, month: parts.month, day: parts.day))!
            let epoch = utc.date(from: DateComponents(year: 1899, month: 12, day: 30))!
            let seconds = Double(parts.hour! * 3600 + parts.minute! * 60 + parts.second!)
                + Double(parts.nanosecond!) / 1e9
            return day.timeIntervalSince(epoch) / 86400 + seconds / 86400
        }
        let lower = excelSerial(before)
        let upper = excelSerial(after)
        #expect(today == lower.rounded(.down) || today == upper.rounded(.down))
        #expect(now.isFinite && now >= lower - 1e-8 && now <= upper + 1e-8)
    }

    @Test("Forecast confidence intervals respond to confidence, horizon and scale")
    func forecastIntervals() throws {
        let timeline = "{1,2,3,4,5,6,7,8}"
        let values = "{2,5,4,9,8,10,15,14}"
        func interval(_ target: Int, _ confidence: Double, _ data: String = "{2,5,4,9,8,10,15,14}") throws -> Double {
            let result = try #require(evaluate("=FORECAST.ETS.CONFINT(\(target),\(data),\(timeline),\(confidence),0)").numericValue)
            #expect(result.isFinite && result > 0)
            return result
        }
        let low = try interval(9, 0.8)
        let high = try interval(9, 0.95)
        #expect(high > low)
        #expect(try interval(12, 0.95) > high)
        let scaled = try interval(9, 0.95, "{20,50,40,90,80,100,150,140}")
        #expect(numericAnswerMatches(.number(scaled), high * 10, relativeTolerance: 1e-10))
        let translated = try interval(9, 0.95, "{102,105,104,109,108,110,115,114}")
        #expect(numericAnswerMatches(.number(translated), high, relativeTolerance: 1e-10))
        #expect(evaluate("=FORECAST.ETS.CONFINT(9,\(values),\(timeline),0)") == .error(.numberError))
        #expect(evaluate("=FORECAST.ETS.CONFINT(9,\(values),\(timeline),1)") == .error(.numberError))
        #expect(evaluate("=FORECAST.ETS.STAT(\(values),\(timeline),9)") == .error(.numberError))
    }

    @Test("PHONETIC preserves Excel's saved reading instead of replacing it with cell text")
    func savedPhonetic() throws {
        var sheet = Worksheet(name: "Sheet1")
        sheet[CellAddress(a1: "A1")!] = CellInputParser.cell(from: "東京都", inheriting: .default)
        sheet[CellAddress(a1: "B1")!] = Cell(value: .text("トウキョウト"), formula: "PHONETIC(A1)")
        var workbook = Workbook(sheets: [sheet])
        workbook.recalculate()
        #expect(workbook.sheets[0][CellAddress(a1: "B1")!].value == .text("トウキョウト"))
        let reopened = try XLSXReader.workbook(from: XLSXWriter.data(from: workbook))
        #expect(reopened.sheets[0][CellAddress(a1: "B1")!].value == .text("トウキョウト"))
        #expect(reopened.sheets[0][CellAddress(a1: "B1")!].formula == "PHONETIC(A1)")
    }
}
