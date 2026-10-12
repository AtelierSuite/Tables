import Synchronization
import SwiftUI
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

/// The app's document: an entire workbook, loaded from `.xlsx`, `.xlsm` or
/// `.csv`, or imported from Numbers.
struct TablesDocument: FileDocument {
    static let readableContentTypes: [UTType] = [
        .openXMLWorkbook, .macroEnabledWorkbook, .commaSeparatedText, .tabSeparatedText,
        .numbersDocument, .numbersPackage
    ]
    static let writableContentTypes: [UTType] = [
        .openXMLWorkbook, .macroEnabledWorkbook, .commaSeparatedText, .tabSeparatedText,
        .numbersDocument, .numbersPackage
    ]

    var workbook: Workbook
    /// CSV holds a single sheet, so exporting picks one: whichever the user
    /// is looking at. Held by reference, because looking at a sheet is not an
    /// edit — written through the document, it marked the file changed and
    /// saved it just for being opened.
    let csvExport = CSVExportChoice()
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

    /// What the opened file used that Tables cannot edit. Empty for anything we
    /// authored ourselves and for CSV, which has no such features to begin with.
    var unsupportedFeatures: UnsupportedFeatureReport { workbook.unsupportedFeatures }

    init() {
        workbook = Workbook()
        isPlainText = false
        isMacroEnabled = false
        numbersSource = nil
    }

    init(workbook: Workbook) {
        self.workbook = workbook
        isPlainText = false
        isMacroEnabled = false
        numbersSource = nil
    }

    init(configuration: ReadConfiguration) throws {
        isMacroEnabled = configuration.contentType.conforms(to: .macroEnabledWorkbook)
        if Self.isNumbers(configuration.contentType) {
            let file = configuration.file
            let document = try file.isDirectory
                ? NumbersReader.document(from: file)
                : NumbersReader.document(from: file.regularFileContents ?? Data())
            workbook = document.workbook
            numbersSource = document.source
            isPlainText = false
            return
        }
        numbersSource = nil

        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let name = configuration.file.preferredFilename.map {
            ($0 as NSString).deletingPathExtension
        } ?? Workbook.defaultSheetName(1)

        if configuration.contentType.conforms(to: .openXMLWorkbook)
            || configuration.contentType.conforms(to: .macroEnabledWorkbook) {
            workbook = try XLSXReader.workbook(from: data)
            isPlainText = false
        } else if configuration.contentType.conforms(to: .commaSeparatedText)
                    || configuration.contentType.conforms(to: .tabSeparatedText)
                    || configuration.contentType.conforms(to: .text) {
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

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        if Self.isNumbers(configuration.contentType) {
            // Only into the document it came from: Tables can patch a Numbers
            // document but can't make one.
            guard let numbersSource else { throw CocoaError(.fileWriteUnsupportedScheme) }
            return try NumbersWriter.fileWrapper(
                for: workbook, source: numbersSource, existing: configuration.existingFile
            )
        }
        let data: Data
        // Tab separated text does not conform to the comma separated type, so
        // ask about it in its own right rather than relying on the order here.
        if configuration.contentType.conforms(to: .tabSeparatedText) {
            data = CSVCodec.data(from: exportSheet, delimiter: "\t")
        } else if configuration.contentType.conforms(to: .commaSeparatedText) {
            data = CSVCodec.data(from: exportSheet)
        } else {
            data = try XLSXWriter.data(
                from: workbook, macroEnabled: configuration.contentType.conforms(to: .macroEnabledWorkbook)
            )
        }
        return FileWrapper(regularFileWithContents: data)
    }

    private static func isNumbers(_ type: UTType) -> Bool {
        type.conforms(to: .numbersDocument) || type.conforms(to: .numbersPackage)
    }

    /// Saving as delimited text writes whichever sheet the user picked.
    private var exportSheet: Worksheet {
        workbook.sheet(at: csvExport.sheetIndex)
    }
}

/// The sheet a delimited-text save writes. Read when the document is saved,
/// which happens off the main actor, hence the lock.
final class CSVExportChoice: Sendable {
    private let index = Mutex(0)

    var sheetIndex: Int {
        get { index.withLock { $0 } }
        set { index.withLock { $0 = newValue } }
    }
}
