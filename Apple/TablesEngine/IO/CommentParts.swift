import CryptoKit
import Foundation

/// Reading and writing the package parts behind cell comments.
///
/// A note lives in a `comments` part, with a shape in the sheet's VML drawing
/// that Excel draws it with. A threaded comment lives in a `threadedComments`
/// part whose authors are listed in the workbook's `persons` part; Excel also
/// writes each one as a note, so older versions can read it.
public enum CommentParts {
    public static let commentsType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/comments"
    public static let vmlType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/vmlDrawing"
    public static let threadType = "http://schemas.microsoft.com/office/2017/10/relationships/threadedComment"
    public static let personType = "http://schemas.microsoft.com/office/2017/10/relationships/person"
    public static let commentsContentType = "application/vnd.openxmlformats-officedocument.spreadsheetml.comments+xml"
    public static let vmlContentType = "application/vnd.openxmlformats-officedocument.vmlDrawing"
    public static let threadContentType = "application/vnd.ms-excel.threadedcomments+xml"
    public static let personContentType = "application/vnd.ms-excel.person+xml"

    // MARK: - Reading

    /// What a sheet's comment parts held, and which parts and relationships
    /// were read so the package plan can leave them to be written afresh.
    public struct SheetComments: Sendable {
        public var comments: [CellAddress: CellComment] = [:]
        public var preservedShapes: String?
        /// The `<v:shape>` of each form control, in drawing order.
        public var controlShapes: [String] = []
        public var preservedShapeRelationships: Data?
        /// Relationship ids in the sheet's `_rels` that the writer replaces.
        public var relationshipIDs: Set<String> = []
        public var parts: Set<String> = []
        /// Parts the kept shapes point at, which must stay in the package.
        public var shapeTargets: [String] = []
    }

    /// Display names by person id, from the workbook's persons part.
    public static func persons(entries: [String: Data], workbookRelationships: [XLSXReader.PackagePreservation.RelationshipEntry])
        -> (names: [String: String], path: String?) {
        guard let entry = workbookRelationships.first(where: { $0.type == personType }),
              let path = XLSXReader.PackagePreservation.packagePath(of: entry, relativeTo: "xl"),
              let data = entries[path], let root = try? XMLLite.parse(data) else { return ([:], nil) }
        var names: [String: String] = [:]
        for person in root.children(named: "person") {
            guard let id = person.attribute("id") else { continue }
            names[id] = person.attribute("displayName") ?? ""
        }
        return (names, path)
    }

    public static func read(
        sheetPath: String, legacyDrawingID: String?, entries: [String: Data], persons: [String: String]
    ) -> SheetComments {
        var result = SheetComments()
        let directory = XLSXReader.PackagePreservation.directory(of: sheetPath)
        let relationships = XLSXReader.PackagePreservation.relationships(
            in: entries[XLSXReader.PackagePreservation.relationshipsPath(for: sheetPath)])

        var notes: [CellAddress: CellComment] = [:]
        var threads: [CellAddress: CellComment] = [:]
        var visibleNotes: Set<CellAddress> = []

        for entry in relationships {
            guard let id = entry.id,
                  let path = XLSXReader.PackagePreservation.packagePath(of: entry, relativeTo: directory) else { continue }
            switch entry.type {
            case commentsType:
                result.relationshipIDs.insert(id)
                result.parts.insert(path)
                if let data = entries[path] { notes.merge(readNotes(data)) { $1 } }
            case threadType:
                result.relationshipIDs.insert(id)
                result.parts.insert(path)
                if let data = entries[path] { threads.merge(readThreads(data, persons: persons)) { $1 } }
            case vmlType where id == legacyDrawingID:
                result.relationshipIDs.insert(id)
                result.parts.insert(path)
                guard let data = entries[path] else { continue }
                let drawing = String(decoding: data, as: UTF8.self)
                let shapes = splitShapes(drawing)
                visibleNotes = shapes.visibleNotes
                result.controlShapes = shapes.controls
                if !shapes.kept.isEmpty || !shapes.controls.isEmpty {
                    result.preservedShapes = shapes.kept.isEmpty ? nil : shapes.kept
                    let relationshipsPath = XLSXReader.PackagePreservation.relationshipsPath(for: path)
                    if let payload = entries[relationshipsPath] {
                        result.preservedShapeRelationships = payload
                        result.shapeTargets = XLSXReader.PackagePreservation.relationships(in: payload).compactMap {
                            XLSXReader.PackagePreservation.packagePath(
                                of: $0, relativeTo: XLSXReader.PackagePreservation.directory(of: path))
                        }
                    }
                }
            default:
                continue
            }
        }
        // A threaded comment's note is only its stand-in for older Excel.
        result.comments = notes.merging(threads) { _, thread in thread }
        for address in visibleNotes where result.comments[address]?.kind == .note {
            result.comments[address]?.isAlwaysVisible = true
        }
        return result
    }

    private static func readNotes(_ data: Data) -> [CellAddress: CellComment] {
        guard let root = try? XMLLite.parse(data) else { return [:] }
        let authors = root.firstChild(named: "authors")?.children(named: "author").map(\.text) ?? []
        var notes: [CellAddress: CellComment] = [:]
        for comment in root.firstChild(named: "commentList")?.children(named: "comment") ?? [] {
            guard let ref = comment.attribute("ref"), let address = CellAddress(a1: ref) else { continue }
            let authorIndex = comment.attribute("authorId").flatMap(Int.init) ?? 0
            let author = authors.indices.contains(authorIndex) ? authors[authorIndex] : ""
            let text = comment.firstChild(named: "text").map(richText) ?? ""
            notes[address] = CellComment(kind: .note, entries: [
                CellComment.Entry(id: comment.attribute("uid") ?? CellComment.newIdentifier(), author: author, text: text),
            ])
        }
        return notes
    }

    /// The text of a rich text element: its runs in order, phonetic guides left out.
    private static func richText(_ element: XMLElement) -> String {
        if element.name == "rPh" || element.name == "phoneticPr" { return "" }
        if element.name == "t" { return element.text }
        return element.children.map(richText).joined()
    }

    private static func readThreads(_ data: Data, persons: [String: String]) -> [CellAddress: CellComment] {
        guard let root = try? XMLLite.parse(data) else { return [:] }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate,
                                   .withFractionalSeconds]
        var roots: [String: (CellAddress, CellComment)] = [:]
        var order: [String] = []
        var replies: [(parent: String, entry: CellComment.Entry)] = []
        for element in root.children(named: "threadedComment") {
            guard let ref = element.attribute("ref"), let address = CellAddress(a1: ref),
                  let id = element.attribute("id") else { continue }
            let dateText = element.attribute("dT") ?? ""
            let date = formatter.date(from: dateText) ?? ISO8601DateFormatter().date(from: dateText + "Z")
                ?? ISO8601DateFormatter().date(from: dateText)
            let entry = CellComment.Entry(
                id: id, author: persons[element.attribute("personId") ?? ""] ?? "",
                text: element.firstChild(named: "text")?.text ?? "", date: date)
            if let parent = element.attribute("parentId") {
                replies.append((parent, entry))
            } else {
                roots[id] = (address, CellComment(kind: .thread, entries: [entry],
                                                  isResolved: element.attribute("done") == "1"))
                order.append(id)
            }
        }
        for reply in replies { roots[reply.parent]?.1.entries.append(reply.entry) }
        var threads: [CellAddress: CellComment] = [:]
        for id in order { if let (address, thread) = roots[id] { threads[address] = thread } }
        return threads
    }

    /// Splits a VML drawing into the notes it draws, which are written afresh,
    /// the form controls, which are read into the model, and everything
    /// else, kept verbatim.
    private static func splitShapes(_ drawing: String)
        -> (kept: String, controls: [String], visibleNotes: Set<CellAddress>) {
        var kept = ""
        var controls: [String] = []
        var visible: Set<CellAddress> = []
        for block in blocks(in: drawing, tag: "v:shapetype") where !block.contains("_x0000_t202") {
            kept += block
        }
        for block in blocks(in: drawing, tag: "v:shape") {
            guard block.contains("ObjectType=\"Note\"") else {
                if block.contains("<x:ClientData") { controls.append(block) } else { kept += block }
                continue
            }
            if block.contains("<x:Visible"), let row = number(after: "<x:Row>", in: block),
               let column = number(after: "<x:Column>", in: block) {
                visible.insert(CellAddress(row: row, column: column))
            }
        }
        return (kept, controls, visible)
    }

    /// Every `<tag …>…</tag>` (or self-closed `<tag …/>`) block in the text.
    public static func blocks(in text: String, tag: String) -> [String] {
        var result: [String] = []
        var searchStart = text.startIndex
        while let open = text.range(of: "<" + tag, range: searchStart..<text.endIndex) {
            // `<v:shape` must not match `<v:shapetype`.
            let next = open.upperBound < text.endIndex ? text[open.upperBound] : ">"
            guard next == " " || next == ">" || next == "/" || next == "\n" || next == "\t" else {
                searchStart = open.upperBound
                continue
            }
            guard let headEnd = text.range(of: ">", range: open.upperBound..<text.endIndex) else { break }
            if text[text.index(before: headEnd.lowerBound)] == "/" {
                result.append(String(text[open.lowerBound..<headEnd.upperBound]))
                searchStart = headEnd.upperBound
                continue
            }
            guard let close = text.range(of: "</" + tag + ">", range: headEnd.upperBound..<text.endIndex) else { break }
            result.append(String(text[open.lowerBound..<close.upperBound]))
            searchStart = close.upperBound
        }
        return result
    }

    private static func number(after marker: String, in text: String) -> Int? {
        guard let start = text.range(of: marker) else { return nil }
        let digits = text[start.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }

    // MARK: - Writing

    /// A stable id for an author, so saving twice does not churn the file.
    public static func personID(for author: String) -> String {
        let digest = SHA256.hash(data: Data(author.utf8))
        let hex = digest.prefix(16).map { String(format: "%02X", $0) }.joined()
        let parts = [hex.prefix(8), hex.dropFirst(8).prefix(4), hex.dropFirst(12).prefix(4),
                     hex.dropFirst(16).prefix(4), hex.dropFirst(20).prefix(12)]
        return "{" + parts.joined(separator: "-") + "}"
    }

    private static func timestamp(_ date: Date?) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SS"
        return formatter.string(from: date ?? Date())
    }

    private static func ordered(_ comments: [CellAddress: CellComment]) -> [(CellAddress, CellComment)] {
        comments.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    /// The legacy comments part: every note, and a stand-in note for each thread.
    public static func commentsPart(_ comments: [CellAddress: CellComment]) -> String {
        var authors: [String] = []
        func authorIndex(_ name: String) -> Int {
            if let index = authors.firstIndex(of: name) { return index }
            authors.append(name)
            return authors.count - 1
        }
        var list = ""
        for (address, comment) in ordered(comments) {
            let author: String
            let text: String
            let uid = comment.entries.first?.id ?? CellComment.newIdentifier()
            switch comment.kind {
            case .note:
                author = comment.author
                text = comment.text
            case .thread:
                author = "tc=" + uid
                var body = "[Threaded comment]\n\nYour version of Excel allows you to read this threaded comment; "
                    + "however, any edits to it will get removed if the file is opened in a newer version of Excel. "
                    + "Learn more: https://go.microsoft.com/fwlink/?linkid=870924\n\nComment:\n    " + comment.text
                for reply in comment.entries.dropFirst() { body += "\nReply:\n    " + reply.text }
                text = body
            }
            list += "<comment ref=\"\(address.a1)\" authorId=\"\(authorIndex(author))\" shapeId=\"0\""
            list += " xr:uid=\"\(XMLLite.escape(uid))\"><text><t xml:space=\"preserve\">\(XMLLite.escape(text))</t></text></comment>"
        }
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        xml += "<comments xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\""
        xml += " xmlns:mc=\"http://schemas.openxmlformats.org/markup-compatibility/2006\" mc:Ignorable=\"xr\""
        xml += " xmlns:xr=\"http://schemas.microsoft.com/office/spreadsheetml/2014/revision\"><authors>"
        xml += authors.map { "<author>\(XMLLite.escape($0))</author>" }.joined()
        xml += "</authors><commentList>" + list + "</commentList></comments>"
        return xml
    }

    /// The threaded comments part, or nil when the sheet has no conversations.
    public static func threadsPart(_ comments: [CellAddress: CellComment]) -> String? {
        let threads = ordered(comments).filter { $0.1.kind == .thread }
        guard !threads.isEmpty else { return nil }
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        xml += "<ThreadedComments xmlns=\"http://schemas.microsoft.com/office/spreadsheetml/2018/threadedcomments\""
        xml += " xmlns:x=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">"
        for (address, thread) in threads {
            guard let first = thread.entries.first else { continue }
            for (index, entry) in thread.entries.enumerated() {
                xml += "<threadedComment ref=\"\(address.a1)\" dT=\"\(timestamp(entry.date))\""
                xml += " personId=\"\(personID(for: entry.author))\" id=\"\(XMLLite.escape(entry.id))\""
                if index > 0 { xml += " parentId=\"\(XMLLite.escape(first.id))\"" }
                if index == 0, thread.isResolved { xml += " done=\"1\"" }
                xml += "><text>\(XMLLite.escape(entry.text))</text></threadedComment>"
            }
        }
        xml += "</ThreadedComments>"
        return xml
    }

    /// The persons part listing every author of a threaded comment.
    public static func personsPart(_ authors: [String]) -> String {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        xml += "<personList xmlns=\"http://schemas.microsoft.com/office/spreadsheetml/2018/threadedcomments\""
        xml += " xmlns:x=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">"
        for author in authors {
            xml += "<person displayName=\"\(XMLLite.escape(author))\" id=\"\(personID(for: author))\""
            xml += " userId=\"\(XMLLite.escape(author))\" providerId=\"None\"/>"
        }
        xml += "</personList>"
        return xml
    }

    /// The VML drawing: a hidden sticky note for each comment, beside its cell,
    /// plus the form controls and whatever other shapes the file had.
    public static func vmlPart(
        _ comments: [CellAddress: CellComment], preservedShapes: String?, controlShapes: [String] = [],
        sheetNumber: Int
    ) -> String {
        // Shape ids come in blocks of 1024 named by `o:idmap`; ours take a
        // block clear of any the kept shapes use.
        let keptIDs = (blocks(in: preservedShapes ?? "", tag: "v:shape") + controlShapes).compactMap { block -> Int? in
            guard let range = block.range(of: "_x0000_s") else { return nil }
            return Int(block[range.upperBound...].prefix { $0.isNumber })
        }
        let keptBlocks = Set(keptIDs.map { $0 / 1024 })
        var block = max(1, sheetNumber)
        while keptBlocks.contains(block) { block += 1 }
        let idmap = (keptBlocks.union([block])).sorted().map(String.init).joined(separator: ",")

        var xml = "<xml xmlns:v=\"urn:schemas-microsoft-com:vml\" xmlns:o=\"urn:schemas-microsoft-com:office:office\""
        xml += " xmlns:x=\"urn:schemas-microsoft-com:office:excel\">"
        xml += "<o:shapelayout v:ext=\"edit\"><o:idmap v:ext=\"edit\" data=\"\(idmap)\"/></o:shapelayout>"
        xml += "<v:shapetype id=\"_x0000_t202\" coordsize=\"21600,21600\" o:spt=\"202\" path=\"m,l,21600r21600,l21600,xe\">"
        xml += "<v:stroke joinstyle=\"miter\"/><v:path gradientshapeok=\"t\" o:connecttype=\"rect\"/></v:shapetype>"
        xml += preservedShapes ?? ""
        xml += controlShapes.joined()
        for (offset, (address, comment)) in ordered(comments).enumerated() {
            let visible = comment.kind == .note && comment.isAlwaysVisible
            let id = block * 1024 + 1 + offset
            xml += "<v:shape id=\"_x0000_s\(id)\" type=\"#_x0000_t202\""
            xml += " style=\"position:absolute;margin-left:59.25pt;margin-top:1.5pt;width:108pt;height:59.25pt;"
            xml += "z-index:\(offset + 1);visibility:\(visible ? "visible" : "hidden")\""
            xml += " fillcolor=\"#ffffe1\" o:insetmode=\"auto\"><v:fill color2=\"#ffffe1\"/>"
            xml += "<v:shadow on=\"t\" color=\"black\" obscured=\"t\"/><v:path o:connecttype=\"none\"/>"
            xml += "<v:textbox style=\"mso-direction-alt:auto\"><div style=\"text-align:left\"></div></v:textbox>"
            let top = max(0, address.row - 1)
            xml += "<x:ClientData ObjectType=\"Note\"><x:MoveWithCells/><x:SizeWithCells/>"
            xml += "<x:Anchor>\(address.column + 1), 15, \(top), 10, \(address.column + 3), 15, \(top + 4), 4</x:Anchor>"
            xml += "<x:AutoFill>False</x:AutoFill><x:Row>\(address.row)</x:Row><x:Column>\(address.column)</x:Column>"
            if visible { xml += "<x:Visible/>" }
            xml += "</x:ClientData></v:shape>"
        }
        xml += "</xml>"
        return xml
    }
}

/// Where each sheet's comment parts go in a saved package, worked out up front
/// because the content types and relationships have to agree on it.
public struct CommentPlan: Sendable {
    public struct SheetParts: Sendable {
        public var vmlPath: String
        public var commentsPath: String?
        public var threadsPath: String?
    }

    public private(set) var sheets: [Worksheet.ID: SheetParts] = [:]
    public private(set) var personsPath: String?
    /// Everyone who wrote in a threaded comment, for the persons part.
    public private(set) var authors: [String] = []

    public var generatedPartNames: Set<String> {
        var names = Set(sheets.values.flatMap { [$0.vmlPath, $0.commentsPath, $0.threadsPath].compactMap { $0 } }
            .map { "/" + $0 })
        if let personsPath { names.insert("/" + personsPath) }
        return names
    }

    public init(workbook: Workbook, preserved: PreservedPackage) {
        var taken = Set(preserved.parts.keys)
        func allocate(_ stem: String, _ ext: String) -> String {
            var number = 1
            while taken.contains("\(stem)\(number).\(ext)") { number += 1 }
            let path = "\(stem)\(number).\(ext)"
            taken.insert(path)
            return path
        }
        for sheet in workbook.sheets where !sheet.isChartSheet {
            guard !sheet.comments.isEmpty || sheet.preservedVMLShapes != nil || !sheet.formControls.isEmpty
            else { continue }
            let hasThreads = sheet.comments.values.contains { $0.kind == .thread }
            sheets[sheet.id] = SheetParts(
                vmlPath: allocate("xl/drawings/vmlDrawing", "vml"),
                commentsPath: sheet.comments.isEmpty ? nil : allocate("xl/comments", "xml"),
                threadsPath: hasThreads ? allocate("xl/threadedComments/threadedComment", "xml") : nil)
            for comment in sheet.comments.values where comment.kind == .thread {
                for entry in comment.entries where !authors.contains(entry.author) { authors.append(entry.author) }
            }
        }
        if !authors.isEmpty { personsPath = "xl/persons/person.xml" }
    }
}
