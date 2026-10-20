import Foundation

/// What one change to a workbook touched, as far as undo cares.
///
/// Some edits arrive as a stream of tiny changes — a title typed a letter at
/// a time, a column edge dragged, a tab carried along the strip — and undoing
/// them one letter or one point at a time would be useless. Consecutive
/// changes with the same coalescing scope are undone as one.
public enum EditScope: Hashable, Sendable {
    /// One chart's properties, and nothing else.
    case chart(Worksheet.ID, Chart.ID)
    /// Column widths or row heights on one sheet, and nothing else.
    case sheetLayout(Worksheet.ID)
    /// The order of the sheets, and nothing else.
    case sheetOrder
    /// Anything else, which is always a step of its own.
    case other

    public var coalesces: Bool { self != .other }

    public var actionName: String {
        switch self {
        case .chart: return String(localized: "Undo.Action.Chart", bundle: #bundle)
        case .sheetLayout: return String(localized: "Undo.Action.Resize", bundle: #bundle)
        case .sheetOrder: return String(localized: "Undo.Action.MoveSheet", bundle: #bundle)
        case .other: return ""
        }
    }
}

extension Workbook {
    /// The scope of the change from `old` to this workbook.
    public func editScope(from old: Workbook) -> EditScope {
        // Everything outside the sheets has to be untouched.
        var outside = self
        outside.sheets = old.sheets
        guard outside == old else { return .other }

        let ids = sheets.map(\.id)
        let oldIDs = old.sheets.map(\.id)
        if ids != oldIDs {
            guard Set(ids) == Set(oldIDs) else { return .other }
            let byID = Dictionary(uniqueKeysWithValues: sheets.map { ($0.id, $0) })
            return old.sheets.allSatisfy({ byID[$0.id] == $0 }) ? .sheetOrder : .other
        }

        let changed = sheets.indices.filter { sheets[$0] != old.sheets[$0] }
        guard changed.count == 1, let index = changed.first else { return .other }
        let sheet = sheets[index]
        let before = old.sheets[index]

        var probe = sheet
        probe.columnWidths = before.columnWidths
        probe.rowHeights = before.rowHeights
        probe.fittedRows = before.fittedRows
        if probe == before { return .sheetLayout(sheet.id) }

        probe = sheet
        probe.charts = before.charts
        guard probe == before, sheet.charts.map(\.id) == before.charts.map(\.id) else { return .other }
        let edited = zip(sheet.charts, before.charts).filter { $0 != $1 }.map(\.0.id)
        guard edited.count == 1, let chart = edited.first else { return .other }
        return .chart(sheet.id, chart)
    }

    /// The sheet a change from `old` happened on, for showing it after an
    /// undo: the first sheet that differs, or that exists on one side only.
    public func changedSheetID(from old: Workbook) -> Worksheet.ID? {
        let previous = Dictionary(uniqueKeysWithValues: old.sheets.map { ($0.id, $0) })
        return sheets.first { previous[$0.id] != $0 }?.id
    }
}
