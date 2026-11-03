import SwiftUI
import TablesEngine

/// How the selected cells look, laid out for the Mac inspector: the same
/// settings as the iPhone and iPad's format panel, as compact rows.
struct CellInspector: View {
    @Binding var workbook: Workbook
    @Bindable var state: EditorState

    /// Which sides the border line style and colour are aimed at.
    @State private var borderScope: BorderScope = .all

    private var style: CellStyle { state.representativeStyle(in: workbook) }

    var body: some View {
        InspectorScroll {
            textSection
            fillSection
            alignmentSection
            if state.formatting.contains(.borders) {
                bordersSection
            }
            if state.formatting.contains(.merging) {
                mergeSection
            }
            InspectorSection(showsDivider: false) {
                Button("Format.ClearAll", role: .destructive) {
                    state.clearFormatting(in: &workbook)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Text

    private var textSection: some View {
        InspectorSection("Format.Section.Text") {
            InspectorSegments(mode: .selectAny, segments: [
                .init(symbol: "bold", label: String(localized: "Toolbar.Bold"), isOn: style.isBold) {
                    state.toggleBold(in: &workbook)
                },
                .init(symbol: "italic", label: String(localized: "Toolbar.Italic"), isOn: style.isItalic) {
                    state.toggleItalic(in: &workbook)
                },
                .init(
                    symbol: "underline", label: String(localized: "Toolbar.Underline"), isOn: style.isUnderlined
                ) {
                    state.toggleUnderline(in: &workbook)
                },
                .init(
                    symbol: "strikethrough", label: String(localized: "Toolbar.Strikethrough"),
                    isOn: style.isStruckThrough
                ) {
                    state.toggleStrikethrough(in: &workbook)
                },
            ])

            InspectorRow("Format.Text.Size") {
                HStack(spacing: 4) {
                    TextField("", value: fontSize, format: .number.precision(.fractionLength(0...1)))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 48)
                    Stepper("", value: fontSize, in: 6...96, step: 1)
                        .labelsHidden()
                    Text(verbatim: "pt").foregroundStyle(.secondary)
                }
            }

            InspectorRow("Mac.Inspector.Color") {
                InspectorColorWell(
                    selectedHex: style.textColorHex,
                    noneShowsAutomatic: true,
                    noneLabel: "ColorSwatches.None.Text.Accessibility"
                ) { hex in
                    state.applyStyle(in: &workbook) { $0.textColorHex = hex }
                }
            }
        }
    }

    private var fontSize: Binding<Double> {
        Binding(
            get: { style.fontSize },
            set: { value in
                state.applyStyle(in: &workbook) { $0.fontSize = min(96, max(6, value)) }
            }
        )
    }

    // MARK: - Fill

    private var fillSection: some View {
        InspectorSection("Format.Section.Fill") {
            InspectorRow("Mac.Inspector.Color") {
                InspectorColorWell(
                    selectedHex: style.fillColorHex,
                    automaticColor: .white,
                    noneLabel: "ColorSwatches.None.Fill.Accessibility"
                ) { hex in
                    state.applyStyle(in: &workbook) { $0.fillColorHex = hex }
                }
            }
        }
    }

    // MARK: - Alignment

    private var alignmentSection: some View {
        InspectorSection("Format.Section.Alignment") {
            InspectorSegments(mode: .selectOne, segments: HorizontalTextAlignment.allCases.map { option in
                let isOn = style.horizontalAlignment == option
                let action = { state.applyStyle(in: &workbook) { $0.horizontalAlignment = option } }
                // Automatic and left share a glyph, so automatic says so in words.
                return option == .automatic
                    ? .init(text: option.label, isOn: isOn, action: action)
                    : .init(symbol: option.symbolName, label: option.label, isOn: isOn, action: action)
            })

            InspectorSegments(mode: .selectOne, segments: VerticalTextAlignment.allCases.map { option in
                .init(symbol: option.symbolName, label: option.label, isOn: style.verticalAlignment == option) {
                    state.applyStyle(in: &workbook) { $0.verticalAlignment = option }
                }
            })

            InspectorRow("Format.Alignment.WrapText") {
                Toggle("", isOn: Binding(
                    get: { style.wrapsText },
                    set: { value in state.applyStyle(in: &workbook) { $0.wrapsText = value } }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
            }

            // Offered only where they can be saved: a Numbers document keeps
            // its own indents, rotation, borders and merges.
            if state.formatting.contains(.indents) {
                InspectorRow("Format.Alignment.Indent") {
                    HStack(spacing: 8) {
                        Text(String(style.indent))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        InspectorSegments(mode: .momentary, segments: [
                            .init(symbol: "decrease.indent", label: String(localized: "Format.Alignment.Indent")) {
                                state.applyStyle(in: &workbook) { $0.indent = max(0, $0.indent - 1) }
                            },
                            .init(symbol: "increase.indent", label: String(localized: "Format.Alignment.Indent")) {
                                state.applyStyle(in: &workbook) { $0.indent = min(250, $0.indent + 1) }
                            },
                        ], fillsWidth: false)
                        .fixedSize()
                    }
                }
            }
            if state.formatting.contains(.rotation) {
                InspectorRow("Format.Alignment.Rotation") {
                    InspectorPopup(selection: Binding(
                        get: { style.textRotation },
                        set: { value in state.applyStyle(in: &workbook) { $0.textRotation = value } }
                    )) {
                        // OOXML stores clockwise angles as 90 + the angle.
                        Text("Format.Rotation.None").tag(0)
                        Text("Format.Rotation.Up45").tag(45)
                        Text("Format.Rotation.Up90").tag(90)
                        Text("Format.Rotation.Down45").tag(135)
                        Text("Format.Rotation.Down90").tag(180)
                        Text("Format.Rotation.Stacked").tag(CellStyle.stackedTextRotation)
                    }
                }
            }
        }
    }

    // MARK: - Borders

    private var bordersSection: some View {
        InspectorSection("Format.Section.Borders") {
            BorderBoxPicker(style: style) { target in toggle(target) }
                .frame(maxWidth: .infinity)

            InspectorRow("Format.Border.ApplyTo") {
                InspectorPopup(selection: $borderScope) {
                    ForEach(BorderScope.allCases) { scope in
                        Text(scope.label).tag(scope)
                    }
                }
            }

            InspectorRow("Mac.Inspector.LineStyle") {
                InspectorPopup(selection: Binding(
                    get: { style.lineStyle(in: borderScope) ?? .thin },
                    set: { value in state.applyStyle(in: &workbook) { $0.setLineStyle(value, in: borderScope) } }
                )) {
                    ForEach(BorderLineStyle.allCases, id: \.self) { lineStyle in
                        Text(lineStyle.label).tag(lineStyle)
                    }
                }
            }

            InspectorRow("Mac.Inspector.Color") {
                InspectorColorWell(
                    selectedHex: style.colorHex(in: borderScope),
                    noneShowsAutomatic: true,
                    noneLabel: "ColorSwatches.None.Border.Accessibility"
                ) { hex in
                    state.applyStyle(in: &workbook) { $0.setColorHex(hex, in: borderScope) }
                }
            }
        }
    }

    /// Draws or clears whichever part of the box was clicked in the diagram.
    private func toggle(_ target: BorderTarget) {
        state.applyStyle(in: &workbook) { current in
            let diagonal = current.diagonalBorder
            switch target {
            case .edge(let edge):
                current.toggleBorder(edge.edges)
            case .diagonalUp:
                current.setDiagonal(up: !(diagonal?.goesUp ?? false), down: diagonal?.goesDown ?? false)
            case .diagonalDown:
                current.setDiagonal(up: diagonal?.goesUp ?? false, down: !(diagonal?.goesDown ?? false))
            }
        }
    }

    // MARK: - Merge

    private var mergeSection: some View {
        InspectorSection("Format.Section.Merge") {
            HStack(spacing: 8) {
                Button {
                    state.mergeSelection(in: &workbook)
                } label: {
                    Text("Format.Merge.Merge").frame(maxWidth: .infinity)
                }
                .disabled(!state.canMergeSelection(in: workbook))
                Button {
                    state.unmergeSelection(in: &workbook)
                } label: {
                    Text("Format.Merge.Unmerge").frame(maxWidth: .infinity)
                }
                .disabled(!state.canUnmergeSelection(in: workbook))
            }
        }
    }
}

/// How the selected cells' numbers read, laid out for the Mac inspector.
struct NumberFormatInspector: View {
    @Binding var workbook: Workbook
    @Bindable var state: EditorState

    @State private var customCode = ""

    private var currentCode: String { state.representativeStyle(in: workbook).numberFormat }

    var body: some View {
        InspectorScroll {
            InspectorSection("Panel.NumberFormat.Title") {
                InspectorRow("Mac.Inspector.NumberFormat.Format") {
                    InspectorPopup(selection: Binding(
                        get: { currentCode },
                        set: { code in
                            state.applyStyle(in: &workbook) { $0.numberFormat = code }
                            customCode = code
                        }
                    )) {
                        ForEach(NumberFormatPreset.allCases) { preset in
                            Text(preset.label).tag(preset.code)
                        }
                        if NumberFormatPreset.preset(forCode: currentCode) == nil {
                            Divider()
                            Text("Mac.Inspector.NumberFormat.Custom").tag(currentCode)
                        }
                    }
                }

                InspectorRow("Mac.Inspector.NumberFormat.Sample") {
                    Text(sample(for: currentCode))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            InspectorSection("NumberFormat.Section.CustomCode", showsDivider: false) {
                HStack(spacing: 8) {
                    TextField("NumberFormat.CustomCode.Placeholder", text: $customCode)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(applyCustomCode)
                    Button("Common.Apply", action: applyCustomCode)
                        .disabled(customCode.trimmed.isEmpty || customCode.trimmed == currentCode)
                }
            }
        }
        .onAppear { customCode = currentCode }
        .onChange(of: currentCode) { _, code in customCode = code }
    }

    private func applyCustomCode() {
        let code = customCode.trimmed
        guard !code.isEmpty else { return }
        state.applyStyle(in: &workbook) { $0.numberFormat = code }
    }

    private func sample(for code: String) -> String {
        let value: CellValue = code == NumberFormatPreset.text.code
            ? .text(String(localized: "NumberFormat.Sample.Text"))
            : .number(code.contains("%") ? 0.128 : 1234.5)
        return CellFormatter.displayText(for: value, format: code)
    }
}
