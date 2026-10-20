import Foundation
import TablesEngine

/// The source code of a workbook's macros, read out of `vbaProject.bin`.
///
/// Only the source is read. The project also carries each module compiled
/// to p-code for the Office build that last saved it, but Office recompiles
/// from source whenever that cache does not match, so the source is the
/// authority — and the only part documented well enough to rely on.
public struct VBAProject: Hashable, Sendable {
    public struct Module: Hashable, Sendable, Identifiable {
        public enum Kind: Hashable, Sendable {
            /// A standard module: `Module1`, public procedures anyone can call.
            case standard
            /// A class module, instantiated with `New`.
            case classModule
            /// The module behind the workbook or one of its sheets, named by
            /// the code name it is bound to.
            case document
            /// A UserForm, whose layout lives in a designer storage beside it.
            case designer
        }

        public var name: String
        public var kind: Kind
        /// The text as the editor shows it, without the `Attribute` lines
        /// that precede it in the stored source.
        public var source: String
        /// The `Attribute VB_…` header exactly as stored, kept apart because
        /// the editor never shows it and saving has to put it back.
        public var attributes: String
        /// The stream under `VBA/` that holds the module.
        public var streamName: String
        /// The name the project file knows the module by, which differs from
        /// `name` once it is renamed, and is nil for a module not yet saved.
        public var storedName: String?

        public var id: String { storedName ?? name }
    }

    public var name: String
    public var modules: [Module]
    /// The Windows code page the project's text is stored in.
    public var codePage: UInt32
    /// The container the project was read from. Saving an edit writes the
    /// changed modules back into it, keeping everything else it held —
    /// references, UserForm designers, protection — as it was.
    public var file: CompoundFile?

    public func module(named name: String) -> Module? {
        modules.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    public struct FormatError: LocalizedError, Sendable {
        public var message: String
        public var errorDescription: String? { message }
    }

    public init(name: String, modules: [Module], codePage: UInt32 = 1252) {
        self.name = name
        self.modules = modules
        self.codePage = codePage
    }

    public init(data: Data) throws {
        try self.init(compoundFile: CompoundFile(data: data))
    }

    public init(compoundFile file: CompoundFile) throws {
        guard let vba = file.root.storage(named: "VBA"), let compressedDirectory = vba.stream(named: "dir") else {
            throw FormatError(message: "The macro project has no VBA storage.")
        }
        let directory = try DirectoryStream(VBACompression.decompress(compressedDirectory))
        self.file = file
        codePage = directory.codePage
        name = directory.projectName

        let kinds = Self.moduleKinds(in: file.root.stream(named: "PROJECT"), codePage: directory.codePage)
        modules = try directory.modules.map { entry in
            guard let stream = vba.stream(named: entry.streamName) else {
                throw FormatError(message: "The macro project is missing module \(entry.name).")
            }
            let bytes = [UInt8](stream)
            guard entry.offset <= bytes.count else {
                throw FormatError(message: "Module \(entry.name) points past the end of its stream.")
            }
            let text = Self.decode(
                [UInt8](try VBACompression.decompress(bytes[entry.offset...])), codePage: directory.codePage
            )
            let (attributes, source) = Self.splitAttributes(text)
            let kind = kinds[entry.name.lowercased()] ?? (entry.isProcedural ? .standard : .classModule)
            return Module(name: entry.name, kind: kind, source: source, attributes: attributes,
                          streamName: entry.streamName, storedName: entry.name)
        }
    }

    // MARK: - Text

    public static func encoding(forCodePage codePage: UInt32) -> String.Encoding {
        let encoding = CFStringConvertWindowsCodepageToEncoding(codePage)
        guard encoding != kCFStringEncodingInvalidId else { return .windowsCP1252 }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))
    }

    public static func decode(_ bytes: [UInt8], codePage: UInt32) -> String {
        String(data: Data(bytes), encoding: encoding(forCodePage: codePage))
            ?? String(decoding: bytes, as: UTF8.self)
    }

    /// Stored source opens with `Attribute VB_Name = "Module1"` and friends;
    /// everything from the first other line on is what the user wrote.
    public static func splitAttributes(_ text: String) -> (attributes: String, source: String) {
        let lines = text.components(separatedBy: "\r\n")
        let headerCount = lines.prefix { $0.hasPrefix("Attribute ") }.count
        let attributes = lines.prefix(headerCount).map { $0 + "\r\n" }.joined()
        let source = lines.dropFirst(headerCount).joined(separator: "\n")
        return (attributes, source)
    }

    /// The `PROJECT` stream lists each module by kind — `Module=`, `Class=`,
    /// `Document=`, `BaseClass=` — which the `dir` stream alone cannot tell
    /// apart for anything but standard modules.
    public static func moduleKinds(in stream: Data?, codePage: UInt32) -> [String: Module.Kind] {
        guard let stream else { return [:] }
        var kinds: [String: Module.Kind] = [:]
        for line in decode([UInt8](stream), codePage: codePage).components(separatedBy: .newlines) {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals]
            let value = line[line.index(after: equals)...]
            switch key {
            case "Module": kinds[value.lowercased()] = .standard
            case "Class": kinds[value.lowercased()] = .classModule
            case "BaseClass": kinds[value.lowercased()] = .designer
            case "Document":
                // `Document=Sheet1/&H00000000`: the part after the slash is a version.
                let name = value.split(separator: "/", maxSplits: 1).first.map(String.init) ?? String(value)
                kinds[name.lowercased()] = .document
            default:
                continue
            }
        }
        return kinds
    }
}

// MARK: - The dir stream

/// The decompressed `dir` stream of [MS-OVBA] §2.3.4.2: a run of records,
/// each an id, a size and that many bytes, describing the project and then
/// each of its modules in turn.
private struct DirectoryStream {
    struct ModuleEntry {
        var name: String
        var streamName: String
        var offset: Int
        var isProcedural: Bool
    }

    private enum RecordID: UInt16 {
        case codePage = 0x0003
        case projectName = 0x0004
        case projectVersion = 0x0009
        case moduleName = 0x0019
        case moduleStreamName = 0x001A
        case moduleTypeProcedural = 0x0021
        case moduleTypeOther = 0x0022
        case moduleTerminator = 0x002B
        case moduleOffset = 0x0031
        case moduleStreamNameUnicode = 0x0032
        case moduleNameUnicode = 0x0047
        case terminator = 0x0010
    }

    var codePage: UInt32 = 1252
    var projectName = ""
    var modules: [ModuleEntry] = []

    init(_ data: Data) throws {
        let bytes = [UInt8](data)
        var position = 0
        var current: ModuleEntry?
        var unicodeName: String?
        var unicodeStreamName: String?

        func text(_ payload: ArraySlice<UInt8>) -> String { VBAProject.decode(Array(payload), codePage: codePage) }
        func unicode(_ payload: ArraySlice<UInt8>) -> String {
            let units = stride(from: payload.startIndex, to: payload.endIndex - 1, by: 2).map {
                UInt16(payload[$0]) | UInt16(payload[$0 + 1]) << 8
            }
            return String(decoding: units, as: UTF16.self)
        }

        while position + 6 <= bytes.count {
            let rawID = ByteReader.uint16(bytes, position)
            var size = Int(ByteReader.uint32(bytes, position + 2))
            // The one record whose size field lies: it says 4 and is followed
            // by six bytes of version number.
            if rawID == RecordID.projectVersion.rawValue { size = 6 }
            let start = position + 6
            guard start + size <= bytes.count else {
                throw VBAProject.FormatError(message: "The macro project's directory is truncated.")
            }
            let payload = bytes[start..<(start + size)]
            position = start + size

            switch RecordID(rawValue: rawID) {
            case .codePage:
                codePage = UInt32(ByteReader.uint16(bytes, start))
            case .projectName:
                projectName = text(payload)
            case .moduleName:
                current = ModuleEntry(name: text(payload), streamName: text(payload), offset: 0, isProcedural: true)
                unicodeName = nil
                unicodeStreamName = nil
            case .moduleNameUnicode:
                unicodeName = unicode(payload)
            case .moduleStreamName:
                current?.streamName = text(payload)
            case .moduleStreamNameUnicode:
                unicodeStreamName = unicode(payload)
            case .moduleOffset:
                current?.offset = Int(ByteReader.uint32(bytes, start))
            case .moduleTypeProcedural:
                current?.isProcedural = true
            case .moduleTypeOther:
                current?.isProcedural = false
            case .moduleTerminator:
                guard var module = current else { continue }
                // The Unicode spellings are the faithful ones when present;
                // the code-page ones lose whatever the page cannot hold.
                if let unicodeName, !unicodeName.isEmpty { module.name = unicodeName }
                if let unicodeStreamName, !unicodeStreamName.isEmpty { module.streamName = unicodeStreamName }
                modules.append(module)
                current = nil
            case .terminator:
                return
            default:
                continue
            }
        }
    }
}
