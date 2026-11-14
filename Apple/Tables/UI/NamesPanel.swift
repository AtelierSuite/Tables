import SwiftUI
import TablesEngine

/// The workbook's names: each with where it can be used and what it refers
/// to. Tapping one goes to its range; a name is made from the selection,
/// changed, or deleted from here. Excel's own names and hidden ones are kept
/// in the file but not listed.
struct NamesPanel: View {
    @Binding var workbook: Workbook
    @Bindable var state: EditorState

    @State private var draft: DefinedNameDraft?

    var body: some View {
        let names = workbook.editableDefinedNames
        let kept = workbook.definedNames.count - names.count
        Form {
            Section {
                Button("Names.NewFromSelection", systemImage: "plus.circle") {
                    draft = DefinedNameDraft(
                        name: state.suggestedName(in: workbook),
                        refersTo: state.selectionFormula(in: workbook)
                    )
                }
                .accessibilityIdentifier("names.new")
            } footer: {
                Text(state.selectionFormula(in: workbook))
                    .font(.caption.monospaced())
            }

            if names.isEmpty {
                Section {
                    Text("Names.Empty")
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(scopes(of: names), id: \.self) { scope in
                Section {
                    ForEach(names.filter { $0.scope == scope }, id: \.self) { name in
                        row(name)
                    }
                } header: {
                    Text(EditorState.scopeLabel(scope, in: workbook))
                } footer: {
                    if scope == scopes(of: names).last, kept > 0 {
                        Text(String.localizedStringWithFormat(String(localized: "Names.Kept.Footer"), kept))
                    }
                }
            }
        }
        .navigationDestination(item: $draft) { draft in
            DefinedNameEditor(workbook: workbook, draft: draft) { saved in
                do throws(DefinedNameError) {
                    try state.save(saved, in: &workbook)
                    self.draft = nil
                    return nil
                } catch {
                    return error
                }
            } cancel: {
                self.draft = nil
            }
            .navigationTitle(draft.isNew ? "Names.New.Title" : "Names.Edit.Title")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden()
        }
    }

    /// The workbook first, then each sheet with names of its own, in order.
    private func scopes(of names: [DefinedName]) -> [Worksheet.ID?] {
        var seen: [Worksheet.ID?] = []
        for name in names where !seen.contains(name.scope) { seen.append(name.scope) }
        return seen
    }

    private func row(_ name: DefinedName) -> some View {
        HStack {
            Button {
                if state.go(to: name, in: workbook) { state.presentedPanel = nil }
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(name.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("=" + name.formula)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(!state.canGo(to: name, in: workbook))
            .accessibilityIdentifier("names.row.\(name.name)")

            Button("Names.Edit", systemImage: "info.circle") {
                draft = DefinedNameDraft(editing: name)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .accessibilityIdentifier("names.edit.\(name.name)")
        }
        .swipeActions {
            Button("Names.Delete", systemImage: "trash", role: .destructive) { delete(name) }
            Button("Names.Edit", systemImage: "pencil") { draft = DefinedNameDraft(editing: name) }
                .tint(.blue)
        }
        .contextMenu {
            Button("Names.GoTo", systemImage: "arrow.right.circle") {
                if state.go(to: name, in: workbook) { state.presentedPanel = nil }
            }
            .disabled(!state.canGo(to: name, in: workbook))
            Button("Names.Edit", systemImage: "pencil") { draft = DefinedNameDraft(editing: name) }
            Button("Names.Delete", systemImage: "trash", role: .destructive) { delete(name) }
        }
    }

    private func delete(_ name: DefinedName) {
        var changed = workbook
        guard (try? changed.removeDefinedName(name.name, scope: name.scope)) != nil else { return }
        workbook = changed
    }
}
