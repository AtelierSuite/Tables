import Foundation
import TablesEngine

/// The obfuscation [MS-OVBA] §2.4.3 applies to the protection fields of the
/// `PROJECT` stream — `CMG`, `DPB` and `GC` — which Office requires to be
/// present even in a project nobody has protected.
///
/// It is keyed on the project's id and protects nothing; it is here only so
/// a new project can say "unlocked, no password, visible" the way Office
/// expects to read it.
public enum VBAProjectEncryption {
    /// `projectID` is the `{…}` id from the `PROJECT` stream.
    public static func encrypt(_ data: [UInt8], projectID: String, seed: UInt8 = .random(in: 0...255)) -> [UInt8] {
        let version: UInt8 = 2
        let projectKey = key(for: projectID)
        var output: [UInt8] = [seed, seed ^ version, seed ^ projectKey]
        var unencrypted1 = projectKey
        var encrypted1 = seed ^ projectKey
        var encrypted2 = seed ^ version

        func emit(_ byte: UInt8) {
            let encrypted = byte ^ (encrypted2 &+ unencrypted1)
            output.append(encrypted)
            encrypted2 = encrypted1
            encrypted1 = encrypted
            unencrypted1 = byte
        }

        for _ in 0..<Int((seed & 6) / 2) { emit(7) }
        let length = UInt32(data.count)
        for shift in stride(from: 0, to: 32, by: 8) { emit(UInt8(length >> UInt32(shift) & 0xFF)) }
        for byte in data { emit(byte) }
        return output
    }

    /// The data back out, or nil when the bytes are not this scheme's.
    public static func decrypt(_ bytes: [UInt8]) -> (data: [UInt8], projectKey: UInt8)? {
        guard bytes.count >= 3 else { return nil }
        let seed = bytes[0]
        guard seed ^ bytes[1] == 2 else { return nil }
        let projectKey = seed ^ bytes[2]
        var unencrypted1 = projectKey
        var encrypted1 = bytes[2]
        var encrypted2 = bytes[1]
        var position = 3

        func next() -> UInt8? {
            guard position < bytes.count else { return nil }
            let encrypted = bytes[position]
            position += 1
            let byte = encrypted ^ (encrypted2 &+ unencrypted1)
            encrypted2 = encrypted1
            encrypted1 = encrypted
            unencrypted1 = byte
            return byte
        }

        for _ in 0..<Int((seed & 6) / 2) { guard next() != nil else { return nil } }
        var length: UInt32 = 0
        for shift in stride(from: 0, to: 32, by: 8) {
            guard let byte = next() else { return nil }
            length |= UInt32(byte) << UInt32(shift)
        }
        var data: [UInt8] = []
        for _ in 0..<length {
            guard let byte = next() else { return nil }
            data.append(byte)
        }
        return (data, projectKey)
    }

    /// The key is the low byte of the sum of the id's characters.
    public static func key(for projectID: String) -> UInt8 {
        UInt8(truncatingIfNeeded: projectID.utf8.reduce(0) { $0 + Int($1) })
    }

    public static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined()
    }

    public static func bytes(fromHex hex: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex), index < hex.endIndex {
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return [] }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}
