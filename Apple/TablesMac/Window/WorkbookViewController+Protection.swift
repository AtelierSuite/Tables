import AppKit
import TablesEngine

/// Protecting and unprotecting the sheet in front and the workbook, from
/// the Table menu.
extension WorkbookViewController {
    @objc func toggleSheetProtection(_ sender: Any?) {
        guard let document else { return }
        var request: ProtectionRequest?
        commitPendingEdit()
        document.edit { request = document.state.sheetProtectionRequest(in: &$0) }
        ask(request)
    }

    @objc func toggleWorkbookProtection(_ sender: Any?) {
        guard let document else { return }
        var request: ProtectionRequest?
        commitPendingEdit()
        document.edit { request = document.state.workbookProtectionRequest(in: &$0) }
        ask(request)
    }

    private func commitPendingEdit() {
        if document?.state.editingAddress != nil { grid.commitEditing(then: nil) }
    }

    /// Asks for the password a request needs — and, protecting a sheet, what
    /// to go on allowing — then carries it out.
    private func ask(_ request: ProtectionRequest?) {
        guard let request, let document, let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = request.heading
        alert.informativeText = request.message
        alert.addButton(withTitle: String(localized: request.isProtecting ? "Protection.Protect" : "Protection.Unprotect"))
        alert.addButton(withTitle: String(localized: "Common.Cancel"))

        let field = NSSecureTextField()
        field.placeholderString = String(
            localized: request.isProtecting ? "Protection.Password.Optional" : "Protection.Password")
        field.setAccessibilityIdentifier("protectionPassword")
        let stack = NSStackView(views: [field])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        var boxes: [(SheetProtection.Action, NSButton)] = []
        if request == .protectSheet {
            let heading = NSTextField(labelWithString: String(localized: "Protection.Allow.Title"))
            heading.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            heading.textColor = .secondaryLabelColor
            stack.addArrangedSubview(heading)
            stack.setCustomSpacing(12, after: field)
            for action in SheetProtection.Action.offered {
                let box = NSButton(checkboxWithTitle: action.label, target: nil, action: nil)
                box.controlSize = .small
                box.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
                stack.addArrangedSubview(box)
                boxes.append((action, box))
            }
        }
        field.widthAnchor.constraint(equalToConstant: 260).isActive = true
        stack.setFrameSize(stack.fittingSize)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = field

        alert.beginSheetModal(for: window) { [weak document] response in
            guard response == .alertFirstButtonReturn, let document else { return }
            var allowed = SheetProtection.defaultAllowed
            for (action, box) in boxes where box.state == .on { allowed.insert(action) }
            let password = field.stringValue
            document.edit { document.state.complete(request, password: password, allowing: allowed, in: &$0) }
            document.notify()
        }
    }
}
