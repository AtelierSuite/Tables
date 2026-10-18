import Foundation
import TablesEngine
import UniformTypeIdentifiers

extension UTType {
    /// The Office Open XML workbook type, declared by the system.
    static let openXMLWorkbook = UTType("org.openxmlformats.spreadsheetml.sheet") ?? .data
    /// The `.xlsm` workbook, which may carry macros. It does not conform to
    /// the plain workbook type, so it is asked about in its own right.
    static let macroEnabledWorkbook = UTType("org.openxmlformats.spreadsheetml.sheet.macroenabled") ?? .data
    /// A Numbers document saved as a single file, as Numbers saves by default.
    /// Imported rather than looked up, so that a system without Numbers'
    /// declarations can't leave it falling back on a type everything matches.
    static let numbersDocument = UTType(importedAs: "com.apple.iwork.numbers.sffnumbers")
    /// A Numbers document saved as a package, as older versions saved them.
    static let numbersPackage = UTType(importedAs: "com.apple.iwork.numbers.numbers")
}

/// What a file Tables opens holds, and how it is read and written: an entire
/// workbook, from `.xlsx`, `.xlsm` or `.csv`, or imported from Numbers.
///
/// Both apps' documents keep one of these, so a file opens and saves the same
/// way on the iPhone, the iPad and the Mac.
struct WorkbookFile {
    static let readableContentTypes: [UTType] = [
        .openXMLWorkbook, .macroEnabledWorkbook, .commaSeparatedText, .tabSeparatedText,
        .numbersDocument, .numbersPackage
    ]
    static let writableContentTypes: [UTType] = [
        .openXMLWorkbook, .macroEnabledWorkbook, .commaSeparatedText, .tabSeparatedText,
        .numbersDocument, .numbersPackage
    ]

    var workbook: Workbook
    /// Whether the file is delimited text, which keeps values but no styling,
    /// so formatting applied to it would be thrown away on save. Settable
    /// because the file can be converted into a workbook while open.
    var isPlainText: Bool
    /// Whether the file is an `.xlsm`, the only kind that keeps macros.
    var isMacroEnabled: Bool
    /// The Numbers document the workbook was read from, which saving
    /// patches with the workbook's changes. Nil for any other kind of file.
    let numbersSource: NumbersSource?

    /// Whether the file is a Numbers document, which keeps only the changes
    /// `NumbersEditPolicy` allows.
    var isNumbers: Bool { numbersSource != nil }

    /// Whether rows and columns can be inserted into and deleted from a sheet:
    /// in a Numbers document, only where nothing Tables can't move depends on
    /// where its cells are.
    func allowsMovingCells(in sheetID: Worksheet.ID?) -> Bool {
        guard let source = numbersSource else { return true }
        guard let sheetID, let table = source.tables[sheetID], let imported = source.imported[sheetID] else { return false }
        return NumbersEditPolicy.canMoveCells(in: table, imported: imported, source: source)
    }

    /// The formatting a sheet keeps: none in delimited text, and in a Numbers
    /// document only what `NumbersEditPolicy` can save.
    func formatting(in sheetID: Worksheet.ID?) -> FormattingKinds {
        if isPlainText { return [] }
        guard let source = numbersSource else { return .all }
        guard let sheetID, let table = source.tables[sheetID] else { return [] }
        return NumbersEditPolicy.formatting(in: table)
    }

    /// What the opened file used that Tables cannot edit. Empty for anything we
    /// authored ourselves and for CSV, which has no such features to begin with.
    var unsupportedFeatures: UnsupportedFeatureReport { numbersSource?.features ?? workbook.unsupportedFeatures }

    init(workbook: Workbook = Workbook()) {
        self.workbook = workbook
        isPlainText = false
        isMacroEnabled = false
        numbersSource = nil
    }

    init(file: FileWrapper, contentType: UTType) throws {
        isMacroEnabled = contentType.conforms(to: .macroEnabledWorkbook)
        if Self.isNumbers(contentType) {
            let document = try file.isDirectory
                ? NumbersReader.document(from: file)
                : NumbersReader.document(from: file.regularFileContents ?? Data())
            workbook = document.workbook
            numbersSource = document.source
            isPlainText = false
            return
        }
        numbersSource = nil

        guard let data = file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let name = file.preferredFilename.map {
            ($0 as NSString).deletingPathExtension
        } ?? Workbook.defaultSheetName(1)

        if contentType.conforms(to: .openXMLWorkbook) || contentType.conforms(to: .macroEnabledWorkbook) {
            workbook = try XLSXReader.workbook(from: data)
            isPlainText = false
        } else if contentType.conforms(to: .commaSeparatedText)
                    || contentType.conforms(to: .tabSeparatedText)
                    || contentType.conforms(to: .text) {
            workbook = CSVCodec.workbook(from: data, sheetName: name)
            isPlainText = true
        } else {
            // Fall back on content sniffing: ZIP packages start with "PK".
            if data.starts(with: [0x50, 0x4B]) {
                workbook = try XLSXReader.workbook(from: data)
                isPlainText = false
            } else {
                workbook = CSVCodec.workbook(from: data, sheetName: name)
                isPlainText = true
            }
        }
    }

    /// The file for `contentType`. Delimited text holds one sheet, so saving
    /// as it writes the sheet at `exportSheetIndex`.
    func fileWrapper(contentType: UTType, existing: FileWrapper?, exportSheetIndex: Int) throws -> FileWrapper {
        if Self.isNumbers(contentType) {
            // Only into the document it came from: Tables can patch a Numbers
            // document but can't make one.
            guard let numbersSource else { throw CocoaError(.fileWriteUnsupportedScheme) }
            return try NumbersWriter.fileWrapper(for: workbook, source: numbersSource, existing: existing)
        }
        let data: Data
        // Tab separated text does not conform to the comma separated type, so
        // ask about it in its own right rather than relying on the order here.
        if contentType.conforms(to: .tabSeparatedText) {
            data = CSVCodec.data(from: workbook.sheet(at: exportSheetIndex), delimiter: "\t")
        } else if contentType.conforms(to: .commaSeparatedText) {
            data = CSVCodec.data(from: workbook.sheet(at: exportSheetIndex))
        } else {
            data = try XLSXWriter.data(from: workbook, macroEnabled: contentType.conforms(to: .macroEnabledWorkbook))
        }
        return FileWrapper(regularFileWithContents: data)
    }

    static func isNumbers(_ type: UTType) -> Bool {
        type.conforms(to: .numbersDocument) || type.conforms(to: .numbersPackage)
    }
}
