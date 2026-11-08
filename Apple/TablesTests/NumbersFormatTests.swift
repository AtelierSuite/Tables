import Foundation
import Testing
@testable import Tables
@testable import TablesEngine

@Suite("Numbers number formats")
@MainActor
struct NumbersFormatTests {
    private func format(_ type: UInt64, _ build: (inout ProtobufMessage) -> Void = { _ in }) -> ProtobufMessage {
        var message = ProtobufMessage()
        message.set(1, uint: type)
        build(&message)
        return message
    }

    private func shown(_ value: Double, _ format: ProtobufMessage, language: String? = nil) throws -> String {
        let code = try #require(NumbersFormats.code(for: format, language: language))
        return CellFormatter.displayText(for: .number(value), format: code)
    }

    @Test("Currency shows its symbol, its decimal places and its thousands separators")
    func currency() throws {
        let yen = format(NumbersFormats.FormatType.currency) {
            $0.set(2, uint: 0)
            $0.set(3, bytes: Array("JPY".utf8))
            $0.set(5, uint: 1)
            $0.set(6, uint: 1)
        }
        #expect(try shown(388_794.56, yen) == "¥388,795")
        let dollars = format(NumbersFormats.FormatType.currency) {
            $0.set(2, uint: 2)
            $0.set(3, bytes: Array("USD".utf8))
        }
        #expect(try shown(1234.5, dollars) == "$1234.50")
    }

    @Test("An accounting format puts its currency symbol at the cell's left edge and the amount at its right")
    func accounting() throws {
        let yen = format(NumbersFormats.FormatType.currency) {
            $0.set(2, uint: 0)
            $0.set(3, bytes: Array("JPY".utf8))
            $0.set(5, uint: 1)
            $0.set(6, uint: 1)
        }
        var cell = Cell(value: .number(24_524), formula: nil, style: .default)
        cell.style.numberFormat = try #require(NumbersFormats.code(for: yen, language: nil))
        let parts = try #require(CellFormatter.filledText(for: cell))
        #expect(parts.leading == "¥")
        #expect(parts.trailing == "24,524")
        cell.style.numberFormat = "\"¥\"#,##0"
        #expect(CellFormatter.filledText(for: cell) == nil)
    }

    @Test("Numbers keep the decimal places they are given, or as many as they need")
    func decimals() throws {
        let fixed = format(NumbersFormats.FormatType.decimal) {
            $0.set(2, uint: 2)
            $0.set(5, uint: 1)
        }
        #expect(try shown(1_039_838.9000000001, fixed) == "1,039,838.90")
        let automatic = format(NumbersFormats.FormatType.decimal) { $0.set(2, uint: 253) }
        #expect(NumbersFormats.code(for: automatic, language: nil) == "General")
        #expect(try shown(0.125, format(NumbersFormats.FormatType.percentage) { $0.set(2, uint: 1) }) == "12.5%")
    }

    @Test("A date pattern comes across in Excel's tokens, its months named in the document's language")
    func dates() throws {
        let pattern = format(NumbersFormats.FormatType.date) { $0.set(14, bytes: Array("yyyy年MMMM".utf8)) }
        let serial = CellFormatter.serial(fromDate: DateComponents(
            calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(identifier: "UTC"),
            year: 2026, month: 10, day: 1).date!)
        #expect(try shown(serial, pattern, language: "ja_JP") == "2026年10月")
        #expect(NumbersFormats.excelDateCode(fromUnicodePattern: "y/MM/dd", language: nil) == "yyyy/mm/dd")
        #expect(NumbersFormats.excelDateCode(fromUnicodePattern: "H:mm", language: nil) == "h:mm")
        #expect(NumbersFormats.excelDateCode(fromUnicodePattern: "d MMMM yyyy", language: "en_GB") == "d mmmm yyyy")
    }

    @Test("A tap on a checkbox ticks it or clears it, and leaves one showing a formula's result alone")
    func checkbox() {
        var sheet = Worksheet(name: "Sheet")
        var box = Cell(value: .boolean(false))
        box.style.showsCheckbox = true
        sheet[CellAddress(row: 0, column: 0)] = box
        var computed = Cell(value: .boolean(true), formula: "TRUE()")
        computed.style.showsCheckbox = true
        sheet[CellAddress(row: 1, column: 0)] = computed
        sheet[CellAddress(row: 2, column: 0)] = Cell(value: .boolean(false))
        var book = Workbook(sheets: [sheet])
        let state = EditorState()
        state.activeSheetID = book.sheets[0].id

        state.toggleCheckbox(at: CellAddress(row: 0, column: 0), in: &book)
        #expect(book.sheets[0][CellAddress(row: 0, column: 0)].value == .boolean(true))
        state.toggleCheckbox(at: CellAddress(row: 1, column: 0), in: &book)
        #expect(book.sheets[0][CellAddress(row: 1, column: 0)].value == .boolean(true))
        state.toggleCheckbox(at: CellAddress(row: 2, column: 0), in: &book)
        #expect(book.sheets[0][CellAddress(row: 2, column: 0)].value == .boolean(false), "not a checkbox")
    }
}
