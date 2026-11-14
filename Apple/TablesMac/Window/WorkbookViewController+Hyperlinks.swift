import AppKit
import TablesEngine

/// Adding, editing, removing and following the link on a cell.
extension WorkbookViewController {
    /// Asks for the link on the selected cell: where it goes, and the text
    /// the cell shows. Editing a link starts from what it has.
    @objc func editHyperlink(_ sender: Any?) {
        guard let document, let window = view.window else { return }
        let state = document.state
        if state.editingAddress != nil { grid.commitEditing(then: nil) }
        let address = state.selectedAddress
        let existing = state.storedHyperlink(at: address, in: document.workbook)

        let target = NSTextField(string: existing?.target ?? "")
        target.placeholderString = String(localized: "Hyperlink.Target.Placeholder")
        let display = NSTextField(string: state.hyperlinkDisplayText(at: address, in: document.workbook))
        display.placeholderString = String(localized: "Hyperlink.Display.Placeholder")
        let form = NSGridView(views: [
            [NSTextField(labelWithString: String(localized: "Hyperlink.Target")), target],
            [NSTextField(labelWithString: String(localized: "Hyperlink.Display")), display],
        ])
        form.column(at: 0).xPlacement = .trailing
        form.rowAlignment = .firstBaseline
        target.widthAnchor.constraint(equalToConstant: 260).isActive = true
        form.frame = NSRect(origin: .zero, size: form.fittingSize)

        let alert = NSAlert()
        alert.messageText = existing == nil
            ? String(localized: "Hyperlink.Add.Title") : String(localized: "Hyperlink.Edit.Title")
        alert.informativeText = String(localized: "Hyperlink.Message")
        alert.accessoryView = form
        alert.addButton(withTitle: String(localized: "Common.OK"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        if existing != nil { alert.addButton(withTitle: String(localized: "Hyperlink.Remove")) }
        alert.window.initialFirstResponder = target
        alert.beginSheetModal(for: window) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn:
                self?.editLinks { state, workbook in
                    if !state.setHyperlink(target.stringValue, display: display.stringValue, at: address, in: &workbook) {
                        NSSound.beep()
                    }
                }
            case .alertThirdButtonReturn:
                self?.editLinks { state, workbook in state.removeHyperlinks(in: &workbook) }
            default:
                break
            }
        }
    }

    @objc func removeHyperlink(_ sender: Any?) {
        editLinks { state, workbook in state.removeHyperlinks(in: &workbook) }
    }

    /// Follows the selected cell's link: opens an outside address, or goes
    /// to the place in the workbook it names.
    @objc func openHyperlink(_ sender: Any?) {
        guard let document else { return }
        let state = document.state
        switch state.hyperlinkDestination(at: state.selectedAddress, in: document.workbook) {
        case .external(let address)?:
            guard let url = EditorState.url(forHyperlinkAddress: address) else { return NSSound.beep() }
            NSWorkspace.shared.open(url)
        case .cells(let sheet, let range)?:
            if state.activeSheetID != sheet { document.selectSheet(sheet) }
            state.reveal(range, in: document.workbook)
            view.window?.makeFirstResponder(grid)
            document.notify()
        case nil:
            NSSound.beep()
        }
    }

    private func editLinks(_ change: (EditorState, inout Workbook) -> Void) {
        guard let document else { return }
        let state = document.state
        document.edit { change(state, &$0) }
        document.notify()
    }
}
