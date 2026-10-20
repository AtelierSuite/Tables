import Foundation
import TablesEngine

/// The files a macro can reach: one folder per workbook, and nothing above
/// it. Every path a macro gives — relative, absolute, Windows-style with
/// backslashes — is resolved inside that folder or refused, so `..`, links
/// that lead out, and other drives all end in a "Path/File access error".
///
/// Files a macro opens are read whole and written back when closed: macro
/// data files are small, and it keeps a half-finished run from leaving a
/// half-written file behind.
public final class VBAFileSystem {
    /// The working folder, with links resolved, as every check compares it.
    public let root: URL
    public private(set) var currentDirectory: URL

    /// What `Open` gave back, by file number.
    public final class OpenFile {
        public let url: URL
        public let mode: VBAFileMode
        public let recordLength: Int
        public var bytes: [UInt8]
        /// Zero-based byte offset of the next read or write.
        public var position = 0
        /// Characters written since the last line break, for `Tab` and `,`.
        public var column = 0
        public var width = 0
        /// Set when a `Get` ran out of file, which is when `EOF` turns true
        /// for binary and random access.
        public var readPastEnd = false
        public var isDirty = false

        public init(url: URL, mode: VBAFileMode, recordLength: Int, bytes: [UInt8]) {
            self.url = url
            self.mode = mode
            self.recordLength = recordLength
            self.bytes = bytes
        }

        public var isWritable: Bool { mode != .input }
    }

    public private(set) var openFiles: [Int: OpenFile] = [:]
    /// The listing `Dir()` without arguments continues.
    private var pendingListing: [String] = []

    /// Created if it does not exist yet.
    public init(root folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        root = folder.standardizedFileURL.resolvingSymlinksInPath()
        currentDirectory = root
    }

    // MARK: - Errors

    public static let badFileNumber = VBAError(number: 52, "Bad file name or number")
    public static let fileNotFound = VBAError(number: 53, "File not found")
    public static let badFileMode = VBAError(number: 54, "Bad file mode")
    public static let fileAlreadyOpen = VBAError(number: 55, "File already open")
    public static let fileExists = VBAError(number: 58, "File already exists")
    public static let pastEndOfFile = VBAError(number: 62, "Input past end of file")
    public static let tooManyFiles = VBAError(number: 67, "Too many files")
    public static let permissionDenied = VBAError(number: 70, "Permission denied")
    public static let accessError = VBAError(number: 75, "Path/File access error")
    public static let pathNotFound = VBAError(number: 76, "Path not found")

    // MARK: - Paths

    /// The real location of a path a macro gave, which is always inside the
    /// working folder; anything else throws.
    public func resolve(_ path: String) throws -> URL {
        let text = path.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !text.contains("\u{0}") else { throw Self.badFileNumber }
        var normalized = text.replacingOccurrences(of: "\\", with: "/")
        // A drive letter (`C:`) or a network share (`//server`) names a
        // place outside the folder by definition.
        let drive = normalized.count >= 2 && normalized.first!.isLetter
            && normalized[normalized.index(after: normalized.startIndex)] == ":"
        if drive || normalized.hasPrefix("//") { throw Self.accessError }
        while normalized.count > 1, normalized.hasSuffix("/") { normalized.removeLast() }

        let candidate = normalized.hasPrefix("/")
            ? URL(fileURLWithPath: normalized)
            : currentDirectory.appendingPathComponent(normalized)
        // `..` and `.` collapse here, before the containment check.
        let standardized = candidate.standardizedFileURL
        guard isInside(standardized) || isInside(standardized.resolvingSymlinksInPath()) else {
            throw Self.accessError
        }
        // A link inside the folder could still lead out of it, so the
        // deepest part that exists is resolved and checked too.
        var existing = standardized
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            existing.deleteLastPathComponent()
        }
        guard isInside(existing.resolvingSymlinksInPath()) else { throw Self.accessError }
        let remainder = standardized.path.dropFirst(existing.path.count)
        return URL(fileURLWithPath: existing.resolvingSymlinksInPath().path + remainder)
    }

    private func isInside(_ url: URL) -> Bool {
        let path = url.path
        return path == root.path || path.hasPrefix(root.path + "/")
    }

    /// A path for a macro to see: the real one, so it can be built on and
    /// handed back.
    public static func displayPath(_ url: URL) -> String { url.path }

    private func exists(_ url: URL, isDirectory: Bool? = nil) -> Bool {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) else { return false }
        return isDirectory.map { $0 == directory.boolValue } ?? true
    }

    private func isOpen(_ url: URL) -> Bool {
        openFiles.values.contains { $0.url.path == url.path }
    }

    // MARK: - Folders and files

    public func changeDirectory(_ path: String) throws {
        let url = try resolve(path)
        guard exists(url, isDirectory: true) else { throw Self.pathNotFound }
        currentDirectory = url
    }

    public func makeDirectory(_ path: String) throws {
        let url = try resolve(path)
        guard !exists(url) else { throw Self.accessError }
        guard exists(url.deletingLastPathComponent(), isDirectory: true) else { throw Self.pathNotFound }
        try mapErrors { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false) }
    }

    public func removeDirectory(_ path: String) throws {
        let url = try resolve(path)
        guard exists(url, isDirectory: true) else { throw Self.pathNotFound }
        // The working folder itself stays, and so does anything not empty.
        guard url.path != root.path,
              (try? FileManager.default.contentsOfDirectory(atPath: url.path))?.isEmpty == true else {
            throw Self.accessError
        }
        if currentDirectory.path.hasPrefix(url.path) { currentDirectory = url.deletingLastPathComponent() }
        try mapErrors { try FileManager.default.removeItem(at: url) }
    }

    /// `Kill`, which takes wildcards in its last part.
    public func delete(_ pattern: String) throws {
        let matches = try files(matching: pattern, includeDirectories: false)
        guard !matches.isEmpty else { throw Self.fileNotFound }
        for url in matches {
            guard !isOpen(url) else { throw Self.accessError }
            try mapErrors { try FileManager.default.removeItem(at: url) }
        }
    }

    public func copy(_ source: String, to destination: String) throws {
        let from = try resolve(source)
        let to = try resolve(destination)
        guard exists(from, isDirectory: false) else { throw Self.fileNotFound }
        guard exists(to.deletingLastPathComponent(), isDirectory: true) else { throw Self.pathNotFound }
        guard !openFiles.values.contains(where: { $0.url.path == from.path && $0.isWritable }), !isOpen(to) else {
            throw Self.permissionDenied
        }
        try mapErrors {
            if exists(to) { try FileManager.default.removeItem(at: to) }
            try FileManager.default.copyItem(at: from, to: to)
        }
    }

    public func rename(_ source: String, to destination: String) throws {
        let from = try resolve(source)
        let to = try resolve(destination)
        guard exists(from) else { throw Self.fileNotFound }
        guard !exists(to) else { throw Self.fileExists }
        guard exists(to.deletingLastPathComponent(), isDirectory: true) else { throw Self.pathNotFound }
        guard !isOpen(from) else { throw Self.accessError }
        try mapErrors { try FileManager.default.moveItem(at: from, to: to) }
    }

    public func length(of path: String) throws -> Int {
        let url = try resolve(path)
        guard exists(url, isDirectory: false) else { throw Self.fileNotFound }
        return (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    public func modificationDate(of path: String) throws -> Date {
        let url = try resolve(path)
        guard exists(url) else { throw Self.fileNotFound }
        return (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? Date()
    }

    /// `GetAttr`'s bits: 1 read-only, 2 hidden, 16 directory, 32 archive.
    public func attributes(of path: String) throws -> Int {
        let url = try resolve(path)
        guard exists(url) else { throw Self.fileNotFound }
        var bits = exists(url, isDirectory: true) ? 16 : 32
        if url.lastPathComponent.hasPrefix(".") { bits |= 2 }
        if !FileManager.default.isWritableFile(atPath: url.path) { bits |= 1 }
        return bits
    }

    /// `SetAttr`: only read-only means anything here.
    public func setAttributes(of path: String, to bits: Int) throws {
        let url = try resolve(path)
        guard exists(url) else { throw Self.fileNotFound }
        let permissions = bits & 1 != 0 ? 0o444 : 0o644
        try mapErrors { try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path) }
    }

    // MARK: - Dir

    /// `Dir(pattern, attributes)`: the first name matching, remembering the
    /// rest for `Dir()` to hand out one at a time.
    public func firstMatch(_ pattern: String, attributes: Int) throws -> String {
        // Attribute 8 asks for the volume label, which there is none of.
        if attributes & 8 != 0 { return "" }
        let includeDirectories = attributes & 16 != 0
        let includeHidden = attributes & 2 != 0
        let matches = (try? files(matching: pattern, includeDirectories: includeDirectories)) ?? []
        pendingListing = matches.map(\.lastPathComponent).filter { includeHidden || !$0.hasPrefix(".") }
        return nextMatch()
    }

    public func nextMatch() -> String {
        guard !pendingListing.isEmpty else { return "" }
        return pendingListing.removeFirst()
    }

    /// Files in a folder whose names match the last part of `pattern`,
    /// sorted. A pattern naming a folder (`"data\"`) lists that folder.
    public func files(matching pattern: String, includeDirectories: Bool) throws -> [URL] {
        var text = pattern.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\", with: "/")
        if text.isEmpty || text.hasSuffix("/") { text += "*" }
        let slash = text.lastIndex(of: "/")
        let folderPart = slash.map { String(text[...$0]) } ?? ""
        let namePart = slash.map { String(text[text.index(after: $0)...]) } ?? text
        let folder = folderPart.isEmpty ? currentDirectory : try resolve(folderPart)
        guard exists(folder, isDirectory: true) else { return [] }
        if !namePart.contains("*"), !namePart.contains("?") {
            let url = folder.appendingPathComponent(namePart)
            guard exists(url), includeDirectories || exists(url, isDirectory: false) else { return [] }
            return [try resolve(url.path)]
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .filter { Self.wildcardMatches($0, namePart) }
            .map { folder.appendingPathComponent($0) }
            .filter { includeDirectories || exists($0, isDirectory: false) }
    }

    /// `*` and `?`, case-insensitively, with `*.*` matching names without a
    /// dot too, as Windows does.
    public static func wildcardMatches(_ name: String, _ pattern: String) -> Bool {
        if pattern == "*.*" || pattern == "*" { return true }
        let escaped = pattern.lowercased().map { character -> String in
            switch character {
            case "*": return "*"
            case "?": return "?"
            case "[", "#": return "[\(character)]"
            default: return String(character)
            }
        }.joined()
        return VBAOperators.like(name.lowercased(), escaped, textCompare: false)
    }

    // MARK: - Open files

    public static let maximumFileSize = 64 * 1024 * 1024

    public func open(_ path: String, mode: VBAFileMode, number: Int, recordLength: Int?) throws {
        guard (1...511).contains(number) else { throw Self.badFileNumber }
        guard openFiles[number] == nil else { throw Self.fileAlreadyOpen }
        let url = try resolve(path)
        guard !exists(url, isDirectory: true) else { throw Self.accessError }
        guard exists(url.deletingLastPathComponent(), isDirectory: true) else { throw Self.pathNotFound }
        // One writer per file, as Windows enforces.
        if mode != .input, isOpen(url) { throw Self.fileAlreadyOpen }
        var bytes: [UInt8] = []
        switch mode {
        case .input:
            guard exists(url) else { throw Self.fileNotFound }
            bytes = try read(url)
        case .output:
            bytes = []
        case .append, .binary, .random:
            if exists(url) { bytes = try read(url) }
        }
        let file = OpenFile(url: url, mode: mode, recordLength: max(1, recordLength ?? (mode == .random ? 128 : 1)),
                            bytes: bytes)
        if mode == .append { file.position = bytes.count }
        // Opening for output creates the file at once, as VBA does.
        if mode == .output || !exists(url) {
            file.isDirty = true
            try flush(file)
        }
        openFiles[number] = file
    }

    private func read(_ url: URL) throws -> [UInt8] {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size <= Self.maximumFileSize else { throw VBAError(number: 7, "Out of memory") }
        do {
            return [UInt8](try Data(contentsOf: url))
        } catch {
            throw Self.permissionDenied
        }
    }

    public func file(_ number: Int) throws -> OpenFile {
        guard let file = openFiles[number] else { throw Self.badFileNumber }
        return file
    }

    public func close(_ number: Int) throws {
        guard let file = openFiles.removeValue(forKey: number) else { throw Self.badFileNumber }
        try flush(file)
    }

    /// `Reset`, and the end of every run: nothing a macro wrote is lost
    /// because it forgot to close a file.
    public func closeAll() {
        for number in openFiles.keys.sorted() { try? close(number) }
    }

    private func flush(_ file: OpenFile) throws {
        guard file.isDirty else { return }
        do {
            try Data(file.bytes).write(to: file.url, options: .atomic)
            file.isDirty = false
        } catch {
            throw Self.permissionDenied
        }
    }

    /// `FreeFile`: the lowest number free, from 1–255 or, given 1, 256–511.
    public func freeNumber(upperRange: Bool) throws -> Int {
        let range = upperRange ? 256...511 : 1...255
        guard let number = range.first(where: { openFiles[$0] == nil }) else { throw Self.tooManyFiles }
        return number
    }

    private func mapErrors(_ body: () throws -> Void) throws {
        do {
            try body()
        } catch let error as VBAError {
            throw error
        } catch {
            throw Self.permissionDenied
        }
    }

    // MARK: - Reading and writing open files

    public func write(_ bytes: [UInt8], to file: OpenFile) throws {
        guard file.isWritable else { throw Self.badFileMode }
        let end = file.position + bytes.count
        if end > file.bytes.count { file.bytes += [UInt8](repeating: 0, count: end - file.bytes.count) }
        file.bytes.replaceSubrange(file.position..<end, with: bytes)
        file.position = end
        file.isDirty = true
    }

    /// Text goes out as UTF-8, with Windows line breaks so files written here
    /// read back the same in Excel on Windows.
    public func writeText(_ text: String, to file: OpenFile) throws {
        guard file.mode == .output || file.mode == .append else { throw Self.badFileMode }
        try write([UInt8](text.utf8), to: file)
        // "\r\n" is one Character to Swift, so all three line endings are looked for.
        if let lastBreak = text.lastIndex(where: { $0 == "\r\n" || $0 == "\n" || $0 == "\r" }) {
            file.column = text.distance(from: text.index(after: lastBreak), to: text.endIndex)
        } else {
            file.column += text.count
        }
    }

    public func readBytes(_ count: Int, from file: OpenFile) -> [UInt8] {
        let available = max(0, min(count, file.bytes.count - file.position))
        let slice = Array(file.bytes[file.position..<(file.position + available)])
        file.position += available
        if available < count { file.readPastEnd = true }
        return slice
    }

    /// One line, without its CR, LF or CR LF.
    public func readLine(from file: OpenFile) throws -> String {
        guard file.mode == .input || file.mode == .binary else { throw Self.badFileMode }
        guard file.position < file.bytes.count else { throw Self.pastEndOfFile }
        var end = file.position
        while end < file.bytes.count, file.bytes[end] != 0x0A, file.bytes[end] != 0x0D { end += 1 }
        let line = Self.decode(Array(file.bytes[file.position..<end]))
        file.position = end
        if file.position < file.bytes.count, file.bytes[file.position] == 0x0D { file.position += 1 }
        if file.position < file.bytes.count, file.bytes[file.position] == 0x0A { file.position += 1 }
        return line
    }

    /// One `Input #` field: quoted text up to its closing quote, or anything
    /// up to the next comma or line break. Nil for an unquoted field.
    public func readField(from file: OpenFile) throws -> (text: String, wasQuoted: Bool) {
        guard file.mode == .input || file.mode == .binary else { throw Self.badFileMode }
        let bytes = file.bytes
        var index = file.position
        // Leading spaces and blank lines don't start a field.
        while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        guard index < bytes.count else { throw Self.pastEndOfFile }
        var field: [UInt8] = []
        var quoted = false
        if bytes[index] == 0x22 {
            quoted = true
            index += 1
            while index < bytes.count, bytes[index] != 0x22 {
                field.append(bytes[index])
                index += 1
            }
            index += 1
            // Skip to the separator after the closing quote.
            while index < bytes.count, bytes[index] == 0x20 { index += 1 }
        } else {
            while index < bytes.count, ![0x2C, 0x0A, 0x0D].contains(bytes[index]) {
                field.append(bytes[index])
                index += 1
            }
            while field.last == 0x20 || field.last == 0x09 { field.removeLast() }
        }
        if index < bytes.count, bytes[index] == 0x2C { index += 1 }
        else {
            if index < bytes.count, bytes[index] == 0x0D { index += 1 }
            if index < bytes.count, bytes[index] == 0x0A { index += 1 }
        }
        file.position = index
        return (Self.decode(field), quoted)
    }

    /// UTF-8 where the bytes are valid UTF-8, Windows Latin otherwise — which
    /// is what a text file written by Excel on Windows most likely is.
    public static func decode(_ bytes: [UInt8]) -> String {
        if let text = String(bytes: bytes, encoding: .utf8) { return text }
        return String(bytes: bytes, encoding: .windowsCP1252) ?? String(decoding: bytes, as: UTF8.self)
    }
}
