import Foundation

/// The changes a protected sheet or workbook lets through.
///
/// Every edit, however it was made — typed, pasted, filled, dragged, run from
/// a menu — arrives as the workbook before and the workbook after. Whatever
/// part of the change the protection forbids is taken back out here, so no
/// way of editing can forget to ask.
public enum ProtectionPolicy {
    public enum Violation: Error, Equatable, LocalizedError, Sendable {
        /// A change to a locked cell on a protected sheet.
        case lockedCell
        /// Something else the sheet's protection doesn't allow: formatting,
        /// inserting or deleting rows and columns, changing objects.
        case sheetAction
        /// Adding, deleting, renaming, hiding or moving a sheet of a
        /// protected workbook.
        case workbookStructure

        public var errorDescription: String? {
            switch self {
            case .lockedCell: return String(localized: "Protection.Restriction.LockedCell", bundle: .engine)
            case .sheetAction: return String(localized: "Protection.Restriction.SheetAction", bundle: .engine)
            case .workbookStructure: return String(localized: "Protection.Restriction.WorkbookStructure", bundle: .engine)
            }
        }
    }

    /// `new` with every change from `old` that protection forbids taken back
    /// out, and the reason the first one was.
    ///
    /// Protection is judged as it stood in `old`. A change that turns it off
    /// or alters it is let through whole: checking the password is the
    /// business of whoever makes that change.
    public static func reconcile(_ new: Workbook, from old: Workbook) -> (workbook: Workbook, violation: Violation?) {
        guard old != new else { return (new, nil) }
        if old.isStructureLocked, new.protection == old.protection, changesStructure(new, from: old) {
            return (old, .workbookStructure)
        }
        guard old.sheets.contains(where: \.isProtected) else { return (new, nil) }

        let before = Dictionary(uniqueKeysWithValues: old.sheets.map { ($0.id, $0) })
        var result = new
        var violation: Violation?
        for index in new.sheets.indices {
            let sheet = new.sheets[index]
            guard let previous = before[sheet.id], previous.isProtected,
                  sheet.protection == previous.protection, sheet != previous else { continue }
            let (allowed, reason) = reconcile(sheet, from: previous)
            result.sheets[index] = allowed
            violation = violation ?? reason
        }
        // Formulas worked out from what was taken back need working out again.
        if violation != nil { result.recalculate() }
        return (result, violation)
    }

    private static func changesStructure(_ new: Workbook, from old: Workbook) -> Bool {
        guard new.sheets.count == old.sheets.count else { return true }
        return zip(new.sheets, old.sheets).contains {
            $0.id != $1.id || $0.name != $1.name || $0.isHidden != $1.isHidden || $0.isVeryHidden != $1.isVeryHidden
        }
    }

    private static func reconcile(_ sheet: Worksheet, from previous: Worksheet) -> (Worksheet, Violation?) {
        guard let protection = previous.protection else { return (sheet, nil) }

        // Rows and columns coming and going move every cell after them, so
        // the change is allowed or refused as a whole.
        let rows = sheet.rowCount - previous.rowCount
        let columns = sheet.columnCount - previous.columnCount
        if rows != 0 || columns != 0 {
            let allowed = (rows <= 0 || protection.allows(.insertRows))
                && (rows >= 0 || protection.allows(.deleteRows))
                && (columns <= 0 || protection.allows(.insertColumns))
                && (columns >= 0 || protection.allows(.deleteColumns))
            return allowed ? (sheet, nil) : (previous, .sheetAction)
        }

        var result = sheet
        var violation: Violation?
        func refuse(_ reason: Violation) { violation = violation ?? reason }

        // Merging throws away what the cells merged over held, locked or not.
        if sheet.mergedRanges != previous.mergedRanges { return (previous, .sheetAction) }

        if !protection.allows(.formatColumns),
           sheet.columnWidths != previous.columnWidths || sheet.hiddenColumns != previous.hiddenColumns
            || sheet.columnStyles != previous.columnStyles {
            result.columnWidths = previous.columnWidths
            result.hiddenColumns = previous.hiddenColumns
            result.columnStyles = previous.columnStyles
            refuse(.sheetAction)
        }
        if !protection.allows(.formatRows) {
            // A row whose height follows its text may still grow with it.
            let fitted = sheet.fittedRows.union(previous.fittedRows)
            let set = { (heights: [Int: Double]) in heights.filter { !fitted.contains($0.key) } }
            if set(sheet.rowHeights) != set(previous.rowHeights) || sheet.hiddenRows != previous.hiddenRows
                || sheet.rowStyles != previous.rowStyles || sheet.fittedRows != previous.fittedRows {
                result.rowHeights = previous.rowHeights
                result.fittedRows = previous.fittedRows
                result.hiddenRows = previous.hiddenRows
                result.rowStyles = previous.rowStyles
                refuse(.sheetAction)
            }
        }
        if !protection.allows(.objects),
           sheet.charts != previous.charts || sheet.preservedDrawingAnchors != previous.preservedDrawingAnchors
            || sheet.comments != previous.comments {
            result.charts = previous.charts
            result.preservedDrawingAnchors = previous.preservedDrawingAnchors
            result.comments = previous.comments
            refuse(.sheetAction)
        }
        if !protection.allows(.formatCells), sheet.conditionalRules != previous.conditionalRules {
            result.conditionalRules = previous.conditionalRules
            refuse(.sheetAction)
        }

        guard sheet.cells != previous.cells else { return (result, violation) }
        let editable = previous.editableRanges
        for address in Set(sheet.cells.keys).union(previous.cells.keys) {
            let cell = sheet[address]
            let original = previous[address]
            guard cell != original else { continue }
            // What a formula comes to, and where a neighbour's array spills,
            // follow from other cells; they are no change of this one.
            let contentChanged = cell.formula != original.formula
                || cell.formula == nil && cell.value != original.value && !cell.isSpilled && !original.isSpilled
                || cell.arrayExtent != original.arrayExtent || cell.richText != original.richText
            let isLocked = original.style.isLocked && !editable.contains { $0.contains(address) }
            if contentChanged, isLocked {
                result[address] = original
                refuse(.lockedCell)
                continue
            }
            // Typing into a cell may format it — a date, a percentage — which
            // is part of the entry. Any other formatting needs permission.
            if cell.style != original.style, !contentChanged, !protection.allows(.formatCells) {
                var restored = cell
                restored.style = original.style
                result[address] = restored
                refuse(.sheetAction)
            }
        }
        return (result, violation)
    }
}
