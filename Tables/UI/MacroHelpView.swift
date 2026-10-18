import SwiftUI
import TablesEngine

/// The macro help book: how macros run here, and what of VBA and Excel's
/// objects Tables can run — and plainly, what it cannot. Searching answers
/// "does this work?" for any name in it.
struct MacroHelpView: View {
    @State private var query = ""

    var body: some View {
        List {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                Section {
                    ForEach(MacroHelp.topics) { topic in
                        NavigationLink(value: topic) {
                            Label(topic.title, systemImage: topic.symbol)
                        }
                        .accessibilityIdentifier("helpTopic.\(topic.id)")
                    }
                } footer: {
                    Text("Help.Footer")
                }
            } else {
                searchResults
            }
        }
        .navigationTitle("Help.Title")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .searchable(text: $query, prompt: Text("Help.Search.Prompt"))
        .navigationDestination(for: MacroHelp.Topic.self) { MacroHelpTopicView(topic: $0) }
    }

    @ViewBuilder
    private var searchResults: some View {
        let results = MacroHelp.search(query)
        if results.isEmpty {
            ContentUnavailableView {
                Label("Help.Search.NoResults.Title", systemImage: "questionmark.circle")
            } description: {
                Text(String(format: String(localized: "Help.Search.NoResults.Message"), query))
            }
        }
        ForEach(results) { entry in
            NavigationLink(value: entry.topic) {
                HStack(spacing: 12) {
                    Image(systemName: entry.group.isAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(entry.group.isAvailable ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.group.isCode ? "\(entry.group.title).\(entry.name)" : entry.name)
                            .font(.system(.body, design: .monospaced))
                        Text(entry.group.isAvailable
                             ? String(format: String(localized: "Help.Search.Available"), entry.topic.title)
                             : String(localized: "Help.Search.Unavailable"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// Opens the help book over whatever is showing.
struct MacroHelpButton: View {
    @State private var isShowingHelp = false

    var body: some View {
        Button("Help.Title", systemImage: "book") { isShowingHelp = true }
            .help(String(localized: "Help.Title"))
            .accessibilityIdentifier("macroHelp")
            .sheet(isPresented: $isShowingHelp) {
                NavigationStack {
                    MacroHelpView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button(role: .confirm) { isShowingHelp = false }
                            }
                        }
                }
                .presentationContentInteraction(.scrolls)
                #if os(macOS)
                .frame(minWidth: 520, minHeight: 560)
                #endif
            }
    }
}

/// One topic: a few paragraphs, then the names it covers, available first.
private struct MacroHelpTopicView: View {
    let topic: MacroHelp.Topic

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(topic.paragraphs, id: \.self) { key in
                    Text(LocalizedStringKey(key))
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(topic.groups) { group in
                    GroupView(group: group)
                }
            }
            .padding()
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(topic.title)
    }
}

private struct GroupView: View {
    let group: MacroHelp.Group

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: group.isAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(group.isAvailable ? .green : .secondary)
                Text(group.displayTitle)
                    .font(group.isCode ? .system(.headline, design: .monospaced) : .headline)
                if group.isCode, !group.isAvailable {
                    Text("Help.Unavailable")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            FlowLayout(spacing: 6) {
                ForEach(group.items, id: \.self) { item in
                    Text(item)
                        .font(.system(.callout, design: .monospaced))
                        .strikethrough(!group.isAvailable, color: .secondary)
                        .foregroundStyle(group.isAvailable ? .primary : .secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            group.isAvailable ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.1),
                            in: .capsule
                        )
                }
            }
            if let note = group.note {
                Text(LocalizedStringKey(note))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 16))
    }
}

/// Lays its children out in rows, wrapping to the next row when one is full.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map { row in row.map(\.size.width).reduce(0, +) + spacing * CGFloat(max(0, row.count - 1)) }
            .max() ?? 0
        let height = rows.map { $0.map(\.size.height).max() ?? 0 }.reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: min(width, proposal.width ?? width), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            let height = row.map(\.size.height).max() ?? 0
            for item in row {
                subviews[item.index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += height + spacing
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [[(index: Int, size: CGSize)]] {
        var rows: [[(index: Int, size: CGSize)]] = [[]]
        var rowWidth: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if !rows[rows.count - 1].isEmpty, rowWidth + spacing + size.width > width {
                rows.append([])
                rowWidth = 0
            }
            rowWidth += (rows[rows.count - 1].isEmpty ? 0 : spacing) + size.width
            rows[rows.count - 1].append((index, size))
        }
        return rows
    }
}
