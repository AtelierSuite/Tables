import Foundation
import UIKit
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
        let original = try commented(budget())
        let (workbook, source) = try NumbersReader.document(from: original)
        #expect(try save(workbook, source) == original)

        let package = FileWrapper(directoryWithFileWrappers: ["Index.zip": FileWrapper(regularFileWithContents: original)])
        let (packaged, packageSource) = try NumbersReader.document(from: package)
        let saved = try NumbersWriter.fileWrapper(for: packaged, source: packageSource, existing: package)
        #expect(saved.fileWrappers?["Index.zip"]?.regularFileContents == original)
    }

    /// An archive that archiving its entries again wouldn't reproduce, as
    /// Numbers' own aren't: this one with a comment at its end.
    private func commented(_ archive: Data) -> Data {
        var data = archive
        let comment = Data("Numbers".utf8)
        data[data.count - 2] = UInt8(comment.count)
        data.append(comment)
        return data
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

    /// A blank JPEG of the given size, standing in for one Numbers drew.
    private func jpeg(width: Int, height: Int, color: UIColor = .white) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return try #require(image.jpegData(compressionQuality: 0.8))
    }

    private func pixelSize(_ data: Data?) -> CGSize? {
        (data.flatMap(UIImage.init(data:))?.cgImage).map { CGSize(width: $0.width, height: $0.height) }
    }

    @Test("Saving a change draws the previews again, each at its size, keeping any that can't be drawn")
    func previews() throws {
        var document = NumbersDocumentBuilder()
        var table = NumbersDocumentBuilder.Table(name: "Table 1", rows: [[.text("Item"), .text("Amount")], [.text("Rent")]])
        table.columnCount = 2
        table.headerRows = 1
        table.hasStyles = true
        document.addSheet("Budget", tables: [table])
        let originals = [
            "preview.jpg": try jpeg(width: 720, height: 552),
            "preview-web.jpg": try jpeg(width: 173, height: 225, color: .black),
            "preview-micro.jpg": Data([0xFF, 0xD8]),
        ]
        let original = try ZipArchive.archive(
            entries: ZipArchive.orderedEntries(in: document.singleFile()) + originals.sorted { $0.key < $1.key }.map { ($0.key, $0.value) },
            compressing: false
        )

        var (workbook, source) = try NumbersReader.document(from: original)
        workbook.sheets[0][CellAddress(a1: "B2")!] = Cell(value: .number(1_200))
        let entries = Dictionary(try ZipArchive.orderedEntries(in: save(workbook, source)), uniquingKeysWith: { $1 })

        for name in ["preview.jpg", "preview-web.jpg"] {
            #expect(entries[name] != originals[name], "\(name) is drawn again")
            #expect(entries[name]?.starts(with: [0xFF, 0xD8]) == true, "as a JPEG")
            #expect(pixelSize(entries[name]) == pixelSize(originals[name]))
        }
        #expect(entries["preview-micro.jpg"] == originals["preview-micro.jpg"], "one that can't be read is kept")

        // Drawn in the appearance the original was: a dark canvas stays dark.
        let web = try #require(entries["preview-web.jpg"].flatMap(UIImage.init(data:))?.cgImage?.cropping(to: CGRect(x: 0, y: 0, width: 1, height: 1)))
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.draw(web, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        #expect(pixel[0] < 40)
    }

    @Test("A document without previews is saved without any")
    func noPreviews() throws {
        var (workbook, source) = try NumbersReader.document(from: budget())
        workbook.sheets[0][CellAddress(a1: "B2")!] = Cell(value: .number(7))
        let paths = try ZipArchive.orderedEntries(in: save(workbook, source)).map(\.path)
        #expect(!paths.contains { $0.hasPrefix("preview") })
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

    @Test("A sheet with a table to itself can be renamed")
    func renamesSheet() throws {
        var (workbook, source) = try NumbersReader.document(from: budget())
        workbook.renameSheet(workbook.sheets[0].id, to: "Household")
        #expect(NumbersEditPolicy.violation(in: workbook, source: source) == nil)
        let reread = try NumbersReader.workbook(from: save(workbook, source))
        #expect(reread.sheets[0].name == "Household")
        #expect(reread.sheets[0][CellAddress(a1: "A2")!].value == .text("Rent"))
    }

    @Test("A table sharing its sheet with others can't be renamed, being named after both")
    func refusesRenamingSharedSheet() throws {
        var document = NumbersDocumentBuilder()
        document.addSheet("Budget", tables: [
            .init(name: "Income", rows: [[.number(1, exponent: 0)]]),
            .init(name: "Spending", rows: [[.number(2, exponent: 0)]]),
        ])
        let (workbook, source) = try NumbersReader.document(from: document.singleFile())
        var renamed = workbook
        renamed.renameSheet(renamed.sheets[0].id, to: "Earnings")
        #expect(NumbersEditPolicy.reconcile(renamed, from: workbook, source: source).violation == .structure)
    }

    @Test("Changes Numbers can't keep are refused rather than saved")
    func refusesUnsupportedChanges() throws {
        let (workbook, source) = try NumbersReader.document(from: budget())

        var formula = workbook
        formula.sheets[0][CellAddress(a1: "C1")!] = Cell(value: .number(2), formula: "LET(x,1,x)")
        #expect(throws: NumbersEditPolicy.Violation.formula) { try save(formula, source) }

        var overwritten = workbook
        overwritten.sheets[0][CellAddress(a1: "B3")!] = Cell(value: .number(5))
        #expect(throws: NumbersEditPolicy.Violation.protectedCell) { try save(overwritten, source) }

        var hidden = workbook
        hidden.sheets[0].isHidden = true
        #expect(throws: NumbersEditPolicy.Violation.structure) { try save(hidden, source) }
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
        edited.sheets[0][CellAddress(a1: "A1")!].value = .text("Thing")
        edited.sheets[0].addRows(5)
        edited.sheets[0].columnWidths[0] = 120
        let (result, violation) = NumbersEditPolicy.reconcile(edited, from: workbook, source: source)
        #expect(result == edited)
        #expect(violation == nil)
    }

    @Test("Formulas Numbers can't be given and changes to its own formula cells are taken back out")
    func formulas() throws {
        let (workbook, source) = try document()
        var edited = workbook
        edited.sheets[0][CellAddress(a1: "A1")!] = Cell(value: .text("Kept"))
        edited.sheets[0][CellAddress(a1: "A2")!] = Cell(value: .number(2), formula: "LET(x,1,x)")
        edited.sheets[0][CellAddress(a1: "B1")!] = Cell(value: .number(9))
        let (result, violation) = NumbersEditPolicy.reconcile(edited, from: workbook, source: source)
        #expect(result.sheets[0][CellAddress(a1: "A1")!].value == .text("Kept"))
        #expect(result.sheets[0][CellAddress(a1: "A2")!].isBlank)
        #expect(result.sheets[0][CellAddress(a1: "B1")!].value == .number(3))
        #expect(violation != nil)
    }

    @Test("In a table without a list of styles, formatting is reset to the document's, keeping a number's format")
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
        "hideSheet", "shrink", "merge", "addSheet", "hideRow",
    ])
    func structure(_ change: String) throws {
        let (workbook, source) = try document()
        var edited = workbook
        switch change {
        case "hideSheet": edited.sheets[0].isHidden = true
        case "shrink": edited.sheets[0].columnCount -= 1
        case "merge": edited.sheets[0].mergedRanges = [CellRange(start: CellAddress(row: 0, column: 0), end: CellAddress(row: 1, column: 0))]
        case "addSheet": _ = edited.addSheet()
        default: edited.sheets[0].hiddenRows = [0]
        }
        let (result, violation) = NumbersEditPolicy.reconcile(edited, from: workbook, source: source)
        #expect(result == workbook)
        #expect(violation == .structure)
    }

    @Test("Changes to a table collaboration left unmerged are refused as they're made, others kept and saved")
    func unmergedChanges() throws {
        var document = NumbersDocumentBuilder()
        var patched = NumbersDocumentBuilder.Table(name: "Table 1", rows: [[.text("Item"), .number(1, exponent: 0)]])
        patched.isPatched = true
        document.addSheet("Shared", tables: [patched])
        document.addSheet("Budget", tables: [.init(name: "Table 1", rows: [[.text("Item"), .number(2, exponent: 0)]])])
        let (workbook, source) = try NumbersReader.document(from: document.singleFile())
        let address = CellAddress(a1: "B1")!

        var shared = workbook
        shared.sheets[0][address] = Cell(value: .number(5))
        let (result, violation) = NumbersEditPolicy.reconcile(shared, from: workbook, source: source)
        #expect(result == workbook)
        #expect(violation == .unmergedChanges)
        var renamed = workbook
        renamed.sheets[0].name = "Mine"
        #expect(NumbersEditPolicy.reconcile(renamed, from: workbook, source: source).violation == .unmergedChanges)

        var budget = workbook
        budget.sheets[1][address] = Cell(value: .number(5))
        #expect(NumbersEditPolicy.reconcile(budget, from: workbook, source: source).violation == nil)
        let saved = try NumbersWriter.fileWrapper(for: budget, source: source, existing: nil)
        let reread = try NumbersReader.workbook(from: try #require(saved.regularFileContents))
        #expect(reread.sheets[1][address].value == .number(5))
    }

    @Test("Every change is refused while the calculation engine, which hears of each one, is unmerged")
    func unmergedEngine() throws {
        var document = NumbersDocumentBuilder()
        document.addSheet("Budget", tables: [.init(name: "Table 1", rows: [[.text("Item"), .formula(3)]])])
        document.patchedTypes = [4000]
        let (workbook, source) = try NumbersReader.document(from: document.singleFile())
        var edited = workbook
        edited.sheets[0][CellAddress(a1: "A1")!] = Cell(value: .text("Thing"))
        #expect(NumbersEditPolicy.reconcile(edited, from: workbook, source: source).violation == .unmergedChanges)
        #expect(throws: NumbersEditPolicy.Violation.unmergedChanges) {
            try NumbersWriter.fileWrapper(for: edited, source: source, existing: nil)
        }
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

@Suite("Numbers rows and columns")
struct NumbersMovingTests {
    /// Item and Amount under a header row, totalled by Numbers' own
    /// `SUM(B2:B3)`, with borders and an identifier for every row and column.
    private func document(protected: Bool = false) throws -> Data {
        let sum = [
            NumbersNodes.relativeRange(columns: 0...0, rows: -2 ... -1),
            NumbersNodes.function("SUM", arguments: 1),
        ]
        var table = NumbersDocumentBuilder.Table(name: "Table 1", rows: [
            [.text("Item"), .text("Amount")],
            [.styledText("Rent", style: 77), .number(1_200, exponent: 0)],
            [.text("Food"), .number(300, exponent: 0)],
            [.text("Total"), .formulaNodes(1_500, sum), protected ? .formula(1) : .empty],
        ])
        table.headerRows = 1
        table.hasIdentifiers = true
        table.leftBorders = [1: 1..<3]
        table.topBorders = [3: 0..<2]
        var document = NumbersDocumentBuilder()
        document.addSheet("Budget", tables: [table])
        return try document.singleFile()
    }

    private func save(_ workbook: Workbook, _ source: NumbersSource) throws -> Data {
        try #require(NumbersWriter.fileWrapper(for: workbook, source: source, existing: nil).regularFileContents)
    }

    private func model(in source: NumbersSource) throws -> ProtobufMessage {
        let table = try #require(source.tables.values.first)
        return try #require(source.archive[table.modelIdentifier]?.message)
    }

    @Test("A row inserted in the middle moves the cells below with everything Numbers stored for them")
    func insertRow() throws {
        var (workbook, source) = try NumbersReader.document(from: document())
        workbook.sheets[0].insertRows(1, at: 2)
        workbook.recalculate()
        #expect(NumbersEditPolicy.violation(in: workbook, source: source) == nil)
        let (reread, saved) = try NumbersReader.document(from: save(workbook, source))

        let sheet = reread.sheets[0]
        #expect(sheet.rowCount == 5)
        #expect(sheet[CellAddress(a1: "A2")!].value == .text("Rent"))
        #expect(sheet[CellAddress(a1: "A3")!].isBlank)
        #expect(sheet[CellAddress(a1: "A4")!].value == .text("Food"))
        #expect(sheet[CellAddress(a1: "B5")!].formula == "SUM(B2:B4)")
        #expect(sheet[CellAddress(a1: "B5")!].value == .number(1_500))
        let table = try #require(saved.tables.values.first)
        let rent = try #require(table.storage[CellAddress(a1: "A2")!].flatMap(NumbersCellStorage.init))
        #expect(rent.field(0x20) == [77, 0, 0, 0], "Rent's cell style stays with it")

        // Rows keep their identifiers; the new one gets its own.
        let model = try model(in: saved)
        let map = try #require(saved.archive[model.message(46)]?.message)
        let uids: [(upper: UInt64, lower: UInt64)] = map.messages(4).map { ($0.uint(2) ?? 0, $0.uint(1) ?? 0) }
        #expect(uids.count == 5)
        let isSorted = zip(uids, uids.dropFirst()).allSatisfy { $0.upper < $1.upper || ($0.upper == $1.upper && $0.lower < $1.lower) }
        #expect(isSorted)
        let forIndex = map.uints(6).map(Int.init), indexFor = map.uints(5).map(Int.init)
        #expect(forIndex.indices.allSatisfy { indexFor[forIndex[$0]] == $0 })
        let food = NumbersDocumentBuilder.identifierUUID(2, row: true)
        #expect(uids[forIndex[3]].lower == food.lower && uids[forIndex[3]].upper == food.upper)

        // Borders: the one down column B splits around the new row, and the
        // one over Total moves down with it.
        let sidecar = try #require(saved.archive[model.message(49)]?.message)
        #expect(sidecar.uint(3) == 5)
        let left = try #require(saved.archive[sidecar.messages(4).first]?.message)
        #expect(left.messages(2).map { [$0.int(1) ?? -1, $0.int(2) ?? -1] } == [[1, 1], [3, 1]])
        let top = try #require(saved.archive[sidecar.messages(6).first]?.message)
        #expect(top.int(1) == 4)
    }

    @Test("A deleted column takes its cells, borders and identifier with it")
    func deleteColumn() throws {
        var (workbook, source) = try NumbersReader.document(from: document())
        workbook.sheets[0].removeColumns(0...0)
        workbook.recalculate()
        let (reread, saved) = try NumbersReader.document(from: save(workbook, source))
        let sheet = reread.sheets[0]
        #expect(sheet.columnCount == 2)
        #expect(sheet[CellAddress(a1: "A2")!].value == .number(1_200))
        #expect(sheet[CellAddress(a1: "A4")!].formula == "SUM(A2:A3)")
        let model = try model(in: saved)
        let sidecar = try #require(saved.archive[model.message(49)]?.message)
        let left = try #require(saved.archive[sidecar.messages(4).first]?.message)
        #expect(left.int(1) == 0)
        let map = try #require(saved.archive[model.message(46)]?.message)
        #expect(map.messages(1).count == 2)
    }

    @Test("Deleting rows drops their cells and counts the formulas gone")
    func deleteRows() throws {
        var (workbook, source) = try NumbersReader.document(from: document())
        workbook.sheets[0].removeRows(2...3)
        let (reread, saved) = try NumbersReader.document(from: save(workbook, source))
        #expect(reread.sheets[0].rowCount == 2)
        #expect(reread.sheets[0][CellAddress(a1: "A2")!].value == .text("Rent"))
        let engine = try #require(saved.archive[3]?.message)
        #expect(engine.message(2)?.uint(5) == 0)
    }

    @Test("Moving cells is refused where something Tables can't move depends on them")
    func refused() throws {
        let (protectedWorkbook, protectedSource) = try NumbersReader.document(from: document(protected: true))
        var edited = protectedWorkbook
        edited.sheets[0].insertRows(1, at: 2)
        #expect(NumbersEditPolicy.reconcile(edited, from: protectedWorkbook, source: protectedSource).violation == .movingCells)

        let (workbook, source) = try NumbersReader.document(from: document())
        var header = workbook
        header.sheets[0].insertRows(1, at: 0)
        #expect(NumbersEditPolicy.reconcile(header, from: workbook, source: source).violation == .movingCells)
        var appended = workbook
        appended.sheets[0].insertRows(1, at: 2)
        appended.sheets[0].insertColumns(1, at: 1)
        #expect(NumbersEditPolicy.reconcile(appended, from: workbook, source: source).violation == nil)
    }

    @Test("A formula Tables can't read keeps cells from moving only in its own table and those it refers to")
    func unreadFormulasHoldTheirTables() throws {
        let rates = MergeOwners.UUID(lower: 0x51, upper: 0x52)
        let budget = MergeOwners.UUID(lower: 0x61, upper: 0x62)
        let other = MergeOwners.UUID(lower: 0x71, upper: 0x72)
        func movable(_ nodes: [ProtobufMessage]?) throws -> [String: Bool] {
            func table(_ uuid: MergeOwners.UUID, _ cell: NumbersDocumentBuilder.Cell = .empty) -> NumbersDocumentBuilder.Table {
                var table = NumbersDocumentBuilder.Table(name: "Table 1", rows: [[.number(1, exponent: 0), cell]])
                table.uuid = uuid
                return table
            }
            var document = NumbersDocumentBuilder()
            document.addSheet("Rates", tables: [table(rates)])
            document.addSheet("Budget", tables: [table(budget, nodes.map { .formulaNodes(2, $0) } ?? .formula(2))])
            document.addSheet("Other", tables: [table(other)])
            let (workbook, source) = try NumbersReader.document(from: document.singleFile())
            #expect(source.tables.values.contains { !$0.protectedCells.isEmpty })
            return Dictionary(uniqueKeysWithValues: try workbook.sheets.map { sheet in
                let table = try #require(source.tables[sheet.id]), imported = try #require(source.imported[sheet.id])
                return (sheet.name, NumbersEditPolicy.canMoveCells(in: table, imported: imported, source: source))
            })
        }
        // Tables has no `DUR2DAYS`, so can't read it.
        let unread = NumbersNodes.function("DUR2DAYS", arguments: 1)
        let rateCell = NumbersNodes.cell(column: 0, row: 0, columnAbsolute: true, rowAbsolute: true, table: rates)
        #expect(try movable([rateCell, unread]) == ["Rates": false, "Budget": false, "Other": true])
        #expect(try movable([NumbersNodes.cell(column: -1, row: 0), unread]) == ["Rates": true, "Budget": false, "Other": true])

        // Text naming cells, or a formula with nothing to go on, could refer
        // to any table.
        let text = NumbersNodes.node(NumbersFormula.NodeType.string) { $0.set(6, bytes: Array("A1".utf8)) }
        let indirect = [text, NumbersNodes.function("INDIRECT", arguments: 1), unread]
        #expect(try movable(indirect) == ["Rates": false, "Budget": false, "Other": false])
        #expect(try movable(nil) == ["Rates": false, "Budget": false, "Other": false])
    }
}

@Suite("Numbers hidden rows and columns")
struct NumbersHidingTests {
    private func document() throws -> (Workbook, NumbersSource) {
        var document = NumbersDocumentBuilder()
        var table = NumbersDocumentBuilder.Table(name: "Table 1", rows: [
            [.text("Item")], [.text("Rent")], [.text("Food")], [.text("Fuel")], [.text("Gas")],
        ])
        table.columnCount = 3
        table.hasIdentifiers = true
        table.hasHiddenStates = true
        table.userHiddenRows = [1]
        table.filteredRows = [3]
        document.addSheet("Budget", tables: [table])
        return try NumbersReader.document(from: document.singleFile())
    }

    private func save(_ workbook: Workbook, _ source: NumbersSource) throws -> Data {
        try #require(NumbersWriter.fileWrapper(for: workbook, source: source, existing: nil).regularFileContents)
    }

    @Test("Rows and columns are hidden and shown by their UUIDs, leaving filtered ones be")
    func hidesAndShows() throws {
        let (workbook, source) = try document()
        var edited = workbook
        edited.sheets[0].setRows(1...1, hidden: false)
        edited.sheets[0].setRows(2...2, hidden: true)
        edited.sheets[0].setColumns(0...0, hidden: true)
        #expect(NumbersEditPolicy.violation(in: edited, source: source) == nil)

        let (reread, rereadSource) = try NumbersReader.document(from: save(edited, source))
        let sheet = reread.sheets[0]
        #expect(sheet.hiddenRows == [2, 3])
        #expect(sheet.hiddenColumns == [0])
        #expect(rereadSource.tables[sheet.id]?.hidden.lockedRows == [3])
        #expect(sheet[CellAddress(a1: "A3")!].value == .text("Food"))
    }

    @Test("Hidden rows are listed in UUID order with nothing left for those shown again")
    func listsStatesInOrder() throws {
        let (workbook, source) = try document()
        var edited = workbook
        edited.sheets[0].hiddenRows = [0, 2, 3, 4]
        let (_, rereadSource) = try NumbersReader.document(from: save(edited, source))
        let table = try #require(rereadSource.tables.values.first)
        let model = try #require(rereadSource.archive[table.modelIdentifier]?.message)
        let states = try #require(model.message(70)?.messages(2).first?.message(3)?.messages(2))
        let uids = states.compactMap { MergeOwners.UUID($0.message(1)) }
        #expect(uids.count == 4)
        #expect(uids == uids.sorted { ($0.upper, $0.lower) < ($1.upper, $1.lower) })
        #expect(!uids.contains(table.rowIdentifiers[1]))
    }

    @Test("Rows hidden by a filter, new rows, and tables without hidden states can't be changed", arguments: [
        "showFiltered", "hideNew", "noStates",
    ])
    func refuses(_ change: String) throws {
        var (workbook, source) = try document()
        if change == "noStates" {
            var document = NumbersDocumentBuilder()
            var table = NumbersDocumentBuilder.Table(name: "Table 1", rows: [[.text("Item")], [.text("Rent")]])
            table.hasIdentifiers = true
            document.addSheet("Budget", tables: [table])
            (workbook, source) = try NumbersReader.document(from: document.singleFile())
        }
        var edited = workbook
        switch change {
        case "showFiltered": edited.sheets[0].setRows(3...3, hidden: false)
        case "hideNew":
            edited.sheets[0].addRows(1)
            edited.sheets[0].setRows(5...5, hidden: true)
        default: edited.sheets[0].setRows(0...0, hidden: true)
        }
        #expect(NumbersEditPolicy.reconcile(edited, from: workbook, source: source).violation == .structure)
    }
}

@Suite("Numbers formatting")
struct NumbersFormattingTests {
    private func document() throws -> (Workbook, NumbersSource) {
        var document = NumbersDocumentBuilder()
        var table = NumbersDocumentBuilder.Table(name: "Table 1", rows: [
            [.text("Item"), .text("Amount")], [.boldText("Rent"), .text("Food")], [.text("Fuel"), .text("Gas")],
        ])
        table.headerRows = 1
        table.hasStyles = true
        document.addSheet("Budget", tables: [table])
        return try NumbersReader.document(from: document.singleFile())
    }

    private func save(_ workbook: Workbook, _ source: NumbersSource) throws -> Data {
        try #require(NumbersWriter.fileWrapper(for: workbook, source: source, existing: nil).regularFileContents)
    }

    private func edit(_ workbook: Workbook, _ reference: String, _ change: (inout CellStyle) -> Void) -> Workbook {
        var workbook = workbook
        let address = CellAddress(a1: reference)!
        var cell = workbook.sheets[0][address]
        change(&cell.style)
        workbook.sheets[0][address] = cell
        return workbook
    }

    /// The style a cell's storage field refers to, through the table's list.
    private func style(_ field: UInt32, at reference: String, in source: NumbersSource) throws -> ProtobufMessage? {
        let table = try #require(source.tables.values.first)
        let storage = try #require(table.storage[CellAddress(a1: reference)!].flatMap(NumbersCellStorage.init))
        guard let key = storage.key(of: field) else { return nil }
        let model = try #require(source.archive[table.modelIdentifier]?.message)
        let list = try #require(source.archive[model.message(4)?.message(5)]?.message)
        let entry = try #require(list.messages(3).first { $0.uint(1) == key })
        return source.archive[entry.message(4)]?.message
    }

    @Test("Bold, italic, colours, size and alignment are saved as variations of the cell's styles")
    func formats() throws {
        let (workbook, source) = try document()
        var edited = edit(workbook, "B2") {
            $0.isBold = true
            $0.isItalic = true
            $0.isUnderlined = true
            $0.isStruckThrough = true
            $0.fontSize = 14
            $0.textColorHex = "FF0000FF"
            $0.horizontalAlignment = .center
            $0.fillColorHex = "FFFF0000"
            $0.verticalAlignment = .bottom
            $0.wrapsText = false
        }
        edited = NumbersEditPolicy.reconcile(edited, from: workbook, source: source).workbook
        #expect(NumbersEditPolicy.violation(in: edited, source: source) == nil)

        let (reread, rereadSource) = try NumbersReader.document(from: save(edited, source))
        let style = reread.sheets[0][CellAddress(a1: "B2")!].style
        #expect(style.isBold && style.isItalic && style.isUnderlined && style.isStruckThrough)
        #expect(style.fontSize == 14)
        #expect(style.textColorHex == "FF0000FF")
        #expect(style.horizontalAlignment == .center)
        #expect(style.fillColorHex == "FFFF0000")
        #expect(style.verticalAlignment == .bottom)
        #expect(!style.wrapsText)
        #expect(reread.sheets[0][CellAddress(a1: "B2")!].value == .text("Food"))
        #expect(reread.sheets[0][CellAddress(a1: "A2")!].style.isBold, "others keep theirs")

        let text = try #require(try self.style(NumbersStyles.Field.textStyle, at: "B2", in: rereadSource))
        let base = try #require(text.message(1))
        #expect(base.bool(4), "a variation")
        let root = try #require(base.message(3)?.uint(1))
        #expect(rereadSource.archive[root]?.message.message(1)?.string(1) == "Body", "of the body's text style")
        let sheet = try #require(rereadSource.archive[base.message(5)]?.message)
        let made = try #require(rereadSource.archive.identifiers(ofType: NumbersStyles.ObjectType.paragraphStyle).max())
        #expect(sheet.messages(1).contains { $0.uint(1) == made }, "listed in the stylesheet")
        #expect(sheet.messages(5).contains { $0.message(1)?.uint(1) == root && $0.messages(2).contains { $0.uint(1) == made } })
        let cell = try #require(try self.style(NumbersStyles.Field.cellStyle, at: "B2", in: rereadSource))
        #expect(cell.message(1)?.bool(4) == true)
    }

    @Test("Cells formatted alike share a variation, Numbers' own where it has one")
    func sharesVariations() throws {
        let (workbook, source) = try document()
        var edited = edit(workbook, "B2") { $0.isItalic = true }
        edited = edit(edited, "B3") { $0.isItalic = true }
        edited = edit(edited, "A3") { $0.isBold = true }
        let (_, rereadSource) = try NumbersReader.document(from: save(edited, source))
        let paragraphStyles = rereadSource.archive.identifiers(ofType: NumbersStyles.ObjectType.paragraphStyle)
        #expect(paragraphStyles.count == source.archive.identifiers(ofType: NumbersStyles.ObjectType.paragraphStyle).count + 1)

        let table = try #require(rereadSource.tables.values.first)
        func key(_ reference: String) -> UInt64? {
            table.storage[CellAddress(a1: reference)!].flatMap(NumbersCellStorage.init)?.key(of: NumbersStyles.Field.textStyle)
        }
        #expect(key("B2") != nil && key("B2") == key("B3"))
        #expect(key("A3") == key("A2"), "the bold Numbers made")
    }

    @Test("Formatting put back to its part's default leaves the cell to it")
    func clears() throws {
        let (workbook, source) = try document()
        var edited = edit(workbook, "A2") { $0.isBold = false }
        edited = edit(edited, "A1") { $0.fillColorHex = nil }
        let (reread, rereadSource) = try NumbersReader.document(from: save(edited, source))
        #expect(!reread.sheets[0][CellAddress(a1: "A2")!].style.isBold)
        #expect(try style(NumbersStyles.Field.textStyle, at: "A2", in: rereadSource) == nil)
        #expect(reread.sheets[0][CellAddress(a1: "A1")!].style.fillColorHex == nil)
        #expect(reread.sheets[0][CellAddress(a1: "B1")!].style.fillColorHex == NumbersDocumentBuilder.headerFill)
    }

    @Test("New styles in the stylesheet are listed as references of the table's list of styles")
    func listsReferences() throws {
        let (workbook, source) = try document()
        let data = try save(edit(workbook, "B2") { $0.isItalic = true }, source)
        let (_, rereadSource) = try NumbersReader.document(from: data)
        let made = try #require(rereadSource.archive.identifiers(ofType: NumbersStyles.ObjectType.paragraphStyle).max())
        let metadataIdentifier = try #require(rereadSource.archive.identifiers(ofType: NumbersReader.ObjectType.packageMetadata).first)
        let metadata = try #require(rereadSource.archive[metadataIdentifier]?.message)
        let dataLists = try #require(metadata.messages(3).first { $0.string(2) == "Tables/DataList" })
        #expect(dataLists.messages(6).contains { $0.uint(1) == 1 && $0.uint(2) == made })
    }

    @Test("Formatting Numbers can't be given is put back, keeping what it can")
    func keepsWhatCanBeSaved() throws {
        let (workbook, source) = try document()
        let edited = edit(workbook, "B2") {
            $0.isBold = true
            $0.fontName = "Courier"
            $0.borders = .all
        }
        let result = NumbersEditPolicy.reconcile(edited, from: workbook, source: source).workbook
        let style = result.sheets[0][CellAddress(a1: "B2")!].style
        #expect(style.isBold)
        #expect(style.fontName == workbook.sheets[0][CellAddress(a1: "B2")!].style.fontName)
        #expect(style.borders.isEmpty)
    }
}
