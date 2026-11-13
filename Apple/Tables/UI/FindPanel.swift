import SwiftUI
import TablesEngine

/// Finds text in the cells of every sheet, by what they show or by their
/// formulas, goes to the cell picked from the results, and replaces it in
/// one cell or in all of them.
struct FindPanel: View {
    @Binding var workbook: Workbook
    @Bindable var state: EditorState

    @State private var query = ""
    @State private var replacement = ""
    @State private var options = FindOptions()
    /// What the last Replace did, until the search changes.
    @State private var summary: String?
    @FocusState private var isSearching: Bool

    var body: some View {
        let matches = workbook.matches(for: query, options: options)
        Form {
            Section {
                TextField("Find.Placeholder", text: $query)
                    .focused($isSearching)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("findText")
                TextField("Find.ReplacePlaceholder", text: $replacement)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("replaceText")
            } footer: {
                if let summary {
                    Text(summary)
                } else if !query.isEmpty {
                    Text(String.localizedStringWithFormat(String(localized: "Find.Count"), matches.count))
                }
            }

            Section {
                Button("Find.Replace") { replaceOne(in: matches) }
                    .accessibilityIdentifier("replaceOne")
                Button("Find.ReplaceAll") { replaceAll() }
                    .accessibilityIdentifier("replaceAll")
            }
            .disabled(matches.isEmpty)

            Section {
                Toggle("Find.MatchCase", isOn: $options.matchesCase)
                Toggle("Find.MatchWholeCell", isOn: $options.matchesWholeCell)
                Picker("Find.LookIn", selection: $options.lookIn) {
                    ForEach(FindOptions.LookIn.allCases, id: \.self) { lookIn in
                        Text(lookIn.title).tag(lookIn)
                    }
                }
            }

            if !matches.isEmpty {
                Section("Find.Section.Results") {
                    ForEach(matches) { match in
                        result(match)
                    }
                }
            }
        }
        .onAppear { isSearching = true }
        .onChange(of: query) { summary = nil }
        .onChange(of: options) { summary = nil }
    }

    /// Replaces the selected match, or the next one, then goes to the match
    /// after it.
    private func replaceOne(in matches: [FindMatch]) {
        guard let sheetID = state.activeSheetID,
              let target = FindReplace.target(
                  in: matches, sheetID: sheetID, address: state.selectedAddress, workbook: workbook
              ) else { return }
        var book = workbook
        let result = book.replace([target], query: query, with: replacement, options: options)
        workbook = book
        summary = FindReplace.summary(of: result)
        let remaining = book.matches(for: query, options: options)
        if let next = FindReplace.next(after: target.sheetID, target.address, in: remaining, workbook: book) {
            show(next)
        }
    }

    /// Replaces every match in the workbook, as one step to undo.
    private func replaceAll() {
        var book = workbook
        let result = book.replaceAll(query, with: replacement, options: options)
        workbook = book
        summary = FindReplace.summary(of: result)
    }

    private func result(_ match: FindMatch) -> some View {
        Button {
            show(match)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(location(of: match))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(match.text)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            }
        }
    }

    /// The cell's address, led by its sheet's name when the workbook has more
    /// than one sheet.
    private func location(of match: FindMatch) -> String {
        guard workbook.sheets.count > 1, let sheet = workbook[match.sheetID] else { return match.address.a1 }
        return sheet.name + " · " + match.address.a1
    }

    /// Brings the match's sheet up and selects the cell, scrolled into view.
    private func show(_ match: FindMatch) {
        if state.activeSheetID != match.sheetID {
            state.selectSheet(match.sheetID, in: workbook)
        }
        guard let sheet = workbook[match.sheetID] else { return }
        state.select(match.address, in: sheet)
        state.scrollTarget = match.address
    }
}
