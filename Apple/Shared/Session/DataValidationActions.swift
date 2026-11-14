import SwiftUI
import TablesEngine

/// What a failed entry is answered with: the rule's own title and message,
/// and the entry itself for the alerts that let it through after all.
struct ValidationAlert: Equatable, Identifiable {
    let id = UUID()
    var style: DataValidation.AlertStyle
    var title: String
    var message: String
    var sheetID: Worksheet.ID
    var address: CellAddress
    /// What was typed, as typed.
    var text: String

    /// Whether the person may keep the entry: everything but a stop.
    var offersKeeping: Bool { style != .stop }

    static func == (lhs: ValidationAlert, rhs: ValidationAlert) -> Bool { lhs.id == rhs.id }
}

extension EditorState {
    // MARK: - The rule under the selection

    /// The rule the selected cell answers to, when the document keeps rules.
    func selectedDataValidation(in workbook: Workbook) -> DataValidation? {
        guard allowsDataValidation else { return nil }
        return activeSheet(in: workbook).dataValidation(at: selectedAddress)
    }

    /// The list rule whose arrow the selected cell shows: one cell selected,
    /// and nothing being typed into it.
    func dropDownRule(in workbook: Workbook) -> DataValidation? {
        guard !hasMultipleSelections, editingAddress == nil, !isTableUnfocused,
              let rule = selectedDataValidation(in: workbook),
              rule.kind == .list, rule.showsDropDown else { return nil }
        let sheet = activeSheet(in: workbook)
        // One cell, or the one merged region it stands for.
        guard sheet.expandedToMerges(CellRange(selectedAddress)) == sheet.expandedToMerges(selection) else {
            return nil
        }
        return rule
    }

    /// The entries the selected cell's list offers, or nil when it shows no arrow.
    func dropDownItems(in workbook: Workbook) -> [String]? {
        guard let rule = dropDownRule(in: workbook) else { return nil }
        return workbook.dataValidationItems(for: rule, at: selectedAddress, sheetIndex: activeIndex(in: workbook))
    }

    /// The input message to show beside the selected cell.
    func inputMessage(in workbook: Workbook) -> (title: String, message: String)? {
        guard let rule = selectedDataValidation(in: workbook), rule.hasInputMessage else { return nil }
        return (rule.promptTitle ?? "", rule.promptMessage ?? "")
    }

    // MARK: - Entering

    /// Puts an entry picked from a list into the selected cell.
    func enter(_ text: String, in workbook: inout Workbook) {
        let sheet = activeSheet(in: workbook)
        let address = sheet.mergedRange(containing: selectedAddress)?.normalized.start ?? selectedAddress
        editingAddress = address
        editingText = text
        commitEditing(in: &workbook, then: nil)
    }

    /// Turns away an entry its cell's rule fails, leaving the alert to show.
    /// True when the entry must not be written.
    func refuses(_ cell: Cell, typedAs text: String, at address: CellAddress, in workbook: Workbook) -> Bool {
        guard allowsDataValidation else { return false }
        let index = activeIndex(in: workbook)
        guard let rule = workbook.dataValidationFailure(entering: cell, at: address, sheetIndex: index) else {
            return false
        }
        let title = rule.errorTitle ?? ""
        let message = rule.errorMessage ?? ""
        validationAlert = ValidationAlert(
            style: rule.alertStyle,
            title: title.isEmpty ? String(localized: "DataValidation.Alert.DefaultTitle") : title,
            message: message.isEmpty ? String(localized: "DataValidation.Alert.DefaultMessage") : message,
            sheetID: workbook.sheets[index].id, address: address, text: text)
        return true
    }

    /// Writes the entry an alert was raised over after all, as a warning
    /// or an information alert lets the person choose to.
    func keepEntry(of alert: ValidationAlert, in workbook: inout Workbook) {
        guard alert.offersKeeping, let index = workbook.index(of: alert.sheetID),
              workbook.sheets[index].contains(alert.address) else { return }
        let existing = workbook.sheets[index][alert.address]
        workbook.sheets[index][alert.address] = CellInputParser.cell(from: alert.text, replacing: existing)
        workbook.recalculate()
    }

    // MARK: - Editing rules

    /// Gives every selected range the one rule, or with nil takes theirs away.
    func setDataValidation(_ rule: DataValidation?, in workbook: inout Workbook) {
        let index = activeIndex(in: workbook)
        let sheet = workbook.sheets[index]
        workbook.sheets[index].setDataValidation(rule, for: selectedRanges.map { sheet.expandedToMerges($0) })
    }
}
