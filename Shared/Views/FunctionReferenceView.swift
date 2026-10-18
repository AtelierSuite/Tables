import SwiftUI

/// The function reference: every function Tables calculates, browsed by
/// Excel's categories or searched by name and purpose, with how each is
/// written and an example.
struct FunctionReferenceView: View {
    /// Starts the function in the workbook being edited, when there is one.
    var insert: ((FunctionReference) -> Void)?

    /// What the sidebar picks: every function, or one category.
    private enum Scope: Hashable {
        case all
        case category(FunctionReference.Category)
    }

    @State private var scope: Scope? = .all
    @State private var selection: FunctionReference.ID?
    @State private var query = ""

    private var category: FunctionReference.Category? {
        if case .category(let category) = scope { return category }
        return nil
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $scope) {
                NavigationLink(value: Scope.all) {
                    Label("FunctionReference.All", systemImage: "function")
                }
                Section("FunctionReference.Categories") {
                    ForEach(FunctionReference.Category.allCases) { category in
                        NavigationLink(value: Scope.category(category)) {
                            Label(category.title, systemImage: category.symbol)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } content: {
            let entries = FunctionReference.entries(in: category, matching: query)
            List(entries, selection: $selection) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.system(.body, design: .monospaced, weight: .medium))
                    Text(entry.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(.vertical, 2)
            }
            .overlay {
                if entries.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .navigationTitle(category?.title ?? String(localized: "FunctionReference.All"))
            .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } detail: {
            if let entry = selection.flatMap({ id in FunctionReference.all.first { $0.id == id } }) {
                FunctionReferenceDetail(entry: entry, insert: insert)
                    // A view of its own per function, so the detail never
                    // holds on to the last one while the list moves on.
                    .id(entry.id)
            } else {
                ContentUnavailableView("FunctionReference.NoSelection", systemImage: "function")
            }
        }
        .searchable(text: $query, placement: .sidebar, prompt: Text("FunctionReference.Search"))
    }
}

/// One function, written out.
private struct FunctionReferenceDetail: View {
    let entry: FunctionReference
    var insert: ((FunctionReference) -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.name)
                        .font(.system(.largeTitle, design: .monospaced, weight: .semibold))
                        .textSelection(.enabled)
                    Label(entry.category.title, systemImage: entry.category.symbol)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text(entry.summary)
                    .font(.title3)
                    .fixedSize(horizontal: false, vertical: true)
                section("FunctionReference.Syntax", text: entry.syntax)
                section("FunctionReference.Example", text: entry.example)
                if let insert {
                    Button {
                        insert(entry)
                    } label: {
                        Label("FunctionReference.Insert", systemImage: "plus.circle")
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(entry.name)
    }

    private func section(_ title: LocalizedStringKey, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            Text(text)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
        }
    }
}
