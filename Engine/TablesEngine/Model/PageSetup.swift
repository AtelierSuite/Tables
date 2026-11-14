import Foundation

/// How a sheet prints: its paper, orientation, scale, margins, and the text
/// at the head and foot of each page.
///
/// The file keeps these in four worksheet children — `<pageSetup>`,
/// `<printOptions>`, `<pageMargins>` and `<headerFooter>` — which Tables
/// carries through a save as it found them. This is a view onto those
/// fragments: reading parses them, and writing changes only the attributes
/// that differ, so everything else in them stays as the file had it.
public struct PageSetup: Equatable, Sendable {
    public enum Orientation: String, CaseIterable, Sendable {
        case portrait, landscape
    }

    /// Distances from the paper's edges, in inches, as the file gives them.
    public struct Margins: Equatable, Sendable {
        public var left = 0.7
        public var right = 0.7
        public var top = 0.75
        public var bottom = 0.75
        /// From the paper's top edge to the header.
        public var header = 0.3
        /// From the paper's bottom edge to the footer.
        public var footer = 0.3

        public init() {}
    }

    public var orientation = Orientation.portrait
    /// Excel's number for the paper, or nil where the file leaves it to the
    /// printer.
    public var paperSize: Int?
    /// Percent of full size, used unless the sheet is fitted to pages.
    public var scale = 100
    /// Whether the sheet is shrunk to fit `fitWide` pages across and
    /// `fitTall` pages down, rather than printed at `scale`.
    public var fitsToPages = false
    /// Pages across when fitted. Zero is as many as it takes.
    public var fitWide = 1
    /// Pages down when fitted. Zero is as many as it takes.
    public var fitTall = 1
    public var margins = Margins()
    public var printsGridlines = false
    public var centersHorizontally = false
    public var centersVertically = false
    public var header = HeaderFooterText()
    public var footer = HeaderFooterText()

    public init() {}

    public static let scaleRange = 10...400
}

/// A paper Excel knows by number.
public struct PaperSize: Hashable, Sendable {
    /// The `paperSize` the file names it by.
    public var code: Int
    public var name: String
    /// Upright, in points.
    public var width: Double
    public var height: Double

    public static let known: [PaperSize] = [
        PaperSize(code: 1, name: "Letter", width: 612, height: 792),
        PaperSize(code: 5, name: "Legal", width: 612, height: 1008),
        PaperSize(code: 3, name: "Tabloid", width: 792, height: 1224),
        PaperSize(code: 7, name: "Executive", width: 522, height: 756),
        PaperSize(code: 8, name: "A3", width: 842, height: 1191),
        PaperSize(code: 9, name: "A4", width: 595, height: 842),
        PaperSize(code: 11, name: "A5", width: 420, height: 595),
        PaperSize(code: 12, name: "B4 (JIS)", width: 729, height: 1032),
        PaperSize(code: 13, name: "B5 (JIS)", width: 516, height: 729),
    ]

    public static func known(code: Int) -> PaperSize? { known.first { $0.code == code } }
}

/// The text of a header or a footer: what sits at the left, in the middle
/// and at the right, each still holding Excel's `&` codes.
public struct HeaderFooterText: Equatable, Sendable {
    public var left = ""
    public var center = ""
    public var right = ""

    public init(left: String = "", center: String = "", right: String = "") {
        self.left = left
        self.center = center
        self.right = right
    }

    public var isEmpty: Bool { left.isEmpty && center.isEmpty && right.isEmpty }

    /// What stands in for the codes on one printed page.
    public struct Fields: Equatable, Sendable {
        public var page: Int
        public var pageCount: Int
        public var date: String
        public var time: String
        public var fileName: String
        public var sheetName: String

        public init(page: Int, pageCount: Int, date: String, time: String = "", fileName: String, sheetName: String) {
            self.page = page
            self.pageCount = pageCount
            self.date = date
            self.time = time
            self.fileName = fileName
            self.sheetName = sheetName
        }
    }

    /// Splits `<oddHeader>`'s text at its `&L`, `&C` and `&R` marks. Text
    /// before any mark is the middle's, as Excel reads it.
    public init(code: String) {
        var sections = ["", "", ""]
        var current = 1
        let characters = Array(code)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            guard character == "&", index + 1 < characters.count else {
                sections[current].append(character)
                index += 1
                continue
            }
            let next = characters[index + 1]
            switch next {
            case "L": current = 0
            case "C": current = 1
            case "R": current = 2
            case "\"":
                // A font name, which may hold any of the letters above.
                var end = index + 2
                while end < characters.count, characters[end] != "\"" { end += 1 }
                end = min(end, characters.count - 1)
                sections[current].append(contentsOf: characters[index...end])
                index = end + 1
                continue
            default:
                sections[current].append(character)
                sections[current].append(next)
            }
            index += 2
        }
        self.init(left: sections[0], center: sections[1], right: sections[2])
    }

    /// The three parts joined as the file holds them.
    public var code: String {
        var code = ""
        if !left.isEmpty { code += "&L" + left }
        if !center.isEmpty { code += "&C" + center }
        if !right.isEmpty { code += "&R" + right }
        return code
    }

    /// One part as it prints: the page number, page count, date, time, file
    /// name and sheet name filled in, and the font and colour codes, which
    /// Tables does not draw, taken out.
    public static func printed(_ section: String, fields: Fields) -> String {
        var result = ""
        let characters = Array(section)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            guard character == "&", index + 1 < characters.count else {
                if character != "&" { result.append(character) }
                index += 1
                continue
            }
            let next = characters[index + 1]
            index += 2
            switch next {
            case "&": result.append("&")
            case "P": result += String(fields.page)
            case "N": result += String(fields.pageCount)
            case "D": result += fields.date
            case "T": result += fields.time
            case "F": result += fields.fileName
            case "A": result += fields.sheetName
            case "\"":
                while index < characters.count, characters[index] != "\"" { index += 1 }
                index += 1
            case "K":
                // A colour: six characters, hex or a theme and tint.
                index = min(characters.count, index + 6)
            case _ where next.isNumber:
                // A font size, of up to three digits.
                var digits = 1
                while digits < 3, index < characters.count, characters[index].isNumber {
                    index += 1
                    digits += 1
                }
            default:
                // Bold, italic and the rest, and anything not known.
                break
            }
        }
        return result
    }
}

/// The rows and columns printed again at the top and left of every page.
public struct PrintTitles: Equatable, Sendable {
    public var rows: ClosedRange<Int>?
    public var columns: ClosedRange<Int>?

    public init(rows: ClosedRange<Int>? = nil, columns: ClosedRange<Int>? = nil) {
        self.rows = rows
        self.columns = columns
    }

    /// The rows as typed: `1:2`, or nothing.
    public var rowsText: String {
        rows.map { "\($0.lowerBound + 1):\($0.upperBound + 1)" } ?? ""
    }

    /// The columns as typed: `A:B`, or nothing.
    public var columnsText: String {
        columns.map { "\(CellAddress.columnName($0.lowerBound)):\(CellAddress.columnName($0.upperBound))" } ?? ""
    }

    /// Reads `1:2`, `$1:$2` or a single `3`. Nil for anything else; an empty
    /// text is no rows, given as a nil inside.
    public static func rows(fromText text: String) -> ClosedRange<Int>?? {
        lines(fromText: text) { Int($0).flatMap { $0 >= 1 ? $0 - 1 : nil } }
    }

    /// Reads `A:B`, `$A:$B` or a single `C`.
    public static func columns(fromText text: String) -> ClosedRange<Int>?? {
        lines(fromText: text) { name in
            guard !name.isEmpty, name.allSatisfy(\.isLetter) else { return nil }
            return CellAddress(a1: name.uppercased() + "1")?.column
        }
    }

    private static func lines(fromText text: String, index: (String) -> Int?) -> ClosedRange<Int>?? {
        let cleaned = text.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: " ", with: "")
        guard !cleaned.isEmpty else { return .some(nil) }
        let parts = cleaned.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count <= 2, let first = index(parts[0]), let last = index(parts[parts.count - 1]) else {
            return nil
        }
        return .some(min(first, last)...max(first, last))
    }
}

/// Everything the page setup panel edits for one sheet.
public struct PrintSetup: Equatable, Sendable {
    public var page = PageSetup()
    /// The cells printed, or none for the whole sheet.
    public var areas: [CellRange] = []
    public var titles = PrintTitles()

    public init() {}

    /// The print areas as typed: `A1:D20`, several divided by commas.
    public static func areasText(_ areas: [CellRange]) -> String {
        areas.map(\.normalized.a1).joined(separator: ",")
    }

    /// Reads what `areasText` writes. Nil for text that is not a range.
    public static func areas(fromText text: String) -> [CellRange]? {
        let cleaned = text.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: " ", with: "")
        guard !cleaned.isEmpty else { return [] }
        var areas: [CellRange] = []
        for part in cleaned.split(separator: ",") {
            guard let range = CellRange(a1Range: String(part).uppercased()) else { return nil }
            areas.append(range.normalized)
        }
        return areas
    }
}

// MARK: - The sheet's kept fragments

extension Worksheet {
    public var pageSetup: PageSetup {
        get {
            var setup = PageSetup()
            setup.fitsToPages = printsFittedToPages
            if let element = keptElement("pageSetup") {
                if element.attribute("orientation") == "landscape" { setup.orientation = .landscape }
                setup.paperSize = element.attribute("paperSize").flatMap(Int.init)
                if let scale = element.attribute("scale").flatMap(Int.init) {
                    setup.scale = min(max(scale, PageSetup.scaleRange.lowerBound), PageSetup.scaleRange.upperBound)
                }
                if let wide = element.attribute("fitToWidth").flatMap(Int.init) { setup.fitWide = max(0, wide) }
                if let tall = element.attribute("fitToHeight").flatMap(Int.init) { setup.fitTall = max(0, tall) }
            }
            if let element = keptElement("printOptions") {
                setup.printsGridlines = Self.flag(element.attribute("gridLines"))
                setup.centersHorizontally = Self.flag(element.attribute("horizontalCentered"))
                setup.centersVertically = Self.flag(element.attribute("verticalCentered"))
            }
            if let element = keptElement("pageMargins") {
                func inches(_ name: String, _ fallback: Double) -> Double {
                    element.attribute(name).flatMap(Double.init).map { max(0, $0) } ?? fallback
                }
                setup.margins.left = inches("left", setup.margins.left)
                setup.margins.right = inches("right", setup.margins.right)
                setup.margins.top = inches("top", setup.margins.top)
                setup.margins.bottom = inches("bottom", setup.margins.bottom)
                setup.margins.header = inches("header", setup.margins.header)
                setup.margins.footer = inches("footer", setup.margins.footer)
            }
            if let element = keptElement("headerFooter") {
                setup.header = HeaderFooterText(code: element.firstChild(named: "oddHeader")?.text ?? "")
                setup.footer = HeaderFooterText(code: element.firstChild(named: "oddFooter")?.text ?? "")
            }
            return setup
        }
        set {
            let old = pageSetup
            guard newValue != old else { return }
            printsFittedToPages = newValue.fitsToPages

            updateKeptElement("pageSetup") { element in
                if newValue.orientation != old.orientation {
                    element.setAttribute("orientation", newValue.orientation.rawValue)
                }
                if newValue.paperSize != old.paperSize {
                    element.setAttribute("paperSize", newValue.paperSize.map(String.init))
                }
                if newValue.scale != old.scale {
                    let scale = min(max(newValue.scale, PageSetup.scaleRange.lowerBound), PageSetup.scaleRange.upperBound)
                    element.setAttribute("scale", scale == 100 ? nil : String(scale))
                }
                if newValue.fitWide != old.fitWide {
                    element.setAttribute("fitToWidth", newValue.fitWide == 1 ? nil : String(max(0, newValue.fitWide)))
                }
                if newValue.fitTall != old.fitTall {
                    element.setAttribute("fitToHeight", newValue.fitTall == 1 ? nil : String(max(0, newValue.fitTall)))
                }
            }
            updateKeptElement("printOptions") { element in
                if newValue.printsGridlines != old.printsGridlines {
                    element.setAttribute("gridLines", newValue.printsGridlines ? "1" : nil)
                }
                if newValue.centersHorizontally != old.centersHorizontally {
                    element.setAttribute("horizontalCentered", newValue.centersHorizontally ? "1" : nil)
                }
                if newValue.centersVertically != old.centersVertically {
                    element.setAttribute("verticalCentered", newValue.centersVertically ? "1" : nil)
                }
            }
            if newValue.margins != old.margins {
                updateKeptElement("pageMargins") { element in
                    // All six are required, so a new element gets them all.
                    element.setAttribute("left", Self.inches(newValue.margins.left))
                    element.setAttribute("right", Self.inches(newValue.margins.right))
                    element.setAttribute("top", Self.inches(newValue.margins.top))
                    element.setAttribute("bottom", Self.inches(newValue.margins.bottom))
                    element.setAttribute("header", Self.inches(newValue.margins.header))
                    element.setAttribute("footer", Self.inches(newValue.margins.footer))
                }
            }
            if newValue.header != old.header || newValue.footer != old.footer {
                updateKeptElement("headerFooter") { element in
                    if newValue.header != old.header {
                        Self.setText(newValue.header.code, ofChild: "oddHeader", in: element)
                    }
                    if newValue.footer != old.footer {
                        Self.setText(newValue.footer.code, ofChild: "oddFooter", in: element)
                    }
                }
            }
        }
    }

    /// The lines a manual page break sits before, from the kept
    /// `<rowBreaks>` and `<colBreaks>`.
    public var manualPageBreaks: (rows: Set<Int>, columns: Set<Int>) {
        func breaks(_ name: String) -> Set<Int> {
            Set(keptElement(name)?.children(named: "brk").compactMap { $0.attribute("id").flatMap(Int.init) } ?? [])
        }
        return (breaks("rowBreaks"), breaks("colBreaks"))
    }

    private func keptElement(_ name: String) -> XMLElement? {
        preservedElements.first { $0.name == name }.flatMap { try? XMLLite.parse(Data($0.xml.utf8)) }
    }

    /// Changes the kept fragment of that name, or a new empty one. The
    /// fragment is left alone when the change makes no difference to it, and
    /// one that was not there is not added empty.
    private mutating func updateKeptElement(_ name: String, _ change: (XMLElement) -> Void) {
        let index = preservedElements.firstIndex { $0.name == name }
        // A new fragment is put in the worksheet's namespace: written
        // verbatim, one without would land outside it, which Excel rejects.
        let source = index.map { preservedElements[$0].xml } ?? "<\(name) xmlns=\"\(Self.mainNamespace)\"/>"
        guard let element = try? XMLLite.parse(Data(source.utf8)) else { return }
        let before = XMLLite.serialize(element)
        change(element)
        guard let xml = XMLLite.serialize(element), xml != before else { return }
        if let index {
            preservedElements[index] = PreservedElement(name: name, xml: xml)
        } else {
            preservedElements.append(PreservedElement(name: name, xml: xml))
        }
    }

    private static let mainNamespace = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"

    private static func flag(_ value: String?) -> Bool { value == "1" || value == "true" }

    private static func inches(_ value: Double) -> String {
        let rounded = (max(0, value) * 10_000).rounded() / 10_000
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }

    /// `<headerFooter>` holds its children in a fixed order: the odd header,
    /// then the odd footer, ahead of the even and first pages' own.
    private static func setText(_ text: String, ofChild name: String, in element: XMLElement) {
        if let child = element.firstChild(named: name) {
            if text.isEmpty { element.removeChild(child) } else { child.setText(text) }
            return
        }
        guard !text.isEmpty,
              let child = XMLLite.fragment("<\(name) xmlns=\"\(mainNamespace)\"/>", namespaces: [:]) else { return }
        child.setText(text)
        let position = name == "oddHeader" ? 0 : (element.firstChild(named: "oddHeader") == nil ? 0 : 1)
        element.insertChild(child, at: position)
    }
}

// MARK: - Print areas and titles

extension Workbook {
    private static let printAreaName = "_xlnm.Print_Area"
    private static let printTitlesName = "_xlnm.Print_Titles"

    /// The sheet's page setup with its print area and titles.
    public func printSetup(of sheetID: Worksheet.ID) -> PrintSetup {
        var setup = PrintSetup()
        if let index = index(of: sheetID) { setup.page = sheets[index].pageSetup }
        setup.areas = printAreas(of: sheetID)
        setup.titles = printTitles(of: sheetID)
        return setup
    }

    public mutating func setPrintSetup(_ setup: PrintSetup, of sheetID: Worksheet.ID) {
        if let index = index(of: sheetID) { sheets[index].pageSetup = setup.page }
        if setup.areas != printAreas(of: sheetID) { setPrintAreas(setup.areas, of: sheetID) }
        if setup.titles != printTitles(of: sheetID) { setPrintTitles(setup.titles, of: sheetID) }
    }

    /// The cells the sheet prints, from its `_xlnm.Print_Area` name. Empty
    /// when it has none, or one Tables cannot read as plain ranges.
    public func printAreas(of sheetID: Worksheet.ID) -> [CellRange] {
        var areas: [CellRange] = []
        for reference in builtInReferences(Self.printAreaName, of: sheetID) {
            guard let range = CellRange(a1Range: reference) else { return [] }
            areas.append(range.normalized)
        }
        return areas
    }

    public mutating func setPrintAreas(_ areas: [CellRange], of sheetID: Worksheet.ID) {
        setBuiltIn(Self.printAreaName, of: sheetID, references: areas.map { area in
            let box = area.normalized
            return "\(Self.absolute(box.start)):\(Self.absolute(box.end))"
        })
    }

    /// The rows and columns the sheet repeats, from its `_xlnm.Print_Titles` name.
    public func printTitles(of sheetID: Worksheet.ID) -> PrintTitles {
        var titles = PrintTitles()
        for reference in builtInReferences(Self.printTitlesName, of: sheetID) {
            if let rows = PrintTitles.rows(fromText: reference), let rows {
                titles.rows = rows
            } else if let columns = PrintTitles.columns(fromText: reference), let columns {
                titles.columns = columns
            }
        }
        return titles
    }

    public mutating func setPrintTitles(_ titles: PrintTitles, of sheetID: Worksheet.ID) {
        var references: [String] = []
        // Excel writes the columns first.
        if let columns = titles.columns {
            references.append("$\(CellAddress.columnName(columns.lowerBound)):$\(CellAddress.columnName(columns.upperBound))")
        }
        if let rows = titles.rows {
            references.append("$\(rows.lowerBound + 1):$\(rows.upperBound + 1)")
        }
        setBuiltIn(Self.printTitlesName, of: sheetID, references: references)
    }

    /// The references a built-in name of that sheet lists, without their
    /// sheet names and `$` signs.
    private func builtInReferences(_ name: String, of sheetID: Worksheet.ID) -> [String] {
        guard let defined = definedNames.first(where: { $0.scope == sheetID && $0.name.lowercased() == name.lowercased() })
        else { return [] }
        var references: [String] = []
        var current = ""
        var isQuoted = false
        for character in defined.formula {
            if character == "'" { isQuoted.toggle() }
            if character == ",", !isQuoted {
                references.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        references.append(current)
        return references.compactMap { reference in
            let cells = reference.split(separator: "!", omittingEmptySubsequences: false).last.map(String.init) ?? reference
            let cleaned = cells.replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespaces)
            return cleaned.isEmpty ? nil : cleaned
        }
    }

    private mutating func setBuiltIn(_ name: String, of sheetID: Worksheet.ID, references: [String]) {
        guard let index = index(of: sheetID) else { return }
        let existing = definedNames.firstIndex { $0.scope == sheetID && $0.name.lowercased() == name.lowercased() }
        guard !references.isEmpty else {
            if let existing { definedNames.remove(at: existing) }
            return
        }
        let sheet = Self.quotedSheetName(sheets[index].name)
        let formula = references.map { "\(sheet)!\($0)" }.joined(separator: ",")
        if let existing {
            definedNames[existing].formula = formula
        } else {
            definedNames.append(DefinedName(name: name, formula: formula, scope: sheetID))
        }
    }

    /// A sheet's name as a reference spells it: bare when it is letters,
    /// digits and underscores and could not be read as a cell, as Excel
    /// writes `Sheet1!$A$1`; otherwise in quotes. Only a column Excel has,
    /// up to XFD, makes a name read as a cell.
    private static func quotedSheetName(_ name: String) -> String {
        let letters = name.prefix { $0.isLetter }
        let digits = name.dropFirst(letters.count)
        let isCell = !letters.isEmpty && !digits.isEmpty && digits.allSatisfy(\.isNumber)
            && (CellAddress.columnIndex(String(letters)).map { $0 <= 16_383 } ?? false)
        let isPlain = !name.isEmpty && !isCell
            && name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" }
            && !(name.first?.isNumber ?? false)
        return isPlain ? name : "'" + name.replacingOccurrences(of: "'", with: "''") + "'"
    }

    private static func absolute(_ address: CellAddress) -> String {
        "$\(CellAddress.columnName(address.column))$\(address.row + 1)"
    }
}
