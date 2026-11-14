import SwiftUI
import TablesEngine

/// What a column of the data is called in the panels: its heading, or its
/// letter where it has none.
@MainActor
private func columnTitle(_ column: Int, headerRow: Int?, in sheet: Worksheet) -> String {
    if let headerRow {
        let text = CellFormatter.displayText(for: sheet[CellAddress(row: headerRow, column: column)])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text }
    }
    return String(format: String(localized: "Sort.ColumnName"), CellAddress.columnName(column))
}

/// Sorts the data around the selection by one or more of its columns.
struct SortPanel: View {
    @Binding var workbook: Workbook
    @Bindable var state: EditorState

    @State private var range = CellRange(CellAddress(row: 0, column: 0))
    @State private var hasHeader = false
    @State private var levels: [SortKey] = []

    private var sheet: Worksheet { state.activeSheet(in: workbook) }

    var body: some View {
        Form {
            Section {
                LabeledContent("Sort.Range", value: range.a1)
                Toggle("Sort.HasHeader", isOn: $hasHeader)
            }
            ForEach(levels.indices, id: \.self) { index in
                Section(index == 0 ? "Sort.SortBy" : "Sort.ThenBy") {
                    Picker("Sort.Column", selection: $levels[index].column) {
                        ForEach(Array(range.columnRange), id: \.self) { column in
                            Text(columnTitle(column, headerRow: hasHeader ? range.start.row : nil, in: sheet)).tag(column)
                        }
                    }
                    Picker("Sort.Order", selection: $levels[index].isAscending) {
                        Text("Sort.Order.Ascending").tag(true)
                        Text("Sort.Order.Descending").tag(false)
                    }
                    .pickerStyle(.segmented)
                    if levels.count > 1 {
                        Button("Sort.RemoveLevel", role: .destructive) { levels.remove(at: index) }
                    }
                }
            }
            Section {
                Button("Sort.AddLevel") {
                    let used = Set(levels.map(\.column))
                    let next = range.columnRange.first { !used.contains($0) } ?? range.start.column
                    levels.append(SortKey(column: next))
                }
                .disabled(levels.count >= range.columnRange.count)
                Button("Sort.Apply") {
                    // Closed first, so the Mac's popover goes with the edit that sorts.
                    state.presentedPanel = nil
                    state.sort(range, by: levels, hasHeader: hasHeader, in: &workbook)
                }
                .disabled(levels.isEmpty || range.rowRange.count < (hasHeader ? 3 : 2))
                .accessibilityIdentifier("sort.apply")
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
    }

    /// Starts from the data around the selection, and from the sort the
    /// sheet remembers when it was of the same rows.
    private func load() {
        (range, hasHeader) = state.dataRange(in: workbook)
        let body = hasHeader ? range.rowRange.dropFirst() : range.rowRange[...]
        if let remembered = sheet.sortState, remembered.range.columnRange == range.columnRange,
           remembered.range.rowRange.lowerBound == body.first, remembered.range.rowRange.upperBound == body.last {
            levels = remembered.keys
        } else {
            let column = min(max(state.selectedAddress.column, range.start.column), range.end.column)
            levels = [SortKey(column: column)]
        }
    }
}

/// The sheet's filter, a column at a time: the values it shows, or a
/// condition they must meet.
struct FilterPanel: View {
    @Binding var workbook: Workbook
    @Bindable var state: EditorState

    @State private var search = ""
    @State private var kind = FilterConditionKind.equals
    @State private var conditionValue = ""

    /// How many values the list shows at once; the search narrows a longer one.
    private static let valueLimit = 500

    private var sheet: Worksheet { state.activeSheet(in: workbook) }

    var body: some View {
        Form {
            if let filter = sheet.autoFilter {
                let column = column(in: filter)
                columnSection(column, in: filter)
                valuesSection(column)
                conditionSection(column)
                Section {
                    Button("Filter.ClearColumn") { state.setFilter(nil, forColumn: column, in: &workbook) }
                        .disabled(sheet.filterCriterion(forColumn: column) == nil)
                    Button("Filter.ClearAll") { state.clearFilters(in: &workbook) }
                        .disabled(!filter.isFiltering)
                    Button("Filter.Remove", role: .destructive) { state.toggleAutoFilter(in: &workbook) }
                }
            } else {
                Section {
                    Text("Filter.None.Message").foregroundStyle(.secondary)
                    Button("Filter.Add") { state.toggleAutoFilter(in: &workbook) }
                        .accessibilityIdentifier("filter.add")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: loadCondition)
        .onChange(of: state.filterColumn) { loadCondition() }
    }

    private func column(in filter: AutoFilter) -> Int {
        min(max(state.filterColumn ?? state.selectedAddress.column, filter.range.start.column), filter.range.end.column)
    }

    @ViewBuilder
    private func columnSection(_ column: Int, in filter: AutoFilter) -> some View {
        Section {
            Picker("Filter.Column", selection: Binding(get: { column }, set: { state.filterColumn = $0 })) {
                ForEach(Array(filter.range.columnRange), id: \.self) { column in
                    Text(columnTitle(column, headerRow: filter.range.start.row, in: sheet)).tag(column)
                }
            }
            Button("Sort.Ascending") { sort(column, ascending: true, in: filter) }
            Button("Sort.Descending") { sort(column, ascending: false, in: filter) }
        }
    }

    private func sort(_ column: Int, ascending: Bool, in filter: AutoFilter) {
        state.sort(filter.range, by: [SortKey(column: column, isAscending: ascending)], hasHeader: true, in: &workbook)
    }

    // MARK: Values

    @ViewBuilder
    private func valuesSection(_ column: Int) -> some View {
        let list = sheet.filterValues(forColumn: column)
        let criterion = sheet.filterCriterion(forColumn: column)
        let matches = search.isEmpty ? list.values : list.values.filter { $0.localizedCaseInsensitiveContains(search) }
        Section("Filter.Values") {
            if list.values.count > 12 {
                TextField("Filter.Search", text: $search)
            }
            Button("Filter.SelectAll") { state.setFilter(nil, forColumn: column, in: &workbook) }
                .disabled(criterion == nil)
            ForEach(matches.prefix(Self.valueLimit), id: \.self) { value in
                valueRow(value, isOn: isShown(value, by: criterion)) { toggle(value, column: column, list: list) }
            }
            if matches.count > Self.valueLimit {
                Text(String(format: String(localized: "Filter.MoreValues"), matches.count - Self.valueLimit))
                    .foregroundStyle(.secondary)
            }
            if list.hasBlanks, search.isEmpty {
                valueRow(String(localized: "Filter.Blanks"), isOn: isShown(nil, by: criterion)) {
                    toggle(nil, column: column, list: list)
                }
            }
        }
    }

    private func valueRow(_ title: String, isOn: Bool, toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            HStack {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                Text(title).foregroundStyle(.primary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    /// Whether the list shows a value ticked; nil stands for blank cells.
    private func isShown(_ value: String?, by criterion: AutoFilter.Criterion?) -> Bool {
        switch criterion {
        case nil: return true
        case .values(let values, let includesBlanks, _):
            guard let value else { return includesBlanks }
            return values.contains { $0.caseInsensitiveCompare(value) == .orderedSame }
        default: return false
        }
    }

    /// Ticks or unticks one value. Everything ticked is no filter at all;
    /// the last tick stays, since a list showing nothing is not a filter
    /// Excel can open.
    private func toggle(_ value: String?, column: Int, list: (values: [String], hasBlanks: Bool)) {
        let criterion = sheet.filterCriterion(forColumn: column)
        var shown = Set(list.values.filter { isShown($0, by: criterion) }.map { $0.lowercased() })
        var blanks = list.hasBlanks && isShown(nil, by: criterion)
        if let value {
            if shown.remove(value.lowercased()) == nil { shown.insert(value.lowercased()) }
        } else {
            blanks.toggle()
        }
        guard !shown.isEmpty || blanks else { return }
        let kept = list.values.filter { shown.contains($0.lowercased()) }
        if kept.count == list.values.count, blanks == list.hasBlanks {
            state.setFilter(nil, forColumn: column, in: &workbook)
        } else {
            state.setFilter(.values(Set(kept), includesBlanks: blanks), forColumn: column, in: &workbook)
        }
    }

    // MARK: Condition

    @ViewBuilder
    private func conditionSection(_ column: Int) -> some View {
        Section("Filter.Condition") {
            Picker("Filter.Condition.Kind", selection: $kind) {
                ForEach(FilterConditionKind.allCases) { kind in Text(kind.title).tag(kind) }
            }
            TextField("Filter.Condition.Value", text: $conditionValue)
                .onSubmit { applyCondition(column) }
                .accessibilityIdentifier("filter.condition.value")
            Button("Filter.Condition.Apply") { applyCondition(column) }
                .disabled(kind.criterion(for: conditionValue) == nil)
                .accessibilityIdentifier("filter.condition.apply")
        }
    }

    private func applyCondition(_ column: Int) {
        guard let criterion = kind.criterion(for: conditionValue) else { return }
        state.setFilter(criterion, forColumn: column, in: &workbook)
    }

    /// Shows the column's condition, if it has one the panel offers.
    private func loadCondition() {
        guard let filter = sheet.autoFilter,
              let shown = FilterConditionKind.described(sheet.filterCriterion(forColumn: column(in: filter))) else {
            conditionValue = ""
            return
        }
        (kind, conditionValue) = shown
    }
}
