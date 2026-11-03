import Foundation
import Testing
@testable import TablesEngine

@Suite("Numbers number formats")
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
}
