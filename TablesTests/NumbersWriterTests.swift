import Foundation
import Testing
@testable import Tables

@Suite("Numbers saving")
struct NumbersWriterTests {
    private func budget(_ rows: [[NumbersDocumentBuilder.Cell]] = [
        [.text("Item"), .text("Amount")],
        [.styledText("Rent", style: 77), .number(1_200, exponent: 0)],
        [.text("Total"), .formula(1_200)],
    ]) throws -> Data {
        var document = NumbersDocumentBuilder()
        document.addSheet("Budget", tables: [.init(name: "Table 1", rows: rows)])
        return try document.singleFile()
    }

    private func save(_ workbook: Workbook, _ source: NumbersSource) throws -> Data {
        try #require(NumbersWriter.fileWrapper(for: workbook, source: source, existing: nil).regularFileContents)
    }

    private func storage(at reference: String, in data: Data) throws -> NumbersCellStorage {
        let (_, source) = try NumbersReader.document(from: data)
        let table = try #require(source.tables.values.first)
        return try #require(table.storage[CellAddress(a1: reference)!].flatMap(NumbersCellStorage.init))
    }

    @Test("A document saved without changes is written back exactly as it was")
    func unchanged() throws {
        let original = try budget()
        let (workbook, source) = try NumbersReader.document(from: original)
        let saved = try save(workbook, source)
        #expect(try ZipArchive.orderedEntries(in: saved).map(\.data) == ZipArchive.orderedEntries(in: original).map(\.data))
    }

    @Test("Edited values read back, and archives the edit didn't touch stay byte for byte")
    func editedValues() throws {
        let original = try budget()
        var (workbook, source) = try NumbersReader.document(from: original)
        workbook.sheets[0].addColumns(1)
        workbook.sheets[0][CellAddress(a1: "B2")!] = Cell(value: .number(0.1))
        workbook.sheets[0][CellAddress(a1: "A1")!] = Cell(value: .text("Thing"))
        workbook.sheets[0][CellAddress(a1: "C2")!] = Cell(value: .boolean(true))
        let saved = try save(workbook, source)

        let sheet = try NumbersReader.workbook(from: saved).sheets[0]
        #expect(sheet[CellAddress(a1: "B2")!].value == .number(0.1))
        #expect(sheet[CellAddress(a1: "A1")!].value == .text("Thing"))
        #expect(sheet[CellAddress(a1: "C2")!].value == .boolean(true))
        #expect(sheet[CellAddress(a1: "A2")!].value == .text("Rent"))
        #expect(sheet[CellAddress(a1: "B3")!].value == .number(1_200))

        let before = Dictionary(try ZipArchive.orderedEntries(in: original), uniquingKeysWith: { $1 })
        let after = Dictionary(try ZipArchive.orderedEntries(in: saved), uniquingKeysWith: { $1 })
        #expect(after["Data/picture.png"] == before["Data/picture.png"])

        // Only the table, its tile, strings and row and column headers, the list of
        // stale formulas and the metadata change; every other object is
        // written back as it was read.
        let table = try #require(source.tables.values.first)
        let expected: Set<UInt64> = [table.modelIdentifier, NumbersDocumentBuilder.staleOwnerListIdentifier, 2]
        let oldArchive = IWAArchive(entries: before), newArchive = IWAArchive(entries: after)
        let changed = Set(oldArchive.objects.keys.filter {
            oldArchive[$0]?.message.encoded() != newArchive[$0]?.message.encoded()
        })
        #expect(changed.isSuperset(of: expected))
        #expect(changed.subtracting(expected).allSatisfy { [6002, 6005, 6006].contains(oldArchive[$0]?.type) })
        #expect(changed.count == expected.count + 4)
    }

    @Test("A changed cell keeps every field but its value")
    func keepsCellAttributes() throws {
        var (workbook, source) = try NumbersReader.document(from: budget())
        workbook.sheets[0][CellAddress(a1: "A2")!] = Cell(value: .number(42))
        let storage = try storage(at: "A2", in: save(workbook, source))
        #expect(storage.type == NumbersCellStorage.CellType.number)
        #expect(storage.field(0x20) == [77, 0, 0, 0], "the cell style it had")
        #expect(storage.field(NumbersCellStorage.Field.string) == nil)
    }

    @Test("Text already in the table reuses its key; new text gets one")
    func strings() throws {
        var (workbook, source) = try NumbersReader.document(from: budget())
        workbook.sheets[0].addColumns(1)
        workbook.sheets[0][CellAddress(a1: "C1")!] = Cell(value: .text("Item"))
        workbook.sheets[0][CellAddress(a1: "C2")!] = Cell(value: .text("Brand new"))
        let saved = try save(workbook, source)
        let reused = try storage(at: "C1", in: saved).field(NumbersCellStorage.Field.string)
        #expect(reused == [1, 0, 0, 0], "the key Item was first stored under")
        #expect(try NumbersReader.workbook(from: saved).sheets[0][CellAddress(a1: "C2")!].value == .text("Brand new"))
    }

    @Test("Dates, durations and cleared cells", arguments: [true, false])
    func datesAndClearing(asDuration: Bool) throws {
        var (workbook, source) = try NumbersReader.document(from: budget())
        var cell = Cell(value: .number(46_083.5))
        cell.style.numberFormat = asDuration ? NumbersCellStorage.durationFormat : NumberFormatPreset.dateTime.code
        workbook.sheets[0][CellAddress(a1: "B2")!] = cell
        workbook.sheets[0][CellAddress(a1: "A1")!] = Cell()
        workbook.sheets[0][CellAddress(a1: "A2")!] = Cell()
        let saved = try save(workbook, source)

        let sheet = try NumbersReader.workbook(from: saved).sheets[0]
        #expect(sheet[CellAddress(a1: "B2")!].value == .number(46_083.5))
        #expect(try storage(at: "B2", in: saved).type == (asDuration ? 7 : 5))
        #expect(sheet[CellAddress(a1: "A1")!].value == .empty)
        let (_, reread) = try NumbersReader.document(from: saved)
        let table = try #require(reread.tables.values.first)
        #expect(table.storage[CellAddress(a1: "A1")!] == nil, "a plain cell emptied is stored as nothing")
        let styled = try #require(table.storage[CellAddress(a1: "A2")!].flatMap(NumbersCellStorage.init))
        #expect(styled.type == NumbersCellStorage.CellType.empty, "a styled one keeps its style")
        #expect(styled.field(0x20) == [77, 0, 0, 0])
    }

    @Test("Rows added past the last tile get a tile of their own, registered with the package")
    func newTile() throws {
        let original = try budget()
        var (workbook, source) = try NumbersReader.document(from: original)
        workbook.sheets[0].addRows(300)
        workbook.sheets[0][CellAddress(row: 299, column: 1)] = Cell(value: .text("Far down"))
        let saved = try save(workbook, source)

        let sheet = try NumbersReader.workbook(from: saved).sheets[0]
        #expect(sheet.rowCount == 303)
        #expect(sheet[CellAddress(row: 299, column: 1)].value == .text("Far down"))
        #expect(sheet[CellAddress(a1: "A2")!].value == .text("Rent"))

        let entries = try ZipArchive.orderedEntries(in: saved)
        let tilePaths = entries.map(\.path).filter { $0.hasPrefix("Index/Tables/Tile-") }
        #expect(tilePaths.count == 1)
        let archive = IWAArchive(entries: Dictionary(entries, uniquingKeysWith: { $1 }))
        let metadata = try #require(archive[2]?.message)
        let tile = try #require(tilePaths.first.flatMap { UInt64($0.dropFirst("Index/Tables/Tile-".count).dropLast(4)) })
        #expect(metadata.messages(3).contains { $0.uint(1) == tile && $0.string(2) == "Tables/Tile" })
        let documentComponent = try #require(metadata.messages(3).first { $0.string(2) == "Document" })
        #expect(documentComponent.messages(6).contains { $0.uint(1) == tile }, "the table's component refers to it")
        #expect(metadata.uint(8) == NumbersDocumentBuilder.saveToken + 1)
        #expect((metadata.uint(1) ?? 0) >= tile)
    }

    @Test("Resized rows and columns")
    func sizes() throws {
        var (workbook, source) = try NumbersReader.document(from: budget())
        workbook.sheets[0].columnWidths[1] = 140
        workbook.sheets[0].rowHeights[2] = 44
        let sheet = try NumbersReader.workbook(from: save(workbook, source)).sheets[0]
        #expect(sheet.columnWidths[1] == 140)
        #expect(sheet.rowHeights[2] == 44)
        #expect(sheet.columnWidths[0] == NumbersDocumentBuilder.defaultColumnWidth)
    }

    @Test("A changed value asks Numbers to recalculate every table's formulas")
    func recalculation() throws {
        var (workbook, source) = try NumbersReader.document(from: budget())
        workbook.sheets[0][CellAddress(a1: "B2")!] = Cell(value: .number(900))
        let entries = try ZipArchive.orderedEntries(in: save(workbook, source))
        let archive = IWAArchive(entries: Dictionary(entries, uniquingKeysWith: { $1 }))
        let stale = try #require(archive[NumbersDocumentBuilder.staleOwnerListIdentifier]?.message)
        #expect(stale.message(1)?.messages(1).map { $0.uint(1) } == [100])
    }

    @Test("A package is written back as a package, its other files kept")
    func package() throws {
        let original = try budget()
        let package = FileWrapper(directoryWithFileWrappers: [
            "Index.zip": FileWrapper(regularFileWithContents: original),
            "preview.jpg": FileWrapper(regularFileWithContents: Data([0xFF, 0xD8])),
        ])
        var (workbook, source) = try NumbersReader.document(from: package)
        workbook.sheets[0][CellAddress(a1: "B2")!] = Cell(value: .number(7))
        let saved = try NumbersWriter.fileWrapper(for: workbook, source: source, existing: package)

        #expect(saved.isDirectory)
        #expect(saved.fileWrappers?["preview.jpg"]?.regularFileContents == Data([0xFF, 0xD8]))
        let index = try #require(saved.fileWrappers?["Index.zip"]?.regularFileContents)
        #expect(try NumbersReader.workbook(from: index).sheets[0][CellAddress(a1: "B2")!].value == .number(7))
    }

    @Test("Changes Numbers can't keep are refused rather than saved")
    func refusesUnsupportedChanges() throws {
        let (workbook, source) = try NumbersReader.document(from: budget())

        var formula = workbook
        formula.sheets[0][CellAddress(a1: "C1")!] = Cell(value: .number(2), formula: "1+1")
        #expect(throws: NumbersEditPolicy.Violation.formula) { try save(formula, source) }

        var overwritten = workbook
        overwritten.sheets[0][CellAddress(a1: "B3")!] = Cell(value: .number(5))
        #expect(throws: NumbersEditPolicy.Violation.protectedCell) { try save(overwritten, source) }

        var renamed = workbook
        renamed.sheets[0].name = "Other"
        #expect(throws: NumbersEditPolicy.Violation.structure) { try save(renamed, source) }
    }
}

@Suite("Numbers edit policy")
struct NumbersEditPolicyTests {
    private func document() throws -> (Workbook, NumbersSource) {
        var document = NumbersDocumentBuilder()
        document.addSheet("Budget", tables: [.init(name: "Table 1", rows: [
            [.text("Item"), .formula(3)],
        ])])
        return try NumbersReader.document(from: document.singleFile())
    }

    @Test("Values and growth at the end are kept")
    func allowed() throws {
        let (workbook, source) = try document()
        var edited = workbook
        edited.sheets[0][CellAddress(a1: "A1")!] = Cell(value: .text("Thing"))
        edited.sheets[0].addRows(5)
        edited.sheets[0].columnWidths[0] = 120
        let (result, violation) = NumbersEditPolicy.reconcile(edited, from: workbook, source: source)
        #expect(result == edited)
        #expect(violation == nil)
    }

    @Test("Formulas and changes to formula cells are taken back out")
    func formulas() throws {
        let (workbook, source) = try document()
        var edited = workbook
        edited.sheets[0][CellAddress(a1: "A1")!] = Cell(value: .text("Kept"))
        edited.sheets[0][CellAddress(a1: "A2")!] = Cell(value: .number(2), formula: "1+1")
        edited.sheets[0][CellAddress(a1: "B1")!] = Cell(value: .number(9))
        let (result, violation) = NumbersEditPolicy.reconcile(edited, from: workbook, source: source)
        #expect(result.sheets[0][CellAddress(a1: "A1")!].value == .text("Kept"))
        #expect(result.sheets[0][CellAddress(a1: "A2")!].isBlank)
        #expect(result.sheets[0][CellAddress(a1: "B1")!].value == .number(3))
        #expect(violation != nil)
    }

    @Test("Formatting is reset to the document's, keeping a number's format")
    func formatting() throws {
        let (workbook, source) = try document()
        var edited = workbook
        var cell = Cell(value: .number(46_083))
        cell.style.isBold = true
        cell.style.numberFormat = NumberFormatPreset.date.code
        edited.sheets[0][CellAddress(a1: "A1")!] = cell
        let (result, violation) = NumbersEditPolicy.reconcile(edited, from: workbook, source: source)
        let kept = result.sheets[0][CellAddress(a1: "A1")!]
        #expect(!kept.style.isBold)
        #expect(kept.style.numberFormat == NumberFormatPreset.date.code)
        #expect(violation == nil)
    }

    @Test("Structural changes are refused whole", arguments: [
        "rename", "shrink", "merge", "addSheet", "hideRow",
    ])
    func structure(_ change: String) throws {
        let (workbook, source) = try document()
        var edited = workbook
        switch change {
        case "rename": edited.sheets[0].name = "Other"
        case "shrink": edited.sheets[0].columnCount -= 1
        case "merge": edited.sheets[0].mergedRanges = [CellRange(start: CellAddress(row: 0, column: 0), end: CellAddress(row: 1, column: 0))]
        case "addSheet": _ = edited.addSheet()
        default: edited.sheets[0].hiddenRows = [0]
        }
        let (result, violation) = NumbersEditPolicy.reconcile(edited, from: workbook, source: source)
        #expect(result == workbook)
        #expect(violation == .structure)
    }
}

@Suite("Numbers cell storage")
struct NumbersCellStorageTests {
    @Test("Numbers are stored as the shortest decimal that reads back the same", arguments: [
        0.1, 123.45, -5, 1e20, 1.5e-7, 1_200, 0, 46_083.395833333336,
    ])
    func decimal(_ value: Double) {
        #expect(NumbersCellStorage.decimal128(NumbersCellStorage.decimal128(value)) == value)
    }

    @Test("A value's fields are replaced; the rest are written back in flag order")
    func replacing() throws {
        var bytes: [UInt8] = [5, 3, 0, 0, 0, 0, 0x80, 0, 0x28, 0x20, 0, 0]
        bytes += [9, 0, 0, 0] + [4, 0, 0, 0] + [6, 0, 0, 0]
        let storage = try #require(NumbersCellStorage(bytes[...]))
        #expect(storage.field(0x2000) == [6, 0, 0, 0])
        #expect(storage.encoded == bytes)

        let number = storage.replacingValue(with: Cell(value: .number(2))) { _ in 0 }
        #expect(number.type == NumbersCellStorage.CellType.number)
        #expect(number.field(NumbersCellStorage.Field.string) == nil)
        #expect(number.field(0x20) == [4, 0, 0, 0])
        #expect(number.field(0x2000) == [6, 0, 0, 0])
        #expect(number.encoded[6] & 0x80 == 0, "no longer marked as holding a string")
    }
}
