import AppKit
import SwiftUI
import TablesEngine

/// Data validation: the rule editor, and the alert a failed entry raises.
extension WorkbookViewController {
    /// Shows the rule of the selected cells in a sheet on the window.
    @objc func editDataValidation(_ sender: Any?) {
        guard let document else { return }
        let state = document.state
        if state.editingAddress != nil { grid.commitEditing(then: nil) }
        weak var sheet: NSViewController?
        let host = NSHostingController(rootView: DataValidationPanel(
            rule: state.selectedDataValidation(in: document.workbook)
        ) { [weak self, weak document] outcome in
            switch outcome {
            case .cancel: break
            case .clear: document?.edit { state.setDataValidation(nil, in: &$0) }
            case .apply(let rule): document?.edit { state.setDataValidation(rule, in: &$0) }
            }
            if let sheet { self?.dismiss(sheet) }
        })
        host.sizingOptions = .preferredContentSize
        sheet = host
        presentAsSheet(host)
    }

    /// Raises the alert for an entry a rule turned away: a stop only says
    /// so, and the other two ask whether to keep the entry anyway.
    func showValidationAlertIfNeeded(in document: WorkbookDocument) {
        guard let pending = document.state.validationAlert, let window = view.window else { return }
        document.state.validationAlert = nil
        let alert = NSAlert()
        alert.messageText = pending.title
        alert.informativeText = pending.message
        switch pending.style {
        case .stop:
            alert.alertStyle = .critical
            alert.addButton(withTitle: String(localized: "Common.OK"))
        case .warning:
            alert.alertStyle = .warning
            alert.informativeText += "\n\n" + String(localized: "DataValidation.Alert.Continue")
            alert.addButton(withTitle: String(localized: "DataValidation.Alert.Yes"))
            alert.addButton(withTitle: String(localized: "DataValidation.Alert.No"))
        case .information:
            alert.alertStyle = .informational
            alert.addButton(withTitle: String(localized: "Common.OK"))
            alert.addButton(withTitle: String(localized: "DataValidation.Alert.Cancel"))
        }
        alert.beginSheetModal(for: window) { [weak document] response in
            guard pending.offersKeeping, response == .alertFirstButtonReturn, let document else { return }
            document.edit { document.state.keepEntry(of: pending, in: &$0) }
        }
    }
}
