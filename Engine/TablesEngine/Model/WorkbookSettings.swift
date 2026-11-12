import Foundation

/// The workbook-wide settings an XLSX file keeps in `xl/workbook.xml` beside
/// its list of sheets: `<workbookPr>`, `<workbookProtection>`, `<bookViews>`
/// and `<calcPr>`.
///
/// Attributes are kept by their unprefixed names, and only those the schema
/// defines for each element: anything else — an extension's `xr:uid`, say —
/// would have to be written back in its own namespace, and the reader has
/// already dropped the prefix that says which.
public struct WorkbookSettings: Hashable, Sendable {
    /// `<workbookPr>`'s attributes, except the code name, which the workbook
    /// keeps itself, and `date1904`, since serials are read into the 1900
    /// system and written back in it.
    public var properties: [String: String] = [:]
    /// `<workbookProtection>`'s attributes, or nil for a workbook without one.
    public var protection: [String: String]?
    /// The file's windows onto the workbook, in order. The first is the one
    /// Excel opens.
    public var views: [WorkbookWindow] = []
    /// `<calcPr>`'s attributes, except the two a save sets itself to have
    /// Excel recalculate on open.
    public var calculation: [String: String] = [:]

    public init() {}

    /// The sheet the file was left looking at.
    public var activeSheetID: Worksheet.ID? { views.first?.activeSheetID }

    /// Whether the file asks for formulas to be recalculated only on demand.
    public var isManualCalculation: Bool { calculation["calcMode"] == "manual" }

    /// How circular references settle, or nil when they are errors.
    public var iteration: Iteration? {
        guard Self.isTrue(calculation["iterate"]) else { return nil }
        var iteration = Iteration()
        if let count = calculation["iterateCount"].flatMap(Int.init) { iteration.maximumCount = max(1, count) }
        if let delta = calculation["iterateDelta"].flatMap(Double.init) { iteration.maximumChange = max(0, delta) }
        return iteration
    }

    /// Excel's iterative calculation: formulas in a cycle are worked out again
    /// and again from each other's last results, until none moves by more
    /// than `maximumChange` or `maximumCount` passes have run.
    public struct Iteration: Hashable, Sendable {
        public var maximumCount = 100
        public var maximumChange = 0.001
    }

    static func isTrue(_ value: String?) -> Bool { value == "1" || value == "true" }

    // MARK: - Schema

    /// `CT_WorkbookPr`'s attributes, in schema order (ECMA-376 Part 1 §18.2.28).
    public static let propertyAttributes = [
        "date1904", "showObjects", "showBorderUnselectedTables", "filterPrivacy", "promptedSolutions",
        "showInkAnnotation", "backupFile", "saveExternalLinkValues", "updateLinks", "codeName",
        "hidePivotFieldList", "showPivotChartFilter", "allowRefreshQuery", "publishItems",
        "checkCompatibility", "autoCompressPictures", "refreshAllConnections", "defaultThemeVersion",
    ]

    /// `CT_WorkbookProtection`'s attributes, in schema order (§18.2.29).
    public static let protectionAttributes = [
        "workbookPassword", "workbookPasswordCharacterSet", "revisionsPassword",
        "revisionsPasswordCharacterSet", "lockStructure", "lockWindows", "lockRevision",
        "revisionsAlgorithmName", "revisionsHashValue", "revisionsSaltValue", "revisionsSpinCount",
        "workbookAlgorithmName", "workbookHashValue", "workbookSaltValue", "workbookSpinCount",
    ]

    /// `CT_BookView`'s attributes, in schema order (§18.2.30).
    public static let viewAttributes = [
        "visibility", "minimized", "showHorizontalScroll", "showVerticalScroll", "showSheetTabs",
        "xWindow", "yWindow", "windowWidth", "windowHeight", "tabRatio", "firstSheet", "activeTab",
        "autoFilterDateGrouping",
    ]

    /// `CT_CalcPr`'s attributes, in schema order (§18.2.2).
    public static let calculationAttributes = [
        "calcId", "calcMode", "fullCalcOnLoad", "refMode", "iterate", "iterateCount", "iterateDelta",
        "fullPrecision", "calcCompleted", "calcOnSave", "concurrentCalc", "concurrentManualCount",
        "forceFullCalc",
    ]
}

/// One `<workbookView>`: a window's size and place, and the tabs it shows.
///
/// The tabs are kept as sheets rather than positions, so the window still
/// opens on the same sheet after sheets are added, moved or deleted.
public struct WorkbookWindow: Hashable, Sendable {
    /// The view's attributes, except `activeTab` and `firstSheet`.
    public var attributes: [String: String] = [:]
    /// The sheet the window shows.
    public var activeSheetID: Worksheet.ID?
    /// The sheet whose tab the strip is scrolled to start at.
    public var firstSheetID: Worksheet.ID?

    public init(attributes: [String: String] = [:], activeSheetID: Worksheet.ID? = nil,
                firstSheetID: Worksheet.ID? = nil) {
        self.attributes = attributes
        self.activeSheetID = activeSheetID
        self.firstSheetID = firstSheetID
    }
}

extension Workbook {
    /// The sheet to open on: the one the file was left looking at, if it can
    /// be seen, and otherwise the first that can.
    public var openingSheetID: Worksheet.ID? {
        if let id = settings.activeSheetID, let sheet = self[id], !sheet.isHidden { return id }
        return (visibleSheets.first ?? sheets.first)?.id
    }

    /// The hidden sheets a person can show again. A very hidden sheet is
    /// left out: only a macro can bring it back, as in Excel.
    public var unhidableSheets: [Worksheet] { sheets.filter { $0.isHidden && !$0.isVeryHidden } }
}
