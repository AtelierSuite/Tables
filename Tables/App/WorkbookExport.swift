import CoreTransferable
import Foundation
import TablesEngine
import UniformTypeIdentifiers

/// Wraps a workbook so it can be handed to `ShareLink`. The workbook is written
/// lazily, only when the user actually picks a share destination.
struct WorkbookExport: Transferable, Sendable {
    var workbook: Workbook
    var name: String
    /// Delimited formats hold one sheet, so sharing as CSV or TSV writes the
    /// sheet the user is looking at — the same one saving as those types picks.
    var sheetIndex = 0

    static var transferRepresentation: some TransferRepresentation {
        // Offered first when there are macros to keep: sharing as `.xlsx`
        // would leave them behind.
        FileRepresentation(exportedContentType: .macroEnabledWorkbook) { export in
            SentTransferredFile(try export.write(extension: "xlsm") {
                try XLSXWriter.data(from: export.workbook, macroEnabled: true)
            })
        }
        .suggestedFileName { $0.name + ".xlsm" }
        .exportingCondition { $0.workbook.hasMacros }

        FileRepresentation(exportedContentType: .openXMLWorkbook) { export in
            SentTransferredFile(try export.write(extension: "xlsx") {
                try XLSXWriter.data(from: export.workbook)
            })
        }
        .suggestedFileName { $0.name + ".xlsx" }

        FileRepresentation(exportedContentType: .commaSeparatedText) { export in
            SentTransferredFile(try export.write(extension: "csv") {
                CSVCodec.data(from: export.exportSheet)
            })
        }
        .suggestedFileName { $0.name + ".csv" }

        FileRepresentation(exportedContentType: .tabSeparatedText) { export in
            SentTransferredFile(try export.write(extension: "tsv") {
                CSVCodec.data(from: export.exportSheet, delimiter: "\t")
            })
        }
        .suggestedFileName { $0.name + ".tsv" }
    }

    var exportSheet: Worksheet { workbook.sheet(at: sheetIndex) }

    private func write(
        extension pathExtension: String, encode: () throws -> Data
    ) throws -> URL {
        // A per-export directory keeps concurrent shares from colliding on name.
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "Share-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let url = directory.appending(path: "\(sanitizedName).\(pathExtension)")
        try encode().write(to: url, options: .atomic)
        return url
    }

    private var sanitizedName: String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Workbook" : cleaned
    }
}
