import AppIntents
import Foundation
import TablesEngine
import UniformTypeIdentifiers

// MARK: - The workbook passed between actions

/// A workbook as it travels through a shortcut. Each action takes one and,
/// if it changes it, hands on the changed copy, so actions chain:
/// Get Workbook → Set Cell → Append Row → Export Workbook.
struct WorkbookEntity: TransientAppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Intent.Workbook.Type")

    @Property(title: "Intent.Workbook.Name")
    var name: String

    @Property(title: "Intent.Workbook.Sheets")
    var sheetNames: [String]

    /// The workbook itself, as an Excel file.
    @Property(title: "Intent.Workbook.File")
    var file: IntentFile

    /// A bookmark to the file the workbook was read from, so Save Workbook
    /// can write the changes back to it.
    @Property(title: "Intent.Workbook.Source")
    var source: String?

    init() {
        name = ""
        sheetNames = []
        file = IntentFile(data: Data(), filename: "Workbook.xlsx", type: .openXMLWorkbook)
        source = nil
    }

    init(_ workbook: Workbook, name: String) throws {
        self.init()
        self.name = name
        sheetNames = workbook.sheets.map(\.name)
        // A workbook with macros travels between actions as an .xlsm, so
        // they are still there when it is saved.
        let format: WorkbookAutomation.Format = workbook.hasMacros ? .xlsm : .xlsx
        file = IntentFile(data: try WorkbookAutomation.write(workbook, as: format),
                          filename: name + "." + format.fileExtension, type: format.type)
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: LocalizedStringResource("Intent.Workbook.SheetCount \(sheetNames.count)")
        )
    }

    func load() throws -> Workbook {
        try WorkbookAutomation.read(file.data, filename: file.filename)
    }

    /// The same workbook after a change, still tied to its original file.
    func replacing(with workbook: Workbook) throws -> WorkbookEntity {
        var changed = try WorkbookEntity(workbook, name: name)
        changed.source = source
        return changed
    }

    /// The file the workbook was read from, when it can still be reached.
    var sourceURL: URL? {
        guard let source, let data = Data(base64Encoded: source) else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: data, options: WorkbookFiles.bookmarkResolution,
                        relativeTo: nil, bookmarkDataIsStale: &stale)
    }
}

/// Reading and writing the files actions point at.
enum WorkbookFiles {
    #if os(macOS)
    static let bookmarkCreation: URL.BookmarkCreationOptions = [.withSecurityScope]
    static let bookmarkResolution: URL.BookmarkResolutionOptions = [.withSecurityScope]
    #else
    static let bookmarkCreation: URL.BookmarkCreationOptions = []
    static let bookmarkResolution: URL.BookmarkResolutionOptions = []
    #endif

    static func bookmark(for url: URL) -> String? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return (try? url.bookmarkData(options: bookmarkCreation, includingResourceValuesForKeys: nil,
                                      relativeTo: nil))?.base64EncodedString()
    }

    /// Writes data over a file through file coordination, so a copy open in
    /// the editor sees the change rather than overwriting it later.
    static func write(_ data: Data, to url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            do { try data.write(to: target, options: .atomic) } catch { writeError = error }
        }
        if let error = coordinationError ?? writeError { throw error }
    }

    /// The format a file's name asks for.
    static func format(for url: URL) -> WorkbookAutomation.Format {
        WorkbookAutomation.Format(rawValue: url.pathExtension.lowercased()) ?? .xlsx
    }

    /// A new file in the app's own documents folder, named after the workbook.
    static func newDocumentURL(named name: String) -> URL {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let stem = name.isEmpty ? "Workbook" : name
        var candidate = folder.appendingPathComponent(stem).appendingPathExtension("xlsx")
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(stem) \(number)").appendingPathExtension("xlsx")
            number += 1
        }
        return candidate
    }
}

enum WorkbookFileFormat: String, AppEnum {
    case xlsx, csv, tsv

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Intent.Format.Type")
    static let caseDisplayRepresentations: [WorkbookFileFormat: DisplayRepresentation] = [
        .xlsx: DisplayRepresentation(title: "Intent.Format.XLSX"),
        .csv: DisplayRepresentation(title: "Intent.Format.CSV"),
        .tsv: DisplayRepresentation(title: "Intent.Format.TSV"),
    ]

    var format: WorkbookAutomation.Format {
        switch self {
        case .xlsx: return .xlsx
        case .csv: return .csv
        case .tsv: return .tsv
        }
    }
}

enum CellContentPart: String, AppEnum {
    case value, formula

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Intent.CellPart.Type")
    static let caseDisplayRepresentations: [CellContentPart: DisplayRepresentation] = [
        .value: DisplayRepresentation(title: "Intent.CellPart.Value"),
        .formula: DisplayRepresentation(title: "Intent.CellPart.Formula"),
    ]
}

enum RangeLayout: String, AppEnum {
    case cells, rows, csv

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Intent.Layout.Type")
    static let caseDisplayRepresentations: [RangeLayout: DisplayRepresentation] = [
        .cells: DisplayRepresentation(title: "Intent.Layout.Cells"),
        .rows: DisplayRepresentation(title: "Intent.Layout.Rows"),
        .csv: DisplayRepresentation(title: "Intent.Layout.CSV"),
    ]
}

// MARK: - Files

struct GetWorkbookIntent: AppIntent {
    static let title: LocalizedStringResource = "Intent.Open.Title"
    static let description = IntentDescription("Intent.Open.Description")

    @Parameter(title: "Intent.Parameter.File",
               supportedContentTypes: [.spreadsheet, .commaSeparatedText, .tabSeparatedText])
    var file: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("Intent.Open.Summary \(\.$file)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<WorkbookEntity> {
        let workbook = try WorkbookAutomation.read(file.data, filename: file.filename)
        let name = (file.filename as NSString).deletingPathExtension
        var entity = try WorkbookEntity(workbook, name: name.isEmpty ? "Workbook" : name)
        entity.source = file.fileURL.flatMap(WorkbookFiles.bookmark)
        return .result(value: entity)
    }
}

struct CreateWorkbookIntent: AppIntent {
    static let title: LocalizedStringResource = "Intent.Create.Title"
    static let description = IntentDescription("Intent.Create.Description")

    @Parameter(title: "Intent.Parameter.Name", default: "Workbook")
    var name: String

    static var parameterSummary: some ParameterSummary {
        Summary("Intent.Create.Summary \(\.$name)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<WorkbookEntity> {
        .result(value: try WorkbookEntity(Workbook(), name: name))
    }
}

struct ExportWorkbookIntent: AppIntent {
    static let title: LocalizedStringResource = "Intent.Export.Title"
    static let description = IntentDescription("Intent.Export.Description")

    @Parameter(title: "Intent.Parameter.Workbook")
    var workbook: WorkbookEntity

    @Parameter(title: "Intent.Parameter.Format", default: .xlsx)
    var format: WorkbookFileFormat

    @Parameter(title: "Intent.Parameter.Sheet")
    var sheet: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Intent.Export.Summary \(\.$workbook) \(\.$format)") {
            \.$sheet
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let book = try workbook.load()
        let data = try WorkbookAutomation.write(book, as: format.format, sheet: sheet)
        let file = IntentFile(data: data, filename: workbook.name + "." + format.format.fileExtension,
                              type: format.format.type)
        return .result(value: file)
    }
}

// MARK: - Reading

struct ListSheetsIntent: AppIntent {
    static let title: LocalizedStringResource = "Intent.ListSheets.Title"
    static let description = IntentDescription("Intent.ListSheets.Description")

    @Parameter(title: "Intent.Parameter.Workbook")
    var workbook: WorkbookEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Intent.ListSheets.Summary \(\.$workbook)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
        .result(value: try workbook.load().sheets.map(\.name))
    }
}

struct GetCellIntent: AppIntent {
    static let title: LocalizedStringResource = "Intent.GetCell.Title"
    static let description = IntentDescription("Intent.GetCell.Description")

    @Parameter(title: "Intent.Parameter.Workbook")
    var workbook: WorkbookEntity

    @Parameter(title: "Intent.Parameter.Cell", default: "A1")
    var cell: String

    @Parameter(title: "Intent.Parameter.Part", default: .value)
    var part: CellContentPart

    @Parameter(title: "Intent.Parameter.Sheet")
    var sheet: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Intent.GetCell.Summary \(\.$part) \(\.$cell) \(\.$workbook)") {
            \.$sheet
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let book = try workbook.load()
        let index = try WorkbookAutomation.sheetIndex(sheet, in: book)
        let stored = WorkbookAutomation.cell(at: try WorkbookAutomation.address(cell), sheet: index, in: book)
        switch part {
        case .value: return .result(value: WorkbookAutomation.displayText(of: stored))
        case .formula: return .result(value: stored.formula.map { "=" + $0 } ?? stored.editableText)
        }
    }
}

struct GetRangeIntent: AppIntent {
    static let title: LocalizedStringResource = "Intent.GetRange.Title"
    static let description = IntentDescription("Intent.GetRange.Description")

    @Parameter(title: "Intent.Parameter.Workbook")
    var workbook: WorkbookEntity

    @Parameter(title: "Intent.Parameter.Range", default: "A1:B10")
    var range: String

    @Parameter(title: "Intent.Parameter.Layout", default: .rows)
    var layout: RangeLayout

    @Parameter(title: "Intent.Parameter.Sheet")
    var sheet: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Intent.GetRange.Summary \(\.$range) \(\.$workbook) \(\.$layout)") {
            \.$sheet
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
        let book = try workbook.load()
        let index = try WorkbookAutomation.sheetIndex(sheet, in: book)
        let rows = WorkbookAutomation.rows(try WorkbookAutomation.range(range, in: book.sheets[index]),
                                           sheet: index, in: book)
        switch layout {
        case .cells: return .result(value: rows.flatMap { $0 })
        case .rows: return .result(value: rows.map { $0.joined(separator: "\t") })
        case .csv:
            var sheet = Worksheet(name: "Range")
            for (row, line) in rows.enumerated() {
                for (column, text) in line.enumerated() where !text.isEmpty {
                    sheet[CellAddress(row: row, column: column)] = Cell(value: .text(text))
                }
            }
            sheet.rowCount = max(1, rows.count)
            sheet.columnCount = max(1, rows.first?.count ?? 1)
            return .result(value: [String(decoding: CSVCodec.data(from: sheet), as: UTF8.self)])
        }
    }
}

struct FindRowsIntent: AppIntent {
    static let title: LocalizedStringResource = "Intent.FindRows.Title"
    static let description = IntentDescription("Intent.FindRows.Description")

    @Parameter(title: "Intent.Parameter.Workbook")
    var workbook: WorkbookEntity

    @Parameter(title: "Intent.Parameter.Column", default: "A")
    var column: String

    @Parameter(title: "Intent.Parameter.Condition")
    var condition: String

    @Parameter(title: "Intent.Parameter.Sheet")
    var sheet: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Intent.FindRows.Summary \(\.$column) \(\.$condition) \(\.$workbook)") {
            \.$sheet
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
        let book = try workbook.load()
        let index = try WorkbookAutomation.sheetIndex(sheet, in: book)
        let rows = WorkbookAutomation.findRows(
            where: try WorkbookAutomation.column(column), matches: condition, sheet: index, in: book)
        return .result(value: rows.map { $0.joined(separator: "\t") })
    }
}

struct EvaluateFormulaIntent: AppIntent {
    static let title: LocalizedStringResource = "Intent.Evaluate.Title"
    static let description = IntentDescription("Intent.Evaluate.Description")

    @Parameter(title: "Intent.Parameter.Formula", default: "=SUM(1,2)")
    var formula: String

    @Parameter(title: "Intent.Parameter.Workbook")
    var workbook: WorkbookEntity?

    @Parameter(title: "Intent.Parameter.Sheet")
    var sheet: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Intent.Evaluate.Summary \(\.$formula)") {
            \.$workbook
            \.$sheet
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let book = try workbook?.load() ?? Workbook()
        let index = try WorkbookAutomation.sheetIndex(sheet, in: book)
        let value = WorkbookAutomation.evaluate(formula, sheet: index, in: book)
        return .result(value: value.stringValue)
    }
}

// MARK: - Changing

struct SetCellIntent: AppIntent {
    static let title: LocalizedStringResource = "Intent.SetCell.Title"
    static let description = IntentDescription("Intent.SetCell.Description")

    @Parameter(title: "Intent.Parameter.Workbook")
    var workbook: WorkbookEntity

    @Parameter(title: "Intent.Parameter.Cell", default: "A1")
    var cell: String

    @Parameter(title: "Intent.Parameter.Value")
    var value: String

    @Parameter(title: "Intent.Parameter.Sheet")
    var sheet: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Intent.SetCell.Summary \(\.$cell) \(\.$value) \(\.$workbook)") {
            \.$sheet
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<WorkbookEntity> {
        var book = try workbook.load()
        let index = try WorkbookAutomation.sheetIndex(sheet, in: book)
        try WorkbookAutomation.setCell(value, at: try WorkbookAutomation.address(cell), sheet: index, in: &book)
        return .result(value: try workbook.replacing(with: book))
    }
}

struct AppendRowIntent: AppIntent {
    static let title: LocalizedStringResource = "Intent.AppendRow.Title"
    static let description = IntentDescription("Intent.AppendRow.Description")

    @Parameter(title: "Intent.Parameter.Workbook")
    var workbook: WorkbookEntity

    @Parameter(title: "Intent.Parameter.Values")
    var values: [String]

    @Parameter(title: "Intent.Parameter.Sheet")
    var sheet: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Intent.AppendRow.Summary \(\.$values) \(\.$workbook)") {
            \.$sheet
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<WorkbookEntity> {
        var book = try workbook.load()
        let index = try WorkbookAutomation.sheetIndex(sheet, in: book)
        try WorkbookAutomation.appendRow(values, sheet: index, in: &book)
        return .result(value: try workbook.replacing(with: book))
    }
}

struct ClearRangeIntent: AppIntent {
    static let title: LocalizedStringResource = "Intent.Clear.Title"
    static let description = IntentDescription("Intent.Clear.Description")

    @Parameter(title: "Intent.Parameter.Workbook")
    var workbook: WorkbookEntity

    @Parameter(title: "Intent.Parameter.Range", default: "A1:B10")
    var range: String

    @Parameter(title: "Intent.Parameter.Sheet")
    var sheet: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Intent.Clear.Summary \(\.$range) \(\.$workbook)") {
            \.$sheet
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<WorkbookEntity> {
        var book = try workbook.load()
        let index = try WorkbookAutomation.sheetIndex(sheet, in: book)
        WorkbookAutomation.clear(try WorkbookAutomation.range(range, in: book.sheets[index]), sheet: index, in: &book)
        return .result(value: try workbook.replacing(with: book))
    }
}

struct SortRangeIntent: AppIntent {
    static let title: LocalizedStringResource = "Intent.Sort.Title"
    static let description = IntentDescription("Intent.Sort.Description")

    @Parameter(title: "Intent.Parameter.Workbook")
    var workbook: WorkbookEntity

    @Parameter(title: "Intent.Parameter.Range", default: "A1:B10")
    var range: String

    @Parameter(title: "Intent.Parameter.Column", default: "A")
    var column: String

    @Parameter(title: "Intent.Parameter.Ascending", default: true)
    var ascending: Bool

    @Parameter(title: "Intent.Parameter.HasHeader", default: true)
    var hasHeader: Bool

    @Parameter(title: "Intent.Parameter.Sheet")
    var sheet: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Intent.Sort.Summary \(\.$range) \(\.$column) \(\.$workbook)") {
            \.$ascending
            \.$hasHeader
            \.$sheet
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<WorkbookEntity> {
        var book = try workbook.load()
        let index = try WorkbookAutomation.sheetIndex(sheet, in: book)
        try WorkbookAutomation.sort(
            try WorkbookAutomation.range(range, in: book.sheets[index]), by: try WorkbookAutomation.column(column),
            ascending: ascending, hasHeader: hasHeader, sheet: index, in: &book)
        return .result(value: try workbook.replacing(with: book))
    }
}

struct AddSheetIntent: AppIntent {
    static let title: LocalizedStringResource = "Intent.AddSheet.Title"
    static let description = IntentDescription("Intent.AddSheet.Description")

    @Parameter(title: "Intent.Parameter.Workbook")
    var workbook: WorkbookEntity

    @Parameter(title: "Intent.Parameter.Name")
    var name: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Intent.AddSheet.Summary \(\.$name) \(\.$workbook)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<WorkbookEntity> {
        var book = try workbook.load()
        WorkbookAutomation.addSheet(named: name, in: &book)
        return .result(value: try workbook.replacing(with: book))
    }
}

struct RenameSheetIntent: AppIntent {
    static let title: LocalizedStringResource = "Intent.RenameSheet.Title"
    static let description = IntentDescription("Intent.RenameSheet.Description")

    @Parameter(title: "Intent.Parameter.Workbook")
    var workbook: WorkbookEntity

    @Parameter(title: "Intent.Parameter.Sheet")
    var sheet: String

    @Parameter(title: "Intent.Parameter.NewName")
    var newName: String

    static var parameterSummary: some ParameterSummary {
        Summary("Intent.RenameSheet.Summary \(\.$sheet) \(\.$newName) \(\.$workbook)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<WorkbookEntity> {
        var book = try workbook.load()
        WorkbookAutomation.renameSheet(try WorkbookAutomation.sheetIndex(sheet, in: book), to: newName, in: &book)
        return .result(value: try workbook.replacing(with: book))
    }
}

struct DeleteSheetIntent: AppIntent {
    static let title: LocalizedStringResource = "Intent.DeleteSheet.Title"
    static let description = IntentDescription("Intent.DeleteSheet.Description")

    @Parameter(title: "Intent.Parameter.Workbook")
    var workbook: WorkbookEntity

    @Parameter(title: "Intent.Parameter.Sheet")
    var sheet: String

    static var parameterSummary: some ParameterSummary {
        Summary("Intent.DeleteSheet.Summary \(\.$sheet) \(\.$workbook)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<WorkbookEntity> {
        var book = try workbook.load()
        try WorkbookAutomation.deleteSheet(try WorkbookAutomation.sheetIndex(sheet, in: book), in: &book)
        return .result(value: try workbook.replacing(with: book))
    }
}

// MARK: - Saving and opening

struct SaveWorkbookIntent: AppIntent {
    static let title: LocalizedStringResource = "Intent.Save.Title"
    static let description = IntentDescription("Intent.Save.Description")

    @Parameter(title: "Intent.Parameter.Workbook")
    var workbook: WorkbookEntity

    /// Where to save; the file the workbook came from when left out.
    @Parameter(title: "Intent.Parameter.Destination",
               supportedContentTypes: [.spreadsheet, .commaSeparatedText, .tabSeparatedText])
    var destination: IntentFile?

    @Parameter(title: "Intent.Parameter.Sheet")
    var sheet: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Intent.Save.Summary \(\.$workbook)") {
            \.$destination
            \.$sheet
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        guard let url = destination?.fileURL ?? workbook.sourceURL else { throw WorkbookAutomation.Failure.noSaveLocation }
        let format = WorkbookFiles.format(for: url)
        let data = try WorkbookAutomation.write(try workbook.load(), as: format, sheet: sheet)
        try WorkbookFiles.write(data, to: url)
        return .result(value: IntentFile(data: data, filename: url.lastPathComponent, type: format.type))
    }
}

struct OpenInTablesIntent: AppIntent {
    static let title: LocalizedStringResource = "Intent.OpenInTables.Title"
    static let description = IntentDescription("Intent.OpenInTables.Description")
    static let openAppWhenRun = true

    @Parameter(title: "Intent.Parameter.Workbook")
    var workbook: WorkbookEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Intent.OpenInTables.Summary \(\.$workbook)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        // A workbook read from a file opens that file, with any changes the
        // shortcut made saved into it first; one made in the shortcut is
        // saved among the app's own documents.
        let url: URL
        if let source = workbook.sourceURL {
            let format = WorkbookFiles.format(for: source)
            try WorkbookFiles.write(try WorkbookAutomation.write(try workbook.load(), as: format), to: source)
            url = source
        } else {
            url = WorkbookFiles.newDocumentURL(named: workbook.name)
            try WorkbookFiles.write(workbook.file.data, to: url)
        }
        try await WorkbookOpener.open(url)
        return .result()
    }
}
