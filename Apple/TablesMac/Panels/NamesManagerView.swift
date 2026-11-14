import SwiftUI
import TablesEngine

/// The workbook's names in a sheet over its window, as Excel's Name Manager
/// is: a table of each name, where it can be used and what it refers to,
/// with buttons beneath to add, remove, change and go to one. Excel's own
/// names and hidden ones are kept in the file but not listed.
struct NamesManagerView: View {
    let model: HostedWorkbook
    @Bindable var state: EditorState
    /// Called once a name has been gone to, or Done is clicked.
    let close: () -> Void

    private struct Row: Identifiable {
        let name: DefinedName
        let scope: String
        var id: String { "\(name.scope?.uuidString ?? "")/\(name.name.lowercased())" }
    }

    @State private var selection: Row.ID?
    @State private var draft: DefinedNameDraft?

    private var workbook: Workbook { model.workbook }

    private var rows: [Row] {
        workbook.editableDefinedNames.map { Row(name: $0, scope: EditorState.scopeLabel($0.scope, in: workbook)) }
    }

    private var selected: DefinedName? { rows.first { $0.id == selection }?.name }

    var body: some View {
        let rows = rows
        let kept = workbook.definedNames.count - rows.count
        VStack(alignment: .leading, spacing: 12) {
            Text("Panel.Names.Title")
                .font(.headline)

            Table(rows, selection: $selection) {
                TableColumn("Names.Column.Name") { row in
                    Text(row.name.name).fontWeight(.medium)
                }
                .width(min: 100, ideal: 150)
                TableColumn("Names.Column.Scope", value: \.scope)
                    .width(min: 80, ideal: 110)
                TableColumn("Names.Column.RefersTo") { row in
                    Text("=" + row.name.formula)
                        .font(.body.monospaced())
                        .foregroundStyle(.secondary)
                        .help("=" + row.name.formula)
                }
            }
            .contextMenu(forSelectionType: Row.ID.self) { ids in
                if let id = ids.first, let name = rows.first(where: { $0.id == id })?.name {
                    Button("Names.GoTo") { go(to: name) }
                        .disabled(!state.canGo(to: name, in: workbook))
                    Button("Names.Edit") { draft = DefinedNameDraft(editing: name) }
                    Divider()
                    Button("Names.Delete") { delete(name) }
                }
            } primaryAction: { ids in
                if let id = ids.first, let name = rows.first(where: { $0.id == id })?.name { go(to: name) }
            }
            .overlay {
                if rows.isEmpty {
                    Text("Names.Empty")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                }
            }
            .onDeleteCommand { if let selected { delete(selected) } }
            .accessibilityIdentifier("names.table")

            if kept > 0 {
                Text(String.localizedStringWithFormat(String(localized: "Names.Kept.Footer"), kept))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                ControlGroup {
                    Button {
                        draft = DefinedNameDraft(name: state.suggestedName(in: workbook),
                                                 refersTo: state.selectionFormula(in: workbook))
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help(String(localized: "Names.NewFromSelection"))
                    .accessibilityLabel("Names.NewFromSelection")
                    .accessibilityIdentifier("names.new")
                    Button {
                        if let selected { delete(selected) }
                    } label: {
                        Image(systemName: "minus")
                    }
                    .disabled(selected == nil)
                    .help(String(localized: "Names.Delete"))
                    .accessibilityLabel("Names.Delete")
                    .accessibilityIdentifier("names.delete")
                }
                .fixedSize()

                Button("Names.EditEllipsis") {
                    if let selected { draft = DefinedNameDraft(editing: selected) }
                }
                .disabled(selected == nil)
                .accessibilityIdentifier("names.edit")

                Button("Names.GoTo") {
                    if let selected { go(to: selected) }
                }
                .disabled(selected.map { !state.canGo(to: $0, in: workbook) } ?? true)
                .accessibilityIdentifier("names.goTo")

                Spacer()

                Button("Names.Done", action: close)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 560, idealWidth: 620, minHeight: 360, idealHeight: 420)
        .sheet(item: $draft) { draft in
            DefinedNameEditor(workbook: workbook, draft: draft) { saved in
                do throws(DefinedNameError) {
                    var changed = workbook
                    try state.save(saved, in: &changed)
                    model.binding.wrappedValue = changed
                    self.draft = nil
                    return nil
                } catch {
                    return error
                }
            } cancel: {
                self.draft = nil
            }
            .frame(width: 440)
            .navigationTitle(draft.isNew ? "Names.New.Title" : "Names.Edit.Title")
        }
    }

    private func go(to name: DefinedName) {
        guard state.go(to: name, in: workbook) else { return NSSound.beep() }
        close()
    }

    private func delete(_ name: DefinedName) {
        var changed = workbook
        guard (try? changed.removeDefinedName(name.name, scope: name.scope)) != nil else { return }
        model.binding.wrappedValue = changed
        selection = nil
    }
}
