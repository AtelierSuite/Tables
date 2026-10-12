import Foundation

/// The objects of an iWork document, read from the `.iwa` archives in its
/// `Index` folder, and the means to write those archives back with some
/// objects changed and every other byte as it was.
///
/// Every object is a Protocol Buffers message with a document-wide identifier
/// and a type number; objects point at one another by identifier. Each `.iwa`
/// is a run of Snappy-compressed chunks whose concatenation holds the objects
/// one after another, each preceded by a header describing it.
struct IWAArchive: @unchecked Sendable {
    enum Failure: Error {
        case corrupt
    }

    struct Object {
        var type: Int
        var message: ProtobufMessage
        /// The archive it was read from.
        var path: String
    }

    /// One object as stored: its header, a `TSP.ArchiveInfo`, and the bytes
    /// of the payloads the header describes.
    private struct Segment {
        var identifier: UInt64?
        var header: ProtobufMessage
        var range: Range<Int>
    }

    private struct File {
        var stream: [UInt8]
        var segments: [Segment]
    }

    private(set) var objects: [UInt64: Object] = [:]
    private var files: [String: File] = [:]
    /// Objects stored in more than one piece, a base and patches over it,
    /// which collaboration leaves behind. The reader sees only the base, so
    /// they are never written back.
    private(set) var patchedObjects: Set<UInt64> = []

    /// Reads every `.iwa` among a document's entries, keyed by path.
    ///
    /// One that won't decode is passed over rather than failing the whole
    /// document: some hold only collaboration history, which newer versions
    /// of Numbers compress differently. Whether what the reader needs is all
    /// there is for it to judge.
    init(entries: [String: Data]) {
        for (path, data) in entries where path.hasSuffix(".iwa") {
            guard let stream = try? Self.decompress(data), let segments = try? Self.segments(in: stream) else { continue }
            files[path] = File(stream: stream, segments: segments)
            for segment in segments {
                guard let identifier = segment.identifier else { continue }
                let infos = segment.header.messages(2)
                if infos.count > 1 || segment.header.bool(3) { patchedObjects.insert(identifier) }
                // The first message is the object itself. A type of zero marks
                // a patch to an object read earlier, which a reader after the
                // stored values can do without.
                guard let first = infos.first, let type = first.int(1), type != 0 else { continue }
                guard objects[identifier] == nil else {
                    patchedObjects.insert(identifier)
                    continue
                }
                let length = first.int(3) ?? 0
                let start = segment.range.upperBound - infos.reduce(0) { $0 + ($1.int(3) ?? 0) }
                guard let message = try? ProtobufMessage(stream[start..<(start + length)]) else { continue }
                objects[identifier] = Object(type: type, message: message, path: path)
            }
        }
    }

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

    var largestIdentifier: UInt64 {
        objects.keys.max() ?? 0
    }

    // MARK: - Writing

    /// An archive's bytes with `changes` made: changed objects take their
    /// new messages, new objects are appended, and all else is copied.
    ///
    /// `references` lists, for objects that gained references to others, the
    /// identifiers to add to their headers: Numbers keeps every object's
    /// outgoing references there, and drops objects nothing refers to.
    func data(
        for path: String,
        changing changes: [UInt64: ProtobufMessage],
        adding additions: [(identifier: UInt64, type: Int, message: ProtobufMessage)] = [],
        references: [UInt64: [UInt64]] = [:]
    ) -> Data {
        var stream: [UInt8] = []
        if let file = files[path] {
            for segment in file.segments {
                if let identifier = segment.identifier, let message = changes[identifier] {
                    var header = segment.header
                    var info = header.messages(2).first ?? ProtobufMessage()
                    let payload = message.encoded()
                    info.set(3, uint: UInt64(payload.count))
                    Self.addReferences(references[identifier] ?? [], to: &info)
                    header.set(2, messages: [info])
                    Self.appendSegment(header: header, payload: payload, to: &stream)
                } else {
                    stream += file.stream[segment.range]
                }
            }
        }
        for addition in additions {
            var info = ProtobufMessage()
            let payload = addition.message.encoded()
            info.set(1, uint: UInt64(addition.type))
            info.set(2, [.varint(1), .varint(0), .varint(5)])
            info.set(3, uint: UInt64(payload.count))
            Self.addReferences(references[addition.identifier] ?? [], to: &info)
            var header = ProtobufMessage()
            header.set(1, uint: addition.identifier)
            header.set(2, messages: [info])
            Self.appendSegment(header: header, payload: payload, to: &stream)
        }
        return Self.compress(stream)
    }

    private static func addReferences(_ identifiers: [UInt64], to info: inout ProtobufMessage) {
        let existing = info.uints(5)
        let added = identifiers.filter { !existing.contains($0) }
        guard !added.isEmpty else { return }
        info.set(5, (existing + added).map { .varint($0) })
    }

    private static func appendSegment(header: ProtobufMessage, payload: [UInt8], to stream: inout [UInt8]) {
        let headerBytes = header.encoded()
        ProtobufMessage.appendVarint(UInt64(headerBytes.count), to: &stream)
        stream += headerBytes
        stream += payload
    }

    // MARK: - Framing

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

    /// Splits a stream into chunks of 64 KiB, as Numbers writes them.
    private static func compress(_ stream: [UInt8]) -> Data {
        var output = Data()
        var start = 0
        repeat {
            let end = min(start + 65_536, stream.count)
            let block = Snappy.compress(stream[start..<end])
            output += [0, UInt8(block.count & 0xFF), UInt8(block.count >> 8 & 0xFF), UInt8(block.count >> 16 & 0xFF)]
            output += block
            start = end
        } while start < stream.count
        return output
    }

    /// Walks the decompressed stream: a varint-prefixed `TSP.ArchiveInfo`,
    /// then the payloads its `MessageInfo`s describe, over and over.
    private static func segments(in stream: [UInt8]) throws -> [Segment] {
        var segments: [Segment] = []
        var cursor = 0
        while cursor < stream.count {
            let start = cursor
            let headerLength = Int(try ProtobufMessage.readVarint(stream[...], at: &cursor))
            guard headerLength <= stream.count - cursor else { throw Failure.corrupt }
            let header = try ProtobufMessage(stream[cursor..<(cursor + headerLength)])
            cursor += headerLength
            for info in header.messages(2) {
                let length = info.int(3) ?? 0
                guard length >= 0, length <= stream.count - cursor else { throw Failure.corrupt }
                cursor += length
            }
            segments.append(Segment(identifier: header.uint(1), header: header, range: start..<cursor))
        }
        return segments
    }
}
