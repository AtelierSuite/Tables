import Foundation

/// One cell as Numbers 5 and later store it: a version byte, a type byte, six
/// bytes of bookkeeping, a word of flags saying which fields follow, then
/// those fields in flag order.
///
/// The fields are the cell's value and everything else about it — its styles,
/// formats, formula, control, comment — mostly as keys into tables kept with
/// the table. Changing the value replaces only the value's fields, so all the
/// rest stays exactly as Numbers wrote it.
struct NumbersCellStorage: Hashable {
    /// The type byte's values.
    enum CellType {
        static let empty: UInt8 = 0
        static let number: UInt8 = 2
        static let text: UInt8 = 3
        static let date: UInt8 = 5
        static let boolean: UInt8 = 6
        static let duration: UInt8 = 7
        static let formulaError: UInt8 = 8
        static let richText: UInt8 = 9
        static let currency: UInt8 = 10
    }

    /// The flags of the fields this reader and writer know about.
    enum Field {
        static let decimal: UInt32 = 0x1
        static let double: UInt32 = 0x2
        static let seconds: UInt32 = 0x4
        static let string: UInt32 = 0x8
        static let richText: UInt32 = 0x10
        static let formula: UInt32 = 0x200
        static let formulaError: UInt32 = 0x800

        /// The fields that hold a value, all replaced when it changes.
        static let value: [UInt32] = [decimal, double, seconds, string, richText, formula, formulaError]
        /// Every flag up to here has a known size; a cell using one beyond
        /// it can't be taken apart safely.
        static let lastKnown: UInt32 = 0x100000
    }

    /// The bookkeeping byte that notes, among other things, a string field.
    private static let stringPresenceBit: UInt8 = 0x80

    var type: UInt8
    /// Bytes 2 to 7, kept as they were.
    var bookkeeping: [UInt8]
    private(set) var fields: [UInt32: [UInt8]] = [:]

    init(type: UInt8) {
        self.type = type
        bookkeeping = [0, 0, 0, 0, 0, 0]
    }

    init?(_ bytes: ArraySlice<UInt8>) {
        let bytes = Array(bytes)
        guard bytes.count >= 12, bytes[0] == 5 else { return nil }
        type = bytes[1]
        bookkeeping = Array(bytes[2..<8])
        let flags = Self.readUInt32(bytes, 8)
        guard flags < Field.lastKnown << 1 else { return nil }
        var cursor = 12
        var flag: UInt32 = 1
        while flag <= Field.lastKnown {
            if flags & flag != 0 {
                let size = Self.size(of: flag)
                guard cursor + size <= bytes.count else { return nil }
                fields[flag] = Array(bytes[cursor..<(cursor + size)])
                cursor += size
            }
            flag <<= 1
        }
    }

    func field(_ flag: UInt32) -> [UInt8]? {
        fields[flag]
    }

    var hasFormula: Bool { fields[Field.formula] != nil }

    /// The key of the cell's formula in its table's formulas.
    var formulaKey: UInt64? { key(Field.formula) }

    /// The key a field holds into one of its table's lists — a style's, say.
    func key(of flag: UInt32) -> UInt64? { key(flag) }

    /// Sets the key a field holds, or removes the field.
    mutating func setKey(_ key: UInt32?, of flag: UInt32) {
        fields[flag] = key.map { withUnsafeBytes(of: $0.littleEndian, Array.init) }
    }

    var encoded: [UInt8] {
        var output: [UInt8] = [5, type] + bookkeeping
        var flags: UInt32 = 0
        var body: [UInt8] = []
        for flag in fields.keys.sorted() {
            flags |= flag
            body += fields[flag]!
        }
        output += withUnsafeBytes(of: flags.littleEndian, Array.init)
        return output + body
    }

    /// Whether the cell is nothing but an empty value, which Numbers stores
    /// by storing nothing at all.
    var isBare: Bool { type == CellType.empty && fields.isEmpty }

    private static func size(of flag: UInt32) -> Int {
        switch flag {
        case Field.decimal: return 16
        case Field.double, Field.seconds: return 8
        default: return 4
        }
    }

    // MARK: - Values

    /// Excel's serial number for 1 January 2001, the moment Numbers counts
    /// dates from.
    static let epochSerial = 36_892.0
    static let secondsPerDay = 86_400.0
    static let durationFormat = "[h]:mm:ss"

    /// The cell's value as Tables holds it, with the number format a date or
    /// a duration needs to show as one. `strings` and `richText` resolve the
    /// keys text cells hold.
    func cell(strings: [UInt64: String], richText: [UInt64: String]) -> Cell? {
        var cell = Cell()
        switch type {
        case CellType.number, CellType.currency:
            guard let number = fields[Field.decimal].map(Self.decimal128) ?? double(Field.double) else { return nil }
            // Numbers keeps the sign of a zero that a calculation left
            // negative; nothing shows it, so neither should we.
            cell.value = .number(number == 0 ? 0 : number)
        case CellType.text:
            cell.value = .text(key(Field.string).flatMap { strings[$0] } ?? "")
        case CellType.richText:
            cell.value = .text(key(Field.richText).flatMap { richText[$0] } ?? "")
        case CellType.date:
            guard let seconds = double(Field.seconds) else { return nil }
            cell.value = .number(Self.epochSerial + seconds / Self.secondsPerDay)
            let hasTime = seconds.truncatingRemainder(dividingBy: Self.secondsPerDay) != 0
            cell.style.numberFormat = (hasTime ? NumberFormatPreset.dateTime : .date).code
        case CellType.boolean:
            cell.value = .boolean((double(Field.double) ?? 0) > 0)
        case CellType.duration:
            guard let seconds = double(Field.double) else { return nil }
            cell.value = .number(seconds / Self.secondsPerDay)
            cell.style.numberFormat = Self.durationFormat
        case CellType.formulaError:
            // Numbers does not say which error; #VALUE! is the general one.
            cell.value = .error(.valueError)
        default:
            return nil
        }
        return cell.isBlank ? nil : cell
    }

    /// The same cell holding `cell`'s value instead, with every field that
    /// isn't part of the value kept. `stringKey` finds or adds the key for a
    /// piece of text in the table's strings.
    ///
    /// For a formula, `formulaKey` is its key in the table's formulas, and
    /// the value is the result it was last worked out to.
    func replacingValue(
        with cell: Cell, formulaKey: UInt32? = nil, stringKey: (String) -> UInt32
    ) -> NumbersCellStorage {
        var storage = self
        for flag in Field.value { storage.fields[flag] = nil }
        if let formulaKey {
            storage.fields[Field.formula] = withUnsafeBytes(of: formulaKey.littleEndian, Array.init)
        }

        switch cell.value {
        case .empty:
            storage.type = CellType.empty
        case .text(let text):
            storage.setText(stringKey(text))
        case .error where formulaKey != nil:
            // Numbers doesn't keep which error a formula came to; it works
            // that out again when it opens the document.
            storage.type = CellType.formulaError
        case .error(let error):
            // Typed in, an error is the text it looks like.
            storage.setText(stringKey(error.rawValue))
        case .boolean(let flag):
            storage.type = CellType.boolean
            storage.fields[Field.double] = Self.bytes(of: flag ? 1.0 : 0.0)
        case .number(let number):
            let format = cell.style.numberFormat
            if format == Self.durationFormat || (type == CellType.duration && CellFormatter.isDateFormat(format)) {
                storage.type = CellType.duration
                storage.fields[Field.double] = Self.bytes(of: number * Self.secondsPerDay)
            } else if CellFormatter.isDateFormat(format) {
                storage.type = CellType.date
                storage.fields[Field.seconds] = Self.bytes(of: (number - Self.epochSerial) * Self.secondsPerDay)
            } else {
                storage.type = type == CellType.currency ? CellType.currency : CellType.number
                storage.fields[Field.decimal] = Self.decimal128(number)
            }
        }
        if storage.fields[Field.string] != nil {
            storage.bookkeeping[4] |= Self.stringPresenceBit
        } else {
            storage.bookkeeping[4] &= ~Self.stringPresenceBit
        }
        return storage
    }

    private mutating func setText(_ key: UInt32) {
        type = CellType.text
        fields[Field.string] = withUnsafeBytes(of: key.littleEndian, Array.init)
    }

    private func key(_ flag: UInt32) -> UInt64? {
        fields[flag].map { UInt64(Self.readUInt32($0, 0)) }
    }

    private func double(_ flag: UInt32) -> Double? {
        fields[flag].map { Double(bitPattern: Self.readUInt64($0, 0)) }
    }

    private static func bytes(of value: Double) -> [UInt8] {
        withUnsafeBytes(of: value.bitPattern.littleEndian, Array.init)
    }

    // MARK: - Decimal128

    /// An IEEE 754 decimal128 with a binary-integer significand, which is how
    /// Numbers stores numbers so that 0.1 stays 0.1.
    static func decimal128(_ bytes: [UInt8]) -> Double {
        let high = Int(bytes[15]), next = Int(bytes[14])
        let exponent = ((high & 0x7F) << 7 | next >> 1) - 0x1820
        var significand = Double(next & 1)
        for index in stride(from: 13, through: 0, by: -1) {
            significand = significand * 256 + Double(bytes[index])
        }
        // Dividing by an exact power of ten rounds once, where multiplying by
        // an inexact negative one would round twice: 1234e-2 stays 12.34.
        let value = exponent < 0
            ? significand / pow(10, Double(-exponent))
            : significand * pow(10, Double(exponent))
        return high & 0x80 != 0 ? -value : value
    }

    /// The decimal Numbers would store for `value`: the shortest digits that
    /// read back as the same double, so 0.1 is stored as 1 × 10⁻¹.
    static func decimal128(_ value: Double) -> [UInt8] {
        guard value.isFinite, value != 0 else { return decimal128(significand: 0, exponent: 0, negative: false) }
        let parts = "\(value.magnitude)".lowercased().split(separator: "e")
        var exponent = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        let mantissa = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        var digits = String(mantissa[0])
        if mantissa.count > 1 {
            digits += mantissa[1]
            exponent -= mantissa[1].count
        }
        while digits.count > 1, digits.hasSuffix("0") {
            digits.removeLast()
            exponent += 1
        }
        let significand = UInt64(digits) ?? 0
        return decimal128(significand: significand, exponent: exponent, negative: value < 0)
    }

    private static func decimal128(significand: UInt64, exponent: Int, negative: Bool) -> [UInt8] {
        var bytes = withUnsafeBytes(of: significand.littleEndian, Array.init) + [UInt8](repeating: 0, count: 8)
        let biased = exponent + 0x1820
        bytes[14] = UInt8((biased & 0x7F) << 1)
        bytes[15] = UInt8(biased >> 7 & 0x7F) | (negative ? 0x80 : 0)
        return bytes
    }

    // MARK: - Bytes

    private static func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
    }

    private static func readUInt64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        (0..<8).reduce(0) { $0 | UInt64(bytes[offset + $1]) << (8 * $1) }
    }
}

/// A row's cells within a tile, each column's storage found through a table
/// of offsets.
struct NumbersTileRow {
    /// Each column's storage, by column.
    var cells: [Int: ArraySlice<UInt8>]

    /// Splits a row's storage into each column's bytes. The offsets are
    /// little-endian 16-bit values, -1 for an empty column, counted in words
    /// of four bytes rather than bytes when the row needs the reach.
    init(buffer: ArraySlice<UInt8>, offsets: ArraySlice<UInt8>, wide: Bool) {
        var starts: [(column: Int, start: Int)] = []
        var index = offsets.startIndex
        var column = 0
        while index + 1 < offsets.endIndex {
            let offset = Int(Int16(bitPattern: UInt16(offsets[index]) | UInt16(offsets[index + 1]) << 8))
            if offset >= 0 { starts.append((column, wide ? offset * 4 : offset)) }
            index += 2
            column += 1
        }
        cells = [:]
        for (position, entry) in starts.enumerated() {
            let end = position + 1 < starts.count ? starts[position + 1].start : buffer.count
            guard entry.start < end, end <= buffer.count else { continue }
            let base = buffer.startIndex
            cells[entry.column] = buffer[(base + entry.start)..<(base + end)]
        }
    }

    init(cells: [Int: ArraySlice<UInt8>]) {
        self.cells = cells
    }

    /// The row's storage and offsets for `columns` columns, with wide
    /// offsets when the storage is too long for byte offsets to reach.
    func encoded(columns: Int) -> (buffer: [UInt8], offsets: [UInt8], wide: Bool) {
        var buffer: [UInt8] = []
        var starts = [Int](repeating: -1, count: columns)
        for column in cells.keys.sorted() where column < columns {
            starts[column] = buffer.count
            buffer += cells[column]!
        }
        let wide = buffer.count > Int(Int16.max)
        let offsets = starts.flatMap { start -> [UInt8] in
            let value = start < 0 ? Int16(-1) : Int16(wide ? start / 4 : start)
            return withUnsafeBytes(of: value.littleEndian, Array.init)
        }
        return (buffer, offsets, wide)
    }
}
