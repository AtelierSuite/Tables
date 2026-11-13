import Foundation

/// What a workbook says about itself: the core properties of
/// `docProps/core.xml` that a person can see and change, and a little of
/// `docProps/app.xml` worth showing beside them.
///
/// Every text property is empty when the file has none, which is how a person
/// clears one too. Only what differs from the file is written back, so
/// anything else the property parts hold — custom properties included —
/// survives a save exactly as it was read.
public struct DocumentProperties: Hashable, Sendable {
    public var title = ""
    /// `dc:creator`, which Excel calls the author.
    public var author = ""
    public var subject = ""
    public var keywords = ""
    public var category = ""
    /// `dc:description`, which Excel calls comments.
    public var comments = ""
    public var lastModifiedBy = ""
    public var created: Date?
    public var modified: Date?
    /// The application that wrote the file, from `docProps/app.xml`. Shown,
    /// never changed: it describes the file as it was found.
    public var application = ""
    /// The company the file was written for, from `docProps/app.xml`.
    public var company = ""

    public init() {}
}

extension Workbook {
    /// Brings the properties up to date for a save made at `date`.
    ///
    /// `author` is the name the app already knows the person by, if any; a
    /// save without one leaves the last author as the file had it rather
    /// than make one up. A workbook that has never had properties — one made
    /// in Tables — is given its creation time and, where known, its author.
    public mutating func stampDocumentProperties(savedAt date: Date, by author: String?) {
        let author = author?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        documentProperties.modified = date
        if !author.isEmpty { documentProperties.lastModifiedBy = author }
        guard DocumentPropertiesParts.corePropertiesPath(in: preservedPackage) == nil else { return }
        if documentProperties.created == nil { documentProperties.created = date }
        if documentProperties.author.isEmpty, !author.isEmpty { documentProperties.author = author }
    }
}
