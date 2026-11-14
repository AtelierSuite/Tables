import SwiftUI
import TablesEngine

/// A question about protection waiting on a password: asked for when
/// protecting, and when unprotecting something that was given one.
enum ProtectionRequest: String, Identifiable, Hashable {
    case protectSheet, unprotectSheet, protectWorkbook, unprotectWorkbook

    var id: String { rawValue }

    var isProtecting: Bool { self == .protectSheet || self == .protectWorkbook }

    var title: String {
        switch self {
        case .protectSheet: return String(localized: "Protection.ProtectSheet")
        case .unprotectSheet: return String(localized: "Protection.UnprotectSheet")
        case .protectWorkbook: return String(localized: "Protection.ProtectWorkbook")
        case .unprotectWorkbook: return String(localized: "Protection.UnprotectWorkbook")
        }
    }

    /// The title without the ellipsis a menu item ends in.
    var heading: String { title.trimmingCharacters(in: CharacterSet(charactersIn: "…")) }

    var message: String {
        switch self {
        case .protectSheet: return String(localized: "Protection.Protect.Sheet.Message")
        case .protectWorkbook: return String(localized: "Protection.Protect.Workbook.Message")
        case .unprotectSheet, .unprotectWorkbook: return String(localized: "Protection.Unprotect.Message")
        }
    }
}

extension SheetProtection.Action {
    /// The actions a person is offered when protecting a sheet: those Tables
    /// has a way of doing.
    static let offered: [SheetProtection.Action] = [
        .formatCells, .formatColumns, .formatRows, .insertColumns, .insertRows,
        .deleteColumns, .deleteRows, .objects,
    ]

    var label: String {
        switch self {
        case .formatCells: return String(localized: "Protection.Allow.FormatCells")
        case .formatColumns: return String(localized: "Protection.Allow.FormatColumns")
        case .formatRows: return String(localized: "Protection.Allow.FormatRows")
        case .insertColumns: return String(localized: "Protection.Allow.InsertColumns")
        case .insertRows: return String(localized: "Protection.Allow.InsertRows")
        case .deleteColumns: return String(localized: "Protection.Allow.DeleteColumns")
        case .deleteRows: return String(localized: "Protection.Allow.DeleteRows")
        case .objects: return String(localized: "Protection.Allow.Objects")
        default: return rawValue
        }
    }
}

/// Turning sheet and workbook protection on and off.
extension EditorState {
    /// What choosing Protect Sheet or Unprotect Sheet has to ask first, or
    /// nil where there is nothing to ask and the sheet is simply unprotected.
    func sheetProtectionRequest(in workbook: inout Workbook) -> ProtectionRequest? {
        let index = activeIndex(in: workbook)
        guard workbook.sheets[index].isProtected else { return .protectSheet }
        if workbook.sheets[index].protection?.password.isSet == true { return .unprotectSheet }
        workbook.sheets[index].unprotect()
        return nil
    }

    /// The same for the workbook's structure.
    func workbookProtectionRequest(in workbook: inout Workbook) -> ProtectionRequest? {
        guard workbook.isStructureLocked else { return .protectWorkbook }
        if workbook.protection?.password.isSet == true { return .unprotectWorkbook }
        workbook.unprotect()
        return nil
    }

    /// Carries a request out with the password typed for it. A wrong
    /// password changes nothing and says so.
    func complete(
        _ request: ProtectionRequest, password: String,
        allowing allowed: Set<SheetProtection.Action> = SheetProtection.defaultAllowed,
        in workbook: inout Workbook
    ) {
        let index = activeIndex(in: workbook)
        switch request {
        case .protectSheet:
            workbook.sheets[index].protect(password: password, allowing: allowed)
            cancelEditing()
        case .protectWorkbook:
            workbook.protect(password: password)
        case .unprotectSheet:
            if !workbook.sheets[index].unprotect(password: password) {
                errorMessage = String(localized: "Protection.WrongPassword")
            }
        case .unprotectWorkbook:
            if !workbook.unprotect(password: password) {
                errorMessage = String(localized: "Protection.WrongPassword")
            }
        }
    }

    /// Whether the workbook's sheets can be added, deleted, renamed, hidden
    /// and moved, saying why not when they can't.
    func allowsChangingSheets(in workbook: Workbook) -> Bool {
        guard workbook.isStructureLocked else { return true }
        errorMessage = ProtectionPolicy.Violation.workbookStructure.localizedDescription
        return false
    }
}
