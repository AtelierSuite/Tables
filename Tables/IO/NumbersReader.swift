import Foundation

/// Imports an Apple Numbers document into a workbook.
///
/// Numbers places any number of free-standing tables on each sheet, where a
/// workbook has one grid per sheet, so every table becomes a worksheet of its
/// own — what Numbers itself does when it exports to Excel. Cells come across
/// with the values Numbers last calculated.
enum NumbersReader {
    enum Failure: LocalizedError {
        case notANumbersDocument
        case unsupportedStorage

        var errorDescription: String? {
            switch self {
            case .notANumbersDocument:
                return "This file isn’t a Numbers document Tables can read."
            case .unsupportedStorage:
                return """
                    This Numbers document was saved by a version of Numbers too old for Tables to read. \
                    Open it in Numbers and save it again, then try again.
                    """
            }
        }
    }

    /// Reads a document saved as a single file: a ZIP archive with the
    /// document's objects in its `Index` folder.
    static func workbook(from data: Data) throws -> Workbook {
        try workbook(entries: ZipArchive.entries(in: data))
    }

    /// Reads a document saved as a package, which keeps those objects in an
    /// `Index.zip` inside the package, or in an `Index` folder.
    static func workbook(from package: FileWrapper) throws -> Workbook {
        guard let children = package.fileWrappers else { throw Failure.notANumbersDocument }
        if let index = children["Index.zip"]?.regularFileContents {
            return try workbook(from: index)
        }
        guard let folder = children["Index"] else { throw Failure.notANumbersDocument }
        var entries: [String: Data] = [:]
        collect(folder, path: "Index", into: &entries)
        return try workbook(entries: entries)
    }

    private static func collect(_ wrapper: FileWrapper, path: String, into entries: inout [String: Data]) {
        if let contents = wrapper.regularFileContents {
            entries[path] = contents
        }
        for (name, child) in wrapper.fileWrappers ?? [:] {
            collect(child, path: path + "/" + name, into: &entries)
        }
    }

    static func workbook(entries: [String: Data]) throws -> Workbook {
        let archive = IWAArchive(entries: entries)
        guard let document = archive[documentIdentifier], document.type == ObjectType.document else {
            throw Failure.notANumbersDocument
        }

        let mergeOwners = MergeOwners(archive: archive)
        var workbook = Workbook()
        workbook.sheets = []
        for sheetReference in document.message.messages(1) {
            guard let sheet = archive[sheetReference]?.message else { continue }
            let sheetName = sheet.string(1) ?? ""
            let tables = sheet.messages(2)
                .compactMap { archive[$0] }
                .filter { $0.type == ObjectType.tableInfo }
                .compactMap { archive[$0.message.message(2)]?.message }

            for table in tables {
                var worksheet = try TableReader(table: table, archive: archive).worksheet()
                worksheet.mergedRanges += mergeOwners.ranges(for: table)
                // A sheet's one table goes by the sheet's name, as people think
                // of it; several are told apart by their own names as well.
                let tableName = table.string(8) ?? ""
                let name = tables.count == 1 || tableName.isEmpty ? sheetName : "\(sheetName) – \(tableName)"
                worksheet.name = workbook.uniqueSheetName(basedOn: name)
                workbook.sheets.append(worksheet)
            }
        }
        if workbook.sheets.isEmpty {
            workbook.sheets = [Worksheet(name: Workbook.defaultSheetName(1))]
        }
        workbook.recalculate()
        return workbook
    }

    // MARK: - Format constants

    /// The document object always has this identifier.
    private static let documentIdentifier: UInt64 = 1

    /// Type numbers of the objects this reader follows.
    fileprivate enum ObjectType {
        static let document = 1
        static let tableInfo = 6000
        static let calculationEngine = 4000
        static let formulaOwnerDependencies = 4008
    }
}

/// Merged cells as recent versions of Numbers record them: not with the
/// table, but as ranges the calculation engine tracks for a "merge owner",
/// which refers to the table through two levels of identifiers.
private struct MergeOwners {
    /// The UUID identifying an owner across the document, which some
    /// messages spell as a `TSP.UUID`, two 64-bit halves, and others as a
    /// `TSP.CFUUIDArchive`, four 32-bit words.
    private struct UUID: Hashable {
        var lower: UInt64
        var upper: UInt64

        init?(_ message: ProtobufMessage?) {
            guard let message, let lower = message.uint(1), let upper = message.uint(2) else { return nil }
            self.lower = lower
            self.upper = upper
        }

        init?(words message: ProtobufMessage?) {
            guard let message else { return nil }
            let words = (2...5).map { message.uint($0) ?? 0 }
            lower = words[1] << 32 | words[0]
            upper = words[3] << 32 | words[2]
        }
    }

    /// The kinds of owner, a `TSCE.FormulaOwnerDependenciesArchive`'s field 3.
    private enum OwnerKind {
        static let merge = 5
        static let haunted = 35
    }

    /// Each table's stand-in owner, which is what its haunted owner names,
    /// mapped to the base owner merge ranges refer to.
    private var baseOwners: [UUID: UUID] = [:]
    private var rangesByOwner: [UUID: [CellRange]] = [:]

    init(archive: IWAArchive) {
        // Ranges name their owner by a number internal to the engine; the
        // engine's map turns it back into the owner's UUID.
        var owners: [UInt64: UUID] = [:]
        let engine = archive.identifiers(ofType: NumbersReader.ObjectType.calculationEngine).first
        let tracker = engine.flatMap { archive[$0] }?.message.message(2)
        for entry in tracker?.message(3)?.messages(1) ?? [] {
            if let internalID = entry.uint(1), let uuid = UUID(words: entry.message(2)) { owners[internalID] = uuid }
        }

        for identifier in archive.identifiers(ofType: NumbersReader.ObjectType.formulaOwnerDependencies) {
            guard let dependencies = archive[identifier]?.message else { continue }
            switch dependencies.int(3) {
            case OwnerKind.haunted:
                if let owner = UUID(dependencies.message(1)), let base = UUID(dependencies.message(12)) {
                    baseOwners[owner] = base
                }
            case OwnerKind.merge:
                for dependency in dependencies.message(5)?.messages(2) ?? [] {
                    guard let reference = dependency.message(4),
                          let owner = reference.uint(1).flatMap({ owners[$0] }),
                          let range = reference.message(2),
                          let top = range.int(2), let left = range.int(1),
                          let bottom = range.int(4), let right = range.int(3),
                          bottom >= top, right >= left, bottom > top || right > left else { continue }
                    let cellRange = CellRange(
                        start: CellAddress(row: top, column: left),
                        end: CellAddress(row: bottom, column: right)
                    )
                    if !(rangesByOwner[owner]?.contains(cellRange) ?? false) {
                        rangesByOwner[owner, default: []].append(cellRange)
                    }
                }
            default:
                break
            }
        }
    }

    /// The merged ranges of a `TST.TableModelArchive`.
    func ranges(for table: ProtobufMessage) -> [CellRange] {
        guard let haunted = UUID(table.message(84)?.message(1)), let base = baseOwners[haunted] else { return [] }
        return rangesByOwner[base] ?? []
    }
}

/// Reads one table, a `TST.TableModelArchive`, into a worksheet.
private struct TableReader {
    let table: ProtobufMessage
    let archive: IWAArchive

    /// Excel's serial number for 1 January 2001, the moment Numbers counts
    /// dates from.
    private static let epochSerial = 36_892.0
    private static let secondsPerDay = 86_400.0

    func worksheet() throws -> Worksheet {
        var sheet = Worksheet(name: table.string(8) ?? "")
        let rowCount = table.int(6) ?? 0
        let columnCount = table.int(7) ?? 0
        sheet.rowCount = min(max(rowCount, 1), Worksheet.maximumRowCount)
        sheet.columnCount = min(max(columnCount, 1), Worksheet.maximumColumnCount)

        guard let store = table.message(4) else { return sheet }
        let strings = dataList(store.message(4)) { $0.string(3) ?? "" }
        let richText = dataList(store.message(17)) { text(ofRichTextPayload: $0.message(9)) }

        // Rows are stored in tiles of a fixed number of rows each.
        let tiles = store.message(3)
        let tileSize = tiles?.int(2).flatMap { $0 > 0 ? $0 : nil } ?? 256
        for tile in tiles?.messages(1) ?? [] {
            guard let tileObject = archive[tile.message(2)]?.message else { continue }
            // Tiles saved before Numbers 5 lay cells out differently; files
            // that old are vanishingly rare, so they are asked to be re-saved.
            guard tileObject.bool(7) else { throw NumbersReader.Failure.unsupportedStorage }
            let firstRow = (tile.int(1) ?? 0) * tileSize

            for rowInfo in tileObject.messages(5) {
                let row = firstRow + (rowInfo.int(1) ?? 0)
                guard row < sheet.rowCount,
                      let buffer = rowInfo.bytes(6), let offsets = rowInfo.bytes(7) else { continue }
                let cells = Self.cellBuffers(buffer, offsets: offsets, wide: rowInfo.bool(8), columns: sheet.columnCount)
                for (column, cellBuffer) in cells {
                    let address = CellAddress(row: row, column: column)
                    if let cell = Self.cell(from: cellBuffer, strings: strings, richText: richText) {
                        sheet[address] = cell
                    }
                }
            }
        }

        readHeaders(store, into: &sheet)
        sheet.mergedRanges = mergedRanges(store)
        return sheet
    }

    // MARK: - Cells

    /// Splits a row's storage into each column's bytes. The offsets are
    /// little-endian 16-bit values, -1 for an empty column, counted in words
    /// of four bytes rather than bytes when the row needs the reach.
    private static func cellBuffers(
        _ buffer: ArraySlice<UInt8>, offsets: ArraySlice<UInt8>, wide: Bool, columns: Int
    ) -> [(Int, ArraySlice<UInt8>)] {
        var starts: [(column: Int, start: Int)] = []
        var index = offsets.startIndex
        var column = 0
        while index + 1 < offsets.endIndex, column < columns {
            let offset = Int(Int16(bitPattern: UInt16(offsets[index]) | UInt16(offsets[index + 1]) << 8))
            if offset >= 0 { starts.append((column, wide ? offset * 4 : offset)) }
            index += 2
            column += 1
        }
        return starts.enumerated().compactMap { position, entry in
            let end = position + 1 < starts.count ? starts[position + 1].start : buffer.count
            guard entry.start < end, end <= buffer.count else { return nil }
            let base = buffer.startIndex
            return (entry.column, buffer[(base + entry.start)..<(base + end)])
        }
    }

    /// Decodes one cell's storage, the layout Numbers has written since
    /// version 5: a version byte, a type byte, a word of flags saying which
    /// fields follow, then those fields in flag order.
    private static func cell(
        from buffer: ArraySlice<UInt8>, strings: [UInt64: String], richText: [UInt64: String]
    ) -> Cell? {
        let bytes = Array(buffer)
        guard bytes.count >= 12, bytes[0] == 5 else { return nil }
        let type = bytes[1]
        let flags = readUInt32(bytes, 8)
        var cursor = 12

        func take(_ flag: UInt32, size: Int) -> Int? {
            guard flags & flag != 0 else { return nil }
            defer { cursor += size }
            return cursor + size <= bytes.count ? cursor : nil
        }
        let decimal = take(0x1, size: 16).map { decimal128(bytes, $0) }
        let double = take(0x2, size: 8).map { Double(bitPattern: readUInt64(bytes, $0)) }
        let seconds = take(0x4, size: 8).map { Double(bitPattern: readUInt64(bytes, $0)) }
        let stringID = take(0x8, size: 4).map { UInt64(readUInt32(bytes, $0)) }
        let richTextID = take(0x10, size: 4).map { UInt64(readUInt32(bytes, $0)) }

        var cell = Cell()
        switch type {
        case CellType.number, CellType.currency:
            guard let number = decimal ?? double else { return nil }
            // Numbers keeps the sign of a zero that a calculation left
            // negative; nothing shows it, so neither should we.
            cell.value = .number(number == 0 ? 0 : number)
        case CellType.text:
            cell.value = .text(stringID.flatMap { strings[$0] } ?? "")
        case CellType.richText:
            cell.value = .text(richTextID.flatMap { richText[$0] } ?? "")
        case CellType.date:
            guard let seconds else { return nil }
            cell.value = .number(epochSerial + seconds / secondsPerDay)
            let hasTime = seconds.truncatingRemainder(dividingBy: secondsPerDay) != 0
            cell.style.numberFormat = (hasTime ? NumberFormatPreset.dateTime : .date).code
        case CellType.boolean:
            cell.value = .boolean((double ?? 0) > 0)
        case CellType.duration:
            guard let double else { return nil }
            cell.value = .number(double / secondsPerDay)
            cell.style.numberFormat = "[h]:mm:ss"
        case CellType.formulaError:
            // Numbers does not say which error; #VALUE! is the general one.
            cell.value = .error(.valueError)
        default:
            return nil
        }
        return cell.isBlank ? nil : cell
    }

    /// The cell type byte's values.
    private enum CellType {
        static let number: UInt8 = 2
        static let text: UInt8 = 3
        static let date: UInt8 = 5
        static let boolean: UInt8 = 6
        static let duration: UInt8 = 7
        static let formulaError: UInt8 = 8
        static let richText: UInt8 = 9
        static let currency: UInt8 = 10
    }

    /// An IEEE 754 decimal128 with a binary-integer significand, which is how
    /// Numbers stores numbers so that 0.1 stays 0.1.
    private static func decimal128(_ bytes: [UInt8], _ offset: Int) -> Double {
        let high = Int(bytes[offset + 15]), next = Int(bytes[offset + 14])
        let exponent = ((high & 0x7F) << 7 | next >> 1) - 0x1820
        var significand = Double(next & 1)
        for index in stride(from: 13, through: 0, by: -1) {
            significand = significand * 256 + Double(bytes[offset + index])
        }
        // Dividing by an exact power of ten rounds once, where multiplying by
        // an inexact negative one would round twice: 1234e-2 stays 12.34.
        let value = exponent < 0
            ? significand / pow(10, Double(-exponent))
            : significand * pow(10, Double(exponent))
        return high & 0x80 != 0 ? -value : value
    }

    private static func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
    }

    private static func readUInt64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        (0..<8).reduce(0) { $0 | UInt64(bytes[offset + $1]) << (8 * $1) }
    }

    // MARK: - Tables of shared values

    /// A `TST.TableDataList`: the strings, rich text and the like that cells
    /// refer to by key.
    private func dataList<Value>(
        _ reference: ProtobufMessage?, value: (ProtobufMessage) -> Value
    ) -> [UInt64: Value] {
        guard let list = archive[reference]?.message else { return [:] }
        var values: [UInt64: Value] = [:]
        for entry in list.messages(3) {
            guard let key = entry.uint(1) else { continue }
            values[key] = value(entry)
        }
        return values
    }

    /// The plain text of a rich text cell, from the text storage its payload
    /// points at.
    private func text(ofRichTextPayload reference: ProtobufMessage?) -> String {
        guard let payload = archive[reference]?.message,
              let storage = archive[payload.message(1)]?.message else { return "" }
        // Paragraphs are divided by a paragraph separator, which a cell
        // shows as a line break.
        return storage.strings(3).joined().replacingOccurrences(of: "\u{2029}", with: "\n")
    }

    // MARK: - Layout

    /// Row heights, column widths and hidden rows and columns, all of which
    /// Numbers records only where they differ from the table's defaults.
    ///
    /// The default column width comes across, since Numbers' columns are
    /// wider than ours and text would otherwise be cut short; the default row
    /// height does not, as setting it on every row would cost the grid its
    /// fast path for evenly spaced rows.
    private func readHeaders(_ store: ProtobufMessage, into sheet: inout Worksheet) {
        let defaultWidth = table.double(17) ?? 0
        let rowBuckets = store.message(1)?.messages(2).compactMap { archive[$0]?.message } ?? []

        for header in rowBuckets.flatMap({ $0.messages(2) }) {
            guard let row = header.int(1), row < sheet.rowCount else { continue }
            if let height = header.float(2), height > 0 { sheet.rowHeights[row] = Double(height) }
            if (header.int(3) ?? 0) != 0 { sheet.hiddenRows.insert(row) }
        }

        for header in archive[store.message(2)]?.message.messages(2) ?? [] {
            guard let column = header.int(1), column < sheet.columnCount else { continue }
            if let width = header.float(2), width > 0 { sheet.columnWidths[column] = Double(width) }
            if (header.int(3) ?? 0) != 0 { sheet.hiddenColumns.insert(column) }
        }
        if defaultWidth > 0 {
            for column in 0..<sheet.columnCount
            where sheet.columnWidths[column] == nil && defaultWidth != Worksheet.defaultColumnWidth {
                sheet.columnWidths[column] = defaultWidth
            }
        }
    }

    /// Merged regions, packed as a column in the high half of a word and a
    /// row in the low half, for the origin and the size alike.
    private func mergedRanges(_ store: ProtobufMessage) -> [CellRange] {
        guard let map = archive[store.message(13)]?.message else { return [] }
        return map.messages(1).compactMap { range in
            guard let origin = range.message(1)?.uint(1), let size = range.message(2)?.uint(1) else { return nil }
            let row = Int(origin & 0xFFFF), column = Int(origin >> 16)
            let rows = Int(size & 0xFFFF), columns = Int(size >> 16)
            guard rows > 0, columns > 0, rows * columns > 1 else { return nil }
            return CellRange(
                start: CellAddress(row: row, column: column),
                end: CellAddress(row: row + rows - 1, column: column + columns - 1)
            )
        }
    }
}
