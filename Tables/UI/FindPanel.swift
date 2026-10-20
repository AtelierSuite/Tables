import SwiftUI
import TablesEngine

/// Finds text in the cells of every sheet, by what they show or by their
/// formulas, and goes to the cell picked from the results.
struct FindPanel: View {
    @Binding var workbook: Workbook
    @Bindable var state: EditorState

    @State private var query = ""
    @State private var matchesCase = false
    @FocusState private var isSearching: Bool

    var body: some View {
        let matches = workbook.matches(for: query, matchesCase: matchesCase)
        Form {
            Section {
                TextField("Find.Placeholder", text: $query)
                    .focused($isSearching)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("findText")
                Toggle("Find.MatchCase", isOn: $matchesCase)
            } footer: {
                if !query.isEmpty {
                    Text(String.localizedStringWithFormat(String(localized: "Find.Count"), matches.count))
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
