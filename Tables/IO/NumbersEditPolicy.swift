import Foundation

/// The changes to a workbook read from Numbers that can be saved back to it.
///
/// Saving patches the original document rather than writing a new one, so
/// that everything Tables doesn't read — styles, charts, formulas, images,
/// categories — comes through untouched. That only works for changes the
/// patch can express: values typed into cells, rows and columns added at the
/// end, rows and columns resized. Anything else is turned away as it's made,
/// rather than accepted and then lost when the document is saved.
enum NumbersEditPolicy {
    enum Violation: Error, Equatable, LocalizedError {
        /// A formula typed or pasted in: Tables can't write Numbers formulas.
        case formula
        /// A change to a cell holding a Numbers formula, or in a pivot table.
        case protectedCell
        /// A change to sheets, tables, merged cells, hidden rows and the like.
        case structure

        var errorDescription: String? {
            switch self {
            case .formula: return String(localized: "Numbers.Restriction.Formula")
            case .protectedCell: return String(localized: "Numbers.Restriction.ProtectedCell")
            case .structure: return String(localized: "Numbers.Restriction.Structure")
            }
        }
    }

    /// The most a table's columns can grow to: Numbers lays a row's cells
    /// out in a table of this many columns.
    static let maximumColumnCount = 255

    /// `new` with every change from `old` that can't be saved taken back out,
    /// and the reason the first one couldn't be.
    ///
    /// Formatting is the one exception: it is quietly reset to the
    /// document's own, as it is for delimited text, so pasting keeps the
    /// values and leaves the formatting behind. A number's format is kept,
    /// since it decides whether the number is saved as a date.
    static func reconcile(
        _ new: Workbook, from old: Workbook, source: NumbersSource
    ) -> (workbook: Workbook, violation: Violation?) {
        guard old != new else { return (new, nil) }
        if hasStructuralChange(new, from: old, source: source) { return (old, .structure) }

        var result = new
        var violation: Violation?
        for (index, sheet) in new.sheets.enumerated() {
            let previous = old.sheets[index]
            guard sheet != previous, let table = source.tables[sheet.id],
                  let imported = source.imported[sheet.id] else { continue }
            for address in Set(sheet.cells.keys).union(previous.cells.keys) {
                let cell = sheet[address]
                guard cell != previous[address] else { continue }
                if cell.formula != nil {
                    result.sheets[index][address] = previous[address]
                    violation = violation ?? .formula
                } else if table.isPivot || table.protectedCells.contains(address) {
                    result.sheets[index][address] = previous[address]
                    violation = violation ?? .protectedCell
                } else {
                    var style = imported[address].style
                    style.numberFormat = cell.style.numberFormat
                    if style != cell.style {
                        var coerced = cell
                        coerced.style = style
                        result.sheets[index][address] = coerced
                    }
                }
            }
        }
        return (result, violation)
    }

    /// Why `workbook` can't be saved over the document it was read from, if
    /// it can't.
    static func violation(in workbook: Workbook, source: NumbersSource) -> Violation? {
        if hasStructuralChange(workbook, from: source.imported, source: source) { return .structure }
        for sheet in workbook.sheets {
            guard let table = source.tables[sheet.id], let imported = source.imported[sheet.id] else { continue }
            for address in Set(sheet.cells.keys).union(imported.cells.keys) {
                let cell = sheet[address]
                if cell.formula != nil { return .formula }
                let original = imported[address]
                let changed = cell.value != original.value || cell.style.numberFormat != original.style.numberFormat
                if changed, table.isPivot || table.protectedCells.contains(address) { return .protectedCell }
            }
        }
        return nil
    }

    /// Whether anything but cells, sizes and growth at the end differs.
    private static func hasStructuralChange(_ new: Workbook, from old: Workbook, source: NumbersSource) -> Bool {
        guard new.sheets.map(\.id) == old.sheets.map(\.id),
              new.definedNames == old.definedNames else { return true }
        for (sheet, previous) in zip(new.sheets, old.sheets) where sheet != previous {
            guard sheet.name == previous.name, sheet.isHidden == previous.isHidden, sheet.kind == previous.kind,
                  sheet.tabColorHex == previous.tabColorHex,
                  sheet.mergedRanges == previous.mergedRanges,
                  sheet.hiddenRows == previous.hiddenRows, sheet.hiddenColumns == previous.hiddenColumns,
                  sheet.charts == previous.charts, sheet.comments == previous.comments,
                  sheet.formControls == previous.formControls,
                  sheet.rowCount >= previous.rowCount, sheet.columnCount >= previous.columnCount
            else { return true }
            if sheet.columnCount > previous.columnCount, sheet.columnCount > maximumColumnCount { return true }
            if source.tables[sheet.id]?.isPivot ?? false,
               sheet.rowCount != previous.rowCount || sheet.columnCount != previous.columnCount { return true }
        }
        return false
    }
}
