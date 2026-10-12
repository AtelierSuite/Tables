import Foundation

/// The objects of an iWork document, read from the `.iwa` archives in its
/// `Index` folder.
///
/// Every object is a Protocol Buffers message with a document-wide identifier
/// and a type number; objects point at one another by identifier. Each `.iwa`
/// is a run of Snappy-compressed chunks whose concatenation holds the objects
/// one after another, each preceded by a header describing it.
struct IWAArchive {
    enum Failure: Error {
        case corrupt
    }

    struct Object {
        var type: Int
        var message: ProtobufMessage
    }

    private(set) var objects: [UInt64: Object] = [:]

    /// Reads every `.iwa` among a document's entries, keyed by path.
    ///
    /// One that won't decode is passed over rather than failing the whole
    /// document: some hold only collaboration history, which newer versions
    /// of Numbers compress differently. Whether what the reader needs is all
    /// there is for it to judge.
    init(entries: [String: Data]) {
        for (path, data) in entries where path.hasSuffix(".iwa") {
            var archive = IWAArchive()
            guard (try? archive.read(Self.decompress(data))) != nil else { continue }
            objects.merge(archive.objects) { current, _ in current }
        }
    }

    private init() {}

    subscript(identifier: UInt64) -> Object? {
        objects[identifier]
    }

    /// The object a `TSP.Reference` message points at.
    subscript(reference: ProtobufMessage?) -> Object? {
        reference?.uint(1).flatMap { objects[$0] }
    }

    func identifiers(ofType type: Int) -> [UInt64] {
        objects.filter { $0.value.type == type }.map(\.key).sorted()
    }

    /// Joins an archive's chunks back into one stream. Each chunk is a zero
    /// byte, a three-byte little-endian length and that many bytes of Snappy.
    private static func decompress(_ data: Data) throws -> [UInt8] {
        let bytes = [UInt8](data)
        var output: [UInt8] = []
        var cursor = 0
        while cursor < bytes.count {
            guard cursor + 4 <= bytes.count, bytes[cursor] == 0 else { throw Failure.corrupt }
            let length = Int(bytes[cursor + 1]) | Int(bytes[cursor + 2]) << 8 | Int(bytes[cursor + 3]) << 16
            let start = cursor + 4
            guard start + length <= bytes.count else { throw Failure.corrupt }
            output.append(contentsOf: try Snappy.decompress(bytes[start..<(start + length)]))
            cursor = start + length
        }
        return output
    }

    /// Walks the decompressed stream: a varint-prefixed `TSP.ArchiveInfo`,
    /// then the payloads its `MessageInfo`s describe, over and over.
    private mutating func read(_ stream: [UInt8]) throws {
        var cursor = 0
        while cursor < stream.count {
            let headerLength = Int(try ProtobufMessage.readVarint(stream[...], at: &cursor))
            guard headerLength <= stream.count - cursor else { throw Failure.corrupt }
            let info = try ProtobufMessage(stream[cursor..<(cursor + headerLength)])
            cursor += headerLength

            let messageInfos = info.messages(2)
            var payloads: [(type: Int, bytes: ArraySlice<UInt8>)] = []
            for messageInfo in messageInfos {
                let length = messageInfo.int(3) ?? 0
                guard length >= 0, length <= stream.count - cursor else { throw Failure.corrupt }
                payloads.append((messageInfo.int(1) ?? 0, stream[cursor..<(cursor + length)]))
                cursor += length
            }
            // The first message is the object itself. A type of zero marks a
            // patch to an object read earlier, made during collaboration,
            // which a reader after the stored values can do without.
            guard let identifier = info.uint(1), let first = payloads.first, first.type != 0 else { continue }
            objects[identifier] = Object(type: first.type, message: try ProtobufMessage(first.bytes))
        }
    }
}
