import Foundation
import TablesEngine

/// Turns the open file into a workbook of another kind, in place: a CSV
/// becomes an `.xlsx` that can keep formatting, an `.xlsx` an `.xlsm` that can
/// keep macros, and so on.
///
/// The file is moved to its new name under a file coordinator, the way Rename
/// moves it, so the open document follows it there and from then on saves in
/// the new format.
enum DocumentConversion {
    enum Target: CaseIterable, Identifiable {
        case workbook
        case macroEnabledWorkbook

        var id: Self { self }

        var pathExtension: String {
            switch self {
            case .workbook: return "xlsx"
            case .macroEnabledWorkbook: return "xlsm"
            }
        }
    }

    /// The kinds a file of this type can be turned into: every workbook kind
    /// but its own.
    static func targets(for fileURL: URL) -> [Target] {
        // By extension rather than by type: the system's `.xlsm` type conforms
        // to the `.xlsx` one, which would hide the way back.
        let pathExtension = fileURL.pathExtension.lowercased()
        return Target.allCases.filter { $0.pathExtension != pathExtension }
    }

    /// Writes `workbook` as `target` beside the file and moves the file onto
    /// it, returning where it now lives.
    ///
    /// Off the main actor: the open document has to give the file up before
    /// the coordinator lets this touch it, and it does that on the main thread.
    @concurrent
    static func convert(fileAt url: URL, workbook: Workbook, to target: Target) async throws -> URL {
        let data = try XLSXWriter.data(from: workbook, macroEnabled: target == .macroEnabledWorkbook)
        let destination = availableURL(
            for: url.deletingPathExtension().lastPathComponent,
            extension: target.pathExtension,
            in: url.deletingLastPathComponent()
        )

        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var failure: Error?
        coordinator.coordinate(
            writingItemAt: url, options: .forMoving,
            writingItemAt: destination, options: .forReplacing,
            error: &coordinationError
        ) { source, target in
            do {
                try FileManager.default.moveItem(at: source, to: target)
                coordinator.item(at: source, didMoveTo: target)
                // After the move, so the document reading it back already
                // knows it by its new type.
                try data.write(to: target, options: .atomic)
            } catch {
                failure = error
            }
        }
        if let error = coordinationError ?? failure { throw error }
        return destination
    }

    /// Writes `workbook` as an `.xlsx` beside the file, leaving the file as it
    /// was, and returns where the copy went.
    ///
    /// For documents Tables reads but cannot write, such as Numbers ones:
    /// converting those in place would throw away everything Tables did not
    /// read from them, so the copy is where changes are kept instead.
    @concurrent
    static func saveCopy(of workbook: Workbook, besideFileAt url: URL) async throws -> URL {
        let data = try XLSXWriter.data(from: workbook, macroEnabled: false)
        let destination = availableURL(
            for: url.deletingPathExtension().lastPathComponent,
            extension: Target.workbook.pathExtension,
            in: url.deletingLastPathComponent()
        )

        var coordinationError: NSError?
        var failure: Error?
        NSFileCoordinator().coordinate(writingItemAt: destination, options: .forReplacing, error: &coordinationError) {
            do {
                try data.write(to: $0, options: .atomic)
            } catch {
                failure = error
            }
        }
        if let error = coordinationError ?? failure { throw error }
        return destination
    }

    /// `name.ext`, or `name 2.ext` and upwards when that is taken.
    private static func availableURL(for name: String, extension pathExtension: String, in folder: URL) -> URL {
        var candidate = folder.appendingPathComponent(name).appendingPathExtension(pathExtension)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(name) \(number)").appendingPathExtension(pathExtension)
            number += 1
        }
        return candidate
    }
}
