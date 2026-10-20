import Foundation

/// A name a workbook binds to a formula, as `<definedNames>` declares it.
///
/// The definition is an arbitrary formula — most often an absolute range such
/// as `Sheet1!$A$2:$A$10`, but a constant or a whole expression is just as
/// legal, so it is stored as text and parsed only when something asks for it.
public struct DefinedName: Hashable, Sendable {
    /// Excel matches names case-insensitively. The original spelling is kept
    /// anyway: it is what the file and the formula bar show.
    public var name: String
    /// The definition, stored without a leading `=`, like a cell's formula.
    public var formula: String
    /// The sheet the name is scoped to. `nil` is workbook scope, which is what
    /// a `<definedName>` without a `localSheetId` means. The file identifies
    /// the sheet by position, but positions move when sheets are added,
    /// deleted or dragged, and a scope that drifts would quietly answer the
    /// wrong sheet's formulas — so the binding is to the sheet itself.
    public var scope: Worksheet.ID?

    /// Excel keeps its own entries — print areas, filter ranges — in the same
    /// list under a reserved prefix. They are never usable inside a formula.
    public var isBuiltIn: Bool { name.lowercased().hasPrefix(Self.builtInPrefix) }

    public static let builtInPrefix = "_xlnm."
}

/// Something a workbook carries that Tables can show but not edit.
///
/// The distinction the user cares about is not which OOXML part it lives in
/// but whether saving keeps it, so these name features, not file structure.
public enum UnsupportedFeature: String, CaseIterable, Hashable, Sendable, Comparable {
    case conditionalFormatting
    case dataValidation
    case autoFilter
    case frozenPanes
    case sheetProtection
    case printSetup
    case comments
    case hyperlinks
    case tables
    case chartsAndImages
    case sparklines
    case pivotTables
    case slicers
    case documentProperties
    case macros
    /// A Numbers table's formatting, kept but not editable, where the table
    /// has no list of styles for changes to go in.
    case formatting
    /// A Numbers document's fonts, borders and the like, kept but not
    /// editable.
    case fontsAndBorders
    /// The text formatting of a Numbers cell holding rich text, whose runs
    /// of text are formatted on their own.
    case richTextFormatting
    /// A Numbers table's categories.
    case categories
    /// Formulas Tables can't read, or works out differently, so keeps the
    /// result the file had.
    case unreadFormulas

    public var label: String {
        switch self {
        case .conditionalFormatting: return String(localized: "UnsupportedFeature.ConditionalFormatting", bundle: #bundle)
        case .dataValidation: return String(localized: "UnsupportedFeature.DataValidation", bundle: #bundle)
        case .autoFilter: return String(localized: "UnsupportedFeature.AutoFilter", bundle: #bundle)
        case .frozenPanes: return String(localized: "UnsupportedFeature.FrozenPanes", bundle: #bundle)
        case .sheetProtection: return String(localized: "UnsupportedFeature.SheetProtection", bundle: #bundle)
        case .printSetup: return String(localized: "UnsupportedFeature.PrintSetup", bundle: #bundle)
        case .comments: return String(localized: "UnsupportedFeature.Comments", bundle: #bundle)
        case .hyperlinks: return String(localized: "UnsupportedFeature.Hyperlinks", bundle: #bundle)
        case .tables: return String(localized: "UnsupportedFeature.Tables", bundle: #bundle)
        case .chartsAndImages: return String(localized: "UnsupportedFeature.ChartsAndImages", bundle: #bundle)
        case .sparklines: return String(localized: "UnsupportedFeature.Sparklines", bundle: #bundle)
        case .pivotTables: return String(localized: "UnsupportedFeature.PivotTables", bundle: #bundle)
        case .slicers: return String(localized: "UnsupportedFeature.Slicers", bundle: #bundle)
        case .documentProperties: return String(localized: "UnsupportedFeature.DocumentProperties", bundle: #bundle)
        case .macros: return String(localized: "UnsupportedFeature.Macros", bundle: #bundle)
        case .formatting: return String(localized: "UnsupportedFeature.Formatting", bundle: #bundle)
        case .fontsAndBorders: return String(localized: "UnsupportedFeature.FontsAndBorders", bundle: #bundle)
        case .richTextFormatting: return String(localized: "UnsupportedFeature.RichTextFormatting", bundle: #bundle)
        case .categories: return String(localized: "UnsupportedFeature.Categories", bundle: #bundle)
        case .unreadFormulas: return String(localized: "UnsupportedFeature.UnreadFormulas", bundle: #bundle)
        }
    }

    /// Ordered by declaration so a notice always lists features the same way.
    public static func < (lhs: UnsupportedFeature, rhs: UnsupportedFeature) -> Bool {
        guard let left = allCases.firstIndex(of: lhs), let right = allCases.firstIndex(of: rhs) else {
            return lhs.rawValue < rhs.rawValue
        }
        return left < right
    }
}

/// What a file was found to contain that Tables cannot edit, split by whether
/// saving will keep it.
public struct UnsupportedFeatureReport: Hashable, Sendable {
    /// Written back byte-for-byte exactly as the file had it.
    public private(set) var preserved: Set<UnsupportedFeature> = []
    /// Found, but gone the moment the user saves.
    public private(set) var lost: Set<UnsupportedFeature> = []

    public init(preserved: Set<UnsupportedFeature> = [], lost: Set<UnsupportedFeature> = []) {
        self.preserved = preserved
        self.lost = lost
    }

    public var isEmpty: Bool { preserved.isEmpty && lost.isEmpty }

    /// Records a sighting. A feature that is lost anywhere is reported as lost:
    /// telling someone their comments are safe when one sheet's are not is
    /// worse than saying nothing.
    public mutating func record(_ feature: UnsupportedFeature, isPreserved: Bool) {
        guard isPreserved else {
            preserved.remove(feature)
            lost.insert(feature)
            return
        }
        guard !lost.contains(feature) else { return }
        preserved.insert(feature)
    }

    /// Plain wording for the notice shown when such a document opens.
    public var noticeMessage: String {
        // Languages that do not separate list items with a comma get their own
        // separator, so a translated notice reads as a list in that language.
        let separator = String(localized: "Common.ListSeparator", bundle: #bundle)
        var lines: [String] = []
        if !preserved.isEmpty {
            lines.append(String(
                format: String(localized: "UnsupportedFeature.Notice.Preserved", bundle: #bundle),
                preserved.sorted().map(\.label).joined(separator: separator)
            ))
        }
        if !lost.isEmpty {
            lines.append(String(
                format: String(localized: "UnsupportedFeature.Notice.Lost", bundle: #bundle),
                lost.sorted().map(\.label).joined(separator: separator)
            ))
        }
        return lines.joined(separator: "\n\n")
    }
}

/// The raw XML of an element Tables does not model, kept so that opening and
/// saving a file does not delete it.
///
/// Both the parts this appears in — `<worksheet>` and `<styleSheet>` — fix the
/// order of their children by schema, so the name is what decides where the
/// fragment goes back in.
public struct PreservedElement: Hashable, Sendable {
    public var name: String
    /// The fragment itself, namespace declarations and all.
    public var xml: String

    /// Worksheet children that name a relationship id rather than carrying
    /// their target inline. They are only meaningful while the sheet's own
    /// `_rels` part survives alongside them, and a dangling id is what makes
    /// Excel offer to repair a file.
    public static let relationshipDependentNames: Set<String> = [
        "hyperlinks", "legacyDrawing", "controls", "tableParts", "drawing",
    ]

    public var needsSheetRelationships: Bool { Self.relationshipDependentNames.contains(name) }
}

/// One entry of a `_rels` part, kept as the file wrote it.
///
/// The identifier is deliberately absent: relationship ids are only meaningful
/// within one part, and the ones we re-emit are renumbered around our own.
public struct PreservedRelationship: Hashable, Sendable {
    public var type: String
    public var target: String
    /// `"External"` for a target outside the package, absent otherwise.
    public var targetMode: String?

    public init(type: String, target: String, targetMode: String? = nil) {
        self.type = type
        self.target = target
        self.targetMode = targetMode
    }
}

/// The pieces of an opened package that Tables does not generate and carries
/// through a save untouched.
public struct PreservedPackage: Hashable, Sendable {
    /// Retained ZIP entries, keyed by their path in the package.
    public var parts: [String: Data] = [:]
    /// `<Default>` content types, keyed by extension, that retained parts need.
    public var contentTypeDefaults: [String: String] = [:]
    /// `<Override>` content types, keyed by the absolute part name.
    public var contentTypeOverrides: [String: String] = [:]
    /// Entries to re-emit in `_rels/.rels` beside the one we generate.
    public var rootRelationships: [PreservedRelationship] = []
    /// Entries to re-emit in `xl/_rels/workbook.xml.rels`.
    public var workbookRelationships: [PreservedRelationship] = []
    /// Whole `_rels` parts for individual sheets, kept verbatim because the
    /// sheet XML we also preserve refers to their ids by name. Keyed by sheet
    /// rather than by path: a sheet's position, and so its file name, moves.
    public var sheetRelationshipParts: [Worksheet.ID: Data] = [:]
    /// Children of `xl/styles.xml` we regenerate around rather than rewrite.
    /// Differential formats especially: preserved conditional formatting names
    /// them by position, so dropping them would leave every rule pointing at a
    /// table that is no longer there.
    public var styleSheetElements: [PreservedElement] = []

    public var isEmpty: Bool { parts.isEmpty && sheetRelationshipParts.isEmpty && styleSheetElements.isEmpty }

    public static let macroProjectRelationshipType = "http://schemas.microsoft.com/office/2006/relationships/vbaProject"

    /// The package path of the compiled macro project, when one was kept.
    public var macroProjectPath: String? {
        workbookRelationships.lazy
            .filter { $0.type == Self.macroProjectRelationshipType && $0.targetMode != "External" }
            .map { XLSXReader.PackagePreservation.absolutePath($0.target, relativeTo: "xl") }
            .first { parts[$0] != nil }
    }

    /// The same package with the macros taken out, for saving to a format
    /// that cannot hold them: an `.xlsx` that declares a macro project is one
    /// Excel refuses to open at all.
    public func removingMacros() -> PreservedPackage {
        var package = self
        // The parts themselves, and the `_rels` naming their signatures.
        let dropped = parts.keys.filter { $0.hasPrefix("xl/vbaProject") || $0.hasPrefix("xl/_rels/vbaProject") }
        for path in dropped {
            package.parts[path] = nil
            package.contentTypeOverrides["/" + path] = nil
        }
        package.workbookRelationships.removeAll { $0.type == Self.macroProjectRelationshipType }
        return package
    }
}

/// A collection of worksheets — the whole document.
public struct Workbook: Hashable, Sendable {
    public var sheets: [Worksheet]
    public var definedNames: [DefinedName]
    /// Package parts carried through from the file this workbook was read from.
    public var preservedPackage = PreservedPackage()
    /// What that file used that we cannot edit, for the notice shown on open.
    public var unsupportedFeatures = UnsupportedFeatureReport()
    /// The theme's six accent colours, as six-digit RGB. Chart series without
    /// a colour of their own take these in turn, exactly as Excel draws them.
    public var themeAccentColors = ThemeColorScheme.office.accentColors
    /// The file's tables, so structured references in formulas resolve.
    public var tables: [TableDefinition] = []
    /// Sheets laid out together as tables on one page; see `SheetCanvas`.
    /// A sheet on none of them is a grid of its own.
    public var canvases: [SheetCanvas] = []
    /// The name the macros know the workbook by, `ThisWorkbook` unless the
    /// file renamed it. Like a sheet's, it binds the workbook to its module.
    public var codeName: String?

    /// Whether the file came with macros that a save can carry through.
    public var hasMacros: Bool { preservedPackage.macroProjectPath != nil }

    /// The compiled macro project, `vbaProject.bin`, exactly as it was read.
    public var macroProject: Data? { preservedPackage.macroProjectPath.flatMap { preservedPackage.parts[$0] } }

    public init(sheets: [Worksheet], definedNames: [DefinedName] = []) {
        self.sheets = sheets.isEmpty ? [Worksheet(name: Workbook.defaultSheetName(1))] : sheets
        self.definedNames = definedNames
    }

    public init() {
        self.init(sheets: [Worksheet(name: Workbook.defaultSheetName(1))])
    }

    /// "Sheet 3" in the user's language, for sheets the app names itself.
    public static func defaultSheetName(_ position: Int) -> String {
        String(format: String(localized: "Workbook.Sheet.DefaultName", bundle: #bundle), position)
    }

    /// The definition a formula living on `sheetID` sees for `name`.
    ///
    /// A name scoped to that sheet wins over a workbook-scoped one spelled the
    /// same way, and a name scoped to any *other* sheet is invisible: matching
    /// it would let one sheet's private definition answer another sheet's
    /// formula. Excel's own `_xlnm.` entries never resolve.
    public func definedName(_ name: String, visibleFrom sheetID: Worksheet.ID?) -> DefinedName? {
        let matches = definedNames.filter {
            !$0.isBuiltIn && $0.name.compare(name, options: .caseInsensitive) == .orderedSame
        }
        if let sheetID, let scoped = matches.first(where: { $0.scope == sheetID }) {
            return scoped
        }
        return matches.first { $0.scope == nil }
    }

    public subscript(sheetID: Worksheet.ID) -> Worksheet? {
        get { sheets.first { $0.id == sheetID } }
        set {
            guard let newValue, let index = sheets.firstIndex(where: { $0.id == sheetID }) else { return }
            sheets[index] = newValue
        }
    }

    /// The sheets a user can actually reach — what the tab strip shows.
    public var visibleSheets: [Worksheet] { sheets.filter { !$0.isHidden } }

    /// Hides or reveals a sheet. Hiding the last visible one fails: Excel
    /// requires at least one, and a workbook without it opens to nothing.
    @discardableResult
    public mutating func setSheet(_ sheetID: Worksheet.ID, hidden: Bool) -> Bool {
        guard let index = index(of: sheetID) else { return false }
        guard sheets[index].isHidden != hidden else { return true }
        if hidden, visibleSheets.count <= 1 { return false }
        sheets[index].isHidden = hidden
        return true
    }

    public func index(of sheetID: Worksheet.ID) -> Int? {
        sheets.firstIndex { $0.id == sheetID }
    }

    public func sheet(named name: String) -> Worksheet? {
        sheets.first { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }
    }

    /// The sheet at `index`, clamped. Delimited formats hold a single sheet, so
    /// every export path has to choose one, and none of them can be sure the
    /// index it remembered survived a sheet being deleted. A workbook always
    /// keeps at least one sheet, so there is always something to return.
    public func sheet(at index: Int) -> Worksheet {
        sheets[min(max(0, index), sheets.count - 1)]
    }

    /// A sheet name Excel accepts that doesn't collide with any existing sheet.
    public func uniqueSheetName(basedOn candidate: String) -> String {
        let base = Worksheet.sanitizedName(candidate)
        guard sheet(named: base) != nil else { return base }

        var suffix = 2
        while true {
            // The suffix has to fit inside the length limit too, so trim the
            // stem rather than overrun it.
            let tail = " \(suffix)"
            let stem = String(base.prefix(Worksheet.maximumNameLength - tail.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let candidate = stem + tail
            if sheet(named: candidate) == nil { return candidate }
            suffix += 1
        }
    }

    public mutating func addSheet(named name: String? = nil, at index: Int? = nil) -> Worksheet.ID {
        let resolved = uniqueSheetName(basedOn: name ?? Workbook.defaultSheetName(sheets.count + 1))
        let sheet = Worksheet(name: resolved)
        sheets.insert(sheet, at: min(max(0, index ?? sheets.count), sheets.count))
        return sheet.id
    }

    public mutating func duplicateSheet(_ sheetID: Worksheet.ID) -> Worksheet.ID? {
        guard let index = index(of: sheetID) else { return nil }
        var copy = sheets[index]
        copy.id = UUID()
        copy.name = uniqueSheetName(basedOn: sheets[index].name + " Copy")
        // Code names are unique, and the original's document module stays
        // with the original.
        copy.codeName = nil
        copy.fileSheetID = nil
        // Excel points a copied sheet's charts at the copy's own cells.
        for chart in copy.charts.indices {
            copy.charts[chart].id = UUID()
            // Series keep their ids: they only need to be unique within a
            // chart, and they are how a save matches them to the file's XML.
            copy.charts[chart].retarget(from: sheetID, to: copy.id)
        }
        // The copy's controls get no `ctrlProps` parts of their own; the
        // original's stay the original's.
        for control in copy.formControls.indices {
            copy.formControls[control].source.propertiesPart = nil
        }
        sheets.insert(copy, at: index + 1)
        return copy.id
    }

    /// Removes a sheet unless it is the only one left.
    @discardableResult
    public mutating func removeSheet(_ sheetID: Worksheet.ID) -> Bool {
        guard sheets.count > 1, let index = index(of: sheetID) else { return false }
        // Charts elsewhere that read from the sheet keep the values they were
        // showing, as Excel's do once their source is gone.
        let snapshot = self
        for sheet in sheets.indices where sheet != index {
            for chart in sheets[sheet].charts.indices {
                for series in sheets[sheet].charts[chart].series.indices {
                    let visibleOnly = sheets[sheet].charts[chart].plotsVisibleCellsOnly
                    func detach(_ source: inout ChartSource) {
                        guard source.reference?.sheetID == sheetID else { return }
                        source.cache = source.cells(in: snapshot, visibleOnly: visibleOnly).map(\.value)
                        source.reference = nil
                    }
                    detach(&sheets[sheet].charts[chart].series[series].name)
                    detach(&sheets[sheet].charts[chart].series[series].categories)
                    detach(&sheets[sheet].charts[chart].series[series].values)
                }
            }
        }
        sheets.remove(at: index)
        pruneCanvases()
        // Deleting the only visible sheet would leave the strip empty.
        if visibleSheets.isEmpty { sheets[0].isHidden = false }
        return true
    }

    public mutating func moveSheet(_ sheetID: Worksheet.ID, to destination: Int) {
        guard let index = index(of: sheetID) else { return }
        let sheet = sheets.remove(at: index)
        sheets.insert(sheet, at: min(max(0, destination), sheets.count))
        // A canvas's sheets move as one, around the one carried.
        if let canvas = canvas(containing: sheetID) {
            let members = canvas.tables.map(\.sheetID)
            let moved = members.compactMap { id in sheets.first { $0.id == id } }
            let others = sheets.filter { !canvas.contains($0.id) }
            let at = sheets[..<(self.index(of: sheetID) ?? 0)].filter { !canvas.contains($0.id) }.count
            sheets = Array(others[..<at]) + moved + Array(others[at...])
        }
        // A sheet let go in the middle of another canvas goes after it.
        for canvas in canvases where !canvas.contains(sheetID) { keepCanvasTogether(canvas) }
    }

    public mutating func renameSheet(_ sheetID: Worksheet.ID, to name: String) {
        guard let index = index(of: sheetID) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != sheets[index].name else { return }
        var candidate = self
        candidate.sheets.remove(at: index)
        sheets[index].name = candidate.uniqueSheetName(basedOn: trimmed)
    }
}
