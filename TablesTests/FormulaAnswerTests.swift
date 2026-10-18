import Foundation
import Testing
@testable import Tables
@testable import TablesEngine

/// Absolute and relative tolerances are separate: small probabilities and yields
/// must not inherit the absolute error budget of a number near one.
func numericAnswerMatches(_ value: CellValue, _ expected: Double,
                          absoluteTolerance: Double = 0, relativeTolerance: Double = 1e-12) -> Bool {
    guard case .number(let actual) = value, actual.isFinite, expected.isFinite,
          absoluteTolerance.isFinite, absoluteTolerance >= 0,
          relativeTolerance.isFinite, relativeTolerance >= 0 else { return false }
    return abs(actual - expected) <= absoluteTolerance + relativeTolerance * abs(expected)
}

@Suite("Frozen formula answers")
struct FormulaAnswerTests {
    @Test("Every answer vector runs through workbook recalculation", arguments: formulaAnswerCases)
    func answer(_ vector: FormulaAnswerCase) throws {
        // Metadata cannot claim coverage for a formula that does not call the function.
        let pattern = "(?<![A-Za-z0-9._])" + NSRegularExpression.escapedPattern(for: vector.function) + "\\("
        #expect(vector.formula.range(of: pattern, options: .regularExpression) != nil)
        let origin = CellAddress(a1: "Z99")!
        var sheet = Worksheet(name: "Sheet 1")
        for (reference, input) in vector.entries {
            let address = CellAddress(a1: reference)!
            sheet.rowCount = max(sheet.rowCount, address.row + 1)
            sheet.columnCount = max(sheet.columnCount, address.column + 1)
            sheet[address] = CellInputParser.cell(from: input, inheriting: .default)
        }
        sheet.rowCount = max(sheet.rowCount, origin.row + 10)
        sheet.columnCount = max(sheet.columnCount, origin.column + 10)
        sheet[origin] = CellInputParser.cell(from: vector.formula, inheriting: .default)
        var workbook = Workbook(sheets: [sheet])
        workbook.recalculate()
        let result = workbook.sheets[0]
        if let expected = vector.complexComponents {
            guard case .text(let text) = result[origin].value else {
                Issue.record("Complex function did not return complex text: \(vector.formula)")
                return
            }
            let actual = try #require(parseComplexAnswer(text))
            #expect(numericAnswerMatches(.number(actual.real), expected.real,
                                         absoluteTolerance: vector.absoluteTolerance,
                                         relativeTolerance: vector.relativeTolerance))
            #expect(numericAnswerMatches(.number(actual.imaginary), expected.imaginary,
                                         absoluteTolerance: vector.absoluteTolerance,
                                         relativeTolerance: vector.relativeTolerance))
            #expect(result.spills[origin] == nil)
            return
        }
        let rows = vector.expectedRows ?? [[vector.expected]]
        #expect(!rows.isEmpty && rows.allSatisfy { $0.count == rows[0].count })
        for (r, row) in rows.enumerated() {
            for (c, expected) in row.enumerated() {
                let actual = result[CellAddress(row: origin.row + r, column: origin.column + c)].value
                if case .number(let number) = expected {
                    #expect(numericAnswerMatches(actual, number, absoluteTolerance: vector.absoluteTolerance,
                                                 relativeTolerance: vector.relativeTolerance),
                            "\(vector.formula) [\(r),\(c)]: expected \(expected), got \(actual)")
                } else {
                    #expect(actual == expected, "\(vector.formula) [\(r),\(c)]")
                }
            }
        }
        if rows.count > 1 || rows[0].count > 1 {
            let end = CellAddress(row: origin.row + rows.count - 1, column: origin.column + rows[0].count - 1)
            #expect(result.spills[origin] == CellRange(start: origin, end: end), "Complete result dimensions")
        } else {
            #expect(result.spills[origin] == nil, "A scalar answer must not hide an unexpected array")
        }
    }

    @Test("Numeric assertions reject wrong types, nonfinite values and small-answer errors")
    func numericalAssertions() {
        #expect(!numericAnswerMatches(.boolean(true), 1))
        #expect(!numericAnswerMatches(.text("1"), 1))
        #expect(!numericAnswerMatches(.number(.infinity), 1))
        #expect(!numericAnswerMatches(.number(.nan), 1))
        #expect(!numericAnswerMatches(.number(0), 1e-12))
        #expect(!numericAnswerMatches(.number(0.078), 0.0772, absoluteTolerance: 0.00005))
        #expect(numericAnswerMatches(.number(0.1 + 0.2), 0.3))
        #expect(numericAnswerMatches(.number(0), 0))
    }
}

/// Independent decoding of the returned complex text. Does not call IMREAL,
/// IMAGINARY, or Tables' complex parser, so those functions cannot mask an error.
private func parseComplexAnswer(_ text: String) -> ComplexAnswer? {
    guard text.last == "i" || text.last == "j" else {
        return Double(text).map { ComplexAnswer(real: $0, imaginary: 0) }
    }
    let body = String(text.dropLast())
    let split = body.indices.dropFirst().last { index in
        (body[index] == "+" || body[index] == "-")
            && body[body.index(before: index)] != "e" && body[body.index(before: index)] != "E"
    }
    let realText = split.map { String(body[..<$0]) } ?? "0"
    let imaginaryText = split.map { String(body[$0...]) } ?? body
    let imaginary = imaginaryText.isEmpty || imaginaryText == "+" ? 1
        : (imaginaryText == "-" ? -1 : Double(imaginaryText))
    guard let real = Double(realText), let imaginary else { return nil }
    return ComplexAnswer(real: real, imaginary: imaginary)
}
