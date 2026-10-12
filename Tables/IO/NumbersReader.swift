import Foundation

/// Imports an Apple Numbers document into a workbook.
///
/// Numbers places any number of free-standing tables on each sheet, where a
/// workbook has one grid per sheet, so every table becomes a worksheet of its
/// own — what Numbers itself does when it exports to Excel. Cells come across
/// with the values Numbers last calculated.
///
/// Alongside the workbook comes a `NumbersSource`: the document as it was
/// read, which `NumbersWriter` patches to save changes back to it.
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
        try document(from: data).workbook
    }

    /// Reads a document saved as a package, which keeps those objects in an
    /// `Index.zip` inside the package, or in an `Index` folder.
    static func workbook(from package: FileWrapper) throws -> Workbook {
        try document(from: package).workbook
    }

    static func workbook(entries: [String: Data]) throws -> Workbook {
        try document(entries: entries.map { ($0.key, $0.value) }, layout: .singleFile).workbook
    }

    static func document(from data: Data) throws -> (workbook: Workbook, source: NumbersSource) {
        try document(entries: ZipArchive.orderedEntries(in: data), layout: .singleFile)
    }

    static func document(from package: FileWrapper) throws -> (workbook: Workbook, source: NumbersSource) {
        guard package.isDirectory, let children = package.fileWrappers else { throw Failure.notANumbersDocument }
        if let index = children["Index.zip"], index.isRegularFile, let index = index.regularFileContents {
            return try document(
                entries: ZipArchive.orderedEntries(in: index), layout: .packageWithIndexArchive, package: package
            )
        }
        guard let folder = children["Index"] else { throw Failure.notANumbersDocument }
        var entries: [(path: String, data: Data)] = []
        collect(folder, path: "Index", into: &entries)
        return try document(entries: entries, layout: .packageWithIndexFolder, package: package)
    }

    private static func collect(_ wrapper: FileWrapper, path: String, into entries: inout [(path: String, data: Data)]) {
        // Asking a folder for its contents, or a file for its children,
        // raises an exception.
        if wrapper.isRegularFile, let contents = wrapper.regularFileContents {
            entries.append((path, contents))
        }
        guard wrapper.isDirectory else { return }
        for (name, child) in (wrapper.fileWrappers ?? [:]).sorted(by: { $0.key < $1.key }) {
            collect(child, path: path + "/" + name, into: &entries)
        }
    }

    static func document(
        entries: [(path: String, data: Data)], layout: NumbersSource.Layout, package: FileWrapper? = nil
    ) throws -> (workbook: Workbook, source: NumbersSource) {
        let archive = IWAArchive(entries: Dictionary(entries, uniquingKeysWith: { _, last in last }))
        guard let document = archive[documentIdentifier], document.type == ObjectType.document else {
            throw Failure.notANumbersDocument
        }

        let mergeOwners = MergeOwners(archive: archive)
        var workbook = Workbook()
        workbook.sheets = []
        var tables: [Worksheet.ID: NumbersSource.Table] = [:]
        var readers: [Worksheet.ID: TableReader] = [:]
        for sheetReference in document.message.messages(1) {
            guard let sheet = archive[sheetReference]?.message else { continue }
            let sheetName = sheet.string(1) ?? ""
            let models = sheet.messages(2)
                .compactMap { archive[$0] }
                .filter { $0.type == ObjectType.tableInfo }
                .compactMap { info -> (identifier: UInt64, message: ProtobufMessage, isPivot: Bool)? in
                    guard let identifier = info.message.message(2)?.uint(1),
                          let model = archive[identifier]?.message else { return nil }
                    return (identifier, model, info.message.bool(16))
                }

            for model in models {
                let reader = try TableReader(table: model.message, archive: archive)
                var worksheet = reader.worksheet
                worksheet.mergedRanges += mergeOwners.ranges(for: model.message)
                // A sheet's one table goes by the sheet's name, as people think
                // of it; several are told apart by their own names as well.
                let tableName = model.message.string(8) ?? ""
                let name = models.count == 1 || tableName.isEmpty ? sheetName : "\(sheetName) – \(tableName)"
                worksheet.name = workbook.uniqueSheetName(basedOn: name)
                worksheet.origins = SheetOrigins()
                workbook.sheets.append(worksheet)
                readers[worksheet.id] = reader
                tables[worksheet.id] = NumbersSource.Table(
                    modelIdentifier: model.identifier,
                    sheetIdentifier: sheetReference.uint(1),
                    sharesSheet: models.count > 1,
                    uuid: mergeOwners.tableUUID(of: model.message),
                    storage: reader.storage,
                    protectedCells: reader.protectedCells,
                    isPivot: model.isPivot,
                    rowCount: model.message.int(6) ?? 0,
                    columnCount: model.message.int(7) ?? 0,
                    headerRows: model.message.int(9) ?? 0,
                    headerColumns: model.message.int(10) ?? 0,
                    footerRows: model.message.int(11) ?? 0,
                    rowHeaderBuckets: model.message.message(4)?.message(1)?.messages(2).count ?? 0
                )
            }
        }

        // Formulas name other tables by their worksheets, so they are read
        // once every table has one.
        let sheetNames = NumbersSource.sheetNames(of: workbook, tables: tables)
        for index in workbook.sheets.indices {
            let id = workbook.sheets[index].id
            guard let reader = readers[id], let table = tables[id] else { continue }
            for (address, nodes) in reader.formulas {
                let context = NumbersFormula.Context(host: address, hostTable: table.uuid, sheetNames: sheetNames)
                // Only formulas that can be written back, too: they are
                // written again as rows and columns move.
                guard address.row < workbook.sheets[index].rowCount, address.column < workbook.sheets[index].columnCount,
                      let formula = NumbersFormula.formula(from: nodes, context: context),
                      NumbersFormula.nodes(for: formula, context: context) != nil else { continue }
                workbook.sheets[index][address].formula = formula
                tables[id]?.protectedCells.remove(address)
            }
        }
        if workbook.sheets.isEmpty {
            workbook.sheets = [Worksheet(name: Workbook.defaultSheetName(1))]
        }
        workbook.recalculate()
        keepNumbersResults(in: &workbook, tables: &tables, readers: readers)
        let source = NumbersSource(
            layout: layout, entries: entries, package: package, archive: archive, tables: tables, imported: workbook,
            hasLinkedContent: hasLinkedContent(archive)
        )
        return (workbook, source)
    }

    /// Takes back every formula Tables works out differently from Numbers,
    /// keeping Numbers' result: the two read some things differently —
    /// dates typed as text, numbers written as text in arrays, lookups in
    /// unsorted lists — and opening a document shouldn't change what it
    /// shows.
    ///
    /// A formula reading one that disagrees disagrees with it, though it may
    /// be right by itself, so formulas are taken back from where the
    /// disagreement starts, and the rest checked again once those show
    /// Numbers' results.
    private static func keepNumbersResults(
        in workbook: inout Workbook, tables: inout [Worksheet.ID: NumbersSource.Table], readers: [Worksheet.ID: TableReader]
    ) {
        struct Place: Hashable {
            var sheet: Int
            var address: CellAddress
        }
        while true {
            var disagreeing: [Place: Cell] = [:]
            for index in workbook.sheets.indices {
                guard let reader = readers[workbook.sheets[index].id] else { continue }
                for (address, result) in reader.results {
                    let cell = workbook.sheets[index][address]
                    if cell.formula != nil, !agree(cell.value, result.value) {
                        disagreeing[Place(sheet: index, address: address)] = result
                    }
                }
            }
            guard !disagreeing.isEmpty else { return }

            let sheetIndices = Dictionary(
                workbook.sheets.enumerated().map { ($0.element.name.lowercased(), $0.offset) }, uniquingKeysWith: { $1 }
            )
            func readsDisagreement(_ place: Place) -> Bool {
                let formula = workbook.sheets[place.sheet][place.address].formula ?? ""
                return FormulaReferenceScanner.references(in: "=" + formula).contains { reference in
                    let sheet = reference.sheetName.map { sheetIndices[$0.lowercased()] } ?? place.sheet
                    return disagreeing.keys.contains { $0.sheet == sheet && reference.cells.contains($0.address) }
                }
            }
            let starts = disagreeing.keys.filter { !readsDisagreement($0) }
            for place in starts.isEmpty ? Array(disagreeing.keys) : starts {
                workbook.sheets[place.sheet][place.address] = disagreeing[place]!
                tables[workbook.sheets[place.sheet].id]?.protectedCells.insert(place.address)
            }
            workbook.recalculate()
        }
    }

    private static func agree(_ tables: CellValue, _ numbers: CellValue) -> Bool {
        switch (tables, numbers) {
        case (.number(let ours), .number(let theirs)):
            return abs(ours - theirs) <= max(1e-9, abs(theirs) * 1e-12)
        case (.error, .error):
            return true
        case (.empty, .text(let text)), (.text(let text), .empty):
            // Numbers keeps an empty string a formula came to as nothing.
            return text.isEmpty
        default:
            return tables == numbers
        }
    }

    /// Whether anything in the document follows cells by where they are in
    /// ways Tables can't move along with them: a chart's data, a table's
    /// categories, a filter's rules.
    private static func hasLinkedContent(_ archive: IWAArchive) -> Bool {
        if !archive.identifiers(ofType: ObjectType.chartDrawable).isEmpty { return true }
        for identifier in archive.identifiers(ofType: ObjectType.groupBy) {
            // Categories only once grouped by a column, and switched on.
            if let groupBy = archive[identifier]?.message, groupBy.has(2), groupBy.bool(6) { return true }
        }
        for identifier in archive.identifiers(ofType: ObjectType.filterSet) {
            if let filters = archive[identifier]?.message, filters.has(7) || filters.has(3) { return true }
        }
        return false
    }

    // MARK: - Format constants

    /// The document object always has this identifier.
    static let documentIdentifier: UInt64 = 1

    /// Type numbers of the objects this reader follows.
    enum ObjectType {
        static let document = 1
        static let tableInfo = 6000
        static let tile = 6002
        static let calculationEngine = 4000
        static let formulaOwnerDependencies = 4008
        static let packageMetadata = 11006
        static let chartDrawable = 5021
        static let filterSet = 6220
        static let groupBy = 6373
    }
}

/// A Numbers document as it was read, kept with the workbook made from it so
/// the workbook's changes can be saved back into it.
final class NumbersSource: @unchecked Sendable {
    /// How the document was stored.
    enum Layout {
        /// A ZIP archive, as Numbers saves by default.
        case singleFile
        /// A folder holding its objects in `Index.zip`.
        case packageWithIndexArchive
        /// A folder holding its objects in an `Index` folder.
        case packageWithIndexFolder
    }

    /// What Tables read of one table.
    struct Table {
        /// The `TST.TableModelArchive` it came from.
        var modelIdentifier: UInt64
        /// The `TN.SheetArchive` it is on, and whether other tables are too.
        var sheetIdentifier: UInt64?
        var sharesSheet = false
        /// What formulas know the table by.
        var uuid: MergeOwners.UUID?
        /// Every cell's storage, as Numbers wrote it.
        var storage: [CellAddress: ArraySlice<UInt8>]
        /// Cells holding Numbers formulas Tables can't read, and any it
        /// couldn't take apart: both are left exactly as they are.
        var protectedCells: Set<CellAddress>
        /// Pivot tables are built from other tables by Numbers itself.
        var isPivot: Bool
        var rowCount: Int
        var columnCount: Int
        var headerRows = 0
        var headerColumns = 0
        var footerRows = 0
        /// How many pieces the table's row sizes are kept in.
        var rowHeaderBuckets = 0
    }

    let layout: Layout
    /// The entries of the single file, or of the package's index, in order.
    let entries: [(path: String, data: Data)]
    /// The package as read, for its files outside the index.
    let package: FileWrapper?
    let archive: IWAArchive
    /// By the worksheet each table became.
    let tables: [Worksheet.ID: Table]
    /// The workbook as read, for telling what has changed since.
    let imported: Workbook
    /// Whether charts, categories or filters follow cells by where they are,
    /// so rows and columns can't be inserted or deleted under them.
    let hasLinkedContent: Bool

    init(
        layout: Layout, entries: [(path: String, data: Data)], package: FileWrapper?, archive: IWAArchive,
        tables: [Worksheet.ID: Table], imported: Workbook, hasLinkedContent: Bool = false
    ) {
        self.hasLinkedContent = hasLinkedContent
        self.layout = layout
        self.entries = entries
        self.package = package
        self.archive = archive
        self.tables = tables
        self.imported = imported
    }
}

/// Reads one table, a `TST.TableModelArchive`, into a worksheet.
private struct TableReader {
    private(set) var worksheet: Worksheet
    private(set) var storage: [CellAddress: ArraySlice<UInt8>] = [:]
    private(set) var protectedCells: Set<CellAddress> = []
    /// The nodes of each cell's formula.
    private(set) var formulas: [CellAddress: [ProtobufMessage]] = [:]
    /// What each formula came to when Numbers last worked it out.
    private(set) var results: [CellAddress: Cell] = [:]

    init(table: ProtobufMessage, archive: IWAArchive) throws {
        worksheet = Worksheet(name: table.string(8) ?? "")
        let rowCount = table.int(6) ?? 0
        let columnCount = table.int(7) ?? 0
        worksheet.rowCount = min(max(rowCount, 1), Worksheet.maximumRowCount)
        worksheet.columnCount = min(max(columnCount, 1), Worksheet.maximumColumnCount)

        guard let store = table.message(4) else { return }
        let strings = Self.dataList(store.message(4), in: archive) { $0.string(3) ?? "" }
        let richText = Self.dataList(store.message(17), in: archive) { Self.text(ofRichTextPayload: $0.message(9), in: archive) }
        let formulaNodes = Self.dataList(store.message(6), in: archive) { $0.message(5)?.message(1)?.messages(1) ?? [] }

        // Rows are stored in tiles of a fixed number of rows each.
        let tiles = store.message(3)
        let tileSize = tiles?.int(2).flatMap { $0 > 0 ? $0 : nil } ?? NumbersSource.defaultTileSize
        for tile in tiles?.messages(1) ?? [] {
            guard let tileObject = archive[tile.message(2)]?.message else { continue }
            // Tiles saved before Numbers 5 lay cells out differently; files
            // that old are vanishingly rare, so they are asked to be re-saved.
            guard tileObject.bool(7) else { throw NumbersReader.Failure.unsupportedStorage }
            let firstRow = (tile.int(1) ?? 0) * tileSize

            for rowInfo in tileObject.messages(5) {
                let row = firstRow + (rowInfo.int(1) ?? 0)
                guard let buffer = rowInfo.bytes(6), let offsets = rowInfo.bytes(7) else { continue }
                let cells = NumbersTileRow(buffer: buffer, offsets: offsets, wide: rowInfo.bool(8)).cells
                for (column, bytes) in cells {
                    let address = CellAddress(row: row, column: column)
                    storage[address] = bytes
                    let parsed = NumbersCellStorage(bytes)
                    // A cell that can't be taken apart can't be rewritten
                    // either; guarding it like a formula keeps it as it is.
                    if parsed?.hasFormula ?? true { protectedCells.insert(address) }
                    if let key = parsed?.formulaKey, let nodes = formulaNodes[key] { formulas[address] = nodes }
                    let cell = parsed?.cell(strings: strings, richText: richText)
                    if formulas[address] != nil { results[address] = cell ?? Cell() }
                    guard row < worksheet.rowCount, column < worksheet.columnCount, let cell else { continue }
                    worksheet[address] = cell
                }
            }
        }

        readHeaders(store, table: table, archive: archive)
        worksheet.mergedRanges = Self.mergedRanges(store, in: archive)
    }

    // MARK: - Tables of shared values

    /// A `TST.TableDataList`: the strings, rich text and the like that cells
    /// refer to by key.
    private static func dataList<Value>(
        _ reference: ProtobufMessage?, in archive: IWAArchive, value: (ProtobufMessage) -> Value
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
    private static func text(ofRichTextPayload reference: ProtobufMessage?, in archive: IWAArchive) -> String {
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
    private mutating func readHeaders(_ store: ProtobufMessage, table: ProtobufMessage, archive: IWAArchive) {
        let defaultWidth = table.double(17) ?? 0
        let rowBuckets = store.message(1)?.messages(2).compactMap { archive[$0]?.message } ?? []

        for header in rowBuckets.flatMap({ $0.messages(2) }) {
            guard let row = header.int(1), row < worksheet.rowCount else { continue }
            if let height = header.float(2), height > 0 { worksheet.rowHeights[row] = Double(height) }
            if (header.int(3) ?? 0) != 0 { worksheet.hiddenRows.insert(row) }
        }

        for header in archive[store.message(2)]?.message.messages(2) ?? [] {
            guard let column = header.int(1), column < worksheet.columnCount else { continue }
            if let width = header.float(2), width > 0 { worksheet.columnWidths[column] = Double(width) }
            if (header.int(3) ?? 0) != 0 { worksheet.hiddenColumns.insert(column) }
        }
        if defaultWidth > 0 {
            for column in 0..<worksheet.columnCount
            where worksheet.columnWidths[column] == nil && defaultWidth != Worksheet.defaultColumnWidth {
                worksheet.columnWidths[column] = defaultWidth
            }
        }
    }

    /// Merged regions, packed as a column in the high half of a word and a
    /// row in the low half, for the origin and the size alike.
    private static func mergedRanges(_ store: ProtobufMessage, in archive: IWAArchive) -> [CellRange] {
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

extension NumbersSource {
    /// Rows per tile when a table doesn't say.
    static let defaultTileSize = 256

    /// The name of the worksheet each table became, by the UUID formulas
    /// know the table by.
    static func sheetNames(of workbook: Workbook, tables: [Worksheet.ID: Table]) -> [MergeOwners.UUID: String] {
        var names: [MergeOwners.UUID: String] = [:]
        for sheet in workbook.sheets {
            if let uuid = tables[sheet.id]?.uuid { names[uuid] = sheet.name }
        }
        return names
    }
}

/// Merged cells as recent versions of Numbers record them: not with the
/// table, but as ranges the calculation engine tracks for a "merge owner",
/// which refers to the table through two levels of identifiers.
struct MergeOwners {
    /// The UUID identifying an owner across the document, which some
    /// messages spell as a `TSP.UUID`, two 64-bit halves, and others as a
    /// `TSP.CFUUIDArchive`, four 32-bit words.
    struct UUID: Hashable {
        var lower: UInt64
        var upper: UInt64

        init(lower: UInt64, upper: UInt64) {
            self.lower = lower
            self.upper = upper
        }

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
    enum OwnerKind {
        static let table = 1
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

    /// The UUID formulas know a `TST.TableModelArchive` by: the base owner
    /// its haunted owner stands in for.
    func tableUUID(of table: ProtobufMessage) -> UUID? {
        UUID(table.message(84)?.message(1)).flatMap { baseOwners[$0] }
    }

    /// The merged ranges of a `TST.TableModelArchive`.
    func ranges(for table: ProtobufMessage) -> [CellRange] {
        guard let base = tableUUID(of: table) else { return [] }
        return rangesByOwner[base] ?? []
    }
}
