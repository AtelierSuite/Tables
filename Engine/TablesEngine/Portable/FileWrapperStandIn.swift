#if !canImport(Darwin)
import Foundation

/// The part of Foundation's FileWrapper the Numbers reader and writer use, for
/// platforms without it such as WebAssembly. A Numbers package arrives there as
/// an in-memory tree of files rather than a folder on disk.
open class FileWrapper {
    public private(set) var regularFileContents: Data?
    public private(set) var fileWrappers: [String: FileWrapper]?
    public var preferredFilename: String?
    public var filename: String?

    public var isDirectory: Bool { fileWrappers != nil }
    public var isRegularFile: Bool { regularFileContents != nil }

    public init(regularFileWithContents contents: Data) {
        regularFileContents = contents
    }

    public init(directoryWithFileWrappers children: [String: FileWrapper]) {
        fileWrappers = children
        for (name, child) in children where child.preferredFilename == nil {
            child.preferredFilename = name
        }
    }
}
#endif
