import Foundation
import TablesEngine

/// What a file Tables opens holds, and how it is read and written. The web's
/// counterpart of the Apple apps' `WorkbookFile`, keyed by file extension
/// rather than by uniform type, since that is what a browser hands over.
struct WebDocument {
    enum Kind: String {
        case xlsx, xlsm, csv, tsv, numbers, new

        init(fileName: String, data: Data) {
            switch (fileName as NSString).pathExtension.lowercased() {
            case "xlsx": self = .xlsx
            case "xlsm": self = .xlsm
            case "csv": self = .csv
            case "tsv", "tab": self = .tsv
            case "txt": self = data.starts(with: [0x50, 0x4B]) ? .xlsx : .csv
            case "numbers": self = .numbers
            default:
                // Content sniffing, as the Apple apps fall back on: ZIP packages start with "PK".
                self = data.starts(with: [0x50, 0x4B]) ? .xlsx : .csv
            }
        }
    }

    enum SaveFormat: String {
        case xlsx, xlsm, csv, tsv, numbers

        var fileExtension: String { rawValue }
    }

    struct Failure: LocalizedError {
        var errorDescription: String?
    }

    var workbook: Workbook
    var kind: Kind
    var fileName: String
    let numbersSource: NumbersSource?

    var isPlainText: Bool { kind == .csv || kind == .tsv }
    var isMacroEnabled: Bool { kind == .xlsm }
    var isNumbers: Bool { numbersSource != nil }

    init(workbook: Workbook = Workbook(), fileName: String) {
        self.workbook = workbook
        kind = .new
        self.fileName = fileName
        numbersSource = nil
    }

    init(data: Data, fileName: String) throws {
        self.fileName = fileName
        kind = Kind(fileName: fileName, data: data)
        switch kind {
        case .numbers:
            let document = try NumbersReader.document(from: data)
            workbook = document.workbook
            numbersSource = document.source
        case .xlsx, .xlsm:
            workbook = try XLSXReader.workbook(from: data)
            numbersSource = nil
        case .csv, .tsv, .new:
            let name = (fileName as NSString).deletingPathExtension
            workbook = CSVCodec.workbook(from: data, sheetName: name.isEmpty ? Workbook.defaultSheetName(1) : name)
            numbersSource = nil
        }
    }

    /// The formats this document can be saved as: always a workbook, the file's
    /// own kind, and the delimited text formats.
    var saveFormats: [SaveFormat] {
        var formats: [SaveFormat] = []
        if isNumbers { formats.append(.numbers) }
        if isMacroEnabled || workbook.hasMacros { formats.append(.xlsm) }
        formats.append(.xlsx)
        formats += [.csv, .tsv]
        return formats
    }

    /// The format a plain Save writes: the one the file came in.
    var defaultSaveFormat: SaveFormat {
        switch kind {
        case .xlsm: return .xlsm
        case .csv: return .csv
        case .tsv: return .tsv
        case .numbers: return .numbers
        case .xlsx, .new: return .xlsx
        }
    }

    func data(as format: SaveFormat, sheetIndex: Int) throws -> Data {
        switch format {
        case .numbers:
            // Only into the document it came from: Tables can patch a Numbers
            // document but can't make one.
            guard let numbersSource else { throw Failure(errorDescription: "Only a Numbers document can be saved as Numbers.") }
            let wrapper = try NumbersWriter.fileWrapper(for: workbook, source: numbersSource, existing: nil)
            guard let contents = wrapper.regularFileContents else {
                throw Failure(errorDescription: "This Numbers document is a package, which can't be saved here.")
            }
            return contents
        case .tsv:
            return CSVCodec.data(from: workbook.sheet(at: sheetIndex), delimiter: "\t")
        case .csv:
            return CSVCodec.data(from: workbook.sheet(at: sheetIndex))
        case .xlsx, .xlsm:
            return try XLSXWriter.data(from: workbook, macroEnabled: format == .xlsm)
        }
    }

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

    var unsupportedFeatures: UnsupportedFeatureReport { numbersSource?.features ?? workbook.unsupportedFeatures }
}
