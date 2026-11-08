import Foundation

/// Reads and writes RFC 4180 style delimited text.
public enum CSVCodec {
    /// Builds a single-sheet workbook from delimited text, sniffing the delimiter.
    public static func workbook(from data: Data, sheetName: String) -> Workbook {
        let text = decodeText(data)
        let delimiter = sniffDelimiter(in: text)
        let rows = parse(text, delimiter: delimiter)

        var sheet = Worksheet(name: sheetName)
        for (rowIndex, row) in rows.enumerated() {
            for (columnIndex, field) in row.enumerated() where !field.isEmpty {
                let address = CellAddress(row: rowIndex, column: columnIndex)
                sheet[address] = CellInputParser.cell(from: field, inheriting: .default)
            }
        }
        sheet.rowCount = max(Worksheet.defaultRowCount, min(rows.count, Worksheet.maximumRowCount))
        sheet.columnCount = max(
            Worksheet.defaultColumnCount,
            min(rows.map(\.count).max() ?? 0, Worksheet.maximumColumnCount)
        )

        var workbook = Workbook(sheets: [sheet])
        workbook.recalculate()
        return workbook
    }

    /// Serializes one sheet. CSV has no concept of multiple sheets, so callers
    /// choose which one to export.
    public static func data(from sheet: Worksheet, delimiter: Character = ",") -> Data {
        var lines: [String] = []
        lines.reserveCapacity(sheet.rowCount)
        for row in 0..<sheet.rowCount where !sheet.hiddenRows.contains(row) {
            var fields: [String] = []
            for column in 0..<sheet.columnCount where !sheet.hiddenColumns.contains(column) {
                let cell = sheet[CellAddress(row: row, column: column)]
                fields.append(escape(CellFormatter.displayText(for: cell), delimiter: delimiter))
            }
            lines.append(fields.joined(separator: String(delimiter)))
        }
        // Trailing blank lines carry no information; drop them.
        while let last = lines.last, last.allSatisfy({ $0 == delimiter }) || last.isEmpty {
            lines.removeLast()
        }
        return Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }

    // MARK: - Decoding

    private static func decodeText(_ data: Data) -> String {
        if let (encoding, markLength) = byteOrderMark(in: data),
           let text = String(data: data.dropFirst(markLength), encoding: encoding) {
            return text
        }
        // Must precede the UTF-8 attempt: a zero byte is valid UTF-8, so
        // UTF-16 text full of them decodes "successfully" into mojibake.
        if let wide = decodeUTF16WithoutMark(data) { return wide }
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        if let latin = String(data: data, encoding: .isoLatin1) { return latin }
        return String(decoding: data, as: UTF8.self)
    }

    /// Longest marks first, so UTF-32's leading `FF FE` is not read as UTF-16.
    private static let byteOrderMarks: [([UInt8], String.Encoding)] = [
        ([0xFF, 0xFE, 0x00, 0x00], .utf32LittleEndian),
        ([0x00, 0x00, 0xFE, 0xFF], .utf32BigEndian),
        ([0xEF, 0xBB, 0xBF], .utf8),
        ([0xFF, 0xFE], .utf16LittleEndian),
        ([0xFE, 0xFF], .utf16BigEndian)
    ]

    private static func byteOrderMark(in data: Data) -> (String.Encoding, Int)? {
        for (bytes, encoding) in byteOrderMarks where data.starts(with: bytes) {
            return (encoding, bytes.count)
        }
        return nil
    }

    /// Excel's "UTF-16 Unicode Text" export omits the byte order mark on some
    /// platforms. Latin text in UTF-16 leaves every other byte zero, which is
    /// the giveaway: well-formed UTF-8 spreadsheet text contains no zero bytes.
    private static func decodeUTF16WithoutMark(_ data: Data) -> String? {
        guard data.count >= 4, data.count.isMultiple(of: 2) else { return nil }
        let sample = data.prefix(1024)
        var evenZeros = 0
        var oddZeros = 0
        for (offset, byte) in sample.enumerated() where byte == 0 {
            if offset.isMultiple(of: 2) { evenZeros += 1 } else { oddZeros += 1 }
        }
        let units = sample.count / 2
        if evenZeros == 0, oddZeros * 2 > units {
            return String(data: data, encoding: .utf16LittleEndian)
        }
        if oddZeros == 0, evenZeros * 2 > units {
            return String(data: data, encoding: .utf16BigEndian)
        }
        return nil
    }

    private static let delimiterCandidates: [Character] = [",", ";", "\t", "|"]

    /// Picks the separator that behaves like one: present on every record, and
    /// the same number of times on each. Counting raw characters instead would
    /// let the decimal commas in a European `"1,5";"2,5"` file outvote the
    /// semicolons that actually separate its fields.
    private static func sniffDelimiter(in text: String) -> Character {
        let counts = delimiterCounts(in: sample(of: text))
        var best: Character = ","
        // Ranked on: appears in every record, appears the same number of times
        // in each, how many per record, how many overall.
        var bestScore = (0, 0, 0, 0)
        for candidate in delimiterCandidates {
            guard let perRecord = counts[candidate], let minimum = perRecord.min() else { continue }
            let total = perRecord.reduce(0, +)
            guard total > 0 else { continue }
            let consistent = minimum > 0 && perRecord.allSatisfy { $0 == minimum }
            let score = (minimum > 0 ? 1 : 0, consistent ? 1 : 0, minimum, total)
            if score > bestScore {
                bestScore = score
                best = candidate
            }
        }
        return best
    }

    /// Trims the sample back to a record boundary so a half-read final line
    /// cannot skew the counts.
    private static func sample(of text: String) -> Substring {
        let prefix = text.prefix(4096)
        guard prefix.endIndex != text.endIndex,
              let lastNewline = prefix.lastIndex(where: \.isNewline) else { return prefix }
        return prefix[..<lastNewline]
    }

    /// How often each candidate appears outside quotes, per non-empty record.
    private static func delimiterCounts(in sample: Substring) -> [Character: [Int]] {
        var counts: [Character: [Int]] = [:]
        var record: [Character: Int] = [:]
        for candidate in delimiterCandidates {
            counts[candidate] = []
            record[candidate] = 0
        }
        var inQuotes = false
        var recordHasContent = false

        func endRecord() {
            guard recordHasContent else { return }
            for candidate in delimiterCandidates {
                counts[candidate]?.append(record[candidate] ?? 0)
                record[candidate] = 0
            }
            recordHasContent = false
        }

        for character in sample {
            // A doubled quote toggles twice and so nets out correctly.
            if character == "\"" {
                inQuotes.toggle()
                recordHasContent = true
                continue
            }
            if inQuotes { continue }
            if character.isNewline {
                endRecord()
                continue
            }
            recordHasContent = true
            if record[character] != nil { record[character]! += 1 }
        }
        endRecord()
        return counts
    }

    private static func parse(_ text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.makeIterator()
        var pending: Character?

        func endField() {
            row.append(field)
            field = ""
        }

        func endRow() {
            endField()
            rows.append(row)
            row = []
        }

        while let character = pending ?? iterator.next() {
            pending = nil
            if inQuotes {
                if character == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" {
                            field.append("\"")
                        } else {
                            inQuotes = false
                            pending = next
                        }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(character)
                }
                continue
            }
            switch character {
            case "\"" where field.isEmpty:
                inQuotes = true
            case delimiter:
                endField()
            // A CRLF pair is one Swift Character, so match on the newline
            // property rather than on "\r" and "\n" separately.
            case let newline where newline.isNewline:
                endRow()
            default:
                field.append(character)
            }
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }

    private static func escape(_ field: String, delimiter: Character) -> String {
        let needsQuoting = field.contains(delimiter) || field.contains("\"")
            || field.contains(where: \.isNewline)
        guard needsQuoting else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
