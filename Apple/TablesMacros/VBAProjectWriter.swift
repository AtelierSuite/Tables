import Foundation
import TablesEngine

// Editing a macro project and writing it back out.
//
// Office stores each module twice: as source, and compiled to p-code for the
// build that last saved it, with a further performance cache beside them.
// An edit changes only the source, so the compiled forms are thrown away and
// the project marked as having none: [MS-OVBA] §2.3.4.1 reserves version
// 0xFFFF of `_VBA_PROJECT` for exactly this, and Office recompiles every
// module from its source when it opens a project so marked.

extension VBAProject {
    public struct EditError: LocalizedError, Hashable, Sendable {
        public var message: String
        public var errorDescription: String? { message }
    }

    /// Replaces a module's code.
    public mutating func setSource(_ source: String, ofModule name: String) {
        guard let index = modules.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            return
        }
        modules[index].source = source
    }

    /// Why `name` cannot name a new module, or nil when it can.
    public func problem(withModuleName name: String) -> String? {
        guard let first = name.first, first.isLetter, first.isASCII else {
            return String(localized: "Macros.ModuleName.MustStartWithLetter", bundle: #bundle)
        }
        guard name.allSatisfy({ ($0.isLetter || $0.isNumber || $0 == "_") && $0.isASCII }) else {
            return String(localized: "Macros.ModuleName.InvalidCharacters", bundle: #bundle)
        }
        guard name.count <= 31 else { return String(localized: "Macros.ModuleName.TooLong", bundle: #bundle) }
        guard module(named: name) == nil, name.caseInsensitiveCompare(self.name) != .orderedSame,
              !Self.reservedNames.contains(name.lowercased()) else {
            return String(localized: "Macros.ModuleName.Taken", bundle: #bundle)
        }
        return nil
    }

    private static let reservedNames: Set<String> = [
        "vba", "excel", "office", "stdole", "msforms", "application", "thisworkbook", "dir", "_vba_project",
        "project", "projectwm",
    ]

    /// A name not yet taken: `Module1`, `Module2`, …
    public func nextModuleName(_ stem: String = "Module") -> String {
        var number = 1
        while module(named: "\(stem)\(number)") != nil { number += 1 }
        return "\(stem)\(number)"
    }

    /// Adds an empty standard or class module.
    public mutating func addModule(named name: String, kind: Module.Kind = .standard) throws {
        if let problem = problem(withModuleName: name) { throw EditError(message: problem) }
        let isClass = kind == .classModule
        modules.append(Module(
            name: name, kind: isClass ? .classModule : .standard, source: "Option Explicit\n",
            attributes: isClass ? Self.classAttributes(name: name) : "Attribute VB_Name = \"\(name)\"\r\n",
            streamName: name
        ))
    }

    /// Renames a standard or class module. A document module's name is its
    /// sheet's code name, and is changed with the sheet.
    public mutating func renameModule(_ name: String, to newName: String) throws {
        guard let index = modules.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }),
              modules[index].kind == .standard || modules[index].kind == .classModule else { return }
        guard newName != modules[index].name else { return }
        // Changing only the case of a name is allowed; any other clash is not.
        if newName.caseInsensitiveCompare(name) != .orderedSame, let problem = problem(withModuleName: newName) {
            throw EditError(message: problem)
        }
        modules[index].attributes = modules[index].attributes.replacingOccurrences(
            of: "Attribute VB_Name = \"\(modules[index].name)\"", with: "Attribute VB_Name = \"\(newName)\""
        )
        modules[index].name = newName
        modules[index].streamName = newName
    }

    /// Removes a standard or class module. The workbook's and sheets' own
    /// modules belong to them and stay.
    public mutating func removeModule(named name: String) {
        modules.removeAll {
            $0.name.caseInsensitiveCompare(name) == .orderedSame && ($0.kind == .standard || $0.kind == .classModule)
        }
    }

    /// The project as a `vbaProject.bin`.
    public func data() throws -> Data {
        guard var file else { throw EditError(message: "The macro project has no container to write into.") }
        let encoding = Self.encoding(forCodePage: codePage)
        guard let compressedDirectory = file.root.storage(named: "VBA")?.stream(named: "dir") else {
            throw EditError(message: "The macro project has no VBA storage.")
        }
        let directory = try VBADirectoryRecords(VBACompression.decompress(compressedDirectory))
        let original = Set(directory.moduleNames.map { $0.lowercased() })
        let kept = Set(modules.compactMap { $0.storedName?.lowercased() })

        var moduleStreams: [(name: String, data: Data)] = []
        for module in modules {
            // Stored source ends every line, the last included, with CR LF.
            var text = module.source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
            if !text.isEmpty, !text.hasSuffix("\r\n") { text += "\r\n" }
            guard let encoded = (module.attributes + text).data(using: encoding) else {
                throw EditError(message: String(format: String(localized: "Macros.Save.Unencodable", bundle: #bundle), module.name))
            }
            moduleStreams.append((module.streamName, VBACompression.compress(encoded)))
        }

        let newDirectory = try directory.rewritten(modules: modules, encoding: encoding)
        let removed = original.subtracting(kept)
        var renamed: [String: String] = [:]
        for module in modules {
            guard let stored = module.storedName, original.contains(stored.lowercased()), stored != module.name else {
                continue
            }
            renamed[stored.lowercased()] = module.name
        }
        // Streams of removed modules go, and so do renamed modules' old ones.
        var staleStreams = Set(directory.streamNames.filter { removed.contains($0.key) }.values.map { $0.lowercased() })
        for old in renamed.keys { if let stream = directory.streamNames[old] { staleStreams.insert(stream.lowercased()) } }
        staleStreams.subtract(modules.map { $0.streamName.lowercased() })

        file.root.modifyStorage(named: "VBA") { vba in
            vba.streams.removeAll { stream in
                let lowered = stream.name.lowercased()
                return staleStreams.contains(lowered) || lowered.hasPrefix("__srp_")
            }
            for (name, data) in moduleStreams { vba.setStream(named: name, to: data) }
            vba.setStream(named: "dir", to: VBACompression.compress(newDirectory))
            vba.setStream(named: "_VBA_PROJECT", to: Data([0xCC, 0x61, 0xFF, 0xFF, 0x00, 0x00, 0x00]))
        }

        let added = modules.filter { module in module.storedName.map { !original.contains($0.lowercased()) } ?? true }
        if let project = file.root.stream(named: "PROJECT") {
            file.root.setStream(named: "PROJECT", to: Self.rewrittenProjectStream(
                project, adding: added.map { ($0.name, $0.kind) }, removing: removed, renaming: renamed,
                encoding: encoding
            ))
        }
        if file.root.stream(named: "PROJECTwm") != nil {
            file.root.setStream(named: "PROJECTwm", to: Self.rewrittenNameMap(
                modules: modules.map(\.name), encoding: encoding
            ))
        }
        return try file.data()
    }

    /// The `PROJECT` stream lists modules as `Module=Name` and `Class=Name`
    /// lines, and the editor's window positions under `[Workspace]` as `Name=…`.
    public static func rewrittenProjectStream(
        _ stream: Data, adding added: [(name: String, kind: Module.Kind)], removing removed: Set<String>,
        renaming renamed: [String: String] = [:], encoding: String.Encoding
    ) -> Data {
        let text = String(data: stream, encoding: encoding) ?? String(decoding: stream, as: UTF8.self)
        var lines: [String] = []
        var inWorkspace = false
        for line in text.components(separatedBy: "\r\n") {
            if line.hasPrefix("[") { inWorkspace = line.caseInsensitiveCompare("[Workspace]") == .orderedSame }
            guard let equals = line.firstIndex(of: "=") else {
                lines.append(line)
                continue
            }
            let key = String(line[..<equals])
            let value = String(line[line.index(after: equals)...])
            if inWorkspace {
                guard !removed.contains(key.lowercased()) else { continue }
                lines.append(renamed[key.lowercased()].map { $0 + "=" + value } ?? line)
                continue
            }
            if key == "Module" || key == "Class" {
                guard !removed.contains(value.lowercased()) else { continue }
                lines.append(renamed[value.lowercased()].map { key + "=" + $0 } ?? line)
                continue
            }
            lines.append(line)
        }
        // New modules go after the last module line, or the ID line if none.
        let anchor = lines.lastIndex { $0.hasPrefix("Module=") || $0.hasPrefix("Document=") || $0.hasPrefix("Class=") }
            ?? lines.firstIndex { $0.hasPrefix("ID=") } ?? -1
        lines.insert(contentsOf: added.map { ($0.kind == .classModule ? "Class=" : "Module=") + $0.name }, at: anchor + 1)
        return lines.joined(separator: "\r\n").data(using: encoding) ?? Data(lines.joined(separator: "\r\n").utf8)
    }

    /// `PROJECTwm` pairs each module name in the code page with its UTF-16
    /// spelling, both NUL-terminated, the whole list ended by two zero bytes.
    public static func rewrittenNameMap(modules: [String], encoding: String.Encoding) -> Data {
        var out: [UInt8] = []
        for name in modules {
            out += [UInt8](name.data(using: encoding) ?? Data(name.utf8)) + [0]
            out += name.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] } + [0, 0]
        }
        return Data(out + [0, 0])
    }
}

/// The decompressed `dir` stream as raw records, so it can be written back
/// with only what an edit changes: the module list, and each module's
/// offset to its source, which is zero once the p-code before it is gone.
public struct VBADirectoryRecords: Sendable {
    private struct Record {
        var id: UInt16
        var bytes: [UInt8]
        var payload: ArraySlice<UInt8> { bytes[6...] }
    }

    private var header: [Record] = []
    private var groups: [(name: String, records: [Record])] = []
    private var tail: [Record] = []
    private let codePage: UInt32

    /// Lowercased module name to stream name.
    public private(set) var streamNames: [String: String] = [:]
    public var moduleNames: [String] { groups.map(\.name) }

    public init(_ data: Data) throws {
        let bytes = [UInt8](data)
        var position = 0
        var codePage: UInt32 = 1252
        var current: [Record]?
        var currentName = ""
        var currentStream = ""
        var finished = false
        while position + 6 <= bytes.count {
            let id = ByteReader.uint16(bytes, position)
            var size = Int(ByteReader.uint32(bytes, position + 2))
            if id == 0x0009 { size = 6 }
            guard position + 6 + size <= bytes.count else { throw VBAProject.EditError(message: "The macro project's directory is truncated.") }
            let record = Record(id: id, bytes: Array(bytes[position..<(position + 6 + size)]))
            position += 6 + size
            if finished {
                tail.append(record)
                continue
            }
            switch id {
            case 0x0003:
                codePage = UInt32(ByteReader.uint16(record.bytes, 6))
                header.append(record)
            case 0x0019:
                current = [record]
                currentName = VBAProject.decode(Array(record.payload), codePage: codePage)
                currentStream = currentName
            case 0x0047 where current != nil:
                current?.append(record)
                let units = stride(from: record.payload.startIndex, to: record.payload.endIndex - 1, by: 2).map {
                    (index: Int) -> UInt16 in UInt16(record.bytes[index]) | UInt16(record.bytes[index + 1]) << 8
                }
                let unicode = String(decoding: units, as: UTF16.self)
                if !unicode.isEmpty { currentName = unicode }
            case 0x001A where current != nil:
                current?.append(record)
                currentStream = VBAProject.decode(Array(record.payload), codePage: codePage)
            case 0x002B where current != nil:
                current?.append(record)
                groups.append((currentName, current ?? []))
                streamNames[currentName.lowercased()] = currentStream
                current = nil
            case 0x0010:
                tail.append(record)
                finished = true
            default:
                if current != nil { current?.append(record) } else { header.append(record) }
            }
        }
        self.codePage = codePage
    }

    public func rewritten(modules: [VBAProject.Module], encoding: String.Encoding) throws -> Data {
        var out: [UInt8] = []
        for record in header {
            if record.id == 0x000F {
                out += Self.record(0x000F, Self.little16(UInt16(modules.count)))
            } else {
                out += record.bytes
            }
        }
        for module in modules {
            if let stored = module.storedName,
               let group = groups.first(where: { $0.name.caseInsensitiveCompare(stored) == .orderedSame }) {
                let isRenamed = stored != module.name
                guard let name = module.name.data(using: encoding) else {
                    throw VBAProject.EditError(message: String(format: String(localized: "Macros.Save.Unencodable", bundle: #bundle), module.name))
                }
                let unicode = module.name.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
                for record in group.records {
                    switch record.id {
                    case 0x0031: out += Self.record(0x0031, [0, 0, 0, 0])
                    case 0x0019 where isRenamed, 0x001A where isRenamed: out += Self.record(record.id, [UInt8](name))
                    case 0x0047 where isRenamed, 0x0032 where isRenamed: out += Self.record(record.id, unicode)
                    default: out += record.bytes
                    }
                }
            } else {
                out += try Self.newModuleRecords(module, encoding: encoding)
            }
        }
        for record in tail { out += record.bytes }
        // The terminator's "reserved" field is its zero size.
        if tail.isEmpty { out += Self.record(0x0010, []) }
        return Data(out)
    }

    /// The records [MS-OVBA] §2.3.4.2.3.2 requires for a module.
    private static func newModuleRecords(_ module: VBAProject.Module, encoding: String.Encoding) throws -> [UInt8] {
        guard let name = module.name.data(using: encoding) else {
            throw VBAProject.EditError(message: String(format: String(localized: "Macros.Save.Unencodable", bundle: #bundle), module.name))
        }
        let unicode = module.name.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        var out: [UInt8] = []
        out += record(0x0019, [UInt8](name))
        out += record(0x0047, unicode)
        out += record(0x001A, [UInt8](name))
        out += record(0x0032, unicode)
        out += record(0x001C, [])
        out += record(0x0048, [])
        out += record(0x0031, [0, 0, 0, 0])
        out += record(0x001E, [0, 0, 0, 0])
        out += record(0x002C, [0xFF, 0xFF])
        out += record(module.kind == .standard ? 0x0021 : 0x0022, [])
        out += record(0x002B, [])
        return out
    }

    private static func record(_ id: UInt16, _ payload: [UInt8]) -> [UInt8] {
        little16(id) + little32(UInt32(payload.count)) + payload
    }

    private static func little16(_ value: UInt16) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8)] }

    private static func little32(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24)]
    }
}

// MARK: - New projects

extension VBAProject {
    public static let workbookClassID = "0{00020819-0000-0000-C000-000000000046}"
    public static let worksheetClassID = "0{00020820-0000-0000-C000-000000000046}"

    /// The header a document module carries, binding it to the workbook or a
    /// sheet through the class id of what it stands behind.
    public static func documentAttributes(name: String, classID: String) -> String {
        [
            "Attribute VB_Name = \"\(name)\"", "Attribute VB_Base = \"\(classID)\"",
            "Attribute VB_GlobalNameSpace = False", "Attribute VB_Creatable = False",
            "Attribute VB_PredeclaredId = True", "Attribute VB_Exposed = True",
            "Attribute VB_TemplateDerived = False", "Attribute VB_Customizable = True",
        ].map { $0 + "\r\n" }.joined()
    }

    public static func classAttributes(name: String) -> String {
        [
            "Attribute VB_Name = \"\(name)\"", "Attribute VB_GlobalNameSpace = False",
            "Attribute VB_Creatable = False", "Attribute VB_PredeclaredId = False", "Attribute VB_Exposed = False",
        ].map { $0 + "\r\n" }.joined()
    }

    /// A project for a workbook that has none: a module behind the workbook
    /// and each worksheet, as Excel makes, and one standard module to write
    /// macros in. Gives the workbook and its sheets code names if they lack
    /// them, since those are what bind the document modules.
    public static func newProject(for workbook: inout Workbook) throws -> VBAProject {
        let workbookName = workbook.codeName ?? "ThisWorkbook"
        workbook.codeName = workbookName
        var taken = Set(workbook.sheets.compactMap { $0.codeName?.lowercased() } + [workbookName.lowercased()])
        var modules = [Module(
            name: workbookName, kind: .document, source: "",
            attributes: documentAttributes(name: workbookName, classID: workbookClassID), streamName: workbookName
        )]
        var number = 1
        for index in workbook.sheets.indices where !workbook.sheets[index].isChartSheet {
            if workbook.sheets[index].codeName == nil {
                while taken.contains("sheet\(number)") { number += 1 }
                workbook.sheets[index].codeName = "Sheet\(number)"
                taken.insert("sheet\(number)")
            }
            let name = workbook.sheets[index].codeName ?? "Sheet\(number)"
            modules.append(Module(name: name, kind: .document, source: "",
                                  attributes: documentAttributes(name: name, classID: worksheetClassID),
                                  streamName: name))
        }
        var standard = "Module1"
        var suffix = 1
        while taken.contains(standard.lowercased()) {
            suffix += 1
            standard = "Module\(suffix)"
        }
        modules.append(Module(name: standard, kind: .standard, source: "Option Explicit\n",
                              attributes: "Attribute VB_Name = \"\(standard)\"\r\n", streamName: standard))

        let file = try blankContainer(modules: modules)
        var project = try VBAProject(compoundFile: file)
        // Written once more through the editing path, so a new project and an
        // edited one are laid out by the same code.
        project = try VBAProject(data: project.data())
        return project
    }

    /// The streams of a project whose modules are all empty, laid out as
    /// [MS-OVBA] §2.3 requires.
    private static func blankContainer(modules: [Module]) throws -> CompoundFile {
        func record(_ id: UInt16, _ payload: [UInt8]) -> [UInt8] {
            let size = UInt32(payload.count)
            return [UInt8(id & 0xFF), UInt8(id >> 8),
                    UInt8(size & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size >> 16 & 0xFF), UInt8(size >> 24)] + payload
        }
        func unicode(_ text: String) -> [UInt8] { text.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] } }
        let encoding = String.Encoding.windowsCP1252

        var dir: [UInt8] = []
        dir += record(0x0001, [1, 0, 0, 0])                  // SYSKIND: 32-bit Windows
        dir += record(0x0002, [0x09, 0x04, 0, 0])            // LCID: en-US
        dir += record(0x0014, [0x09, 0x04, 0, 0])            // LCIDINVOKE
        dir += record(0x0003, [0xE4, 0x04])                  // CODEPAGE: 1252
        dir += record(0x0004, Array("VBAProject".utf8))      // NAME
        dir += record(0x0005, []) + record(0x0040, [])       // DOCSTRING
        dir += record(0x0006, []) + record(0x003D, [])       // HELPFILEPATH
        dir += record(0x0007, [0, 0, 0, 0])                  // HELPCONTEXT
        dir += record(0x0008, [0, 0, 0, 0])                  // LIBFLAGS
        // VERSION, whose size field says 4 and which carries 6 bytes.
        dir += [0x09, 0x00, 0x04, 0x00, 0x00, 0x00] + [0x01, 0x00, 0x00, 0x00] + [0x00, 0x00]
        dir += record(0x000C, []) + record(0x003C, [])       // CONSTANTS
        dir += record(0x000F, [UInt8(modules.count & 0xFF), UInt8(modules.count >> 8)])
        dir += record(0x0013, [0xFF, 0xFF])                  // PROJECTCOOKIE
        var vba = CompoundFile.Storage(name: "VBA")
        for module in modules {
            let name = [UInt8](module.name.data(using: encoding) ?? Data(module.name.utf8))
            dir += record(0x0019, name) + record(0x0047, unicode(module.name))
            dir += record(0x001A, name) + record(0x0032, unicode(module.name))
            dir += record(0x001C, []) + record(0x0048, [])
            dir += record(0x0031, [0, 0, 0, 0])
            dir += record(0x001E, [0, 0, 0, 0])
            dir += record(0x002C, [0xFF, 0xFF])
            dir += record(module.kind == .standard ? 0x0021 : 0x0022, [])
            dir += record(0x002B, [])
            let text = module.attributes + module.source.replacingOccurrences(of: "\n", with: "\r\n")
            vba.streams.append(.init(name: module.streamName,
                                     data: VBACompression.compress(text.data(using: encoding) ?? Data(text.utf8))))
        }
        dir += record(0x0010, [])
        vba.streams.append(.init(name: "dir", data: VBACompression.compress(Data(dir))))
        vba.streams.append(.init(name: "_VBA_PROJECT", data: Data([0xCC, 0x61, 0xFF, 0xFF, 0x00, 0x00, 0x00])))

        let projectID = "{\(UUID().uuidString)}"
        var lines = ["ID=\"\(projectID)\""]
        for module in modules {
            switch module.kind {
            case .document: lines.append("Document=\(module.name)/&H00000000")
            case .classModule: lines.append("Class=\(module.name)")
            default: lines.append("Module=\(module.name)")
            }
        }
        // Unlocked, no password, visible.
        lines += [
            "Name=\"VBAProject\"", "HelpContextID=\"0\"", "VersionCompatible32=\"393222000\"",
            "CMG=\"\(VBAProjectEncryption.hex(VBAProjectEncryption.encrypt([0, 0, 0, 0], projectID: projectID)))\"",
            "DPB=\"\(VBAProjectEncryption.hex(VBAProjectEncryption.encrypt([0], projectID: projectID)))\"",
            "GC=\"\(VBAProjectEncryption.hex(VBAProjectEncryption.encrypt([0xFF], projectID: projectID)))\"",
            "", "[Host Extender Info]", "&H00000001={3832D640-CF90-11CF-8E43-00A0C911005A};VBE;&H00000000", "",
            "[Workspace]",
        ]
        lines += modules.map { "\($0.name)=0, 0, 0, 0, C" }
        lines.append("")

        var root = CompoundFile.Storage(name: "Root Entry")
        root.streams = [
            .init(name: "PROJECT", data: lines.joined(separator: "\r\n").data(using: encoding) ?? Data()),
            .init(name: "PROJECTwm", data: rewrittenNameMap(modules: modules.map(\.name), encoding: encoding)),
        ]
        root.storages = [vba]
        return CompoundFile(root: root)
    }
}

extension Workbook {
    /// Gives a workbook without macros a new, empty project to write them
    /// in. Only an `.xlsm` can keep it.
    public mutating func createMacroProject() throws {
        guard !hasMacros else { return }
        let project = try VBAProject.newProject(for: &self)
        let path = "xl/vbaProject.bin"
        preservedPackage.parts[path] = try project.data()
        // An override rather than the `bin` default, which printer settings
        // may already claim for a type of their own.
        preservedPackage.contentTypeOverrides["/" + path] = "application/vnd.ms-office.vbaProject"
        preservedPackage.workbookRelationships.append(PreservedRelationship(
            type: PreservedPackage.macroProjectRelationshipType, target: "vbaProject.bin", targetMode: nil
        ))
    }

    /// Replaces the macro project with an edited one. An edited project no
    /// longer matches its digital signature, so the signature goes with it.
    public mutating func setMacroProject(_ data: Data) {
        guard let path = preservedPackage.macroProjectPath else { return }
        preservedPackage.parts[path] = data
        let signatures = preservedPackage.parts.keys.filter {
            $0.hasPrefix("xl/vbaProjectSignature") || $0 == XLSXReader.PackagePreservation.relationshipsPath(for: path)
        }
        for signature in signatures {
            preservedPackage.parts[signature] = nil
            preservedPackage.contentTypeOverrides["/" + signature] = nil
        }
    }
}
