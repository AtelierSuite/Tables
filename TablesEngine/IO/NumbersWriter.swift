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
public enum NumbersWriter {
    public enum Failure: LocalizedError, Sendable {
        /// The document's objects are stored in pieces that collaboration
        /// left to be merged, which the writer can't put back together.
        case unmergedChanges

        public var errorDescription: String? {
            String(localized: "Numbers.Error.UnmergedChanges", bundle: #bundle)
        }
    }

    /// The document with `workbook`'s changes saved into it.
    ///
    /// `existing` is the package on disk, when the document is one: its files
    /// other than the index are carried over from it.
    public static func fileWrapper(for workbook: Workbook, source: NumbersSource, existing: FileWrapper?) throws -> FileWrapper {
        guard var entries = try patchedEntries(for: workbook, source: source) else {
            return try unchanged(source, existing: existing)
        }
        switch source.layout {
        case .singleFile:
            // The previews are entries of the archive, like everything else.
            let originals = Dictionary(
                entries.filter { NumbersPreview.names.contains($0.path) }, uniquingKeysWith: { first, _ in first }
            )
            let previews = NumbersPreview.previews(replacing: originals, workbook: workbook, source: source)
            entries = entries.map { (path: $0.path, data: previews[$0.path] ?? $0.data) }
            return FileWrapper(regularFileWithContents: try ZipArchive.archive(entries: entries, compressing: false))
        case .packageWithIndexArchive:
            let index = try ZipArchive.archive(entries: entries, compressing: false)
            let original = existing ?? source.package
            return package(from: original, replacing: packagePreviews(of: original, workbook: workbook, source: source)
                .merging(["Index.zip": index], uniquingKeysWith: { $1 }))
        case .packageWithIndexFolder:
            let original = existing ?? source.package
            return package(from: original, replacing: packagePreviews(of: original, workbook: workbook, source: source)
                .merging(entries, uniquingKeysWith: { $1 }))
        }
    }

    /// New previews for those a package keeps at its root.
    private static func packagePreviews(of package: FileWrapper?, workbook: Workbook, source: NumbersSource) -> [String: Data] {
        let children = package?.isDirectory == true ? package?.fileWrappers ?? [:] : [:]
        var originals: [String: Data] = [:]
        for name in NumbersPreview.names {
            if let child = children[name], child.isRegularFile, let data = child.regularFileContents { originals[name] = data }
        }
        return NumbersPreview.previews(replacing: originals, workbook: workbook, source: source)
    }

    /// The document as it was read. Numbers' own archive is written back as
    /// it was, rather than archived again: an archive of the same entries
    /// is still not the same file, without the times and extra fields
    /// Numbers wrote for each entry.
    private static func unchanged(_ source: NumbersSource, existing: FileWrapper?) throws -> FileWrapper {
        let container = try source.container ?? ZipArchive.archive(entries: source.entries, compressing: false)
        switch source.layout {
        case .singleFile:
            return FileWrapper(regularFileWithContents: container)
        case .packageWithIndexArchive:
            return package(from: existing ?? source.package, replacing: ["Index.zip": container])
        case .packageWithIndexFolder:
            return package(from: existing ?? source.package, replacing: Dictionary(source.entries, uniquingKeysWith: { $1 }))
        }
    }

    /// A copy of a package with the files at the given paths replaced or
    /// added.
    private static func package(from original: FileWrapper?, replacing replacements: [String: Data]) -> FileWrapper {
        func copy(_ wrapper: FileWrapper?, path: String) -> FileWrapper {
            var children: [String: FileWrapper] = [:]
            let existing = wrapper?.isDirectory == true ? wrapper?.fileWrappers ?? [:] : [:]
            for (name, child) in existing {
                let childPath = path.isEmpty ? name : path + "/" + name
                if child.isDirectory {
                    children[name] = copy(child, path: childPath)
                } else if replacements[childPath] == nil, child.isRegularFile, let contents = child.regularFileContents {
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
    /// change touched rewritten and any new ones after them. Nil when
    /// nothing has changed.
    public static func patchedEntries(for workbook: Workbook, source: NumbersSource) throws -> [(path: String, data: Data)]? {
        if let violation = NumbersEditPolicy.violation(in: workbook, source: source) { throw violation }

        var patch = Patch(archive: source.archive)
        let sheetNames = NumbersSource.sheetNames(of: workbook, tables: source.tables)
        for sheet in workbook.sheets {
            guard let table = source.tables[sheet.id], let imported = source.imported[sheet.id] else { continue }
            if sheet.name != imported.name, let identifier = table.sheetIdentifier, var numbersSheet = patch[identifier] {
                numbersSheet.set(1, bytes: Array(sheet.name.utf8))
                try patch.change(identifier, to: numbersSheet)
            }
            var renamedBack = sheet
            renamedBack.name = imported.name
            guard renamedBack != imported else { continue }
            try TableWriter(sheet: sheet, imported: imported, table: table, sheetNames: sheetNames).write(into: &patch)
        }
        guard !patch.isEmpty else { return nil }
        try patch.countFormulas()
        if patch.changedValues { try patch.markFormulasForRecalculation() }
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
    /// How many more cells hold formulas than did.
    private(set) var formulaCountChange = 0
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

    mutating func noteFormulaCountChange(_ change: Int) {
        formulaCountChange += change
    }

    /// Variations of styles made by this save, so cells formatted alike
    /// share one: by what they are a variation of and what they set.
    var styleVariations: [String: UInt64] = [:]
    /// References from one object to another in a different component,
    /// which the components' metadata lists.
    private(set) var externalReferences: [(from: UInt64, to: UInt64)] = []

    /// Adds an object to the archive `neighbour` is in, returning its
    /// identifier.
    mutating func addObject(_ message: ProtobufMessage, type: Int, alongside neighbour: UInt64) -> UInt64? {
        guard let path = archive[neighbour]?.path else { return nil }
        let identifier = nextIdentifier
        nextIdentifier += 1
        additions[path, default: []].append((identifier, type, message))
        return identifier
    }

    /// Notes that one object now refers to another, as Numbers keeps every
    /// object's references with it.
    mutating func addReference(from source: UInt64, to target: UInt64) {
        references[source, default: []].append(target)
        externalReferences.append((source, target))
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

    private var calculationEngine: UInt64? {
        archive.identifiers(ofType: NumbersReader.ObjectType.calculationEngine).first
    }

    /// Keeps the calculation engine's count of formulas up to date.
    mutating func countFormulas() throws {
        guard formulaCountChange != 0, let engine = calculationEngine, var message = self[engine],
              var tracker = message.message(2) else { return }
        let count = Int(tracker.uint(5) ?? 0) + formulaCountChange
        tracker.set(5, uint: UInt64(max(0, count)))
        message.set(2, message: tracker)
        try change(engine, to: message)
    }

    /// Asks Numbers to recalculate every table's formulas when it next opens
    /// the document, since the values they read from may have changed.
    ///
    /// The calculation engine keeps a list of owners — tables, mostly — whose
    /// cells are out of date; every table goes on it.
    mutating func markFormulasForRecalculation() throws {
        guard let engine = calculationEngine,
              let engineMessage = self[engine],
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
        try change(listIdentifier, to: list)
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
        addExternalReferences(to: &components)
        metadata.set(3, messages: components)
        try change(identifier, to: metadata)
    }

    /// Lists each reference between objects in different components with
    /// the component it comes from.
    private func addExternalReferences(to components: inout [ProtobufMessage]) {
        let componentsByPath = Dictionary(
            components.compactMap { component in component.uint(1).map { (Self.path(of: component), $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        for (source, target) in externalReferences {
            guard let sourcePath = path(of: source), let targetPath = path(of: target), sourcePath != targetPath,
                  let targetComponent = componentsByPath[targetPath],
                  let index = components.firstIndex(where: { Self.path(of: $0) == sourcePath }) else { continue }
            let listed = components[index].messages(6).contains { $0.uint(1) == targetComponent && $0.uint(2) == target }
            guard !listed else { continue }
            var reference = ProtobufMessage()
            reference.set(1, uint: targetComponent)
            reference.set(2, uint: target)
            components[index].append(6, message: reference)
        }
    }

    /// The archive an object is in, or is being added to.
    private func path(of identifier: UInt64) -> String? {
        archive[identifier]?.path ?? additions.first { $0.value.contains { $0.identifier == identifier } }?.key
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
    let sheetNames: [MergeOwners.UUID: String]

    func write(into patch: inout Patch) throws {
        guard var model = patch[table.modelIdentifier], var store = model.message(4) else { return }
        var strings = StringTable(reference: store.message(4), patch: patch)
        var formulas = FormulaTable(reference: store.message(6), patch: patch)
        var formatting = TableFormatting(model: model, rowCount: sheet.rowCount, patch: patch)

        if sheet.origins?.hasMoved ?? false {
            return try writeMoved(
                model: model, store: store, strings: &strings, formulas: &formulas, formatting: &formatting, patch: &patch
            )
        }

        // The new storage of every changed cell; nil where it is now empty.
        var changedCells: [CellAddress: [UInt8]?] = [:]
        for address in Set(sheet.cells.keys).union(imported.cells.keys)
        where address.row < sheet.rowCount && address.column < sheet.columnCount {
            let cell = sheet[address], original = imported[address]
            guard Self.differs(cell, from: original) else { continue }
            let updated = try storage(
                for: cell, at: address, was: original, stored: table.storage[address],
                strings: &strings, formulas: &formulas, formatting: &formatting, patch: &patch
            )
            changedCells.updateValue(updated, forKey: address)
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
        try formulas.save(into: &patch)
        try formatting.save(into: &patch)
        try writeRowHeaders(rowCount: rowCount, rowCellCounts: rowCellCounts, store: store, patch: &patch)
        try writeColumnHeaders(changedCells, columnCount: columnCount, store: store, patch: &patch)

        model.set(4, message: store)
        if rowCount != table.rowCount { model.set(6, uint: UInt64(rowCount)) }
        if columnCount != table.columnCount { model.set(7, uint: UInt64(columnCount)) }
        if sheet.hiddenRows != imported.hiddenRows || sheet.hiddenColumns != imported.hiddenColumns {
            model = NumbersHiddenStates.model(
                model,
                hidingRows: sheet.hiddenRows.subtracting(table.hidden.lockedRows),
                columns: sheet.hiddenColumns.subtracting(table.hidden.lockedColumns),
                rowIdentifiers: table.rowIdentifiers, columnIdentifiers: table.columnIdentifiers
            ) ?? model
        }
        try patch.change(table.modelIdentifier, to: model)
    }

    private static func differs(_ cell: Cell, from original: Cell) -> Bool {
        cell.value != original.value || cell.style.numberFormat != original.style.numberFormat
            || cell.formula != original.formula
            || NumbersStyles.TextFormat(cell.style) != NumbersStyles.TextFormat(original.style)
            || NumbersStyles.CellFormat(cell.style) != NumbersStyles.CellFormat(original.style)
    }

    /// What to store for `cell` at `address`, from what Numbers stored for
    /// the cell it was; nil where it is now empty.
    private func storage(
        for cell: Cell, at address: CellAddress, was original: Cell, stored: ArraySlice<UInt8>?,
        strings: inout StringTable, formulas: inout FormulaTable, formatting: inout TableFormatting,
        patch: inout Patch, keepingFormula: Bool = true
    ) throws -> [UInt8]? {
        let storage = stored.flatMap(NumbersCellStorage.init) ?? NumbersCellStorage(type: 0)
        var formulaKey: UInt32?
        if let formula = cell.formula {
            if keepingFormula, formula == original.formula, let key = storage.formulaKey {
                // Only the result has changed.
                formulaKey = UInt32(truncatingIfNeeded: key)
            } else {
                let context = NumbersFormula.Context(host: address, hostTable: table.uuid, sheetNames: sheetNames)
                guard let nodes = NumbersFormula.nodes(for: formula, context: context) else {
                    throw NumbersEditPolicy.Violation.formula
                }
                formulaKey = formulas.key(for: nodes)
            }
        }
        if (formulaKey != nil) != storage.hasFormula { patch.noteFormulaCountChange(formulaKey != nil ? 1 : -1) }
        var updated = storage.replacingValue(with: cell, formulaKey: formulaKey) { strings.key(for: $0) }
        try formatting.format(&updated, as: cell.style, was: original.style, at: address, patch: &patch)
        return updated.isBare ? nil : updated.encoded
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
                addTile(tile, number: number, tileSize: tileSize, tileStorage: &tileStorage, rowTileTree: &rowTileTree, patch: &patch)
            }
        }
        store.set(3, message: tileStorage)
        if store.has(9) || !rowTileTree.fields.isEmpty { store.set(9, message: rowTileTree) }
    }

    /// Adds a tile for rows past the last of the table's tiles, listing it
    /// with the others and in the tree that finds a row's tile.
    private func addTile(
        _ tile: ProtobufMessage, number: Int, tileSize: Int,
        tileStorage: inout ProtobufMessage, rowTileTree: inout ProtobufMessage, patch: inout Patch
    ) {
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

/// A table whose rows or columns were inserted or deleted, rewritten whole:
/// every cell's storage goes where its row and column went, along with the
/// row and column sizes, borders and the identifiers Numbers keeps for each
/// row and column.
private extension TableWriter {
    /// Where the file's rows and columns are now, and back.
    struct Moves {
        let rowCount: Int
        let columnCount: Int
        let fileRows: [Int?]
        let fileColumns: [Int?]
        let rowNow: [Int: Int]
        let columnNow: [Int: Int]

        init(sheet: Worksheet, table: NumbersSource.Table) {
            let origins = sheet.origins ?? SheetOrigins()
            rowCount = sheet.rowCount
            columnCount = sheet.columnCount
            fileRows = (0..<rowCount).map { origins.row($0).flatMap { $0 < table.rowCount ? $0 : nil } }
            fileColumns = (0..<columnCount).map { origins.column($0).flatMap { $0 < table.columnCount ? $0 : nil } }
            rowNow = Dictionary(fileRows.enumerated().compactMap { now, file in file.map { ($0, now) } }, uniquingKeysWith: { $1 })
            columnNow = Dictionary(fileColumns.enumerated().compactMap { now, file in file.map { ($0, now) } }, uniquingKeysWith: { $1 })
        }

        func fileAddress(_ address: CellAddress) -> CellAddress? {
            guard let row = fileRows[address.row], let column = fileColumns[address.column] else { return nil }
            return CellAddress(row: row, column: column)
        }
    }

    func writeMoved(
        model: ProtobufMessage, store: ProtobufMessage, strings: inout StringTable, formulas: inout FormulaTable,
        formatting: inout TableFormatting, patch: inout Patch
    ) throws {
        var model = model, store = store
        let moves = Moves(sheet: sheet, table: table)

        // Each cell's storage where its row and column are now.
        var cells: [CellAddress: ArraySlice<UInt8>] = [:]
        for (address, bytes) in table.storage {
            guard let row = moves.rowNow[address.row], let column = moves.columnNow[address.column] else {
                if NumbersCellStorage(bytes)?.hasFormula ?? false { patch.noteFormulaCountChange(-1) }
                continue
            }
            cells[CellAddress(row: row, column: column)] = bytes
        }
        // Then the changes made to them. Every formula is written again: its
        // references count from its cell, and either may have moved.
        for address in Set(cells.keys).union(sheet.cells.keys)
        where address.row < moves.rowCount && address.column < moves.columnCount {
            let cell = sheet[address]
            let original = moves.fileAddress(address).map { imported[$0] } ?? Cell()
            guard cell.formula != nil || Self.differs(cell, from: original) else { continue }
            let updated = try storage(
                for: cell, at: address, was: original, stored: cells[address],
                strings: &strings, formulas: &formulas, formatting: &formatting, patch: &patch, keepingFormula: false
            )
            cells[address] = updated.map { $0[...] }
        }
        patch.noteChangedValues()

        var cellsByRow: [Int: [Int: ArraySlice<UInt8>]] = [:]
        var cellsPerColumn: [Int: Int] = [:]
        for (address, bytes) in cells {
            cellsByRow[address.row, default: [:]][address.column] = bytes
            cellsPerColumn[address.column, default: 0] += 1
        }

        try rewriteTiles(cellsByRow, moves: moves, store: &store, patch: &patch)
        try strings.save(into: &patch)
        try formulas.save(into: &patch)
        try formatting.save(into: &patch)
        if let bucket = store.message(1)?.messages(2).first?.uint(1) {
            try rewriteHeaders(
                bucket, count: moves.rowCount, fileIndices: moves.fileRows,
                cellCounts: { cellsByRow[$0]?.count ?? 0 },
                size: { sheet.rowHeights[$0] }, fileSize: { imported.rowHeights[$0] }, patch: &patch
            )
        }
        if let bucket = store.message(2)?.uint(1) {
            try rewriteHeaders(
                bucket, count: moves.columnCount, fileIndices: moves.fileColumns,
                cellCounts: { cellsPerColumn[$0] ?? 0 },
                size: { sheet.columnWidths[$0] }, fileSize: { imported.columnWidths[$0] }, patch: &patch
            )
        }
        if let identifier = model.message(46)?.uint(1) {
            try rewriteIdentifiers(identifier, moves: moves, patch: &patch)
        }
        if let identifier = model.message(49)?.uint(1) {
            try rewriteStrokes(identifier, moves: moves, patch: &patch)
        }

        model.set(4, message: store)
        model.set(6, uint: UInt64(moves.rowCount))
        model.set(7, uint: UInt64(moves.columnCount))
        try patch.change(table.modelIdentifier, to: model)
    }

    // MARK: Tiles

    private func rewriteTiles(
        _ cellsByRow: [Int: [Int: ArraySlice<UInt8>]], moves: Moves, store: inout ProtobufMessage, patch: inout Patch
    ) throws {
        var tileStorage = store.message(3) ?? ProtobufMessage()
        let tileSize = tileStorage.int(2).flatMap { $0 > 0 ? $0 : nil } ?? NumbersSource.defaultTileSize
        var tilesByNumber: [Int: UInt64] = [:]
        var fileInfos: [Int: ProtobufMessage] = [:]
        var offsetColumns = moves.columnCount
        for entry in tileStorage.messages(1) {
            guard let number = entry.int(1), let identifier = entry.message(2)?.uint(1) else { continue }
            tilesByNumber[number] = identifier
            for info in patch[identifier]?.messages(5) ?? [] {
                guard let index = info.int(1) else { continue }
                fileInfos[number * tileSize + index] = info
                offsetColumns = max(offsetColumns, (info.bytes(7)?.count ?? 0) / 2)
            }
        }
        if fileInfos.isEmpty { offsetColumns = max(offsetColumns, NumbersEditPolicy.maximumColumnCount) }

        var rowTileTree = store.message(9) ?? ProtobufMessage()
        let tileCount = (moves.rowCount + tileSize - 1) / tileSize
        for number in 0..<max(tileCount, (tilesByNumber.keys.max() ?? -1) + 1) {
            let rows = (number * tileSize)..<min(moves.rowCount, (number + 1) * tileSize)
            // A new row with nothing in it is stored as nothing, as Numbers
            // stores one.
            let stored = rows.filter { cellsByRow[$0] != nil || moves.fileRows[$0].flatMap { fileInfos[$0] } != nil }
            let infos = stored.map { row -> ProtobufMessage in
                let index = row - number * tileSize
                var info = moves.fileRows[row].flatMap { fileInfos[$0] } ?? Self.newRowInfo(index: index)
                let encoded = NumbersTileRow(cells: cellsByRow[row] ?? [:]).encoded(columns: offsetColumns)
                info.set(1, uint: UInt64(index))
                info.set(2, uint: UInt64(cellsByRow[row]?.count ?? 0))
                info.set(6, bytes: encoded.buffer)
                info.set(7, bytes: encoded.offsets)
                info.set(8, bool: encoded.wide)
                return info
            }
            let existing = tilesByNumber[number]
            var tile = existing.flatMap { patch[$0] } ?? Self.newTile(wideRows: tileStorage.bool(3))
            tile.set(5, messages: infos)
            tile.set(4, uint: UInt64((stored.last.map { $0 - number * tileSize } ?? -1) + 1))
            if let existing {
                try patch.change(existing, to: tile)
            } else {
                addTile(tile, number: number, tileSize: tileSize, tileStorage: &tileStorage, rowTileTree: &rowTileTree, patch: &patch)
            }
        }
        store.set(3, message: tileStorage)
        if store.has(9) || !rowTileTree.fields.isEmpty { store.set(9, message: rowTileTree) }
    }

    // MARK: Headers

    /// Moves each row's or column's header — its size, its cell count — to
    /// where the row or column is now.
    private func rewriteHeaders(
        _ identifier: UInt64, count: Int, fileIndices: [Int?], cellCounts: (Int) -> Int,
        size: (Int) -> Double?, fileSize: (Int) -> Double?, patch: inout Patch
    ) throws {
        guard var bucket = patch[identifier] else { return }
        var fileHeaders: [Int: ProtobufMessage] = [:]
        for header in bucket.messages(2) {
            if let index = header.int(1) { fileHeaders[index] = header }
        }
        var headers: [ProtobufMessage] = []
        for index in 0..<count {
            let file = fileIndices[index]
            let cells = cellCounts(index)
            let resized = size(index) != file.flatMap(fileSize)
            guard var header = file.flatMap({ fileHeaders[$0] }) ?? ((cells > 0 || resized) ? ProtobufMessage() : nil) else {
                continue
            }
            if !header.has(1) {
                header.set(2, float: 0)
                header.set(3, uint: 0)
            }
            header.set(1, uint: UInt64(index))
            if resized { header.set(2, float: Float(size(index) ?? 0)) }
            header.set(4, uint: UInt64(cells))
            headers.append(header)
        }
        bucket.set(2, messages: headers)
        try patch.change(identifier, to: bucket)
    }

    // MARK: Identifiers

    /// The UUID Numbers knows each row and column by, kept sorted with each
    /// one's index alongside: rows and columns keep theirs as they move, and
    /// new ones are given one.
    private func rewriteIdentifiers(_ identifier: UInt64, moves: Moves, patch: inout Patch) throws {
        guard var map = patch[identifier] else { return }
        func rewrite(sorted: Int, indexForUID: Int, uidForIndex: Int, fileIndices: [Int?]) {
            let uids = map.messages(sorted)
            let forIndex = map.uints(uidForIndex).map(Int.init)
            let packed = map.fields.contains { $0.number == uidForIndex && { if case .bytes = $0 { return true }; return false }($0.value) }
            var assigned: [(upper: UInt64, lower: UInt64)] = fileIndices.map { file in
                if let file, file < forIndex.count, forIndex[file] < uids.count {
                    let uid = uids[forIndex[file]]
                    return (uid.uint(2) ?? 0, uid.uint(1) ?? 0)
                }
                return (UInt64.random(in: .min ... .max), UInt64.random(in: .min ... .max))
            }
            let order = assigned.indices.sorted { (assigned[$0].upper, assigned[$0].lower) < (assigned[$1].upper, assigned[$1].lower) }
            var uidOfIndex = [Int](repeating: 0, count: assigned.count)
            for (position, index) in order.enumerated() { uidOfIndex[index] = position }
            let sortedUIDs = order.map { index -> ProtobufMessage in
                var uid = ProtobufMessage()
                uid.set(1, uint: assigned[index].lower)
                uid.set(2, uint: assigned[index].upper)
                return uid
            }
            map.set(sorted, messages: sortedUIDs)
            Self.setUInts(&map, indexForUID, order.map(UInt64.init), packed: packed)
            Self.setUInts(&map, uidForIndex, uidOfIndex.map(UInt64.init), packed: packed)
        }
        rewrite(sorted: 1, indexForUID: 2, uidForIndex: 3, fileIndices: moves.fileColumns)
        rewrite(sorted: 4, indexForUID: 5, uidForIndex: 6, fileIndices: moves.fileRows)
        try patch.change(identifier, to: map)
    }

    private static func setUInts(_ message: inout ProtobufMessage, _ number: Int, _ values: [UInt64], packed: Bool) {
        if packed {
            var bytes: [UInt8] = []
            for value in values { ProtobufMessage.appendVarint(value, to: &bytes) }
            message.set(number, bytes: bytes)
        } else {
            message.set(number, values.map { .varint($0) })
        }
    }

    // MARK: Borders

    /// Moves the table's borders with its rows and columns. Each row's and
    /// column's borders are a layer of runs along it: a layer moves with its
    /// row or column, and its runs are laid out again along the other.
    private func rewriteStrokes(_ identifier: UInt64, moves: Moves, patch: inout Patch) throws {
        guard var sidecar = patch[identifier] else { return }
        // Left and right column borders run down the rows; top and bottom
        // row borders run along the columns.
        for (field, isColumnLayer) in [(4, true), (5, true), (6, false), (7, false)] {
            var kept: [ProtobufMessage] = []
            for reference in sidecar.messages(field) {
                guard let layerIdentifier = reference.uint(1), var layer = patch[layerIdentifier],
                      let index = layer.int(1) else { kept.append(reference); continue }
                let now = isColumnLayer ? moves.columnNow[index] : moves.rowNow[index]
                guard let now else { continue }
                layer.set(1, uint: UInt64(now))
                layer.set(2, messages: Self.movedRuns(
                    layer.messages(2), fileIndices: isColumnLayer ? moves.fileRows : moves.fileColumns
                ))
                try patch.change(layerIdentifier, to: layer)
                kept.append(reference)
            }
            sidecar.set(field, messages: kept)
        }
        sidecar.set(2, uint: UInt64(moves.columnCount))
        sidecar.set(3, uint: UInt64(moves.rowCount))
        try patch.change(identifier, to: sidecar)
    }

    /// Runs of one stroke over consecutive rows or columns, laid out again
    /// where those rows or columns are now.
    private static func movedRuns(_ runs: [ProtobufMessage], fileIndices: [Int?]) -> [ProtobufMessage] {
        // The stroke at each of the file's positions: the run's own fields
        // but its origin and length.
        var strokes: [Int: ProtobufMessage] = [:]
        for run in runs {
            guard let origin = run.int(1).map({ Int(Int32(truncatingIfNeeded: $0)) }) else { continue }
            var stroke = run
            stroke.set(1, [])
            stroke.set(2, [])
            for position in origin..<(origin + (run.int(2) ?? 1)) { strokes[position] = stroke }
        }
        var moved: [ProtobufMessage] = []
        var current: (origin: Int, length: Int, stroke: ProtobufMessage)?
        func close() {
            guard let run = current else { return }
            // Origin and length come first, as Numbers writes them.
            var message = ProtobufMessage()
            message.set(1, uint: UInt64(bitPattern: Int64(run.origin)))
            message.set(2, uint: UInt64(run.length))
            for number in run.stroke.fields.map(\.number) where !message.has(number) {
                message.set(number, run.stroke.fields.filter { $0.number == number }.map(\.value))
            }
            moved.append(message)
            current = nil
        }
        for (position, file) in fileIndices.enumerated() {
            guard let stroke = file.flatMap({ strokes[$0] }) else { close(); continue }
            if let run = current, run.stroke.encoded() == stroke.encoded(), run.origin + run.length == position {
                current?.length += 1
            } else {
                close()
                current = (position, 1, stroke)
            }
        }
        close()
        return moved
    }
}

/// Formatting changed in a table's cells, given to Numbers as variations
/// of the styles they had, which the table's list of styles refers cells to.
private struct TableFormatting {
    private let regions: NumbersStyles.Regions
    private let rowCount: Int
    private let identifier: UInt64?
    private var list: ProtobufMessage
    private var keys: [UInt64: UInt32] = [:]
    private var references: [UInt32: UInt64] = [:]
    private var nextKey: UInt32
    private var added: [UInt32: UInt64] = [:]
    private var newEntries: [ProtobufMessage] = []
    private let roots: RootFormats

    /// What each style that variations are made from comes to, worked out
    /// once however many cells are restyled from it.
    private final class RootFormats {
        let resolver: NumbersStyles.Resolver
        private var text: [UInt64: NumbersStyles.TextFormat] = [:]
        private var cell: [UInt64: NumbersStyles.CellFormat] = [:]

        init(resolver: NumbersStyles.Resolver) { self.resolver = resolver }

        func text(_ root: UInt64) -> NumbersStyles.TextFormat {
            if let format = text[root] { return format }
            let format = NumbersStyles.TextFormat(resolver.style(text: root, cell: nil))
            text[root] = format
            return format
        }

        func cell(_ root: UInt64) -> NumbersStyles.CellFormat {
            if let format = cell[root] { return format }
            let format = NumbersStyles.CellFormat(resolver.style(text: nil, cell: root))
            cell[root] = format
            return format
        }
    }

    init(model: ProtobufMessage, rowCount: Int, patch: Patch) {
        regions = NumbersStyles.Regions(model: model)
        self.rowCount = rowCount
        let archive = patch.archive
        roots = RootFormats(resolver: NumbersStyles.Resolver { archive[$0]?.message })
        identifier = model.message(4)?.message(5)?.uint(1)
        list = identifier.flatMap { patch[$0] } ?? ProtobufMessage()
        var largest: UInt32 = 0
        for entry in list.messages(3) {
            guard let key = entry.uint(1).map(UInt32.init(truncatingIfNeeded:)) else { continue }
            largest = max(largest, key)
            if let style = entry.message(4)?.uint(1) {
                references[key] = style
                if keys[style] == nil { keys[style] = key }
            }
        }
        nextKey = max(UInt32(truncatingIfNeeded: list.uint(2) ?? 1), largest + 1)
    }

    /// Gives a cell's storage the styles for the formatting it has now,
    /// where that differs from what it had. A table without a list of
    /// styles keeps the formatting it had, as editing it does.
    mutating func format(
        _ storage: inout NumbersCellStorage, as style: CellStyle, was original: CellStyle, at address: CellAddress,
        patch: inout Patch
    ) throws {
        guard identifier != nil else { return }
        let part = regions.part(row: address.row, column: address.column, rowCount: rowCount)
        let roots = roots
        let oldText = NumbersStyles.TextFormat(original), newText = NumbersStyles.TextFormat(style)
        if oldText != newText, storage.type != NumbersCellStorage.CellType.richText {
            try restyle(&storage, field: NumbersStyles.Field.textStyle, partDefault: regions.text[part], patch: &patch) {
                root, character, paragraph in
                NumbersStyles.applyText(from: oldText, to: newText, root: roots.text(root), character: &character, paragraph: &paragraph)
            }
        }
        let oldCell = NumbersStyles.CellFormat(original), newCell = NumbersStyles.CellFormat(style)
        if oldCell != newCell {
            try restyle(&storage, field: NumbersStyles.Field.cellStyle, partDefault: regions.cell[part], patch: &patch) {
                root, properties, _ in
                NumbersStyles.applyCell(from: oldCell, to: newCell, root: roots.cell(root), properties: &properties)
            }
        }
    }

    /// Points a cell's style field at a variation of the style it has, made
    /// by `change` from that style's own properties: the text style's
    /// character and paragraph properties, or the cell style's.
    private mutating func restyle(
        _ storage: inout NumbersCellStorage, field: UInt32, partDefault: UInt64?, patch: inout Patch,
        change: (UInt64, inout ProtobufMessage, inout ProtobufMessage) -> Void
    ) throws {
        guard identifier != nil,
              let current = storage.key(of: field).flatMap({ references[UInt32(truncatingIfNeeded: $0)] }) ?? partDefault,
              let style = patch[current] else { throw NumbersEditPolicy.Violation.structure }
        let isText = field == NumbersStyles.Field.textStyle
        let base = style.message(NumbersStyles.Number.base)
        let isVariation = base?.bool(NumbersStyles.Number.isVariation) ?? false
        let root = isVariation ? base?.message(NumbersStyles.Number.parent)?.uint(1) ?? current : current
        guard let stylesheet = patch[root]?.message(NumbersStyles.Number.base)?.message(NumbersStyles.Number.stylesheet)?.uint(1)
                ?? base?.message(NumbersStyles.Number.stylesheet)?.uint(1) else { throw NumbersEditPolicy.Violation.structure }

        let first = isText ? NumbersStyles.Number.characterProperties : NumbersStyles.Number.cellProperties
        var properties = (isVariation ? style.message(first) : nil) ?? ProtobufMessage()
        var paragraph = (isVariation && isText ? style.message(NumbersStyles.Number.paragraphProperties) : nil) ?? ProtobufMessage()
        change(root, &properties, &paragraph)

        let made: UInt64
        if properties.fields.isEmpty && paragraph.fields.isEmpty {
            made = root
        } else {
            var groups = [(number: first, message: properties)]
            if isText { groups.append((NumbersStyles.Number.paragraphProperties, paragraph)) }
            made = try Self.variation(of: root, stylesheet: stylesheet, isText: isText, groups: groups, patch: &patch)
        }
        storage.setKey(made == partDefault ? nil : key(for: made, patch: &patch), of: field)
    }

    /// A variation of `root` setting these properties: one this save or
    /// Numbers already made, or a new one, added to the stylesheet.
    private static func variation(
        of root: UInt64, stylesheet: UInt64, isText: Bool, groups: [(number: Int, message: ProtobufMessage)],
        patch: inout Patch
    ) throws -> UInt64 {
        let type = isText ? NumbersStyles.ObjectType.paragraphStyle : NumbersStyles.ObjectType.cellStyle
        let signature = "\(type) \(root) " + groups.map { "\($0.number):\($0.message.encoded())" }.joined(separator: " ")
        if let made = patch.styleVariations[signature] { return made }
        guard var sheet = patch[stylesheet] else { throw NumbersEditPolicy.Violation.structure }

        var children = sheet.messages(5)
        let entry = children.firstIndex { $0.message(1)?.uint(1) == root }
        // Numbers' own, where it made one the same.
        for child in entry.map({ children[$0].messages(2).compactMap { $0.uint(1) } }) ?? [] {
            guard patch.archive[child]?.type == type, let style = patch[child],
                  style.message(NumbersStyles.Number.base)?.bool(NumbersStyles.Number.isVariation) ?? false,
                  groups.allSatisfy({ style.message($0.number)?.encoded() == $0.message.encoded() }) else { continue }
            patch.styleVariations[signature] = child
            return child
        }

        let message = NumbersStyles.variation(of: root, stylesheet: stylesheet, type: type, properties: groups)
        guard let made = patch.addObject(message, type: type, alongside: stylesheet) else {
            throw NumbersEditPolicy.Violation.structure
        }
        patch.addReference(from: made, to: root)
        var reference = ProtobufMessage()
        reference.set(1, uint: made)
        sheet.append(1, message: reference)
        if let entry {
            children[entry].append(2, message: reference)
        } else {
            var parent = ProtobufMessage()
            parent.set(1, uint: root)
            var newEntry = ProtobufMessage()
            newEntry.set(1, message: parent)
            newEntry.set(2, messages: [reference])
            children.append(newEntry)
        }
        sheet.set(5, messages: children)
        try patch.change(stylesheet, to: sheet)
        patch.addReference(from: stylesheet, to: made)
        patch.styleVariations[signature] = made
        return made
    }

    /// The key a style has in the table's list, added if it isn't there.
    private mutating func key(for style: UInt64, patch: inout Patch) -> UInt32 {
        let key: UInt32
        if let existing = keys[style] {
            key = existing
        } else {
            key = nextKey
            nextKey += 1
            keys[style] = key
            references[key] = style
            var reference = ProtobufMessage()
            reference.set(1, uint: style)
            var entry = ProtobufMessage()
            entry.set(1, uint: UInt64(key))
            entry.set(2, uint: 0)
            entry.set(4, message: reference)
            newEntries.append(entry)
            if let identifier { patch.addReference(from: identifier, to: style) }
        }
        added[key, default: 0] += 1
        return key
    }

    /// Writes the list back if any style gained a cell. As with strings,
    /// styles a change dropped are left counted.
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

/// A table's formulas, a `TST.TableDataList` cells refer to by key. Cells
/// whose formulas read the same — relative references and all, as when one
/// is filled down a column — share one.
private struct FormulaTable {
    private let identifier: UInt64?
    private var list: ProtobufMessage
    private var keys: [[UInt8]: UInt32] = [:]
    private var nextKey: UInt32
    private var added: [UInt32: UInt64] = [:]
    private var newEntries: [ProtobufMessage] = []

    init(reference: ProtobufMessage?, patch: Patch) {
        identifier = reference?.uint(1)
        list = identifier.flatMap { patch[$0] } ?? ProtobufMessage()
        var largest: UInt32 = 0
        for entry in list.messages(3) {
            guard let key = entry.uint(1).map(UInt32.init(truncatingIfNeeded:)) else { continue }
            largest = max(largest, key)
            if let nodes = entry.message(5)?.message(1)?.encoded(), keys[nodes] == nil { keys[nodes] = key }
        }
        nextKey = max(UInt32(truncatingIfNeeded: list.uint(2) ?? 1), largest + 1)
    }

    /// The key for a formula of these nodes, added if there isn't one yet.
    mutating func key(for nodes: [ProtobufMessage]) -> UInt32 {
        var array = ProtobufMessage()
        array.set(1, messages: nodes)
        let encoded = array.encoded()
        let key: UInt32
        if let existing = keys[encoded] {
            key = existing
        } else {
            key = nextKey
            nextKey += 1
            keys[encoded] = key
            var formula = ProtobufMessage()
            formula.set(1, message: array)
            var entry = ProtobufMessage()
            entry.set(1, uint: UInt64(key))
            entry.set(2, uint: 0)
            entry.set(5, message: formula)
            newEntries.append(entry)
        }
        added[key, default: 0] += 1
        return key
    }

    /// Writes the table back if any formula gained a cell. As with strings,
    /// formulas a change dropped are left counted.
    func save(into patch: inout Patch) throws {
        guard !added.isEmpty else { return }
        guard let identifier else { throw NumbersEditPolicy.Violation.formula }
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
