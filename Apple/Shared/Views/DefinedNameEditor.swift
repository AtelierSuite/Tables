import SwiftUI
import TablesEngine

/// A name being made or changed, before it is saved.
struct DefinedNameDraft: Identifiable, Hashable {
    var name: String
    /// What it refers to, as typed: `=Sheet1!$A$1:$B$4`.
    var refersTo: String
    var scope: Worksheet.ID?
    /// The name as it is in the workbook, when changing one.
    var original: DefinedName?

    var id: String { original.map { "\($0.scope?.uuidString ?? "")/\($0.name)" } ?? "new" }
    var isNew: Bool { original == nil }

    init(editing name: DefinedName) {
        self.name = name.name
        refersTo = "=" + name.formula
        scope = name.scope
        original = name
    }

    init(name: String, refersTo: String, scope: Worksheet.ID? = nil) {
        self.name = name
        self.refersTo = refersTo
        self.scope = scope
        original = nil
    }
}

extension EditorState {
    /// Saves a draft as one change: a new name, or a renamed or repointed one
    /// with every formula using it following the new name.
    func save(_ draft: DefinedNameDraft, in workbook: inout Workbook) throws(DefinedNameError) {
        var changed = workbook
        if let original = draft.original {
            let newName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            // Both are checked before either is made, so a refusal changes nothing.
            if let error = changed.definedNameError(for: newName, scope: original.scope, replacing: original) {
                throw error
            }
            _ = try Workbook.definedNameFormula(from: draft.refersTo)
            try changed.setDefinedNameFormula(original.name, scope: original.scope, to: draft.refersTo)
            try changed.renameDefinedName(original.name, scope: original.scope, to: newName)
        } else {
            try changed.addDefinedName(draft.name, refersTo: draft.refersTo, scope: draft.scope)
        }
        workbook = changed
    }
}

/// The fields of a name: what it is called, where it can be used, and what
/// it refers to. Excel's rules are checked as the name is typed, and once
/// more on saving, with what is wrong said under the field.
struct DefinedNameEditor: View {
    let workbook: Workbook
    @State var draft: DefinedNameDraft
    /// Saves the draft, or says why it can't be.
    let save: (DefinedNameDraft) -> DefinedNameError?
    let cancel: () -> Void

    @State private var refusal: DefinedNameError?
    @FocusState private var isNameFocused: Bool

    private var nameError: DefinedNameError? {
        let trimmed = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || refusal == .empty else { return nil }
        return workbook.definedNameError(for: trimmed, scope: draft.scope, replacing: draft.original)
    }

    var body: some View {
        Form {
            Section {
                TextField("Names.Field.Name", text: $draft.name, prompt: Text("Names.Field.Name.Prompt"))
                    .focused($isNameFocused)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .accessibilityIdentifier("names.name")
                if draft.isNew {
                    Picker("Names.Field.Scope", selection: $draft.scope) {
                        Text("Names.Scope.Workbook").tag(Worksheet.ID?.none)
                        ForEach(workbook.sheets.filter { !$0.isChartSheet }) { sheet in
                            Text(sheet.name).tag(Optional(sheet.id))
                        }
                    }
                    .accessibilityIdentifier("names.scope")
                } else {
                    LabeledContent("Names.Field.Scope", value: EditorState.scopeLabel(draft.scope, in: workbook))
                }
            } footer: {
                if let error = nameError {
                    Label(error.message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("names.error")
                }
            }

            Section {
                TextField("Names.Field.RefersTo", text: $draft.refersTo)
                    .font(.body.monospaced())
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .accessibilityIdentifier("names.refersTo")
            } header: {
                Text("Names.Field.RefersTo")
            } footer: {
                if refusal == .invalidFormula {
                    Label(DefinedNameError.invalidFormula.message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                } else {
                    Text("Names.Field.RefersTo.Footer")
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: draft) { _, _ in refusal = nil }
        .onAppear { isNameFocused = draft.isNew }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Names.Cancel", action: cancel)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(draft.isNew ? "Names.Add" : "Names.Save") {
                    refusal = save(draft)
                }
                .disabled(nameError != nil)
                .accessibilityIdentifier("names.save")
            }
        }
    }
}
