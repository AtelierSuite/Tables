import Foundation

/// The changes to a workbook read from Numbers that can be saved back to it.
///
/// Saving patches the original document rather than writing a new one, so
/// that everything Tables doesn't read — styles, charts, images, categories —
/// comes through untouched. That only works for changes the patch can
/// express: values and formulas typed into cells, rows and columns inserted
/// and deleted where nothing Tables can't move depends on where they are,
/// rows and columns resized, sheets renamed. Anything else is turned away as it's made,
/// rather than accepted and then lost when the document is saved.
enum NumbersEditPolicy {
    enum Violation: Error, Equatable, LocalizedError {
        /// A formula Numbers can't be given: one using a function or a kind
        /// of reference it doesn't have.
        case formula
        /// A change to a cell holding a formula Tables can't read, or in a
        /// pivot table.
        case protectedCell
        /// A change to sheets, tables, merged cells, hidden rows and the like.
        case structure
        /// Rows or columns inserted or deleted where something Tables can't
        /// move would be left behind.
        case movingCells
        /// A change to a table, or a sheet's name, stored as a base and
        /// collaboration's patches over it, which saving can't put together.
        case unmergedChanges

        var errorDescription: String? {
            switch self {
            case .formula: return String(localized: "Numbers.Restriction.Formula")
            case .protectedCell: return String(localized: "Numbers.Restriction.ProtectedCell")
            case .structure: return String(localized: "Numbers.Restriction.Structure")
            case .movingCells: return String(localized: "Numbers.Restriction.MovingCells")
            case .unmergedChanges: return String(localized: "Numbers.Restriction.UnmergedChanges")
            }
        }
    }

    /// The most a table's columns can grow to: Numbers lays a row's cells
    /// out in a table of this many columns.
    static let maximumColumnCount = 255

    /// `new` with every change from `old` that can't be saved taken back out,
    /// and the reason the first one couldn't be.
    ///
    /// Formatting Numbers can't be given — fonts, borders, indents — is the
    /// one exception: it is quietly put back as it was, so pasting keeps the
    /// values and the formatting that can be saved and leaves the rest
    /// behind.
    static func reconcile(
        _ new: Workbook, from old: Workbook, source: NumbersSource
    ) -> (workbook: Workbook, violation: Violation?) {
        guard old != new else { return (new, nil) }
        if let violation = structuralViolation(new, from: old, source: source) { return (old, violation) }

        var result = new
        var violation: Violation?
        let sheetNames = NumbersSource.sheetNames(of: new, tables: source.tables)
        for (index, sheet) in new.sheets.enumerated() {
            let previous = old.sheets[index]
            guard sheet != previous, let table = source.tables[sheet.id],
                  let imported = source.imported[sheet.id] else { continue }
            for address in Set(sheet.cells.keys).union(previous.cells.keys) {
                let cell = sheet[address]
                guard cell != previous[address] else { continue }
                if let reason = problem(with: cell, was: previous[address], at: address, in: table, sheetNames: sheetNames) {
                    result.sheets[index][address] = previous[address]
                    violation = violation ?? reason
                } else {
                    let style = NumbersStyles.keepingWhatCanBeSaved(
                        cell.style, imported: imported[address].style,
                        canFormat: table.canFormat, isRichText: isRichText(address, in: table)
                    )
                    if style != cell.style {
                        var coerced = cell
                        coerced.style = style
                        result.sheets[index][address] = coerced
                    }
                }
            }
        }
        // Formulas worked out from what was taken back need working out again.
        if violation != nil { result.recalculate() }
        return (result, violation)
    }

    /// Why `workbook` can't be saved over the document it was read from, if
    /// it can't.
    static func violation(in workbook: Workbook, source: NumbersSource) -> Violation? {
        if let violation = structuralViolation(workbook, from: source.imported, source: source) { return violation }
        let sheetNames = NumbersSource.sheetNames(of: workbook, tables: source.tables)
        for sheet in workbook.sheets {
            guard let table = source.tables[sheet.id], let imported = source.imported[sheet.id] else { continue }
            for address in Set(sheet.cells.keys).union(imported.cells.keys) {
                if let reason = problem(with: sheet[address], was: imported[address], at: address, in: table, sheetNames: sheetNames) {
                    return reason
                }
            }
        }
        return nil
    }

    /// Why a cell can't be saved as it is now, if it can't. A formula's
    /// result changing is no change of its own.
    private static func problem(
        with cell: Cell, was original: Cell, at address: CellAddress, in table: NumbersSource.Table,
        sheetNames: [MergeOwners.UUID: String]
    ) -> Violation? {
        let edited = cell.formula != original.formula
            || cell.formula == nil && (cell.value != original.value || cell.style.numberFormat != original.style.numberFormat)
            || NumbersStyles.TextFormat(cell.style) != NumbersStyles.TextFormat(original.style)
            || NumbersStyles.CellFormat(cell.style) != NumbersStyles.CellFormat(original.style)
        guard edited else { return nil }
        if table.isPivot || table.protectedCells.contains(address) { return .protectedCell }
        if let formula = cell.formula, formula != original.formula {
            let context = NumbersFormula.Context(host: address, hostTable: table.uuid, sheetNames: sheetNames)
            if NumbersFormula.nodes(for: formula, context: context) == nil { return .formula }
        }
        return nil
    }

    private static func isRichText(_ address: CellAddress, in table: NumbersSource.Table) -> Bool {
        table.storage[address].flatMap(NumbersCellStorage.init)?.type == NumbersCellStorage.CellType.richText
    }

    /// Why the change from `old` to `new` touches more than cells, sizes, and
    /// rows and columns that can be moved, if it does.
    private static func structuralViolation(_ new: Workbook, from old: Workbook, source: NumbersSource) -> Violation? {
        guard new.sheets.map(\.id) == old.sheets.map(\.id),
              new.definedNames == old.definedNames else { return .structure }
        for (sheet, previous) in zip(new.sheets, old.sheets) where sheet != previous {
            // A sheet takes its name from Numbers' sheet when it has the
            // sheet to itself; one of several tables is named after both.
            if sheet.name != previous.name, source.tables[sheet.id].map({ $0.sharesSheet || $0.sheetIdentifier == nil }) ?? true {
                return .structure
            }
            guard sheet.isHidden == previous.isHidden, sheet.kind == previous.kind,
                  sheet.tabColorHex == previous.tabColorHex,
                  sheet.charts == previous.charts, sheet.comments == previous.comments,
                  sheet.formControls == previous.formControls else { return .structure }
            if sheet.columnCount > previous.columnCount, sheet.columnCount > maximumColumnCount { return .structure }
            guard let table = source.tables[sheet.id], let imported = source.imported[sheet.id] else { continue }
            if let violation = unmergedViolation(sheet, from: previous, table: table, source: source) { return violation }

            let moved = sheet.origins?.hasMoved ?? false
            if moved || previous.origins?.hasMoved ?? false {
                if !canMoveCells(in: table, imported: imported, source: source) { return .movingCells }
                if !keepsEdges(sheet, table: table) { return .movingCells }
            } else {
                guard sheet.rowCount >= previous.rowCount, sheet.columnCount >= previous.columnCount else { return .structure }
            }
            guard sheet.mergedRanges == previous.mergedRanges else { return .structure }
            if sheet.hiddenRows != previous.hiddenRows || sheet.hiddenColumns != previous.hiddenColumns {
                if moved { return .movingCells }
                if !canHide(sheet, table: table, imported: imported) { return .structure }
            }
            if table.isPivot, sheet.rowCount != previous.rowCount || sheet.columnCount != previous.columnCount {
                return .structure
            }
        }
        return nil
    }

    /// Why a change to a table can't be saved for collaboration's changes
    /// to what saving it rewrites, if it can't: the table's own objects, or
    /// for a new name, the sheet's.
    private static func unmergedViolation(
        _ sheet: Worksheet, from previous: Worksheet, table: NumbersSource.Table, source: NumbersSource
    ) -> Violation? {
        if sheet.name != previous.name,
           table.hasUnmergedChanges || table.sheetIdentifier.map(source.archive.patchedObjects.contains) ?? false {
            return .unmergedChanges
        }
        guard table.hasUnmergedChanges else { return nil }
        var renamedBack = sheet
        renamedBack.name = previous.name
        return renamedBack == previous ? nil : .unmergedChanges
    }

    /// Whether rows and columns can be inserted into and deleted from a
    /// table: only where everything that follows cells by where they are is
    /// something Tables moves along with them.
    static func canMoveCells(in table: NumbersSource.Table, imported: Worksheet, source: NumbersSource) -> Bool {
        !source.hasLinkedContent && !table.isPivot && table.rowHeaderBuckets <= 1
            && imported.mergedRanges.isEmpty && imported.hiddenRows.isEmpty && imported.hiddenColumns.isEmpty
            // A formula Tables can't read can't be told where its cells went:
            // neither the cells it refers to nor its own.
            && source.tables.values.allSatisfy { other in
                other.protectedCells.isEmpty
                    || other.modelIdentifier != table.modelIdentifier && !refers(to: table, from: other)
            }
    }

    /// Whether the formulas Tables can't read in `other` may refer to
    /// `table`'s cells.
    private static func refers(to table: NumbersSource.Table, from other: NumbersSource.Table) -> Bool {
        guard let references = other.protectedReferences else { return true }
        guard !references.isEmpty else { return false }
        return table.uuid.map(references.contains) ?? true
    }

    /// The formatting a table keeps: number formats, and the styles
    /// `NumbersStyles` can write where the table has a list of styles to keep
    /// them in. A pivot table is Numbers' own to format, and one
    /// collaboration left unmerged takes no changes at all.
    static func formatting(in table: NumbersSource.Table) -> FormattingKinds {
        if table.isPivot || table.hasUnmergedChanges { return [] }
        return table.canFormat ? [.numberFormats, .styles] : .numberFormats
    }

    /// Whether the rows and columns shown or hidden since the table was read
    /// can be: those Numbers knows by a UUID, and hidden by hand rather than
    /// by a filter or a pivot table.
    private static func canHide(_ sheet: Worksheet, table: NumbersSource.Table, imported: Worksheet) -> Bool {
        let rows = sheet.hiddenRows.symmetricDifference(imported.hiddenRows)
        let columns = sheet.hiddenColumns.symmetricDifference(imported.hiddenColumns)
        return table.hasHiddenStates && !table.isPivot
            && rows.allSatisfy { $0 < min(table.rowCount, table.rowIdentifiers.count) && !table.hidden.lockedRows.contains($0) }
            && columns.allSatisfy {
                $0 < min(table.columnCount, table.columnIdentifiers.count) && !table.hidden.lockedColumns.contains($0)
            }
    }

    /// Whether the header rows and columns and the footer rows are still the
    /// ones the table had, in their places.
    private static func keepsEdges(_ sheet: Worksheet, table: NumbersSource.Table) -> Bool {
        let origins = sheet.origins ?? SheetOrigins()
        let headerRows = (0..<table.headerRows).allSatisfy { origins.row($0) == $0 }
        let headerColumns = (0..<table.headerColumns).allSatisfy { origins.column($0) == $0 }
        let footers = (0..<table.footerRows).allSatisfy { offset in
            origins.row(sheet.rowCount - 1 - offset) == table.rowCount - 1 - offset
        }
        return headerRows && headerColumns && footers && sheet.rowCount > table.headerRows + table.footerRows
    }
}
