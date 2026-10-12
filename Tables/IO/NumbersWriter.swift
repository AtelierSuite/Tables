import Foundation

/// Saves a workbook back into the Numbers document it was read from.
///
/// Rather than write a document of its own, which could hold only what Tables
/// understands, the writer patches the original: the objects a change touches
/// are rewritten — a table's tiles of cells, its strings, its row and column
/// headers, its size — and every other object, archive and file is copied
/// through byte for byte. So styles, formulas, charts, images and everything
/// else Tables doesn't read survive any number of saves.
///
/// Changed cells keep everything about them but their value: their styles,
/// formats, controls and comments are fields of the cell Numbers wrote, and
/// only the value's fields are replaced.
enum NumbersWriter {
    enum Failure: LocalizedError {
        /// The document's objects are stored in pieces that collaboration
        /// left to be merged, which the writer can't put back together.
        case unmergedChanges

        var errorDescription: String? {
            String(localized: "Numbers.Error.UnmergedChanges")
        }
    }

    /// The document with `workbook`'s changes saved into it.
    ///
    /// `existing` is the package on disk, when the document is one: its files
    /// other than the index are carried over from it.
    static func fileWrapper(for workbook: Workbook, source: NumbersSource, existing: FileWrapper?) throws -> FileWrapper {
        let entries = try patchedEntries(for: workbook, source: source)
        switch source.layout {
        case .singleFile:
            return FileWrapper(regularFileWithContents: try ZipArchive.archive(entries: entries, compressing: false))
        case .packageWithIndexArchive:
            let index = try ZipArchive.archive(entries: entries, compressing: false)
            return package(from: existing ?? source.package, replacing: ["Index.zip": index])
        case .packageWithIndexFolder:
            return package(from: existing ?? source.package, replacing: Dictionary(entries, uniquingKeysWith: { $1 }))
        }
    }

    /// A copy of a package with the files at the given paths replaced or
    /// added.
    private static func package(from original: FileWrapper?, replacing replacements: [String: Data]) -> FileWrapper {
        func copy(_ wrapper: FileWrapper?, path: String) -> FileWrapper {
            var children: [String: FileWrapper] = [:]
            for (name, child) in wrapper?.fileWrappers ?? [:] {
                let childPath = path.isEmpty ? name : path + "/" + name
                if child.isDirectory {
                    children[name] = copy(child, path: childPath)
                } else if replacements[childPath] == nil, let contents = child.regularFileContents {
                    children[name] = FileWrapper(regularFileWithContents: contents)
                }
            }
            // Files that are new, or replaced, at this level.
            for (replacementPath, contents) in replacements {
                let parent = (replacementPath as NSString).deletingLastPathComponent
                guard parent == path else { continue }
                children[(replacementPath as NSString).lastPathComponent] = FileWrapper(regularFileWithContents: contents)
            }
            // Folders that only new files live in.
            let prefix = path.isEmpty ? "" : path + "/"
            for replacementPath in replacements.keys where replacementPath.hasPrefix(prefix) {
                let rest = replacementPath.dropFirst(prefix.count)
                guard let slash = rest.firstIndex(of: "/") else { continue }
                let name = String(rest[..<slash])
                if children[name] == nil { children[name] = copy(nil, path: prefix + name) }
            }
            let directory = FileWrapper(directoryWithFileWrappers: children)
            if let name = wrapper?.preferredFilename, !name.isEmpty { directory.preferredFilename = name }
            return directory
        }
        return copy(original, path: "")
    }

    /// The document's entries, in their original order, with the archives a
    /// change touched rewritten and any new ones after them.
    static func patchedEntries(for workbook: Workbook, source: NumbersSource) throws -> [(path: String, data: Data)] {
        if let violation = NumbersEditPolicy.violation(in: workbook, source: source) { throw violation }

        var patch = Patch(archive: source.archive)
        for sheet in workbook.sheets {
            guard let table = source.tables[sheet.id], let imported = source.imported[sheet.id],
                  sheet != imported else { continue }
            try TableWriter(sheet: sheet, imported: imported, table: table).write(into: &patch)
        }
        guard !patch.isEmpty else { return source.entries }
        if patch.changedValues { patch.markFormulasForRecalculation() }
        try patch.updateMetadata()
        return patch.entries(from: source.entries)
    }
}

/// The objects a save changes and adds, gathered before any archive is
/// written.
private struct Patch {
    let archive: IWAArchive
    private(set) var changes: [UInt64: ProtobufMessage] = [:]
    /// New objects, by the archive each goes in.
    private(set) var additions: [String: [(identifier: UInt64, type: Int, message: ProtobufMessage)]] = [:]
    /// References each object gained.
    private(set) var references: [UInt64: [UInt64]] = [:]
    /// Tiles made for rows past the last of a table's tiles: each is a
    /// component of its own, which the table's component refers to.
    private(set) var newTiles: [(identifier: UInt64, owner: UInt64)] = []
    private(set) var changedValues = false
    private var nextIdentifier: UInt64

    init(archive: IWAArchive) {
        self.archive = archive
        let recorded = archive.identifiers(ofType: NumbersReader.ObjectType.packageMetadata).first
            .flatMap { archive[$0]?.message.uint(1) } ?? 0
        nextIdentifier = max(archive.largestIdentifier, recorded) + 1
    }

    var isEmpty: Bool { changes.isEmpty && additions.isEmpty }

    /// An object as the save has left it so far.
    subscript(identifier: UInt64) -> ProtobufMessage? {
        changes[identifier] ?? archive[identifier]?.message
    }

    mutating func change(_ identifier: UInt64, to message: ProtobufMessage) throws {
        guard !archive.patchedObjects.contains(identifier) else { throw NumbersWriter.Failure.unmergedChanges }
        changes[identifier] = message
    }

    mutating func noteChangedValues() {
        changedValues = true
    }

    /// Adds a tile for a table whose model is `owner`, returning its
    /// identifier.
    mutating func addTile(_ message: ProtobufMessage, owner: UInt64) -> UInt64 {
        let identifier = nextIdentifier
        nextIdentifier += 1
        additions["Index/Tables/Tile-\(identifier).iwa", default: []]
            .append((identifier, NumbersReader.ObjectType.tile, message))
        references[owner, default: []].append(identifier)
        newTiles.append((identifier, owner))
        return identifier
    }

    // MARK: - Recalculation

    /// Asks Numbers to recalculate every table's formulas when it next opens
    /// the document, since the values they read from may have changed.
    ///
    /// The calculation engine keeps a list of owners — tables, mostly — whose
    /// cells are out of date; every table goes on it.
    mutating func markFormulasForRecalculation() {
        guard let engine = archive.identifiers(ofType: NumbersReader.ObjectType.calculationEngine).first,
              let engineMessage = archive[engine]?.message,
              (engineMessage.message(2)?.uint(5) ?? 0) > 0,
              let listIdentifier = engineMessage.message(15)?.uint(1),
              var list = self[listIdentifier] else { return }

        var owners: [UInt64] = []
        for identifier in archive.identifiers(ofType: NumbersReader.ObjectType.formulaOwnerDependencies) {
            guard let dependencies = archive[identifier]?.message,
                  dependencies.int(3) == MergeOwners.OwnerKind.table,
                  let owner = dependencies.uint(2) else { continue }
            owners.append(owner)
        }
        var set = list.message(1) ?? ProtobufMessage()
        let listed = set.messages(1).flatMap { entry -> ClosedRange<UInt64> in
            let begin = entry.uint(1) ?? 0
            return begin...max(begin, entry.uint(2) ?? begin)
        }
        for owner in owners.sorted() where !listed.contains(owner) {
            var entry = ProtobufMessage()
            entry.set(1, uint: owner)
            set.append(1, message: entry)
        }
        list.set(1, message: set)
        try? change(listIdentifier, to: list)
    }

    // MARK: - Metadata

    /// Brings the package's metadata up to date: a new save token for the
    /// save and the components it rewrote, the highest identifier in use,
    /// and a component for every new tile.
    mutating func updateMetadata() throws {
        guard let identifier = archive.identifiers(ofType: NumbersReader.ObjectType.packageMetadata).first,
              var metadata = archive[identifier]?.message else {
            // Without metadata there is nowhere to record a new component.
            if !newTiles.isEmpty { throw NumbersEditPolicy.Violation.structure }
            return
        }
        let token = (metadata.uint(8) ?? 0) + 1
        metadata.set(8, uint: token)
        metadata.set(1, uint: max(metadata.uint(1) ?? 0, nextIdentifier - 1))

        let paths = rewrittenPaths
        let ownerPaths = Dictionary(newTiles.map { ($0.owner, archive[$0.owner]?.path) }, uniquingKeysWith: { $1 })
        var components = metadata.messages(3)
        for index in components.indices {
            let path = Self.path(of: components[index])
            if paths.contains(path) { components[index].set(12, uint: token) }
            for tile in newTiles where ownerPaths[tile.owner] == path {
                var reference = ProtobufMessage()
                reference.set(1, uint: tile.identifier)
                components[index].append(6, message: reference)
            }
        }
        for tile in newTiles {
            var component = ProtobufMessage()
            component.set(1, uint: tile.identifier)
            component.set(2, bytes: Array("Tables/Tile".utf8))
            component.set(3, bytes: Array("Tables/Tile-\(tile.identifier)".utf8))
            component.set(4, [.varint(2), .varint(0), .varint(0)])
            component.set(5, [.varint(2), .varint(0), .varint(0)])
            component.set(10, bool: false)
            component.set(12, uint: token)
            components.append(component)
        }
        metadata.set(3, messages: components)
        changes[identifier] = metadata
    }

    /// The archive a component is stored in: its locator, or failing that its
    /// preferred locator, under `Index`.
    private static func path(of component: ProtobufMessage) -> String {
        "Index/" + (component.string(3) ?? component.string(2) ?? "") + ".iwa"
    }

    private var rewrittenPaths: Set<String> {
        Set(changes.keys.compactMap { archive[$0]?.path }).union(additions.keys)
    }

    // MARK: - Entries

    func entries(from original: [(path: String, data: Data)]) -> [(path: String, data: Data)] {
        var changesByPath: [String: [UInt64: ProtobufMessage]] = [:]
        for (identifier, message) in changes {
            guard let path = archive[identifier]?.path else { continue }
            changesByPath[path, default: [:]][identifier] = message
        }
        var entries = original.map { entry -> (path: String, data: Data) in
            guard changesByPath[entry.path] != nil || additions[entry.path] != nil else { return entry }
            let data = archive.data(
                for: entry.path, changing: changesByPath[entry.path] ?? [:],
                adding: additions[entry.path] ?? [], references: references
            )
            return (entry.path, data)
        }
        let existing = Set(original.map(\.path))
        for (path, objects) in additions.sorted(by: { $0.key < $1.key }) where !existing.contains(path) {
            entries.append((path, archive.data(for: path, changing: [:], adding: objects, references: references)))
        }
        return entries
    }
}

/// Writes one worksheet's changes into the table it was read from.
private struct TableWriter {
    let sheet: Worksheet
    let imported: Worksheet
    let table: NumbersSource.Table

    func write(into patch: inout Patch) throws {
        guard var model = patch[table.modelIdentifier], var store = model.message(4) else { return }
        var strings = StringTable(reference: store.message(4), patch: patch)

        // The new storage of every changed cell; nil where it is now empty.
        var changedCells: [CellAddress: [UInt8]?] = [:]
        for address in Set(sheet.cells.keys).union(imported.cells.keys)
        where address.row < sheet.rowCount && address.column < sheet.columnCount {
            let cell = sheet[address], original = imported[address]
            guard cell.value != original.value || cell.style.numberFormat != original.style.numberFormat else { continue }
            let storage = table.storage[address].flatMap(NumbersCellStorage.init) ?? NumbersCellStorage(type: 0)
            let updated = storage.replacingValue(with: cell) { strings.key(for: $0) }
            changedCells.updateValue(updated.isBare ? nil : updated.encoded, forKey: address)
        }
        if !changedCells.isEmpty { patch.noteChangedValues() }

        let rowCount = sheet.rowCount > imported.rowCount ? sheet.rowCount : table.rowCount
        let columnCount = sheet.columnCount > imported.columnCount ? sheet.columnCount : table.columnCount

        var rowCellCounts: [Int: Int] = [:]
        try writeTiles(
            changedCells, rowCount: rowCount, columnCount: columnCount,
            store: &store, rowCellCounts: &rowCellCounts, patch: &patch
        )
        try strings.save(into: &patch)
        try writeRowHeaders(rowCount: rowCount, rowCellCounts: rowCellCounts, store: store, patch: &patch)
        try writeColumnHeaders(changedCells, columnCount: columnCount, store: store, patch: &patch)

        model.set(4, message: store)
        if rowCount != table.rowCount { model.set(6, uint: UInt64(rowCount)) }
        if columnCount != table.columnCount { model.set(7, uint: UInt64(columnCount)) }
        try patch.change(table.modelIdentifier, to: model)
    }

    // MARK: - Tiles

    /// Rewrites the tiles holding changed cells or new rows, adding tiles
    /// for rows past the last one.
    private func writeTiles(
        _ changedCells: [CellAddress: [UInt8]?], rowCount: Int, columnCount: Int,
        store: inout ProtobufMessage, rowCellCounts: inout [Int: Int], patch: inout Patch
    ) throws {
        var tileStorage = store.message(3) ?? ProtobufMessage()
        let tileSize = tileStorage.int(2).flatMap { $0 > 0 ? $0 : nil } ?? NumbersSource.defaultTileSize
        var tilesByNumber: [Int: UInt64] = [:]
        for tile in tileStorage.messages(1) {
            if let number = tile.int(1), let identifier = tile.message(2)?.uint(1) { tilesByNumber[number] = identifier }
        }

        var changesByRow: [Int: [Int: [UInt8]?]] = [:]
        for (address, storage) in changedCells {
            changesByRow[address.row, default: [:]].updateValue(storage, forKey: address.column)
        }
        // New rows get rows of their own in their tile, as Numbers gives
        // every row one.
        let newRows = table.rowCount < rowCount ? Array(table.rowCount..<rowCount) : []
        for row in newRows where changesByRow[row] == nil { changesByRow[row] = [:] }

        var rowTileTree = store.message(9) ?? ProtobufMessage()
        let rowsByTile = Dictionary(grouping: changesByRow.keys) { $0 / tileSize }
        for (number, rows) in rowsByTile.sorted(by: { $0.key < $1.key }) {
            let existing = tilesByNumber[number]
            var tile = existing.flatMap { patch[$0] } ?? Self.newTile(wideRows: tileStorage.bool(3))
            var rowInfos: [Int: ProtobufMessage] = [:]
            for info in tile.messages(5) {
                if let index = info.int(1) { rowInfos[index] = info }
            }
            // Rows keep the width of offset table their tile already uses.
            let offsetColumns = max(
                rowInfos.values.lazy.compactMap { $0.bytes(7)?.count }.max().map { $0 / 2 } ?? NumbersEditPolicy.maximumColumnCount,
                columnCount
            )

            for row in rows {
                let index = row - number * tileSize
                var info = rowInfos[index] ?? Self.newRowInfo(index: index)
                var cells = NumbersTileRow(
                    buffer: info.bytes(6) ?? [], offsets: info.bytes(7) ?? [], wide: info.bool(8)
                ).cells
                for (column, storage) in changesByRow[row] ?? [:] {
                    cells[column] = storage.map { $0[...] }
                }
                let encoded = NumbersTileRow(cells: cells).encoded(columns: offsetColumns)
                info.set(2, uint: UInt64(cells.count))
                info.set(6, bytes: encoded.buffer)
                info.set(7, bytes: encoded.offsets)
                info.set(8, bool: encoded.wide)
                rowInfos[index] = info
                rowCellCounts[row] = cells.count
            }
            tile.set(5, messages: rowInfos.keys.sorted().map { rowInfos[$0]! })
            tile.set(4, uint: UInt64(max(tile.int(4) ?? 0, (rowInfos.keys.max() ?? -1) + 1)))

            if let existing {
                try patch.change(existing, to: tile)
            } else {
                let identifier = patch.addTile(tile, owner: table.modelIdentifier)
                var reference = ProtobufMessage()
                reference.set(1, uint: identifier)
                var entry = ProtobufMessage()
                entry.set(1, uint: UInt64(number))
                entry.set(2, message: reference)
                tileStorage.append(1, message: entry)
                var node = ProtobufMessage()
                node.set(1, uint: UInt64(number * tileSize))
                node.set(2, uint: UInt64(number))
                rowTileTree.append(1, message: node)
            }
        }
        store.set(3, message: tileStorage)
        if store.has(9) || !rowTileTree.fields.isEmpty { store.set(9, message: rowTileTree) }
    }

    private static func newTile(wideRows: Bool) -> ProtobufMessage {
        var tile = ProtobufMessage()
        tile.set(1, uint: 0)
        tile.set(2, uint: 0)
        tile.set(3, uint: 0)
        tile.set(4, uint: 0)
        tile.set(6, uint: 5)
        tile.set(7, bool: true)
        tile.set(8, bool: wideRows)
        return tile
    }

    private static func newRowInfo(index: Int) -> ProtobufMessage {
        var info = ProtobufMessage()
        info.set(1, uint: UInt64(index))
        info.set(2, uint: 0)
        // Required, though only versions before Numbers 5 read them.
        info.set(3, bytes: [])
        info.set(4, bytes: [])
        info.set(5, uint: 5)
        return info
    }

    // MARK: - Headers

    /// Row heights, and how many cells each changed row holds.
    private func writeRowHeaders(
        rowCount: Int, rowCellCounts: [Int: Int], store: ProtobufMessage, patch: inout Patch
    ) throws {
        var heights: [Int: Float] = [:]
        for row in Set(sheet.rowHeights.keys).union(imported.rowHeights.keys)
        where sheet.rowHeights[row] != imported.rowHeights[row] && row < rowCount {
            heights[row] = Float(sheet.rowHeights[row] ?? 0)
        }
        guard !heights.isEmpty || !rowCellCounts.isEmpty,
              let bucketIdentifier = store.message(1)?.messages(2).first?.uint(1) else { return }
        try updateHeaders(bucketIdentifier, sizes: heights, cellCounts: rowCellCounts, patch: &patch)
    }

    /// Column widths, and how many cells each column holds now.
    private func writeColumnHeaders(
        _ changedCells: [CellAddress: [UInt8]?], columnCount: Int, store: ProtobufMessage, patch: inout Patch
    ) throws {
        var widths: [Int: Float] = [:]
        for column in Set(sheet.columnWidths.keys).union(imported.columnWidths.keys)
        where sheet.columnWidths[column] != imported.columnWidths[column] && column < columnCount {
            widths[column] = Float(sheet.columnWidths[column] ?? 0)
        }
        var deltas: [Int: Int] = [:]
        for (address, storage) in changedCells {
            let had = table.storage[address] != nil, has = storage != nil
            if had != has { deltas[address.column, default: 0] += has ? 1 : -1 }
        }
        guard !widths.isEmpty || !deltas.isEmpty, let bucketIdentifier = store.message(2)?.uint(1) else { return }
        try updateHeaders(bucketIdentifier, sizes: widths, cellCountChanges: deltas, patch: &patch)
    }

    /// Sets sizes and cell counts in a `TST.HeaderStorageBucket`, adding
    /// headers for rows or columns that had none.
    private func updateHeaders(
        _ identifier: UInt64, sizes: [Int: Float], cellCounts: [Int: Int] = [:],
        cellCountChanges: [Int: Int] = [:], patch: inout Patch
    ) throws {
        guard var bucket = patch[identifier] else { return }
        var headers: [Int: ProtobufMessage] = [:]
        var order: [Int] = []
        for header in bucket.messages(2) {
            guard let index = header.int(1) else { continue }
            headers[index] = header
            order.append(index)
        }
        let touched = Set(sizes.keys).union(cellCounts.keys).union(cellCountChanges.keys)
        for index in touched {
            var header = headers[index] ?? {
                var header = ProtobufMessage()
                header.set(1, uint: UInt64(index))
                header.set(2, float: 0)
                header.set(3, uint: 0)
                header.set(4, uint: 0)
                return header
            }()
            if let size = sizes[index] { header.set(2, float: size) }
            if let count = cellCounts[index] { header.set(4, uint: UInt64(count)) }
            if let change = cellCountChanges[index] {
                header.set(4, uint: UInt64(max(0, (header.int(4) ?? 0) + change)))
            }
            if headers[index] == nil { order.append(index) }
            headers[index] = header
        }
        bucket.set(2, messages: order.sorted().map { headers[$0]! })
        try patch.change(identifier, to: bucket)
    }
}

/// A table's strings, a `TST.TableDataList` cells refer to by key.
private struct StringTable {
    private let identifier: UInt64?
    private var list: ProtobufMessage
    private var keys: [String: UInt32] = [:]
    private var nextKey: UInt32
    /// References added to each existing key.
    private var added: [UInt32: UInt64] = [:]
    private var newEntries: [ProtobufMessage] = []

    init(reference: ProtobufMessage?, patch: Patch) {
        identifier = reference?.uint(1)
        list = identifier.flatMap { patch[$0] } ?? ProtobufMessage()
        var largest: UInt32 = 0
        for entry in list.messages(3) {
            guard let key = entry.uint(1).map(UInt32.init(truncatingIfNeeded:)) else { continue }
            largest = max(largest, key)
            if let string = entry.string(3), keys[string] == nil { keys[string] = key }
        }
        nextKey = max(UInt32(truncatingIfNeeded: list.uint(2) ?? 1), largest + 1)
    }

    /// The key for `text`, added to the table if it isn't there yet.
    mutating func key(for text: String) -> UInt32 {
        if let key = keys[text] {
            added[key, default: 0] += 1
            return key
        }
        let key = nextKey
        nextKey += 1
        keys[text] = key
        var entry = ProtobufMessage()
        entry.set(1, uint: UInt64(key))
        entry.set(2, uint: 0)
        entry.set(3, bytes: Array(text.utf8))
        newEntries.append(entry)
        added[key, default: 0] += 1
        return key
    }

    /// Writes the table back if any key gained a reference. References a
    /// change dropped are left counted: a string kept a little longer than
    /// needed does no harm, where one dropped too soon would.
    func save(into patch: inout Patch) throws {
        guard let identifier, !added.isEmpty else { return }
        var list = list
        let entries = (list.messages(3) + newEntries).map { entry -> ProtobufMessage in
            guard let key = entry.uint(1).map(UInt32.init(truncatingIfNeeded:)), let count = added[key] else { return entry }
            var entry = entry
            entry.set(2, uint: (entry.uint(2) ?? 0) + count)
            return entry
        }
        list.set(3, messages: entries)
        list.set(2, uint: UInt64(nextKey))
        try patch.change(identifier, to: list)
    }
}
