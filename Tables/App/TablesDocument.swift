import SwiftUI
import Synchronization
import TablesEngine
import UniformTypeIdentifiers

/// The app's document: the `WorkbookFile` it was opened from, as a SwiftUI
/// document.
struct TablesDocument: FileDocument {
    static let readableContentTypes = WorkbookFile.readableContentTypes
    static let writableContentTypes = WorkbookFile.writableContentTypes

    private var file: WorkbookFile
    /// CSV holds a single sheet, so exporting picks one: whichever the user
    /// is looking at. Held by reference, because looking at a sheet is not an
    /// edit — written through the document, it marked the file changed and
    /// saved it just for being opened.
    let csvExport = CSVExportChoice()

    var workbook: Workbook {
        get { file.workbook }
        set { file.workbook = newValue }
    }

    var isPlainText: Bool {
        get { file.isPlainText }
        set { file.isPlainText = newValue }
    }

    var isMacroEnabled: Bool {
        get { file.isMacroEnabled }
        set { file.isMacroEnabled = newValue }
    }

    var numbersSource: NumbersSource? { file.numbersSource }
    var isNumbers: Bool { file.isNumbers }
    var unsupportedFeatures: UnsupportedFeatureReport { file.unsupportedFeatures }

    func allowsMovingCells(in sheetID: Worksheet.ID?) -> Bool { file.allowsMovingCells(in: sheetID) }
    func formatting(in sheetID: Worksheet.ID?) -> FormattingKinds { file.formatting(in: sheetID) }

    init() {
        file = WorkbookFile()
    }

    init(workbook: Workbook) {
        file = WorkbookFile(workbook: workbook)
    }

    init(configuration: ReadConfiguration) throws {
        file = try WorkbookFile(file: configuration.file, contentType: configuration.contentType)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try file.fileWrapper(
            contentType: configuration.contentType, existing: configuration.existingFile,
            exportSheetIndex: csvExport.sheetIndex
        )
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
