import SwiftUI
import TablesEngine

/// The kinds of conditional format the editor offers, as a person picks them.
enum ConditionalRuleCategory: String, CaseIterable, Identifiable {
    case cellValue, formula, topBottom, average, duplicates, unique, colorScale, dataBar, iconSet

    var id: String { rawValue }

    init(_ kind: ConditionalRule.Kind, hasComparison: Bool) {
        switch kind {
        case .test: self = hasComparison ? .cellValue : .formula
        case .rank: self = .topBottom
        case .average: self = .average
        case .duplicates(let isUnique): self = isUnique ? .unique : .duplicates
        case .colorScale: self = .colorScale
        case .dataBar: self = .dataBar
        case .iconSet: self = .iconSet
        }
    }

    var name: LocalizedStringKey {
        switch self {
        case .cellValue: return "CellRules.Kind.CellValue"
        case .formula: return "CellRules.Kind.Formula"
        case .topBottom: return "CellRules.Kind.TopBottom"
        case .average: return "CellRules.Kind.Average"
        case .duplicates: return "CellRules.Kind.Duplicates"
        case .unique: return "CellRules.Kind.Unique"
        case .colorScale: return "CellRules.Kind.ColorScale"
        case .dataBar: return "CellRules.Kind.DataBar"
        case .iconSet: return "CellRules.Kind.IconSet"
        }
    }

    var symbol: String {
        switch self {
        case .cellValue: return "lessthan.circle"
        case .formula: return "function"
        case .topBottom: return "list.number"
        case .average: return "chart.line.flattrend.xyaxis"
        case .duplicates: return "square.on.square"
        case .unique: return "square"
        case .colorScale: return "paintpalette"
        case .dataBar: return "chart.bar.fill"
        case .iconSet: return "circle.grid.3x3.fill"
        }
    }
}

/// Starting points for a new conditional format, offered by the Add menu.
enum ConditionalRulePreset: String, CaseIterable, Identifiable {
    case greaterThan, lessThan, between, equalTo, textContains, duplicates
    case top10, bottom10, aboveAverage, belowAverage
    case dataBar, colorScale, iconSet, formula

    var id: String { rawValue }

    var name: LocalizedStringKey {
        switch self {
        case .greaterThan: return "CellRules.Preset.GreaterThan"
        case .lessThan: return "CellRules.Preset.LessThan"
        case .between: return "CellRules.Preset.Between"
        case .equalTo: return "CellRules.Preset.EqualTo"
        case .textContains: return "CellRules.Preset.TextContains"
        case .duplicates: return "CellRules.Kind.Duplicates"
        case .top10: return "CellRules.Preset.Top10"
        case .bottom10: return "CellRules.Preset.Bottom10"
        case .aboveAverage: return "CellRules.Kind.AboveAverage"
        case .belowAverage: return "CellRules.Kind.BelowAverage"
        case .dataBar: return "CellRules.Kind.DataBar"
        case .colorScale: return "CellRules.Kind.ColorScale"
        case .iconSet: return "CellRules.Kind.IconSet"
        case .formula: return "CellRules.Kind.Formula"
        }
    }

    var symbol: String {
        switch self {
        case .greaterThan: return "greaterthan"
        case .lessThan: return "lessthan"
        case .between: return "arrow.left.and.right"
        case .equalTo: return "equal"
        case .textContains: return "textformat.abc"
        case .duplicates: return "square.on.square"
        case .top10: return "arrow.up.to.line"
        case .bottom10: return "arrow.down.to.line"
        case .aboveAverage: return "arrow.up.right"
        case .belowAverage: return "arrow.down.right"
        case .dataBar: return "chart.bar.fill"
        case .colorScale: return "paintpalette"
        case .iconSet: return "circle.grid.3x3.fill"
        case .formula: return "function"
        }
    }

    static let highlight: [Self] = [.greaterThan, .lessThan, .between, .equalTo, .textContains, .duplicates]
    static let ranking: [Self] = [.top10, .bottom10, .aboveAverage, .belowAverage]
    static let visual: [Self] = [.dataBar, .colorScale, .iconSet]

    /// A rule ready to use over `ranges`, styled the way Excel's own first
    /// suggestion is: light red fill with dark red text.
    func rule(over ranges: [CellRange]) -> ConditionalRule {
        let base = ConditionalRule(ranges: ranges, priority: 0).base?.a1 ?? "A1"
        var rule = ConditionalRule(ranges: ranges, priority: 0, style: StylePreset.lightRed.style)
        switch self {
        case .greaterThan: (rule.comparison, rule.formulas) = (.greaterThan, ["0"])
        case .lessThan: (rule.comparison, rule.formulas) = (.lessThan, ["0"])
        case .between: (rule.comparison, rule.formulas) = (.between, ["0", "100"])
        case .equalTo: (rule.comparison, rule.formulas) = (.equal, ["0"])
        case .textContains: rule.formulas = ["ISNUMBER(SEARCH(\"text\",\(base)))"]
        case .duplicates: rule.kind = .duplicates(isUnique: false)
        case .top10: rule.kind = .rank(count: 10, isPercent: false, isBottom: false)
        case .bottom10: rule.kind = .rank(count: 10, isPercent: false, isBottom: true)
        case .aboveAverage: rule.kind = .average(isAbove: true, includesEqual: false, deviations: 0)
        case .belowAverage: rule.kind = .average(isAbove: false, includesEqual: false, deviations: 0)
        case .dataBar: rule.kind = ConditionalRuleEditor.defaultKind(.dataBar, base: base)
        case .colorScale: rule.kind = ConditionalRuleEditor.defaultKind(.colorScale, base: base)
        case .iconSet: rule.kind = ConditionalRuleEditor.defaultKind(.iconSet, base: base)
        case .formula: rule.formulas = ["\(base)>0"]
        }
        if !ConditionalFormatStyling.needsStyle(rule.kind) { rule.style = ConditionalStyle() }
        return rule
    }
}

/// Ready-made looks for a highlighted cell, Excel's own among them.
enum StylePreset: String, CaseIterable, Identifiable {
    case lightRed, yellow, green, lightRedFill, redText, bold

    var id: String { rawValue }

    var style: ConditionalStyle {
        switch self {
        case .lightRed: return ConditionalStyle(fillColorHex: "FFFFC7CE", textColorHex: "FF9C0006")
        case .yellow: return ConditionalStyle(fillColorHex: "FFFFEB9C", textColorHex: "FF9C5700")
        case .green: return ConditionalStyle(fillColorHex: "FFC6EFCE", textColorHex: "FF006100")
        case .lightRedFill: return ConditionalStyle(fillColorHex: "FFFFC7CE")
        case .redText: return ConditionalStyle(textColorHex: "FFFF0000")
        case .bold: return ConditionalStyle(isBold: true)
        }
    }

    var name: LocalizedStringKey {
        switch self {
        case .lightRed: return "CellRules.Style.LightRed"
        case .yellow: return "CellRules.Style.Yellow"
        case .green: return "CellRules.Style.Green"
        case .lightRedFill: return "CellRules.Style.LightRedFill"
        case .redText: return "CellRules.Style.RedText"
        case .bold: return "CellRules.Style.Bold"
        }
    }
}

enum ConditionalFormatStyling {
    static func needsStyle(_ kind: ConditionalRule.Kind) -> Bool {
        switch kind {
        case .colorScale, .dataBar, .iconSet: return false
        case .test, .rank, .average, .duplicates: return true
        }
    }
}

/// One conditional format: what it tests, how it styles the cells that
/// pass, where it applies, a preview, and a tester for its formula.
struct ConditionalRuleEditor: View {
    @Binding var rule: ConditionalRule
    let snapshot: RulePreviewSnapshot?
    let delete: () -> Void

    @State private var first: String
    @State private var second: String
    @State private var formula: String
    @State private var rangesText: String
    @State private var customFill = Color.white
    @State private var customText = Color.black

    init(rule: Binding<ConditionalRule>, snapshot: RulePreviewSnapshot?, delete: @escaping () -> Void) {
        _rule = rule
        self.snapshot = snapshot
        self.delete = delete
        let value = rule.wrappedValue
        let isComparison = value.comparison != nil
        _first = State(initialValue: isComparison ? DataValidation.input(for: value.formulas.first) : "0")
        _second = State(initialValue: isComparison && value.formulas.count > 1 ? DataValidation.input(for: value.formulas[1]) : "100")
        _formula = State(initialValue: isComparison ? "" : (value.formulas.first ?? ""))
        _rangesText = State(initialValue: CellRuleText.ranges(value.ranges))
    }

    private var category: ConditionalRuleCategory {
        ConditionalRuleCategory(rule.kind, hasComparison: rule.comparison != nil)
    }

    private var base: String { rule.base?.a1 ?? "A1" }

    var body: some View {
        Form {
            Section {
                Picker("CellRules.Kind", selection: Binding(get: { category }, set: change(to:))) {
                    ForEach(ConditionalRuleCategory.allCases) { category in
                        Label(category.name, systemImage: category.symbol).tag(category)
                    }
                }
                .accessibilityIdentifier("cellRules.kind")
                kindFields
            } footer: {
                if category == .formula {
                    Text(String(format: String(localized: "CellRules.Formula.Footer"), base))
                } else if category == .cellValue {
                    Text("DataValidation.Value.Footer")
                }
            }

            if ConditionalFormatStyling.needsStyle(rule.kind) {
                styleSection
            }

            Section {
                LabeledContent("CellRules.Ranges") {
                    TextField("CellRules.Ranges", text: $rangesText)
                        .font(.body.monospaced())
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        #if !os(macOS)
                        .textInputAutocapitalization(.characters)
                        #endif
                        .accessibilityIdentifier("cellRules.ranges")
                        .onChange(of: rangesText) { _, text in rule.ranges = CellRuleText.parseRanges(text) ?? [] }
                }
                if ConditionalFormatStyling.needsStyle(rule.kind) {
                    Toggle("CellRules.StopIfTrue", isOn: $rule.stopsIfTrue)
                }
            } footer: {
                if rule.ranges.isEmpty {
                    Text("CellRules.Ranges.Invalid").foregroundStyle(.red)
                } else if ConditionalFormatStyling.needsStyle(rule.kind) {
                    Text("CellRules.StopIfTrue.Footer")
                }
            }

            if let range = rule.ranges.first {
                Section("CellRules.Preview") {
                    RulePreviewGrid(snapshot: snapshot, range: range, showsFailures: false)
                }
            }

            if case .test = rule.kind, !rule.ranges.isEmpty {
                Section {
                    ConditionalFormulaTester(rule: rule, snapshot: snapshot)
                } header: {
                    Text("CellRules.Test.FormulaSection")
                } footer: {
                    Text("CellRules.Test.FormulaFooter")
                }
            }

            Section {
                Button("CellRules.DeleteRule", role: .destructive, action: delete)
                    .accessibilityIdentifier("cellRules.deleteRule")
            }
        }
        .formStyle(.grouped)
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: first) { _, _ in writeOperands() }
        .onChange(of: second) { _, _ in writeOperands() }
        .onChange(of: formula) { _, text in
            let body = text.hasPrefix("=") ? String(text.dropFirst()) : text
            rule.formulas = body.trimmingCharacters(in: .whitespaces).isEmpty ? [] : [body]
        }
    }

    // MARK: - What the rule tests

    @ViewBuilder
    private var kindFields: some View {
        switch rule.kind {
        case .test:
            if let comparison = rule.comparison {
                Picker("DataValidation.Condition", selection: Binding(
                    get: { comparison }, set: { rule.comparison = $0; writeOperands() }
                )) {
                    ForEach(DataValidation.comparisons, id: \.self) {
                        Text(ValidationRuleEditor.name(of: $0)).tag($0)
                    }
                }
                .accessibilityIdentifier("cellRules.comparison")
                valueField(comparison.isRange ? "DataValidation.Minimum" : "DataValidation.Value", $first, "first")
                if comparison.isRange {
                    valueField("DataValidation.Maximum", $second, "second")
                }
            } else {
                HStack(spacing: 4) {
                    Text("=").font(.body.monospaced()).foregroundStyle(.secondary)
                    TextField("CellRules.Formula", text: $formula, axis: .vertical)
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        #if !os(macOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .accessibilityIdentifier("cellRules.formula")
                }
            }
        case .rank(let count, let isPercent, let isBottom):
            Picker("CellRules.Rank.Direction", selection: Binding(
                get: { isBottom }, set: { rule.kind = .rank(count: count, isPercent: isPercent, isBottom: $0) }
            )) {
                Text("CellRules.Rank.Top").tag(false)
                Text("CellRules.Rank.Bottom").tag(true)
            }
            .pickerStyle(.segmented)
            Stepper(value: Binding(
                get: { count }, set: { rule.kind = .rank(count: $0, isPercent: isPercent, isBottom: isBottom) }
            ), in: 1...(isPercent ? 100 : 1000)) {
                LabeledContent("CellRules.Rank.Count", value: isPercent ? "\(count)%" : "\(count)")
            }
            Toggle("CellRules.Rank.Percent", isOn: Binding(
                get: { isPercent }, set: { rule.kind = .rank(count: min(count, $0 ? 100 : count), isPercent: $0, isBottom: isBottom) }
            ))
        case .average(let isAbove, let includesEqual, let deviations):
            Picker("CellRules.Average.Direction", selection: Binding(
                get: { isAbove }, set: { rule.kind = .average(isAbove: $0, includesEqual: includesEqual, deviations: deviations) }
            )) {
                Text("CellRules.Average.Above").tag(true)
                Text("CellRules.Average.Below").tag(false)
            }
            .pickerStyle(.segmented)
            Toggle("CellRules.Average.IncludesEqual", isOn: Binding(
                get: { includesEqual }, set: { rule.kind = .average(isAbove: isAbove, includesEqual: $0, deviations: deviations) }
            ))
            Stepper(value: Binding(
                get: { deviations }, set: { rule.kind = .average(isAbove: isAbove, includesEqual: includesEqual, deviations: $0) }
            ), in: 0...3) {
                LabeledContent("CellRules.Average.Deviations", value: "\(deviations)")
            }
        case .duplicates:
            EmptyView()
        case .colorScale(let thresholds, let colors):
            colorScaleFields(thresholds: thresholds, colors: colors)
        case .dataBar(let bar):
            dataBarFields(bar)
        case .iconSet(let set):
            iconSetFields(set)
        }
    }

    private func valueField(_ label: LocalizedStringKey, _ text: Binding<String>, _ identifier: String) -> some View {
        LabeledContent(label) {
            TextField(label, text: text)
                .multilineTextAlignment(.trailing)
                .autocorrectionDisabled()
                #if !os(macOS)
                .textInputAutocapitalization(.never)
                #endif
                .accessibilityIdentifier("cellRules.\(identifier)")
        }
    }

    private func writeOperands() {
        guard let comparison = rule.comparison else { return }
        let values = (comparison.isRange ? [first, second] : [first])
            .map { DataValidation.formula(fromInput: $0, kind: .decimal) }
        rule.formulas = values.contains(where: { $0 == nil }) ? [] : values.compactMap { $0 }
    }

    private func change(to category: ConditionalRuleCategory) {
        guard category != self.category else { return }
        switch category {
        case .cellValue:
            rule.kind = .test
            rule.comparison = rule.comparison ?? .greaterThan
            writeOperands()
        case .formula:
            rule.kind = .test
            rule.comparison = nil
            if formula.isEmpty { formula = "\(base)>0" }
            rule.formulas = [formula]
        default:
            rule.comparison = nil
            rule.formulas = []
            rule.kind = Self.defaultKind(category, base: base)
        }
        if ConditionalFormatStyling.needsStyle(rule.kind) {
            if rule.style == ConditionalStyle() { rule.style = StylePreset.lightRed.style }
        } else {
            rule.style = ConditionalStyle()
        }
    }

    static func defaultKind(_ category: ConditionalRuleCategory, base: String) -> ConditionalRule.Kind {
        switch category {
        case .cellValue, .formula: return .test
        case .topBottom: return .rank(count: 10, isPercent: false, isBottom: false)
        case .average: return .average(isAbove: true, includesEqual: false, deviations: 0)
        case .duplicates: return .duplicates(isUnique: false)
        case .unique: return .duplicates(isUnique: true)
        case .colorScale:
            return .colorScale(
                thresholds: [.init(kind: .minimum), .init(kind: .percentile, value: "50"), .init(kind: .maximum)],
                colors: ["FFF8696B", "FFFFEB84", "FF63BE7B"])
        case .dataBar: return .dataBar(ConditionalDataBar(colorHex: "FF638EC6"))
        case .iconSet: return .iconSet(iconSet(named: "3TrafficLights1"))
        }
    }

    // MARK: - Colour scales, bars and icons

    @ViewBuilder
    private func colorScaleFields(thresholds: [ConditionalThreshold], colors: [String]) -> some View {
        let isThree = thresholds.count > 2
        Picker("CellRules.Scale.Stops", selection: Binding(
            get: { isThree },
            set: { three in
                if three, !isThree, thresholds.count == 2 {
                    rule.kind = .colorScale(
                        thresholds: [thresholds[0], .init(kind: .percentile, value: "50"), thresholds[1]],
                        colors: [colors[0], "FFFFEB84", colors[1]])
                } else if !three, isThree {
                    rule.kind = .colorScale(
                        thresholds: [thresholds[0], thresholds[thresholds.count - 1]],
                        colors: [colors[0], colors[colors.count - 1]])
                }
            }
        )) {
            Text("CellRules.Scale.Two").tag(false)
            Text("CellRules.Scale.Three").tag(true)
        }
        .pickerStyle(.segmented)
        ForEach(colors.indices, id: \.self) { index in
            ColorPicker(selection: Binding(
                get: { Color(argbHex: colors[index]) ?? .white },
                set: { color in
                    var edited = colors
                    edited[index] = color.argbHex ?? edited[index]
                    rule.kind = .colorScale(thresholds: thresholds, colors: edited)
                }
            ), supportsOpacity: false) {
                Text(index == 0 ? "CellRules.Scale.Lowest"
                     : index == colors.count - 1 ? "CellRules.Scale.Highest" : "CellRules.Scale.Midpoint")
            }
        }
        LinearGradient(colors: colors.map { Color(argbHex: $0) ?? .clear }, startPoint: .leading, endPoint: .trailing)
            .frame(height: 14)
            .clipShape(.capsule)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func dataBarFields(_ bar: ConditionalDataBar) -> some View {
        SystemColorSwatches(
            role: .fill,
            selectedHex: bar.colorHex,
            customColor: Binding(
                get: { Color(argbHex: bar.colorHex) ?? .blue },
                set: { color in updateBar { $0.colorHex = color.argbHex ?? $0.colorHex } }
            ),
            onSelect: { swatch in updateBar { $0.colorHex = swatch.argbHex } },
            onClear: { updateBar { $0.colorHex = "FF638EC6" } }
        )
        Toggle("CellRules.ShowValue", isOn: Binding(
            get: { bar.showsValue }, set: { value in updateBar { $0.showsValue = value } }
        ))
    }

    private func updateBar(_ change: (inout ConditionalDataBar) -> Void) {
        guard case .dataBar(var bar) = rule.kind else { return }
        change(&bar)
        rule.kind = .dataBar(bar)
    }

    static let iconSetNames = [
        "3TrafficLights1", "3Signs", "3Symbols", "3Symbols2", "3Flags", "3Arrows", "3ArrowsGray",
        "4TrafficLights", "4RedToBlack", "4Arrows", "4ArrowsGray", "4Rating",
        "5Arrows", "5ArrowsGray", "5Rating", "5Quarters",
    ]

    /// A set with Excel's default thresholds: equal shares by percent.
    static func iconSet(named name: String) -> ConditionalIconSet {
        let count = ConditionalIcon.icons(ofSet: name).count
        let thresholds = (0..<count).map { index in
            ConditionalThreshold(kind: .percent, value: String(Int((100 * Double(index) / Double(count)).rounded())))
        }
        return ConditionalIconSet(name: name, thresholds: thresholds)
    }

    @ViewBuilder
    private func iconSetFields(_ set: ConditionalIconSet) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 8)], spacing: 8) {
            ForEach(Self.iconSetNames, id: \.self) { name in
                Button {
                    var chosen = Self.iconSet(named: name)
                    chosen.isReversed = set.isReversed
                    chosen.showsValue = set.showsValue
                    rule.kind = .iconSet(chosen)
                } label: {
                    IconSetStrip(name: name)
                        .frame(height: 24)
                        .padding(6)
                        .background(Color.white, in: .rect(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(name == set.name ? Color.accentColor : Color.primary.opacity(0.12),
                                              lineWidth: name == set.name ? 2.5 : 1)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(name))
                .accessibilityAddTraits(name == set.name ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(.vertical, 4)
        let icons = ConditionalIcon.icons(ofSet: set.name)
        ForEach(set.thresholds.indices.dropFirst(), id: \.self) { index in
            LabeledContent {
                HStack {
                    TextField("CellRules.Value", text: Binding(
                        get: { set.thresholds[index].value ?? "" },
                        set: { value in updateIcons { $0.thresholds[index].value = value } }
                    ))
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 80)
                    Picker("CellRules.Threshold.Kind", selection: Binding(
                        get: { set.thresholds[index].kind },
                        set: { kind in updateIcons { $0.thresholds[index].kind = kind } }
                    )) {
                        Text("CellRules.Threshold.Percent").tag(ConditionalThreshold.Kind.percent)
                        Text("CellRules.Threshold.Number").tag(ConditionalThreshold.Kind.number)
                        Text("CellRules.Threshold.Percentile").tag(ConditionalThreshold.Kind.percentile)
                        Text("CellRules.Threshold.Formula").tag(ConditionalThreshold.Kind.formula)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            } label: {
                let shown = set.isReversed ? icons.count - 1 - index : index
                HStack(spacing: 6) {
                    Canvas { context, size in
                        guard icons.indices.contains(shown) else { return }
                        for mark in icons[shown].marks(in: CGRect(origin: .zero, size: size)) {
                            context.fill(mark.path, with: .color(Color(argbHex: mark.colorHex) ?? .gray))
                        }
                    }
                    .frame(width: 16, height: 16)
                    Text("CellRules.Threshold.AtLeast")
                }
            }
        }
        Toggle("CellRules.Icons.Reverse", isOn: Binding(
            get: { set.isReversed }, set: { value in updateIcons { $0.isReversed = value } }
        ))
        Toggle("CellRules.ShowValue", isOn: Binding(
            get: { set.showsValue }, set: { value in updateIcons { $0.showsValue = value } }
        ))
    }

    private func updateIcons(_ change: (inout ConditionalIconSet) -> Void) {
        guard case .iconSet(var set) = rule.kind else { return }
        change(&set)
        rule.kind = .iconSet(set)
    }

    // MARK: - Style

    private var styleSection: some View {
        Section("CellRules.Style") {
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(StylePreset.allCases) { preset in
                        Button {
                            rule.style = preset.style
                        } label: {
                            StyleSample(style: preset.style)
                                .frame(width: 56, height: 32)
                                .clipShape(.rect(cornerRadius: 6))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(rule.style == preset.style ? Color.accentColor : Color.primary.opacity(0.15),
                                                      lineWidth: rule.style == preset.style ? 2.5 : 1)
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(preset.name))
                        .accessibilityIdentifier("cellRules.style.\(preset.rawValue)")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)
            .listRowInsets(EdgeInsets())

            HStack {
                Text("CellRules.Style.Emphasis")
                Spacer()
                emphasis("bold", \.isBold, "CellRules.Style.Bold")
                emphasis("italic", \.isItalic, "CellRules.Style.Italic")
                emphasis("underline", \.isUnderlined, "CellRules.Style.Underline")
                emphasis("strikethrough", \.isStruckThrough, "CellRules.Style.Strikethrough")
            }

            Text("CellRules.Style.Text").font(.subheadline).foregroundStyle(.secondary)
            SystemColorSwatches(
                role: .text,
                selectedHex: rule.style.textColorHex,
                customColor: Binding(
                    get: { Color(argbHex: rule.style.textColorHex) ?? customText },
                    set: { rule.style.textColorHex = $0.argbHex; customText = $0 }
                ),
                onSelect: { rule.style.textColorHex = $0.argbHex },
                onClear: { rule.style.textColorHex = nil }
            )
            Text("CellRules.Style.Fill").font(.subheadline).foregroundStyle(.secondary)
            SystemColorSwatches(
                role: .fill,
                selectedHex: rule.style.fillColorHex,
                customColor: Binding(
                    get: { Color(argbHex: rule.style.fillColorHex) ?? customFill },
                    set: { rule.style.fillColorHex = $0.argbHex; customFill = $0 }
                ),
                onSelect: { rule.style.fillColorHex = $0.argbHex },
                onClear: { rule.style.fillColorHex = nil }
            )
        }
    }

    private func emphasis(
        _ symbol: String, _ keyPath: WritableKeyPath<ConditionalStyle, Bool?>, _ label: LocalizedStringKey
    ) -> some View {
        let isOn = rule.style[keyPath: keyPath] == true
        return Button {
            rule.style[keyPath: keyPath] = isOn ? nil : true
        } label: {
            Image(systemName: symbol)
                .frame(width: 30, height: 30)
                .background(isOn ? Color.accentColor.opacity(0.2) : Color.clear, in: .rect(cornerRadius: 6))
                .foregroundStyle(isOn ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}

private extension ConditionalRule.Comparison {
    var isRange: Bool { self == .between || self == .notBetween }
}
