import SwiftUI
import TablesEngine

/// The data validation rule of the selected cells: what may be entered, the
/// message shown beside the cell, and the alert a failed entry raises.
/// Changes are made to a copy and handed back on Done, so the whole edit is
/// one undo step.
struct DataValidationPanel: View {
    enum Outcome {
        case cancel
        /// Take the rule off the selected cells.
        case clear
        case apply(DataValidation)
    }

    let finish: (Outcome) -> Void
    private let hasRule: Bool
    @State private var rule: DataValidation
    @State private var first: String
    @State private var second: String

    /// `rule` is the one the selection already has, if any.
    init(rule: DataValidation?, finish: @escaping (Outcome) -> Void) {
        self.finish = finish
        hasRule = rule != nil
        let rule = rule ?? DataValidation(ranges: [], kind: .list)
        _rule = State(initialValue: rule)
        _first = State(initialValue: DataValidation.input(for: rule.formula1))
        _second = State(initialValue: DataValidation.input(for: rule.formula2))
    }

    /// The rule as edited, with what was typed turned into its formulas.
    private var edited: DataValidation {
        var edited = rule
        edited.formula1 = DataValidation.formula(fromInput: first, kind: rule.kind)
        edited.formula2 = needsSecondValue ? DataValidation.formula(fromInput: second, kind: rule.kind) : nil
        if rule.kind == .any { edited.formula1 = nil }
        func kept(_ text: String?) -> String? { (text ?? "").isEmpty ? nil : text }
        edited.errorTitle = kept(rule.errorTitle)
        edited.errorMessage = kept(rule.errorMessage)
        edited.promptTitle = kept(rule.promptTitle)
        edited.promptMessage = kept(rule.promptMessage)
        return edited
    }

    private var needsSecondValue: Bool {
        rule.kind.usesComparison && (rule.comparison == .between || rule.comparison == .notBetween)
    }

    /// A rule that tests something needs the thing to test against.
    private var isComplete: Bool {
        let edited = edited
        if rule.kind == .any { return true }
        return edited.formula1 != nil && (!needsSecondValue || edited.formula2 != nil)
    }

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            form
            Divider()
            HStack {
                if hasRule {
                    Button("DataValidation.Clear", role: .destructive) { finish(.clear) }
                        .accessibilityIdentifier("dataValidationClear")
                }
                Spacer()
                Button("DataValidation.Cancel", role: .cancel) { finish(.cancel) }
                    .keyboardShortcut(.cancelAction)
                Button("DataValidation.Done") { finish(.apply(edited)) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isComplete)
                    .accessibilityIdentifier("dataValidationDone")
            }
            .padding(12)
        }
        .frame(width: 460, height: 560)
        #else
        form
            .navigationTitle("DataValidation.Title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { finish(.cancel) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm) { finish(.apply(edited)) }
                        .disabled(!isComplete)
                        .accessibilityIdentifier("dataValidationDone")
                }
            }
        #endif
    }

    private var form: some View {
        Form {
            Section {
                Picker("DataValidation.Allow", selection: $rule.kind) {
                    ForEach(DataValidation.Kind.allCases, id: \.self) { Text(Self.name(of: $0)).tag($0) }
                }
                .accessibilityIdentifier("dataValidationKind")
                if rule.kind.usesComparison {
                    Picker("DataValidation.Condition", selection: $rule.comparison) {
                        ForEach(DataValidation.comparisons, id: \.self) { Text(Self.name(of: $0)).tag($0) }
                    }
                    .accessibilityIdentifier("dataValidationComparison")
                }
                if rule.kind != .any {
                    field(firstLabel, text: $first, identifier: "first")
                    if needsSecondValue {
                        field("DataValidation.Maximum", text: $second, identifier: "second")
                    }
                    Toggle("DataValidation.IgnoreBlank", isOn: $rule.allowsBlank)
                }
                if rule.kind == .list {
                    Toggle("DataValidation.ShowDropDown", isOn: $rule.showsDropDown)
                }
            } footer: {
                if rule.kind == .list {
                    Text("DataValidation.Source.Footer")
                } else if rule.kind.usesComparison {
                    Text("DataValidation.Value.Footer")
                }
            }
            Section("DataValidation.Input.Section") {
                Toggle("DataValidation.Input.Show", isOn: $rule.showsInputMessage)
                field("DataValidation.Field.Title", text: text(\.promptTitle), identifier: "promptTitle")
                message(text(\.promptMessage), identifier: "promptMessage")
            }
            Section("DataValidation.Error.Section") {
                Toggle("DataValidation.Error.Show", isOn: $rule.showsErrorMessage)
                Picker("DataValidation.Error.Style", selection: $rule.alertStyle) {
                    ForEach(DataValidation.AlertStyle.allCases, id: \.self) { Text(Self.name(of: $0)).tag($0) }
                }
                .accessibilityIdentifier("dataValidationAlertStyle")
                field("DataValidation.Field.Title", text: text(\.errorTitle), identifier: "errorTitle")
                message(text(\.errorMessage), identifier: "errorMessage")
            }
            #if !os(macOS)
            if hasRule {
                Section {
                    Button("DataValidation.Clear", role: .destructive) { finish(.clear) }
                        .accessibilityIdentifier("dataValidationClear")
                }
            }
            #endif
        }
        .formStyle(.grouped)
    }

    private var firstLabel: LocalizedStringKey {
        switch rule.kind {
        case .list: return "DataValidation.Source"
        case .custom: return "DataValidation.Formula"
        default: return needsSecondValue ? "DataValidation.Minimum" : "DataValidation.Value"
        }
    }

    private func text(_ keyPath: WritableKeyPath<DataValidation, String?>) -> Binding<String> {
        Binding(get: { rule[keyPath: keyPath] ?? "" }, set: { rule[keyPath: keyPath] = $0 })
    }

    /// A labelled text field. iOS forms show a field's label only as its
    /// placeholder, which disappears once something is typed, so there the
    /// label sits beside it.
    @ViewBuilder
    private func field(_ label: LocalizedStringKey, text: Binding<String>, identifier: String) -> some View {
        #if os(macOS)
        TextField(label, text: text)
            .accessibilityIdentifier("dataValidation.\(identifier)")
        #else
        LabeledContent(label) {
            TextField(label, text: text)
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
