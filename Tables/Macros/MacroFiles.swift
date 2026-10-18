import Foundation
import TablesEngine

/// Where each workbook's macros keep their files: a folder of its own under
/// `Macro Files` in the app's Documents, which on iOS the Files app shows
/// under Tables, and which no macro can see outside of.
enum MacroFiles {
    /// Not translated: a folder's name is part of the paths macros build.
    static let containerName = "Macro Files"

    static var container: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(containerName, isDirectory: true)
    }

    /// The folder for a workbook, named after its file. It is created the
    /// first time a macro runs, not merely by asking.
    static func folder(forWorkbookNamed fileName: String?) -> URL {
        container.appendingPathComponent(folderName(for: fileName), isDirectory: true)
    }

    static func folderName(for fileName: String?) -> String {
        let stem = ((fileName ?? "") as NSString).deletingPathExtension
        // Characters a folder name cannot hold, and leading dots, which would
        // hide it or step outside the container.
        let cleaned = stem.components(separatedBy: CharacterSet(charactersIn: "/:\\\u{0}")).joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))
        return cleaned.isEmpty ? "Workbook" : cleaned
    }

    struct Entry: Identifiable, Hashable {
        var url: URL
        var isDirectory: Bool
        var size: Int
        var modified: Date
        var id: URL { url }
        var name: String { url.lastPathComponent }
    }

    /// What a folder holds, folders first, then by name.
    static func contents(of folder: URL) -> [Entry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        return urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return Entry(url: url, isDirectory: values?.isDirectory ?? false, size: values?.fileSize ?? 0,
                         modified: values?.contentModificationDate ?? .distantPast)
        }
        .sorted { lhs, rhs in
            lhs.isDirectory != rhs.isDirectory ? lhs.isDirectory
                : lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}
