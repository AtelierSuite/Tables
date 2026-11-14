import AppKit
import SwiftUI
import TablesEngine

/// The workbook's names, managed in a sheet over its window.
extension WorkbookViewController {
    @objc func showNames(_ sender: Any?) {
        guard let document, namesSheet == nil else { return }
        if document.state.editingAddress != nil { grid.commitEditing(then: nil) }
        let model = HostedWorkbook(document: document)
        let host = NSHostingController(rootView: NamesManagerView(model: model, state: document.state) { [weak self] in
            self?.closeNames()
        })
        host.sizingOptions = [.preferredContentSize]
        namesObserver = NotificationCenter.default.addObserver(
            forName: .workbookDocumentDidChange, object: document, queue: .main
        ) { _ in
            MainActor.assumeIsolated { model.refresh() }
        }
        namesSheet = host
        presentAsSheet(host)
    }

    /// Puts the sheet away, showing whatever was gone to from it.
    func closeNames() {
        guard let sheet = namesSheet else { return }
        dismiss(sheet)
        namesSheet = nil
        if let namesObserver { NotificationCenter.default.removeObserver(namesObserver) }
        namesObserver = nil
        view.window?.makeFirstResponder(grid)
        document?.notify()
    }
}
