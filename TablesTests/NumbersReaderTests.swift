import Foundation
import Testing
@testable import Tables

@Suite("Numbers import")
struct NumbersReaderTests {
    @Test("Each kind of cell comes across with its value")
    func values() throws {
        var document = NumbersDocumentBuilder()
        document.addSheet("Budget", tables: [
            .init(name: "Table 1", rows: [
                [.text("Item"), .text("Note"), .text("Paid"), .text("When"), .text("Took")],
                [.number(12_345, exponent: -2), .richText("Line one\u{2029}Line two"), .boolean(true),
                 .date(seconds: 794_102_400), .duration(seconds: 5_400)],
                [.number(-5, exponent: 0), .currency(1_999, exponent: -2), .boolean(false),
                 .date(seconds: 794_136_600), .formulaError],
                [.negativeZero, .empty, .number(0, exponent: 0)],
            ]),
        ])
        let workbook = try NumbersReader.workbook(from: document.singleFile())

        #expect(workbook.sheets.count == 1)
        let sheet = workbook.sheets[0]
        func value(_ reference: String) -> CellValue { sheet[CellAddress(a1: reference)!].value }
        func format(_ reference: String) -> String { sheet[CellAddress(a1: reference)!].style.numberFormat }

        #expect(value("A1") == .text("Item"))
        #expect(value("A2") == .number(123.45))
        #expect(value("A3") == .number(-5))
        #expect(value("B2") == .text("Line one\nLine two"))
        #expect(value("B3") == .number(19.99))
        #expect(value("C2") == .boolean(true))
        #expect(value("C3") == .boolean(false))
        // 2 March 2026, 794,102,400 seconds after 1 January 2001.
        #expect(value("D2") == .number(46_083))
        #expect(format("D2") == NumberFormatPreset.date.code)
        #expect(abs((value("D3").numericValue ?? 0) - (46_083 + 9.5 / 24)) < 1e-9)
        #expect(format("D3") == NumberFormatPreset.dateTime.code)
        #expect(value("E2") == .number(1.5 / 24))
        #expect(format("E2") == "[h]:mm:ss")
        #expect(value("E3") == .error(.valueError))
        #expect(value("A4") == .number(0))
        #expect(value("A4").numericValue?.sign == .plus, "a negative zero shows as plain zero")
        #expect(value("B4") == .empty)
        #expect(value("C4") == .number(0))
        #expect(sheet.rowCount == 4)
        #expect(sheet.columnCount == 5)
    }

    @Test("Every table becomes a worksheet, named for its sheet and, among several, itself")
    func tablesBecomeWorksheets() throws {
        var document = NumbersDocumentBuilder()
        document.addSheet("Budget", tables: [.init(name: "Table 1", rows: [[.text("Rent")]])])
        document.addSheet("Plans", tables: [
            .init(name: "Trips", rows: [[.text("Kyoto")]]),
            .init(name: "Extra", rows: [[.text("Second")]]),
        ])
        document.addSheet("Budget", tables: [.init(name: "Table 1", rows: [[.text("Again")]])])
        let workbook = try NumbersReader.workbook(from: document.singleFile())

        #expect(workbook.sheets.map(\.name) == ["Budget", "Plans – Trips", "Plans – Extra", "Budget 2"])
        #expect(workbook.sheets[2][CellAddress(row: 0, column: 0)].value == .text("Second"))
    }

    @Test("The tables sharing a sheet are known together, by their sheet's name and their own")
    func tablesSharingASheet() throws {
        var document = NumbersDocumentBuilder()
        document.addSheet("Budget", tables: [.init(name: "Table 1", rows: [[.text("Rent")]])])
        document.addSheet("Plans", tables: [
            .init(name: "Trips", rows: [[.text("Kyoto")]]),
            .init(name: "Extra", rows: [[.text("Second")]]),
        ])
        let (workbook, source) = try NumbersReader.document(from: document.singleFile())
        let sheets = workbook.sheets

        #expect(source.worksheets(sharingSheetWith: sheets[0].id, in: workbook).isEmpty)
        let shared = source.worksheets(sharingSheetWith: sheets[2].id, in: workbook)
        #expect(shared.map(\.id) == [sheets[1].id, sheets[2].id])
        #expect(shared.map { source.tables[$0.id]?.sheetName } == ["Plans", "Plans"])
        #expect(shared.map { source.tables[$0.id]?.tableName } == ["Trips", "Extra"])
    }

    @Test("Rows past the first tile land where they belong")
    func laterTiles() throws {
        var document = NumbersDocumentBuilder()
        var table = NumbersDocumentBuilder.Table(name: "Long", rows: [[.text("First")]])
        table.rowCount = 300
        table.columnCount = 2
        table.extraTiles = [1: [(row: 10, cells: [.empty, .text("Row 267")])]]
        document.addSheet("Sheet 1", tables: [table])
        let sheet = try NumbersReader.workbook(from: document.singleFile()).sheets[0]

        #expect(sheet.rowCount == 300)
        #expect(sheet[CellAddress(row: 266, column: 1)].value == .text("Row 267"))
    }

    @Test("Sizes, hidden rows and columns, and merged cells")
    func layout() throws {
        var document = NumbersDocumentBuilder()
        var table = NumbersDocumentBuilder.Table(name: "Table 1", rows: [[.text("Merged")], [], [], []])
        table.columnCount = 4
        table.columnSizes = [1: 150]
        table.rowSizes = [2: 40]
        table.hiddenRows = [3]
        table.hiddenColumns = [2]
        table.mergeRegions = [CellRange(start: CellAddress(row: 0, column: 0), end: CellAddress(row: 0, column: 1))]
        table.mergeOwnerRanges = [CellRange(start: CellAddress(row: 1, column: 2), end: CellAddress(row: 2, column: 2))]
        document.addSheet("Sheet 1", tables: [table])
        let sheet = try NumbersReader.workbook(from: document.singleFile()).sheets[0]

        #expect(sheet.columnWidths[1] == 150)
        #expect(sheet.columnWidths[0] == NumbersDocumentBuilder.defaultColumnWidth, "the table's own default width")
        #expect(sheet.rowHeights[2] == 40)
        #expect(sheet.rowHeights[0] == nil, "rows of the default height keep ours")
        #expect(sheet.hiddenRows == [3])
        #expect(sheet.hiddenColumns == [2])
        #expect(Set(sheet.mergedRanges.map(\.a1)) == ["A1:B1", "C2:C3"])
    }

    @Test("Rows and columns hidden by hand or filtered out, which Numbers keeps by UUID")
    func hiddenStates() throws {
        var document = NumbersDocumentBuilder()
        var table = NumbersDocumentBuilder.Table(name: "Table 1", rows: [[.text("A")], [], [], [], []])
        table.columnCount = 3
        table.hasIdentifiers = true
        table.hasHiddenStates = true
        table.userHiddenRows = [1]
        table.filteredRows = [3]
        table.userHiddenColumns = [2]
        document.addSheet("Sheet 1", tables: [table])
        let (workbook, source) = try NumbersReader.document(from: document.singleFile())
        let sheet = workbook.sheets[0]

        #expect(sheet.hiddenRows == [1, 3])
        #expect(sheet.hiddenColumns == [2])
        #expect(source.tables[sheet.id]?.hidden.lockedRows == [3], "a filter would only hide it again")
    }

    @Test("A document saved as a package reads the same as a single file")
    func package() throws {
        var document = NumbersDocumentBuilder()
        document.addSheet("Budget", tables: [.init(name: "Table 1", rows: [[.text("Rent"), .number(1_200, exponent: 0)]])])
        let package = FileWrapper(directoryWithFileWrappers: [
            "Index.zip": FileWrapper(regularFileWithContents: try document.singleFile()),
            "preview.jpg": FileWrapper(regularFileWithContents: Data([0xFF, 0xD8])),
        ])
        let sheet = try NumbersReader.workbook(from: package).sheets[0]
        #expect(sheet[CellAddress(row: 0, column: 1)].value == .number(1_200))
    }

    @Test("The notice lists what Tables keeps but can't edit")
    func features() throws {
        var plain = NumbersDocumentBuilder()
        plain.addSheet("Budget", tables: [.init(name: "Table 1", rows: [[.text("Rent")]])])
        let (_, source) = try NumbersReader.document(from: plain.singleFile())
        #expect(source.features.noticeMessage.contains(UnsupportedFeature.formatting.label))
        #expect(!source.features.noticeMessage.contains(UnsupportedFeature.unreadFormulas.label))

        var withFormula = NumbersDocumentBuilder()
        withFormula.addSheet("Budget", tables: [.init(name: "Table 1", rows: [[.formula(3)]])])
        let (_, formulaSource) = try NumbersReader.document(from: withFormula.singleFile())
        #expect(formulaSource.features.noticeMessage.contains(UnsupportedFeature.unreadFormulas.label))
    }

    @Test("A package can keep its objects in an Index folder rather than a ZIP")
    func packageWithIndexFolder() throws {
        var document = NumbersDocumentBuilder()
        document.addSheet("Budget", tables: [.init(name: "Table 1", rows: [[.text("Rent"), .number(1_200, exponent: 0)]])])
        var folders: [String: [String: FileWrapper]] = [:]
        for (path, data) in try ZipArchive.orderedEntries(in: document.singleFile()) {
            let folder = (path as NSString).deletingLastPathComponent
            folders[folder, default: [:]][(path as NSString).lastPathComponent] = FileWrapper(regularFileWithContents: data)
        }
        var index = folders["Index"] ?? [:]
        index["Tables"] = FileWrapper(directoryWithFileWrappers: folders["Index/Tables"] ?? [:])
        let package = FileWrapper(directoryWithFileWrappers: [
            "Index": FileWrapper(directoryWithFileWrappers: index),
            "Data": FileWrapper(directoryWithFileWrappers: folders["Data"] ?? [:]),
        ])
        let (workbook, source) = try NumbersReader.document(from: package)
        #expect(workbook.sheets[0][CellAddress(row: 0, column: 1)].value == .number(1_200))

        var edited = workbook
        edited.sheets[0][CellAddress(row: 0, column: 1)] = Cell(value: .number(900))
        let saved = try NumbersWriter.fileWrapper(for: edited, source: source, existing: package)
        #expect(saved.fileWrappers?["Data"]?.fileWrappers?["picture.png"] != nil)
        #expect(try NumbersReader.workbook(from: saved).sheets[0][CellAddress(row: 0, column: 1)].value == .number(900))
    }

    @Test("An archive that won't decode is passed over when the tables are elsewhere")
    func skipsUndecodableArchives() throws {
        var document = NumbersDocumentBuilder()
        document.addSheet("Budget", tables: [.init(name: "Table 1", rows: [[.text("Rent")]])])
        var entries = try ZipArchive.entries(in: document.singleFile())
        // Newer versions of Numbers compress their collaboration history with LZFSE.
        entries["Index/OperationStorage.iwa"] = Data("bvx2".utf8) + Data(repeating: 0x41, count: 32)
        let workbook = try NumbersReader.workbook(entries: entries)
        #expect(workbook.sheets[0][CellAddress(row: 0, column: 0)].value == .text("Rent"))
    }

    @Test("Archives that aren't Numbers documents are rejected")
    func rejectsOtherArchives() throws {
        let archive = try ZipArchive.archive(entries: [("Index/Document.iwa", Data()), ("readme.txt", Data("hi".utf8))])
        #expect(throws: NumbersReader.Failure.self) { try NumbersReader.workbook(from: archive) }
    }

    @Test("Tiles from before Numbers 5 ask for the file to be saved again")
    func rejectsOldStorage() throws {
        var document = NumbersDocumentBuilder()
        var table = NumbersDocumentBuilder.Table(name: "Table 1", rows: [[.text("Old")]])
        table.isPreBNC = true
        document.addSheet("Sheet 1", tables: [table])
        #expect(throws: NumbersReader.Failure.self) { try NumbersReader.workbook(from: document.singleFile()) }
    }
}

/// Builds Numbers documents object by object, the way Numbers lays them out,
/// for the reader to be tested against.
struct NumbersDocumentBuilder {
    enum Cell {
        case empty
        case number(Int64, exponent: Int)
        case currency(Int64, exponent: Int)
        case negativeZero
        case text(String)
        case richText(String)
        case boolean(Bool)
        case date(seconds: Double)
        case duration(seconds: Double)
        case formulaError
        /// A number Numbers calculated with a formula Tables can't read.
        case formula(Int64)
        /// A number Numbers calculated with a formula of these nodes.
        case formulaNodes(Int64, [ProtobufMessage])
        /// Text with a cell style, a field the writer has to carry over.
        case styledText(String, style: UInt32)
    }

    struct Table {
        var name: String
        var rows: [[Cell]]
        var rowCount: Int?
        var columnCount: Int?
        /// Rows in tiles after the first, by tile number.
        var extraTiles: [Int: [(row: Int, cells: [Cell])]] = [:]
        var rowSizes: [Int: Float] = [:]
        var columnSizes: [Int: Float] = [:]
        var hiddenRows: Set<Int> = []
        var hiddenColumns: Set<Int> = []
        /// Merges as older versions record them, with the table.
        var mergeRegions: [CellRange] = []
        /// Merges as newer versions record them, with the calculation engine.
        var mergeOwnerRanges: [CellRange] = []
        var isPreBNC = false
        /// Gives the table the UUID formulas in other tables refer to it by.
        var uuid: MergeOwners.UUID?
        var headerRows = 0
        /// Gives every row and column a UUID, as Numbers does.
        var hasIdentifiers = false
        /// Borders down the left of columns, over rows, by column.
        var leftBorders: [Int: Range<Int>] = [:]
        /// Borders along the top of rows, over columns, by row.
        var topBorders: [Int: Range<Int>] = [:]
        /// Hidden rows and columns as recent versions of Numbers keep them,
        /// by each one's UUID: hidden by hand, or filtered out.
        var hasHiddenStates = false
        var userHiddenRows: Set<Int> = []
        var userHiddenColumns: Set<Int> = []
        var filteredRows: Set<Int> = []

        init(name: String, rows: [[Cell]]) {
            self.name = name
            self.rows = rows
        }
    }

    static let defaultColumnWidth = 98.0

    private var objects: [(identifier: UInt64, type: Int, message: ProtobufWriter)] = []
    private var sheetIdentifiers: [UInt64] = []
    private var nextIdentifier: UInt64 = 100
    /// Merge owners and the calculation engine's map of them.
    private var ownerMapEntries: [ProtobufWriter] = []
    private var formulaCount = 0
    private var tableOwnerCount = 0

    /// Where the calculation engine lists owners whose formulas are out of date.
    static let staleOwnerListIdentifier: UInt64 = 4
    static let saveToken: UInt64 = 7

    mutating func addSheet(_ name: String, tables: [Table]) {
        var infos: [UInt64] = []
        for table in tables { infos.append(addTable(table)) }
        let sheet = infos.reduce(ProtobufWriter().string(1, name)) { $0.message(2, Self.reference($1)) }
        sheetIdentifiers.append(add(type: 2, sheet))
    }

    /// The whole document as a single-file `.numbers`.
    func singleFile() throws -> Data {
        var objects = objects
        let document = sheetIdentifiers.reduce(ProtobufWriter()) { $0.message(1, Self.reference($1)) }
        objects.append((1, 1, document))
        let tracker = ProtobufWriter()
            .message(3, ownerMapEntries.reduce(ProtobufWriter()) { $0.message(1, $1) })
            .varint(5, formulaCount)
        objects.append((3, 4000, ProtobufWriter().message(2, tracker).message(15, Self.reference(Self.staleOwnerListIdentifier))))
        objects.append((Self.staleOwnerListIdentifier, 4011, ProtobufWriter()))

        // Split across archives, as Numbers splits a document, each listed
        // as a component in the package's metadata.
        let tables = objects.filter { [6002, 6005, 6006, 6144].contains($0.type) }
        let rest = objects.filter { ![6002, 6005, 6006, 6144].contains($0.type) }
        let metadata = ProtobufWriter()
            .varint(1, nextIdentifier - 1)
            .message(3, ProtobufWriter().varint(1, 1).string(2, "Document").varint(12, 5))
            .message(3, ProtobufWriter().varint(1, 10).string(2, "Tables/DataList").varint(12, 5))
            .varint(8, Self.saveToken)
        return try ZipArchive.archive(entries: [
            ("Index/Document.iwa", Self.archive(rest)),
            ("Index/Tables/DataList.iwa", Self.archive(tables)),
            ("Index/Metadata.iwa", Self.archive([(2, 11006, metadata)])),
            ("Data/picture.png", Data([0x89, 0x50, 0x4E, 0x47])),
        ], compressing: false)
    }

    // MARK: - Tables

    private mutating func addTable(_ table: Table) -> UInt64 {
        var strings: [String] = []
        var richTexts: [UInt64] = []
        var formulas: [[ProtobufMessage]] = []
        let columnCount = table.columnCount ?? max(1, table.rows.map(\.count).max() ?? 1)

        func row(_ index: Int, _ cells: [Cell]) -> ProtobufWriter {
            var buffer: [UInt8] = []
            var offsets: [UInt8] = []
            for column in 0..<columnCount {
                let cell = column < cells.count ? cells[column] : .empty
                guard let storage = storage(of: cell) else {
                    offsets += [0xFF, 0xFF]
                    continue
                }
                offsets += [UInt8(buffer.count & 0xFF), UInt8(buffer.count >> 8)]
                buffer += storage
            }
            return ProtobufWriter()
                .varint(1, index)
                .varint(2, cells.count)
                .bytes(3, [])
                .bytes(4, [])
                .bytes(6, buffer)
                .bytes(7, offsets)
        }

        func storage(of cell: Cell) -> [UInt8]? {
            switch cell {
            case .empty: return nil
            case .number(let significand, let exponent):
                return Self.cellStorage(type: 2, flags: 0x1, Self.decimal128(significand, exponent: exponent))
            case .currency(let significand, let exponent):
                return Self.cellStorage(type: 10, flags: 0x1, Self.decimal128(significand, exponent: exponent))
            case .negativeZero:
                var zero = Self.decimal128(0, exponent: 0)
                zero[15] |= 0x80
                return Self.cellStorage(type: 2, flags: 0x1, zero)
            case .text(let text):
                strings.append(text)
                return Self.cellStorage(type: 3, flags: 0x8, Self.littleEndian(UInt32(strings.count)))
            case .richText(let text):
                let storage = add(type: 2001, ProtobufWriter().string(3, text))
                richTexts.append(add(type: 6218, ProtobufWriter().message(1, Self.reference(storage))))
                return Self.cellStorage(type: 9, flags: 0x10, Self.littleEndian(UInt32(richTexts.count)))
            case .boolean(let value):
                return Self.cellStorage(type: 6, flags: 0x2, Self.littleEndian(value ? 1.0 : 0.0))
            case .date(let seconds):
                return Self.cellStorage(type: 5, flags: 0x4, Self.littleEndian(seconds))
            case .duration(let seconds):
                return Self.cellStorage(type: 7, flags: 0x2, Self.littleEndian(seconds))
            case .formulaError:
                return Self.cellStorage(type: 8, flags: 0, [])
            case .formula(let value):
                formulaCount += 1
                let fields = Self.decimal128(value, exponent: 0) + Self.littleEndian(UInt32(1000 + formulaCount))
                return Self.cellStorage(type: 2, flags: 0x1 | 0x200, fields)
            case .formulaNodes(let value, let nodes):
                formulaCount += 1
                formulas.append(nodes)
                let fields = Self.decimal128(value, exponent: 0) + Self.littleEndian(UInt32(formulas.count))
                return Self.cellStorage(type: 2, flags: 0x1 | 0x200, fields)
            case .styledText(let text, let style):
                strings.append(text)
                return Self.cellStorage(type: 3, flags: 0x8 | 0x20, Self.littleEndian(UInt32(strings.count)) + Self.littleEndian(style))
            }
        }

        var tiles: [Int: [ProtobufWriter]] = [0: table.rows.enumerated().map { row($0.offset, $0.element) }]
        for (tile, rows) in table.extraTiles {
            tiles[tile] = rows.map { row($0.row, $0.cells) }
        }
        var tileStorage = ProtobufWriter()
        for (number, rows) in tiles.sorted(by: { $0.key < $1.key }) {
            let tile = rows.reduce(
                ProtobufWriter().varint(1, columnCount).varint(2, rows.count).varint(3, 0).varint(4, rows.count)
            ) { $0.message(5, $1) }
            let identifier = add(type: 6002, table.isPreBNC ? tile : tile.bool(7, true))
            tileStorage = tileStorage.message(1, ProtobufWriter().varint(1, number).message(2, Self.reference(identifier)))
        }

        let stringTable = add(type: 6005, dataList(strings.enumerated().map { ProtobufWriter().string(3, $0.element) }))
        let richTextTable = add(type: 6005, dataList(richTexts.map { ProtobufWriter().message(9, Self.reference($0)) }))
        let formulaTable = add(type: 6005, dataList(formulas.map { nodes in
            var array = ProtobufMessage()
            array.set(1, messages: nodes)
            var formula = ProtobufMessage()
            formula.set(1, message: array)
            return ProtobufWriter().bytes(5, formula.encoded())
        }))
        let rowHeaders = add(type: 6006, headers(sizes: table.rowSizes, hidden: table.hiddenRows))
        let columnHeaders = add(type: 6006, headers(sizes: table.columnSizes, hidden: table.hiddenColumns))

        var store = ProtobufWriter()
            .message(1, ProtobufWriter().varint(1, 0).message(2, Self.reference(rowHeaders)))
            .message(2, Self.reference(columnHeaders))
            .message(3, tileStorage)
            .message(4, Self.reference(stringTable))
            .message(6, Self.reference(formulaTable))
            .message(17, Self.reference(richTextTable))
        if !table.mergeRegions.isEmpty {
            let map = table.mergeRegions.reduce(ProtobufWriter()) { map, range in
                let range = range.normalized
                return map.message(1, ProtobufWriter()
                    .message(1, ProtobufWriter().fixed32(1, UInt32(range.start.column << 16 | range.start.row)))
                    .message(2, ProtobufWriter().fixed32(1, UInt32(range.columnRange.count << 16 | range.rowRange.count))))
            }
            store = store.message(13, Self.reference(add(type: 6144, map)))
        }

        var model = ProtobufWriter()
            .string(1, "table-\(nextIdentifier)")
            .message(4, store)
            .varint(6, table.rowCount ?? table.rows.count)
            .varint(7, columnCount)
            .string(8, table.name)
            .double(16, 20)
            .double(17, Self.defaultColumnWidth)
        if table.headerRows > 0 { model = model.varint(9, table.headerRows) }
        if table.hasIdentifiers {
            model = model.message(46, Self.reference(addIdentifiers(rows: table.rowCount ?? table.rows.count, columns: columnCount)))
        }
        if !table.leftBorders.isEmpty || !table.topBorders.isEmpty {
            model = model.message(49, Self.reference(addBorders(table, rows: table.rowCount ?? table.rows.count, columns: columnCount)))
        }
        if table.hasHiddenStates { model = model.message(70, Self.hiddenStates(table)) }
        if !table.mergeOwnerRanges.isEmpty || table.uuid != nil {
            model = model.message(84, ProtobufWriter().message(1, addMergeOwner(table.mergeOwnerRanges, base: table.uuid)))
        }
        let modelIdentifier = add(type: 6001, model)
        // The table's own formula owner, which the engine knows by number.
        add(type: 4008, ProtobufWriter().varint(2, 100 + tableOwnerCount).varint(3, 1))
        tableOwnerCount += 1
        return add(type: 6000, ProtobufWriter().message(1, ProtobufWriter()).message(2, Self.reference(modelIdentifier)))
    }

    /// Identifiers for each row and column, numbered so their order differs
    /// from the rows' and columns', as Numbers' random ones do.
    static func identifierUUID(_ index: Int, row: Bool) -> (lower: UInt64, upper: UInt64) {
        (UInt64(index) * 7 % 13, row ? UInt64(1000 - index) : UInt64(2000 - index))
    }

    private static func hiddenStates(_ table: Table) -> ProtobufWriter {
        func uuid(_ uid: (lower: UInt64, upper: UInt64)) -> ProtobufWriter {
            ProtobufWriter().varint(1, uid.lower).varint(2, uid.upper)
        }
        func extent(isRow: Bool, hidden: Set<Int>, filtered: Set<Int>) -> ProtobufWriter {
            var extent = ProtobufWriter().message(1, uuid((isRow ? 2 : 3, 9)))
            for index in hidden.union(filtered).sorted() {
                var state = ProtobufWriter().message(1, uuid(identifierUUID(index, row: isRow)))
                if hidden.contains(index) { state = state.bool(2, true) }
                if filtered.contains(index) { state = state.bool(3, true) }
                extent = extent.message(2, state)
            }
            return extent.varint(3, isRow ? 1 : 0)
        }
        let states = ProtobufWriter().message(1, uuid((1, 9)))
            .message(2, extent(isRow: false, hidden: table.userHiddenColumns, filtered: []))
            .message(3, extent(isRow: true, hidden: table.userHiddenRows, filtered: table.filteredRows))
        return ProtobufWriter().message(1, uuid((1, 9))).message(2, states)
    }

    private mutating func addIdentifiers(rows: Int, columns: Int) -> UInt64 {
        var map = ProtobufWriter()
        for (count, isRow, fields) in [(columns, false, (1, 2, 3)), (rows, true, (4, 5, 6))] {
            let uids = (0..<count).map { Self.identifierUUID($0, row: isRow) }
            let order = uids.indices.sorted { (uids[$0].upper, uids[$0].lower) < (uids[$1].upper, uids[$1].lower) }
            var forIndex = [Int](repeating: 0, count: count)
            for (position, index) in order.enumerated() { forIndex[index] = position }
            for index in order {
                map = map.message(fields.0, ProtobufWriter().varint(1, uids[index].lower).varint(2, uids[index].upper))
            }
            for index in order { map = map.varint(fields.1, index) }
            for position in forIndex { map = map.varint(fields.2, position) }
        }
        return add(type: 6267, map)
    }

    private mutating func addBorders(_ table: Table, rows: Int, columns: Int) -> UInt64 {
        func layer(_ index: Int, _ range: Range<Int>) -> ProtobufWriter {
            let run = ProtobufWriter().varint(1, range.lowerBound).varint(2, range.count)
                .message(3, ProtobufWriter().float(1, 1)).varint(4, 7)
            return ProtobufWriter().varint(1, index).message(2, run)
        }
        var sidecar = ProtobufWriter().varint(1, 7).varint(2, columns).varint(3, rows)
        for (column, range) in table.leftBorders.sorted(by: { $0.key < $1.key }) {
            sidecar = sidecar.message(4, Self.reference(add(type: 6306, layer(column, range))))
        }
        for (row, range) in table.topBorders.sorted(by: { $0.key < $1.key }) {
            sidecar = sidecar.message(6, Self.reference(add(type: 6306, layer(row, range))))
        }
        return add(type: 6305, sidecar)
    }

    /// Registers the owners newer files record merges through: the table's
    /// haunted owner, standing in for its base owner, which the merge owner's
    /// ranges name by the engine's internal number. Returns the haunted
    /// owner's UUID, for the table to point at.
    private mutating func addMergeOwner(_ ranges: [CellRange], base uuid: MergeOwners.UUID? = nil) -> ProtobufWriter {
        let seed = nextIdentifier
        let lower = uuid?.lower ?? seed, upper = uuid?.upper ?? 0xBBBB
        let haunted = ProtobufWriter().varint(1, seed).varint(2, 0xAAAA)
        let base = ProtobufWriter().varint(1, lower).varint(2, upper)
        add(type: 4008, ProtobufWriter().message(1, haunted).varint(3, 35).message(12, base))

        let internalID = ownerMapEntries.count
        // The engine spells the base owner's UUID as four 32-bit words.
        let words = ProtobufWriter()
            .varint(2, lower & 0xFFFF_FFFF).varint(3, lower >> 32)
            .varint(4, upper & 0xFFFF_FFFF).varint(5, upper >> 32)
        ownerMapEntries.append(ProtobufWriter().varint(1, internalID).message(2, words))

        let dependencies = ranges.reduce(ProtobufWriter()) { dependencies, range in
            let range = range.normalized
            let coordinates = ProtobufWriter()
                .varint(1, range.start.column).varint(2, range.start.row)
                .varint(3, range.end.column).varint(4, range.end.row)
            return dependencies.message(2, ProtobufWriter()
                .message(4, ProtobufWriter().varint(1, internalID).message(2, coordinates)))
        }
        add(type: 4008, ProtobufWriter().varint(3, 5).message(5, dependencies))
        return haunted
    }

    private func dataList(_ entries: [ProtobufWriter]) -> ProtobufWriter {
        entries.enumerated().reduce(ProtobufWriter().varint(1, 1).varint(2, entries.count + 1)) { list, entry in
            var body = ProtobufWriter().varint(1, entry.offset + 1).varint(2, 1)
            body = ProtobufWriter(bytes: body.bytes + entry.element.bytes)
            return list.message(3, body)
        }
    }

    private func headers(sizes: [Int: Float], hidden: Set<Int>) -> ProtobufWriter {
        Set(sizes.keys).union(hidden).sorted().reduce(ProtobufWriter().varint(1, 0)) { bucket, index in
            bucket.message(2, ProtobufWriter()
                .varint(1, index)
                .float(2, sizes[index] ?? 0)
                .varint(3, hidden.contains(index) ? 1 : 0)
                .varint(4, 0))
        }
    }

    // MARK: - Objects and archives

    @discardableResult
    private mutating func add(type: Int, _ message: ProtobufWriter) -> UInt64 {
        let identifier = nextIdentifier
        nextIdentifier += 1
        objects.append((identifier, type, message))
        return identifier
    }

    private static func reference(_ identifier: UInt64) -> ProtobufWriter {
        ProtobufWriter().varint(1, identifier)
    }

    /// An `.iwa`: each object behind its `ArchiveInfo`, the lot compressed as
    /// one Snappy block made of a single literal.
    private static func archive(_ objects: [(identifier: UInt64, type: Int, message: ProtobufWriter)]) -> Data {
        var stream = ProtobufWriter()
        for object in objects {
            let info = ProtobufWriter()
                .varint(1, object.identifier)
                .message(2, ProtobufWriter().varint(1, object.type).varint(3, object.message.bytes.count))
            stream.appendVarint(UInt64(info.bytes.count))
            stream = ProtobufWriter(bytes: stream.bytes + info.bytes + object.message.bytes)
        }

        var block = ProtobufWriter()
        block.appendVarint(UInt64(stream.bytes.count))
        var compressed = block.bytes
        if !stream.bytes.isEmpty {
            // Tag 63: a literal whose length, less one, follows in four bytes.
            compressed += [0xFC] + littleEndian(UInt32(stream.bytes.count - 1)) + stream.bytes
        }
        let length = compressed.count
        return Data([0, UInt8(length & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length >> 16 & 0xFF)] + compressed)
    }

    /// One cell in the layout Numbers 5 and later write.
    private static func cellStorage(type: UInt8, flags: UInt32, _ fields: [UInt8]) -> [UInt8] {
        [5, type, 0, 0, 0, 0, 0, 0] + littleEndian(flags) + fields
    }

    private static func decimal128(_ significand: Int64, exponent: Int) -> [UInt8] {
        var bytes = littleEndian(significand.magnitude) + [UInt8](repeating: 0, count: 8)
        let biased = exponent + 0x1820
        bytes[14] = UInt8((biased & 0x7F) << 1)
        bytes[15] = UInt8(biased >> 7 & 0x7F) | (significand < 0 ? 0x80 : 0)
        return bytes
    }

    private static func littleEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian, Array.init)
    }

    private static func littleEndian(_ value: Double) -> [UInt8] {
        littleEndian(value.bitPattern)
    }
}
