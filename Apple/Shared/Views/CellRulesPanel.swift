import SwiftUI
import TablesEngine

/// Conditional formatting and data validation for the selected cells, in
/// one place: a live preview of the cells with every rule applied, the
/// sheet's formatting rules, and the selection's validation rule. Changes
/// are made to a draft and handed back on Done, so they are one undo step.
struct CellRulesPanel: View {
    enum Page: Hashable {
        case rule(UUID)
        case validation
    }

    let workbook: Workbook
    let sheetIndex: Int
    /// Nil on Cancel.
    let finish: (CellRulesDraft?) -> Void

    @State private var draft: CellRulesDraft
    @State private var path: [Page] = []
    @State private var snapshot: RulePreviewSnapshot?
    @State private var showsWholeSheet = false

    init(workbook: Workbook, sheetIndex: Int, draft: CellRulesDraft, finish: @escaping (CellRulesDraft?) -> Void) {
        self.workbook = workbook
        self.sheetIndex = sheetIndex
        self.finish = finish
        _draft = State(initialValue: draft)
    }

    var body: some View {
        content
            .task(id: draft) {
                try? await Task.sleep(for: .milliseconds(snapshot == nil ? 0 : 150))
                guard !Task.isCancelled else { return }
                let (draft, workbook, sheetIndex) = (draft, workbook, sheetIndex)
                let made = await Task.detached(priority: .userInitiated) {
                    RulePreviewSnapshot.make(draft: draft, workbook: workbook, sheetIndex: sheetIndex)
                }.value
                guard !Task.isCancelled else { return }
                snapshot = made
            }
    }

    // MARK: - Navigation

    #if os(macOS)
    private var content: some View {
        VStack(spacing: 0) {
            HStack {
                if !path.isEmpty {
                    Button { path.removeLast() } label: { Label("CellRules.Back", systemImage: "chevron.left") }
                        .accessibilityIdentifier("cellRules.back")
                }
                Spacer()
                Text(title(of: path.last)).font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()
            if let page = path.last { destination(page) } else { overview }
            Divider()
            HStack {
                Spacer()
                Button("DataValidation.Cancel", role: .cancel) { finish(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("DataValidation.Done") { finish(draft) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.isComplete)
                    .accessibilityIdentifier("cellRulesDone")
            }
            .padding(12)
        }
        .frame(width: 560, height: 700)
    }
    #else
    private var content: some View {
        NavigationStack(path: $path) {
            overview
                .navigationTitle("CellRules.Title")
                .navigationBarTitleDisplayMode(.inline)
                .navigationBarBackButtonHidden()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(role: .cancel) { finish(nil) }
                    }
                    doneButton
                }
                .navigationDestination(for: Page.self) { page in
                    destination(page)
                        .navigationTitle(title(of: page))
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { doneButton }
                }
        }
    }

    private var doneButton: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button(role: .confirm) { finish(draft) }
                .disabled(!draft.isComplete)
                .accessibilityIdentifier("cellRulesDone")
        }
    }
    #endif

    private func title(of page: Page?) -> LocalizedStringKey {
        switch page {
        case nil: return "CellRules.Title"
        case .rule: return "CellRules.Formatting.Rule"
        case .validation: return "DataValidation.Title"
        }
    }

    private func open(_ page: Page) {
        path.append(page)
    }

    @ViewBuilder
    private func destination(_ page: Page) -> some View {
        switch page {
        case .rule(let id):
            if let binding = ruleBinding(id) {
                ConditionalRuleEditor(rule: binding, snapshot: snapshot) {
                    path.removeAll { $0 == page }
                    draft.rules.removeAll { $0.id == id }
                }
                .id(id)
            }
        case .validation:
            if let binding = validationBinding {
                ValidationRuleEditor(draft: binding, selection: draft.selection, snapshot: snapshot) {
                    path.removeAll { $0 == .validation }
                    draft.validation = nil
                }
            }
        }
    }

    private func ruleBinding(_ id: UUID) -> Binding<ConditionalRule>? {
        guard draft.rules.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { draft.rules.first { $0.id == id }?.rule ?? ConditionalRule(ranges: [], priority: 0) },
            set: { value in
                if let index = draft.rules.firstIndex(where: { $0.id == id }) { draft.rules[index].rule = value }
            })
    }

    private var validationBinding: Binding<ValidationDraft>? {
        guard draft.validation != nil else { return nil }
        return Binding(
            get: { draft.validation ?? ValidationDraft(rule: DataValidation(ranges: [], kind: .list)) },
            set: { draft.validation = $0 })
    }

    // MARK: - Overview

    private var shownRules: [DraftRule] {
        showsWholeSheet ? draft.rules : draft.rules.filter { draft.touchesSelection($0.rule) }
    }

    private var overview: some View {
        Form {
            if let range = draft.selection.last {
                Section {
                    RulePreviewGrid(snapshot: snapshot, range: range)
                } header: {
                    Text(String(format: String(localized: "CellRules.AppliesTo"), CellRuleText.ranges(draft.selection)))
                } footer: {
                    if let snapshot, !snapshot.failing.isEmpty {
                        Text(String(format: String(localized: "CellRules.Preview.Failing"), snapshot.failing.count))
                    }
                }
            }

            formattingSection
            validationSection
        }
        .formStyle(.grouped)
        .scrollDismissesKeyboard(.interactively)
    }

    /// Dragging only makes sense when every rule is in view.
    private var canReorder: Bool { showsWholeSheet || shownRules.count == draft.rules.count }

    private var mover: ((IndexSet, Int) -> Void)? {
        guard canReorder else { return nil }
        return { source, destination in draft.rules.move(fromOffsets: source, toOffset: destination) }
    }

    private var hasRulesElsewhere: Bool {
        draft.rules.contains { !draft.touchesSelection($0.rule) }
    }

    private var formattingSection: some View {
        Section {
            if hasRulesElsewhere {
                Picker("CellRules.Formatting.Scope", selection: $showsWholeSheet) {
                    Text("CellRules.Formatting.Selection").tag(false)
                    Text("CellRules.Formatting.Sheet").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            if shownRules.isEmpty {
                Text("CellRules.Formatting.Empty").foregroundStyle(.secondary)
            }
            ForEach(shownRules) { item in
                ruleRow(item)
            }
            .onMove(perform: mover)
            .onDelete { offsets in
                let ids = Set(offsets.map { shownRules[$0].id })
                draft.rules.removeAll { ids.contains($0.id) }
            }
            addRuleMenu
        } header: {
            Text("CellRules.Formatting")
        } footer: {
            if draft.rules.count > 1 { Text("CellRules.Formatting.Footer") }
        }
    }

    private func ruleRow(_ item: DraftRule) -> some View {
        Button { open(.rule(item.id)) } label: {
            HStack(spacing: 12) {
                ConditionalRuleSwatch(rule: item.rule)
                VStack(alignment: .leading, spacing: 2) {
                    Text(CellRuleText.summary(of: item.rule))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(CellRuleText.ranges(item.rule.ranges))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("cellRules.rule")
        .contextMenu {
            Button("CellRules.MoveUp", systemImage: "arrow.up") { shift(item.id, by: -1) }
                .disabled(draft.rules.first?.id == item.id)
            Button("CellRules.MoveDown", systemImage: "arrow.down") { shift(item.id, by: 1) }
                .disabled(draft.rules.last?.id == item.id)
            Button("CellRules.Duplicate", systemImage: "plus.square.on.square") { duplicate(item.id) }
            Button("CellRules.DeleteRule", systemImage: "trash", role: .destructive) {
                draft.rules.removeAll { $0.id == item.id }
            }
        }
    }

    private var addRuleMenu: some View {
        Menu {
            Section("CellRules.Add.Highlight") { presetButtons(ConditionalRulePreset.highlight) }
            Section("CellRules.Add.Ranking") { presetButtons(ConditionalRulePreset.ranking) }
            Section("CellRules.Add.Visual") { presetButtons(ConditionalRulePreset.visual) }
            Section { presetButtons([.formula]) }
        } label: {
            Label("CellRules.Add", systemImage: "plus.circle.fill")
        }
        .accessibilityIdentifier("cellRules.add")
    }

    private func presetButtons(_ presets: [ConditionalRulePreset]) -> some View {
        ForEach(presets) { preset in
            Button {
                let item = DraftRule(rule: preset.rule(over: draft.selection))
                // A new rule goes first: it is the one the person is thinking of.
                draft.rules.insert(item, at: 0)
                open(.rule(item.id))
            } label: {
                Label(preset.name, systemImage: preset.symbol)
            }
            .accessibilityIdentifier("cellRules.preset.\(preset.rawValue)")
        }
    }

    private var validationSection: some View {
        Section {
            if let validation = draft.validation {
                Button { open(.validation) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.title3)
                            .foregroundStyle(.tint)
                            .frame(width: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(CellRuleText.summary(of: validation.edited))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                            Text(ValidationRuleEditor.name(of: validation.rule.alertStyle))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("cellRules.validation")
                .swipeActions {
                    Button("DataValidation.Clear", role: .destructive) { draft.validation = nil }
                }
            } else {
                Button {
                    draft.validation = ValidationDraft(rule: DataValidation(ranges: [], kind: .list))
                    open(.validation)
                } label: {
                    Label("CellRules.Validation.Add", systemImage: "plus.circle.fill")
                }
                .accessibilityIdentifier("cellRules.addValidation")
            }
        } header: {
            Text("DataValidation.Title")
        } footer: {
            Text("CellRules.Validation.Footer")
        }
    }

    // MARK: - Order

    private func shift(_ id: UUID, by offset: Int) {
        guard let index = draft.rules.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard draft.rules.indices.contains(target) else { return }
        draft.rules.swapAt(index, target)
    }

    private func duplicate(_ id: UUID) {
        guard let index = draft.rules.firstIndex(where: { $0.id == id }) else { return }
        draft.rules.insert(DraftRule(rule: draft.rules[index].rule), at: index + 1)
    }
}
