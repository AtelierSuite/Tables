import Foundation

/// A link on a cell, as a worksheet's `<hyperlinks>` list holds it.
///
/// A link goes either outside the workbook — a web page, an email address, a
/// file — or to a place inside it: a cell or range, on this sheet or another,
/// or a defined name. Excel lets a link carry both, an outside address with a
/// place inside that document; both are kept.
public struct CellHyperlink: Hashable, Sendable {
    /// Where outside the workbook the link goes, as the file wrote it:
    /// `https://…`, `mailto:…`, or a path to another file.
    public var address: String?
    /// A place in the workbook, such as `Sheet2!A1`, `'Q1 Sales'!B2:C4` or a
    /// defined name. With an `address`, the place inside that document.
    public var location: String?
    /// The text the file says the cell shows. The cell's own value is what
    /// is drawn; this is kept for the round trip.
    public var display: String?
    /// The hint shown when hovering over the link.
    public var tooltip: String?

    public init(address: String? = nil, location: String? = nil, display: String? = nil, tooltip: String? = nil) {
        self.address = address
        self.location = location
        self.display = display
        self.tooltip = tooltip
    }

    /// The color Excel's built-in Hyperlink style gives a link's text.
    public static let textColorHex = "0563C1"

    /// What the link names, as a person would type it back in: the outside
    /// address, or the place in the workbook.
    public var target: String {
        if let address, !address.isEmpty {
            guard let location, !location.isEmpty else { return address }
            return address + "#" + location
        }
        return location ?? ""
    }

    /// A link from what a person typed: a place in `workbook` when it names
    /// one, otherwise an outside address. A bare domain is taken to be a web
    /// page and a bare email address an email, as Excel does. Nil for text
    /// that is empty once trimmed.
    public static func parse(_ text: String, in workbook: Workbook, from sheetID: Worksheet.ID?) -> CellHyperlink? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // A leading `#` is how Excel spells a place in the same document.
        if trimmed.hasPrefix("#") {
            let place = String(trimmed.dropFirst())
            return place.isEmpty ? nil : CellHyperlink(location: place)
        }
        if workbook.destination(ofLocation: trimmed, from: sheetID) != nil {
            return CellHyperlink(location: trimmed)
        }
        return CellHyperlink(address: externalAddress(trimmed))
    }

    /// An outside address with the scheme a person tends to leave off.
    static func externalAddress(_ text: String) -> String {
        if hasScheme(text) { return text }
        if !text.contains(where: \.isWhitespace), !text.contains("/"),
           let at = text.firstIndex(of: "@"), at != text.startIndex, text[text.index(after: at)...].contains(".") {
            return "mailto:" + text
        }
        if text.lowercased().hasPrefix("www.") || (!text.contains(where: \.isWhitespace) && looksLikeDomain(text)) {
            return "https://" + text
        }
        return text
    }

    /// `scheme:` per RFC 3986: a letter, then letters, digits, `+`, `-` or `.`.
    /// A Windows drive (`C:\`) is a single letter and is not a scheme.
    private static func hasScheme(_ text: String) -> Bool {
        guard let colon = text.firstIndex(of: ":") else { return false }
        let scheme = text[..<colon]
        guard scheme.count > 1, let first = scheme.first, first.isASCII, first.isLetter else { return false }
        return scheme.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) }
    }

    /// Endings that name a file beside the workbook rather than a domain.
    private static let fileExtensions: Set<String> = [
        "pdf", "xlsx", "xlsm", "xls", "csv", "txt", "docx", "doc", "pptx", "ppt", "numbers", "pages", "key",
        "png", "jpg", "jpeg", "gif", "htm", "html", "zip",
    ]

    /// `example.com`, `example.co.jp/path`: a dot, and something after it
    /// that could be a top-level domain.
    private static func looksLikeDomain(_ text: String) -> Bool {
        let host = text.split(separator: "/", maxSplits: 1).first.map(String.init) ?? text
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, let last = labels.last, last.count >= 2,
              last.allSatisfy({ $0.isASCII && $0.isLetter }),
              !fileExtensions.contains(last.lowercased()) else { return false }
        return labels.allSatisfy { !$0.isEmpty }
    }
}

/// Where following a link leads.
public enum HyperlinkDestination: Hashable, Sendable {
    /// An address outside the workbook, for the system to open.
    case external(String)
    /// A cell or range in the workbook.
    case cells(sheet: Worksheet.ID, range: CellRange)
}

extension Workbook {
    /// Where a place in the workbook lies: `A1`, `B2:C4`, `Sheet2!A1`,
    /// `'Q1 Sales'!A1` or a defined name naming a range. `sheetID` is the
    /// sheet the link is on, which a place without a sheet means. Nil for a
    /// place that names nothing in this workbook.
    public func destination(ofLocation location: String, from sheetID: Worksheet.ID?) -> (sheet: Worksheet.ID, range: CellRange)? {
        destination(ofLocation: location, from: sheetID, depth: 0)
    }

    private func destination(
        ofLocation location: String, from sheetID: Worksheet.ID?, depth: Int
    ) -> (sheet: Worksheet.ID, range: CellRange)? {
        var text = location.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("=") { text.removeFirst() }
        guard !text.isEmpty, depth < 4 else { return nil }

        var sheet = sheetID.flatMap { self[$0] } ?? sheets.first
        var reference = text
        if let bang = text.lastIndex(of: "!") {
            var name = String(text[..<bang])
            if name.count >= 2, name.hasPrefix("'"), name.hasSuffix("'") {
                name = String(name.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
            }
            guard let named = self.sheet(named: name) else { return nil }
            sheet = named
            reference = String(text[text.index(after: bang)...])
        }
        guard let sheet, !sheet.isChartSheet else { return nil }
        if let range = CellRange(a1Range: reference)?.normalized,
           range.end.row < Worksheet.maximumRowCount, range.end.column < Worksheet.maximumColumnCount {
            return (sheet.id, range)
        }
        // Only a bare name can be a defined name; `Sheet2!Total` is one
        // scoped to that sheet.
        guard reference.first.map({ $0.isLetter || $0 == "_" || $0 == "\\" }) == true,
              let name = definedName(reference, visibleFrom: sheet.id) else { return nil }
        return destination(ofLocation: name.formula, from: sheet.id, depth: depth + 1)
    }

    /// Where following `link`, on the sheet `sheetID`, leads. Nil when it
    /// names a place this workbook does not have, or nothing at all.
    public func destination(of link: CellHyperlink, from sheetID: Worksheet.ID?) -> HyperlinkDestination? {
        if let address = link.address, !address.isEmpty { return .external(link.target) }
        guard let location = link.location,
              let place = destination(ofLocation: location, from: sheetID) else { return nil }
        return .cells(sheet: place.sheet, range: place.range)
    }

    /// The link a cell follows: the one set on it, or for a cell whose
    /// formula is a `HYPERLINK` call, the address that call names.
    public func hyperlink(at address: CellAddress, onSheet sheetID: Worksheet.ID) -> CellHyperlink? {
        guard let index = index(of: sheetID) else { return nil }
        let sheet = sheets[index]
        if let link = sheet.hyperlinks[address] { return link }
        guard let formula = sheet.cells[address]?.formula,
              let argument = Self.hyperlinkArgument(of: formula) else { return nil }
        guard case .text(let target) = CalculationEngine.preview(formula: argument, in: self, sheetIndex: index),
              !target.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        // `HYPERLINK("#Sheet2!A1")` is a place in this workbook.
        if target.hasPrefix("#") { return CellHyperlink(location: String(target.dropFirst())) }
        return CellHyperlink(address: target)
    }

    /// The first argument's text of a formula that is one `HYPERLINK` call.
    static func hyperlinkArgument(of formula: String) -> String? {
        var body = Substring(formula.trimmingCharacters(in: .whitespaces))
        if body.hasPrefix("=") { body = body.dropFirst() }
        for prefix in ["_xlfn.", "@"] where body.lowercased().hasPrefix(prefix.lowercased()) {
            body = body.dropFirst(prefix.count)
        }
        let name = "HYPERLINK("
        guard body.uppercased().hasPrefix(name) else { return nil }
        body = body.dropFirst(name.count)

        var depth = 0
        var inString = false
        var inQuotedName = false
        var argument = ""
        var index = body.startIndex
        while index < body.endIndex {
            let character = body[index]
            if inString {
                if character == "\"" { inString = false }
            } else if inQuotedName {
                if character == "'" { inQuotedName = false }
            } else {
                switch character {
                case "\"": inString = true
                case "'": inQuotedName = true
                case "(", "{", "[": depth += 1
                case ")", "}", "]":
                    if depth == 0 {
                        // The call has to be the whole formula.
                        let rest = body[body.index(after: index)...].trimmingCharacters(in: .whitespaces)
                        guard rest.isEmpty else { return nil }
                        return argument.trimmingCharacters(in: .whitespaces).isEmpty ? nil : argument
                    }
                    depth -= 1
                case ",", ";":
                    if depth == 0 {
                        return argument.trimmingCharacters(in: .whitespaces).isEmpty ? nil : argument
                    }
                default: break
                }
            }
            argument.append(character)
            index = body.index(after: index)
        }
        return nil
    }
}
