import Foundation
import TablesEngine

/// A Compound File Binary container ([MS-CFB]), the "file system in a file"
/// that `vbaProject.bin` is. Storages hold streams and further storages, much
/// as folders hold files.
///
/// Read whole on open: a macro project runs to tens of kilobytes, and holding
/// it as a tree of values is what lets an edited one be written back out.
struct CompoundFile: Hashable, Sendable {
    struct FormatError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// A storage: a named directory of streams and storages. Names compare
    /// without regard to case, as the format specifies.
    struct Storage: Hashable, Sendable {
        var name: String
        var streams: [Stream] = []
        var storages: [Storage] = []
        /// The class id the file gave the storage. Office reads it on some
        /// storages, so it is kept rather than regenerated.
        var classID = Data(count: 16)

        func stream(named name: String) -> Data? {
            streams.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.data
        }

        func storage(named name: String) -> Storage? {
            storages.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }

        mutating func setStream(named name: String, to data: Data) {
            if let index = streams.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                streams[index].data = data
            } else {
                streams.append(Stream(name: name, data: data))
            }
        }

        mutating func modifyStorage(named name: String, _ change: (inout Storage) -> Void) {
            guard let index = storages.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
            else { return }
            change(&storages[index])
        }
    }

    struct Stream: Hashable, Sendable {
        var name: String
        var data: Data
    }

    var root: Storage

    init(root: Storage) {
        self.root = root
    }

    /// The stream at a path of storage names ending in a stream name.
    func stream(at path: [String]) -> Data? {
        guard let name = path.last else { return nil }
        var storage = root
        for component in path.dropLast() {
            guard let next = storage.storage(named: component) else { return nil }
            storage = next
        }
        return storage.stream(named: name)
    }

    // MARK: - Layout constants

    static let signature: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
    fileprivate static let freeSector: UInt32 = 0xFFFF_FFFF
    fileprivate static let endOfChain: UInt32 = 0xFFFF_FFFE
    fileprivate static let fatSectorMarker: UInt32 = 0xFFFF_FFFD
    fileprivate static let noStream: UInt32 = 0xFFFF_FFFF
    fileprivate static let headerSize = 512
    fileprivate static let directoryEntrySize = 128
    fileprivate static let miniSectorSize = 64
    fileprivate static let miniStreamCutoff = 4096
    fileprivate static let headerDIFATCount = 109

    fileprivate enum EntryType: UInt8 {
        case storage = 1
        case stream = 2
        case root = 5
    }

    // MARK: - Reading

    init(data: Data) throws {
        root = try Parser(bytes: [UInt8](data)).root()
    }
}

// MARK: - Parsing

private struct DirectoryEntry {
    var name: String
    var type: UInt8
    var left: UInt32
    var right: UInt32
    var child: UInt32
    var classID: Data
    var startSector: UInt32
    var size: UInt64

    init(_ bytes: [UInt8], at offset: Int, isVersion4: Bool) {
        let nameLength = min(64, Int(ByteReader.uint16(bytes, offset + 64)))
        let units = stride(from: 0, to: max(0, nameLength - 2), by: 2).map {
            ByteReader.uint16(bytes, offset + $0)
        }
        name = String(decoding: units, as: UTF16.self)
        type = bytes[offset + 66]
        left = ByteReader.uint32(bytes, offset + 68)
        right = ByteReader.uint32(bytes, offset + 72)
        child = ByteReader.uint32(bytes, offset + 76)
        classID = Data(bytes[(offset + 80)..<(offset + 96)])
        startSector = ByteReader.uint32(bytes, offset + 116)
        // Version 3 files leave the high half of the size to chance.
        let low = UInt64(ByteReader.uint32(bytes, offset + 120))
        let high = UInt64(ByteReader.uint32(bytes, offset + 124))
        size = isVersion4 ? low | high << 32 : low
    }
}

enum ByteReader {
    static func uint16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    static func uint32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }
}

private struct Parser {
    typealias Error = CompoundFile.FormatError

    let bytes: [UInt8]
    let sectorSize: Int
    let sectorCount: Int
    let isVersion4: Bool
    var fat: [UInt32] = []
    var miniFAT: [UInt32] = []
    var miniStream: [UInt8] = []
    var entries: [DirectoryEntry] = []

    init(bytes: [UInt8]) throws {
        guard bytes.count >= CompoundFile.headerSize, Array(bytes[0..<8]) == CompoundFile.signature else {
            throw Error(message: "The macro project is not a compound file.")
        }
        self.bytes = bytes
        let sectorShift = Int(ByteReader.uint16(bytes, 0x1E))
        guard sectorShift == 9 || sectorShift == 12, ByteReader.uint16(bytes, 0x20) == 6 else {
            throw Error(message: "The macro project uses an unsupported sector size.")
        }
        isVersion4 = sectorShift == 12
        sectorSize = 1 << sectorShift
        sectorCount = (bytes.count - CompoundFile.headerSize + sectorSize - 1) / sectorSize

        fat = try readFAT()
        let directory = try readChain(from: ByteReader.uint32(bytes, 0x30), size: nil)
        entries = stride(from: 0, through: directory.count - CompoundFile.directoryEntrySize,
                         by: CompoundFile.directoryEntrySize)
            .map { DirectoryEntry(directory, at: $0, isVersion4: isVersion4) }
        guard let rootEntry = entries.first, rootEntry.type == CompoundFile.EntryType.root.rawValue else {
            throw Error(message: "The macro project has no root storage.")
        }

        let miniFATSectors = Int(ByteReader.uint32(bytes, 0x40))
        if miniFATSectors > 0 {
            let raw = try readChain(from: ByteReader.uint32(bytes, 0x3C), size: miniFATSectors * sectorSize)
            miniFAT = stride(from: 0, to: raw.count, by: 4).map { ByteReader.uint32(raw, $0) }
        }
        if rootEntry.size > 0 {
            miniStream = try readChain(from: rootEntry.startSector, size: Int(rootEntry.size))
        }
    }

    private func offset(ofSector sector: UInt32) throws -> Int {
        guard Int(sector) < sectorCount else {
            throw Error(message: "The macro project names a sector past the end of the file.")
        }
        return CompoundFile.headerSize + Int(sector) * sectorSize
    }

    /// The DIFAT lists the sectors the FAT itself occupies: the first 109 in
    /// the header, the rest in a chain of DIFAT sectors.
    private func readFAT() throws -> [UInt32] {
        var fatSectors = (0..<CompoundFile.headerDIFATCount).map { ByteReader.uint32(bytes, 0x4C + $0 * 4) }
        let perDIFATSector = sectorSize / 4 - 1
        var difatSector = ByteReader.uint32(bytes, 0x44)
        var visited = 0
        while difatSector != CompoundFile.endOfChain, difatSector != CompoundFile.freeSector {
            guard visited < sectorCount else { throw Error(message: "The macro project's DIFAT loops.") }
            let start = try offset(ofSector: difatSector)
            fatSectors += (0..<perDIFATSector).map { ByteReader.uint32(bytes, start + $0 * 4) }
            difatSector = ByteReader.uint32(bytes, start + perDIFATSector * 4)
            visited += 1
        }
        var fat: [UInt32] = []
        for sector in fatSectors.prefix(Int(ByteReader.uint32(bytes, 0x2C))) where sector != CompoundFile.freeSector {
            let start = try offset(ofSector: sector)
            fat += (0..<(sectorSize / 4)).map { ByteReader.uint32(bytes, start + $0 * 4) }
        }
        return fat
    }

    /// Follows a chain through an allocation table, refusing loops.
    private func chain(from start: UInt32, in table: [UInt32]) throws -> [UInt32] {
        var sectors: [UInt32] = []
        var current = start
        while current != CompoundFile.endOfChain, current != CompoundFile.freeSector {
            guard Int(current) < table.count, sectors.count < table.count else {
                throw Error(message: "The macro project has a broken sector chain.")
            }
            sectors.append(current)
            current = table[Int(current)]
        }
        return sectors
    }

    /// A chain of regular sectors, cut to `size` when one is given.
    private func readChain(from start: UInt32, size: Int?) throws -> [UInt8] {
        var out: [UInt8] = []
        for sector in try chain(from: start, in: fat) {
            let begin = try offset(ofSector: sector)
            out += bytes[begin..<min(begin + sectorSize, bytes.count)]
            if let size, out.count >= size { break }
        }
        guard let size else { return out }
        guard out.count >= size else { throw Error(message: "A stream in the macro project is truncated.") }
        return Array(out.prefix(size))
    }

    private func readStream(_ entry: DirectoryEntry) throws -> Data {
        let size = Int(entry.size)
        guard size > 0 else { return Data() }
        guard size < CompoundFile.miniStreamCutoff else { return Data(try readChain(from: entry.startSector, size: size)) }
        var out: [UInt8] = []
        for sector in try chain(from: entry.startSector, in: miniFAT) {
            let begin = Int(sector) * CompoundFile.miniSectorSize
            guard begin < miniStream.count else {
                throw Error(message: "The macro project names a mini sector past the mini stream.")
            }
            out += miniStream[begin..<min(begin + CompoundFile.miniSectorSize, miniStream.count)]
            if out.count >= size { break }
        }
        guard out.count >= size else { throw Error(message: "A stream in the macro project is truncated.") }
        return Data(out.prefix(size))
    }

    func root() throws -> CompoundFile.Storage {
        var visited = Set<UInt32>()
        return try storage(for: entries[0], visited: &visited, depth: 0)
    }

    /// Siblings form a binary tree through their left and right links, and a
    /// storage names the root of its children's tree.
    private func siblings(from index: UInt32, visited: inout Set<UInt32>) -> [UInt32] {
        guard index != CompoundFile.noStream, Int(index) < entries.count, visited.insert(index).inserted else {
            return []
        }
        let entry = entries[Int(index)]
        return siblings(from: entry.left, visited: &visited) + [index] + siblings(from: entry.right, visited: &visited)
    }

    private func storage(
        for entry: DirectoryEntry, visited: inout Set<UInt32>, depth: Int
    ) throws -> CompoundFile.Storage {
        var storage = CompoundFile.Storage(name: entry.name, classID: entry.classID)
        guard depth < 32 else { return storage }
        for index in siblings(from: entry.child, visited: &visited) {
            let child = entries[Int(index)]
            switch CompoundFile.EntryType(rawValue: child.type) {
            case .stream:
                storage.streams.append(CompoundFile.Stream(name: child.name, data: try readStream(child)))
            case .storage:
                storage.storages.append(try self.storage(for: child, visited: &visited, depth: depth + 1))
            default:
                continue
            }
        }
        return storage
    }
}

// MARK: - Writing

extension CompoundFile {
    /// Serializes the tree as a version 3 file with 512-byte sectors, the
    /// layout Office itself writes for macro projects.
    func data() throws -> Data {
        var builder = Builder(root: root)
        return try builder.build()
    }
}

private struct Builder {
    typealias Error = CompoundFile.FormatError
    private static let sectorSize = 512

    /// One directory entry on its way out, with the sibling tree resolved.
    private struct Entry {
        var name: String
        var type: CompoundFile.EntryType
        var classID: Data
        var data: Data = Data()
        var left = CompoundFile.noStream
        var right = CompoundFile.noStream
        var child = CompoundFile.noStream
        var startSector = CompoundFile.endOfChain
    }

    private var entries: [Entry] = []

    init(root: CompoundFile.Storage) {
        entries.append(Entry(name: "Root Entry", type: .root, classID: root.classID))
        entries[0].child = add(children: root)
    }

    /// The order the format keeps siblings in: shorter names first, then by
    /// the upper-cased name.
    private static func precedes(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.uppercased().utf16)
        let right = Array(rhs.uppercased().utf16)
        return left.count != right.count ? left.count < right.count : left.lexicographicallyPrecedes(right)
    }

    /// Appends a storage's children and returns the root of their tree.
    private mutating func add(children storage: CompoundFile.Storage) -> UInt32 {
        var indices: [(name: String, index: Int)] = []
        for stream in storage.streams {
            entries.append(Entry(name: stream.name, type: .stream, classID: Data(count: 16), data: stream.data))
            indices.append((stream.name, entries.count - 1))
        }
        for child in storage.storages {
            entries.append(Entry(name: child.name, type: .storage, classID: child.classID))
            let index = entries.count - 1
            indices.append((child.name, index))
            entries[index].child = add(children: child)
        }
        indices.sort { Self.precedes($0.name, $1.name) }
        return link(indices.map(\.index)[...])
    }

    /// Hangs sorted siblings into a balanced tree. Every node is written
    /// black; readers follow the links and do not check the colouring.
    private mutating func link(_ sorted: ArraySlice<Int>) -> UInt32 {
        guard !sorted.isEmpty else { return CompoundFile.noStream }
        let middle = sorted.startIndex + sorted.count / 2
        let node = sorted[middle]
        entries[node].left = link(sorted[sorted.startIndex..<middle])
        entries[node].right = link(sorted[(middle + 1)...])
        return UInt32(node)
    }

    mutating func build() throws -> Data {
        let sectorSize = Self.sectorSize
        let miniSize = CompoundFile.miniSectorSize

        // Small streams share the mini stream, in 64-byte mini sectors.
        var miniStream: [UInt8] = []
        var miniFAT: [UInt32] = []
        for index in entries.indices where entries[index].type == .stream {
            let data = entries[index].data
            guard !data.isEmpty, data.count < CompoundFile.miniStreamCutoff else { continue }
            let first = UInt32(miniFAT.count)
            let count = (data.count + miniSize - 1) / miniSize
            for offset in 0..<count {
                miniFAT.append(offset == count - 1 ? CompoundFile.endOfChain : first + UInt32(offset) + 1)
            }
            entries[index].startSector = first
            miniStream += data
            miniStream += [UInt8](repeating: 0, count: count * miniSize - data.count)
        }

        // Everything else goes in regular sectors, laid end to end.
        var body: [UInt8] = []
        var fat: [UInt32] = []
        func place(_ payload: [UInt8]) -> UInt32 {
            guard !payload.isEmpty else { return CompoundFile.endOfChain }
            let first = UInt32(fat.count)
            let count = (payload.count + sectorSize - 1) / sectorSize
            for offset in 0..<count {
                fat.append(offset == count - 1 ? CompoundFile.endOfChain : first + UInt32(offset) + 1)
            }
            body += payload
            body += [UInt8](repeating: 0, count: count * sectorSize - payload.count)
            return first
        }
        for index in entries.indices where entries[index].type == .stream
            && entries[index].data.count >= CompoundFile.miniStreamCutoff {
            entries[index].startSector = place([UInt8](entries[index].data))
        }
        entries[0].startSector = place(miniStream)
        entries[0].data = Data(count: miniStream.count)

        var miniFATBytes: [UInt8] = []
        for value in miniFAT { miniFATBytes += Self.bytes(value) }
        let miniFATSectorCount = (miniFATBytes.count + sectorSize - 1) / sectorSize
        miniFATBytes += Self.bytes(CompoundFile.freeSector, repeating: miniFATSectorCount * 128 - miniFAT.count)
        let miniFATStart = place(miniFATBytes)

        var directory: [UInt8] = []
        for entry in entries { directory += Self.serialize(entry) }
        let perSector = sectorSize / CompoundFile.directoryEntrySize
        let padding = (perSector - entries.count % perSector) % perSector
        for _ in 0..<padding { directory += Self.emptyEntry() }
        let directoryStart = place(directory)

        // The FAT has to describe its own sectors too, so size it to fit.
        var fatSectorCount = 0
        while (fat.count + fatSectorCount + sectorSize / 4 - 1) / (sectorSize / 4) > fatSectorCount {
            fatSectorCount += 1
        }
        guard fatSectorCount <= CompoundFile.headerDIFATCount else {
            throw Error(message: "The macro project is too large to write.")
        }
        let fatStart = fat.count
        fat += [UInt32](repeating: CompoundFile.fatSectorMarker, count: fatSectorCount)
        fat += [UInt32](repeating: CompoundFile.freeSector, count: fatSectorCount * sectorSize / 4 - fat.count)
        var fatBytes: [UInt8] = []
        for value in fat { fatBytes += Self.bytes(value) }

        var header = CompoundFile.signature
        header += [UInt8](repeating: 0, count: 16)               // CLSID
        header += Self.bytes16(0x003E) + Self.bytes16(0x0003)    // minor, major version
        header += Self.bytes16(0xFFFE) + Self.bytes16(9) + Self.bytes16(6)
        header += [UInt8](repeating: 0, count: 6)
        header += Self.bytes(0)                                  // directory sectors (v3: 0)
        header += Self.bytes(UInt32(fatSectorCount))
        header += Self.bytes(directoryStart)
        header += Self.bytes(0)                                  // transaction signature
        header += Self.bytes(UInt32(CompoundFile.miniStreamCutoff))
        header += Self.bytes(miniFATSectorCount > 0 ? miniFATStart : CompoundFile.endOfChain)
        header += Self.bytes(UInt32(miniFATSectorCount))
        header += Self.bytes(CompoundFile.endOfChain)            // first DIFAT sector
        header += Self.bytes(0)                                  // DIFAT sectors
        for slot in 0..<CompoundFile.headerDIFATCount {
            header += Self.bytes(slot < fatSectorCount ? UInt32(fatStart + slot) : CompoundFile.freeSector)
        }
        return Data(header + body + fatBytes)
    }

    private static func serialize(_ entry: Entry) -> [UInt8] {
        var out: [UInt8] = []
        let units = Array(entry.name.utf16.prefix(31))
        for unit in units { out += bytes16(unit) }
        out += [UInt8](repeating: 0, count: 64 - units.count * 2)
        out += bytes16(UInt16((units.count + 1) * 2))
        out += [entry.type.rawValue, 1]                          // type, colour: black
        out += bytes(entry.left) + bytes(entry.right) + bytes(entry.child)
        out += entry.type == .stream ? [UInt8](repeating: 0, count: 16) : [UInt8](entry.classID.prefix(16))
        out += [UInt8](repeating: 0, count: 4 + 16)              // state bits, times
        switch entry.type {
        case .storage:
            out += bytes(0) + bytes(0)
        case .stream, .root:
            out += bytes(entry.data.isEmpty ? CompoundFile.endOfChain : entry.startSector)
            out += bytes(UInt32(entry.data.count))
        }
        out += bytes(0)                                          // high half of the size
        return out
    }

    private static func emptyEntry() -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 66)
        out += [0, 0]
        out += bytes(CompoundFile.noStream) + bytes(CompoundFile.noStream) + bytes(CompoundFile.noStream)
        out += [UInt8](repeating: 0, count: 16 + 4 + 16 + 4 + 8)
        return out
    }

    private static func bytes(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24)]
    }

    private static func bytes(_ value: UInt32, repeating count: Int) -> [UInt8] {
        Array([[UInt8]](repeating: bytes(value), count: max(0, count)).joined())
    }

    private static func bytes16(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8(value >> 8)]
    }
}
