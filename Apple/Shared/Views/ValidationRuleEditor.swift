import SwiftUI
import TablesEngine

/// The data validation rule of the selected cells: what may be entered, a
/// place to try entries against it, the message shown beside the cell, and
/// the alert a failed entry raises.
struct ValidationRuleEditor: View {
    @Binding var draft: ValidationDraft
    let selection: [CellRange]
    let snapshot: RulePreviewSnapshot?
    let remove: () -> Void

    var body: some View {
        Form {
            Section {
                Picker("DataValidation.Allow", selection: $draft.rule.kind) {
                    ForEach(DataValidation.Kind.allCases, id: \.self) { Text(Self.name(of: $0)).tag($0) }
                }
                .accessibilityIdentifier("dataValidationKind")
                if draft.rule.kind.usesComparison {
                    Picker("DataValidation.Condition", selection: $draft.rule.comparison) {
                        ForEach(DataValidation.comparisons, id: \.self) { Text(Self.name(of: $0)).tag($0) }
                    }
                    .accessibilityIdentifier("dataValidationComparison")
                }
                if draft.rule.kind != .any {
                    field(firstLabel, text: $draft.first, identifier: "first", isFormula: draft.rule.kind == .custom)
                    if draft.needsSecondValue {
                        field("DataValidation.Maximum", text: $draft.second, identifier: "second")
                    }
                    Toggle("DataValidation.IgnoreBlank", isOn: $draft.rule.allowsBlank)
                }
                if draft.rule.kind == .list {
                    Toggle("DataValidation.ShowDropDown", isOn: $draft.rule.showsDropDown)
                }
            } header: {
                Text(String(format: String(localized: "CellRules.AppliesTo"), CellRuleText.ranges(selection)))
            } footer: {
                if draft.rule.kind == .list {
                    Text("DataValidation.Source.Footer")
                } else if draft.rule.kind == .custom {
                    Text(String(format: String(localized: "CellRules.Formula.Footer"), selectionBase))
                } else if draft.rule.kind.usesComparison {
                    Text("DataValidation.Value.Footer")
                }
            }

            if draft.rule.kind == .list, let items = listItems, !items.isEmpty {
                Section("CellRules.Validation.ListPreview") {
                    ForEach(Array(items.prefix(12).enumerated()), id: \.offset) { _, item in
                        Text(item)
                    }
                    if items.count > 12 {
                        Text(String(format: String(localized: "CellRules.Validation.More"), items.count - 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if draft.isComplete {
                Section {
                    ValidationEntryTester(rule: draft.edited, ranges: selection, snapshot: snapshot)
                } header: {
                    Text("CellRules.Test.EntrySection")
                } footer: {
                    Text("CellRules.Test.EntryFooter")
                }
            }

            if let range = selection.last {
                Section {
                    RulePreviewGrid(snapshot: snapshot, range: range)
                } header: {
                    Text("CellRules.Preview")
                } footer: {
                    if let snapshot, !snapshot.failing.isEmpty {
                        Text(String(format: String(localized: "CellRules.Preview.Failing"), snapshot.failing.count))
                    }
                }
            }

            Section("DataValidation.Input.Section") {
                Toggle("DataValidation.Input.Show", isOn: $draft.rule.showsInputMessage)
                field("DataValidation.Field.Title", text: text(\.promptTitle), identifier: "promptTitle")
                message(text(\.promptMessage), identifier: "promptMessage")
            }
            Section("DataValidation.Error.Section") {
                Toggle("DataValidation.Error.Show", isOn: $draft.rule.showsErrorMessage)
                Picker("DataValidation.Error.Style", selection: $draft.rule.alertStyle) {
                    ForEach(DataValidation.AlertStyle.allCases, id: \.self) { Text(Self.name(of: $0)).tag($0) }
                }
                .accessibilityIdentifier("dataValidationAlertStyle")
                field("DataValidation.Field.Title", text: text(\.errorTitle), identifier: "errorTitle")
                message(text(\.errorMessage), identifier: "errorMessage")
            }
            Section {
                Button("DataValidation.Clear", role: .destructive, action: remove)
                    .accessibilityIdentifier("dataValidationClear")
            }
        }
        .formStyle(.grouped)
        .scrollDismissesKeyboard(.interactively)
    }

    private var selectionBase: String {
        ConditionalRule(ranges: selection, priority: 0).base?.a1 ?? "A1"
    }

    /// What the list's drop-down will offer, read from the trial workbook.
    private var listItems: [String]? {
        guard let snapshot, let address = PreviewCellStepper.addresses(in: selection, sheet: snapshot.sheet, limit: 1).first
        else { return nil }
        var rule = draft.edited
        rule.ranges = selection
        return snapshot.workbook.dataValidationItems(for: rule, at: address, sheetIndex: snapshot.sheetIndex)
    }

    private var firstLabel: LocalizedStringKey {
        switch draft.rule.kind {
        case .list: return "DataValidation.Source"
        case .custom: return "DataValidation.Formula"
        default: return draft.needsSecondValue ? "DataValidation.Minimum" : "DataValidation.Value"
        }
    }

    private func text(_ keyPath: WritableKeyPath<DataValidation, String?>) -> Binding<String> {
        Binding(get: { draft.rule[keyPath: keyPath] ?? "" }, set: { draft.rule[keyPath: keyPath] = $0 })
    }

    /// A labelled text field. iOS forms show a field's label only as its
    /// placeholder, which disappears once something is typed, so there the
    /// label sits beside it.
    @ViewBuilder
    private func field(
        _ label: LocalizedStringKey, text: Binding<String>, identifier: String, isFormula: Bool = false
    ) -> some View {
        #if os(macOS)
        TextField(label, text: text)
            .font(isFormula ? .body.monospaced() : .body)
            .accessibilityIdentifier("dataValidation.\(identifier)")
        #else
        LabeledContent(label) {
            TextField(label, text: text)
                .font(isFormula ? .body.monospaced() : .body)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("dataValidation.\(identifier)")
        }
        #endif
    }

    private func message(_ text: Binding<String>, identifier: String) -> some View {
        TextField("DataValidation.Field.Message", text: text, axis: .vertical)
            .lineLimit(2...5)
            .accessibilityIdentifier("dataValidation.\(identifier)")
    }

    // MARK: - Names

    static func name(of kind: DataValidation.Kind) -> String {
        switch kind {
        case .any: return String(localized: "DataValidation.Kind.Any")
        case .whole: return String(localized: "DataValidation.Kind.Whole")
        case .decimal: return String(localized: "DataValidation.Kind.Decimal")
        case .list: return String(localized: "DataValidation.Kind.List")
        case .date: return String(localized: "DataValidation.Kind.Date")
        case .time: return String(localized: "DataValidation.Kind.Time")
        case .textLength: return String(localized: "DataValidation.Kind.TextLength")
        case .custom: return String(localized: "DataValidation.Kind.Custom")
        }
    }

    static func name(of comparison: DataValidation.Comparison) -> String {
        switch comparison {
        case .between: return String(localized: "DataValidation.Comparison.Between")
        case .notBetween: return String(localized: "DataValidation.Comparison.NotBetween")
        case .equal: return String(localized: "DataValidation.Comparison.Equal")
        case .notEqual: return String(localized: "DataValidation.Comparison.NotEqual")
        case .greaterThan: return String(localized: "DataValidation.Comparison.GreaterThan")
        case .lessThan: return String(localized: "DataValidation.Comparison.LessThan")
        case .greaterThanOrEqual: return String(localized: "DataValidation.Comparison.GreaterThanOrEqual")
        case .lessThanOrEqual: return String(localized: "DataValidation.Comparison.LessThanOrEqual")
        }
    }

    static func name(of style: DataValidation.AlertStyle) -> String {
        switch style {
        case .stop: return String(localized: "DataValidation.Style.Stop")
        case .warning: return String(localized: "DataValidation.Style.Warning")
        case .information: return String(localized: "DataValidation.Style.Information")
        }
    }
}
