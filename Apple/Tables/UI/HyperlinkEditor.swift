import SwiftUI
import TablesEngine

/// Asks for a cell's link — where it goes, and the text the cell shows —
/// while `state.hyperlinkEditorAddress` names the cell.
struct HyperlinkEditor: ViewModifier {
    @Binding var workbook: Workbook
    let state: EditorState
    @State private var target = ""
    @State private var display = ""
    @State private var isEditingExisting = false

    func body(content: Content) -> some View {
        content
            .onChange(of: state.hyperlinkEditorAddress) { _, address in
                guard let address else { return }
                let existing = state.storedHyperlink(at: address, in: workbook)
                isEditingExisting = existing != nil
                target = existing?.target ?? ""
                display = state.hyperlinkDisplayText(at: address, in: workbook)
            }
            .alert(
                isEditingExisting ? String(localized: "Hyperlink.Edit.Title") : String(localized: "Hyperlink.Add.Title"),
                isPresented: Binding(
                    get: { state.hyperlinkEditorAddress != nil },
                    set: { if !$0 { state.hyperlinkEditorAddress = nil } }
                )
            ) {
                TextField(String(localized: "Hyperlink.Target.Placeholder"), text: $target)
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                TextField(String(localized: "Hyperlink.Display.Placeholder"), text: $display)
                Button("Common.OK") {
                    guard let address = state.hyperlinkEditorAddress else { return }
                    state.hyperlinkEditorAddress = nil
                    state.setHyperlink(target, display: display, at: address, in: &workbook)
                }
                Button("Cancel", role: .cancel) { state.hyperlinkEditorAddress = nil }
            } message: {
                Text("Hyperlink.Message")
            }
    }
}
