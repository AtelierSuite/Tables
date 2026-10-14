import SwiftUI

/// Cell appearance controls. Shared by the iOS sheet and the macOS popover.
struct FormatPanel: View {
    @Binding var workbook: Workbook
    @Bindable var state: EditorState

    /// Which sides the border line style and colour are aimed at.
    @State private var borderScope: BorderScope = .all

    private var style: CellStyle { state.representativeStyle(in: workbook) }

    var body: some View {
        Form {
            Section("Format.Section.Text") {
                HStack(spacing: 12) {
                    styleToggle("bold", label: "Toolbar.Bold", isOn: style.isBold) {
                        state.toggleBold(in: &workbook)
                    }
                    styleToggle("italic", label: "Toolbar.Italic", isOn: style.isItalic) {
                        state.toggleItalic(in: &workbook)
                    }
                    styleToggle("underline", label: "Toolbar.Underline", isOn: style.isUnderlined) {
                        state.toggleUnderline(in: &workbook)
                    }
                    styleToggle("strikethrough", label: "Toolbar.Strikethrough", isOn: style.isStruckThrough) {
                        state.toggleStrikethrough(in: &workbook)
                    }
                }

                LabeledContent("Format.Text.Size") {
                    HStack(spacing: 16) {
                        Button {
                            state.applyStyle(in: &workbook) { $0.fontSize = max(6, $0.fontSize - 1) }
                        } label: {
                            Image(systemName: "minus")
                                .font(.system(size: 17, weight: .medium))
                                .frame(width: 30, height: 30)
                                .contentShape(.rect)
                        }
                        .accessibilityIdentifier("fontSize.decrease")
                        .accessibilityLabel("Format.Text.Size.Decrease")
                        Text(String(Int(style.fontSize)))
                            .font(.system(size: 17, weight: .medium))
                            .monospacedDigit()
                            .frame(minWidth: 30)
                            .accessibilityIdentifier("fontSize.value")
                        Button {
                            state.applyStyle(in: &workbook) { $0.fontSize = min(96, $0.fontSize + 1) }
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 17, weight: .medium))
                                .frame(width: 30, height: 30)
                                .contentShape(.rect)
                        }
                        .accessibilityIdentifier("fontSize.increase")
                        .accessibilityLabel("Format.Text.Size.Increase")
                    }
                    .buttonStyle(.borderless)
                }

                SystemColorSwatches(
                    role: .text,
                    selectedHex: style.textColorHex,
                    customColor: Binding(
                        get: { style.textColor ?? .primary },
                        set: { newValue in
                            state.applyStyle(in: &workbook) { $0.textColorHex = newValue.argbHex }
                        }
                    ),
                    onSelect: { swatch in
                        state.applyStyle(in: &workbook) { $0.textColorHex = swatch.argbHex }
                    },
                    onClear: {
                        state.applyStyle(in: &workbook) { $0.textColorHex = nil }
                    }
                )
            }

            Section("Format.Section.Fill") {
                SystemColorSwatches(
                    role: .fill,
                    selectedHex: style.fillColorHex,
                    customColor: Binding(
                        get: { style.fillColor ?? .clear },
                        set: { newValue in
                            state.applyStyle(in: &workbook) { $0.fillColorHex = newValue.argbHex }
                        }
                    ),
                    onSelect: { swatch in
                        state.applyStyle(in: &workbook) { $0.fillColorHex = swatch.argbHex }
                    },
                    onClear: {
                        state.applyStyle(in: &workbook) { $0.fillColorHex = nil }
                    }
                )
            }

            Section("Format.Section.Alignment") {
                Picker("Format.Alignment.Horizontal", selection: Binding(
                    get: { style.horizontalAlignment },
                    set: { value in state.applyStyle(in: &workbook) { $0.horizontalAlignment = value } }
                )) {
                    ForEach(HorizontalTextAlignment.allCases, id: \.self) { option in
                        Label(option.label, systemImage: option.symbolName).tag(option)
                    }
                }
                Picker("Format.Alignment.Vertical", selection: Binding(
                    get: { style.verticalAlignment },
                    set: { value in state.applyStyle(in: &workbook) { $0.verticalAlignment = value } }
                )) {
                    ForEach(VerticalTextAlignment.allCases, id: \.self) { option in
                        Label(option.label, systemImage: option.symbolName).tag(option)
                    }
                }
                Toggle("Format.Alignment.WrapText", isOn: Binding(
                    get: { style.wrapsText },
                    set: { value in state.applyStyle(in: &workbook) { $0.wrapsText = value } }
                ))

                // Offered only where they can be saved: a Numbers document
                // keeps its own indents, rotation, borders and merges.
                if state.formatting.contains(.indents) {
                    indentControl
                }
                if state.formatting.contains(.rotation) {
                    rotationPicker
                }
            }

            if state.formatting.contains(.borders) {
                bordersSection
            }

            if state.formatting.contains(.merging) {
                Section("Format.Section.Merge") {
                    Button("Format.Merge.Merge") { state.mergeSelection(in: &workbook) }
                        .disabled(!state.canMergeSelection(in: workbook))
                    Button("Format.Merge.Unmerge") { state.unmergeSelection(in: &workbook) }
                        .disabled(!state.canUnmergeSelection(in: workbook))
                }
            }

            Section {
                Button("Format.ClearAll", role: .destructive) {
                    state.clearFormatting(in: &workbook)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var indentControl: some View {
        LabeledContent("Format.Alignment.Indent") {
            HStack(spacing: 12) {
                Button {
                    state.applyStyle(in: &workbook) { $0.indent = max(0, $0.indent - 1) }
                } label: {
                    Image(systemName: "decrease.indent")
                }
                Text(String(style.indent))
                    .font(.system(size: 13, weight: .medium))
                    .frame(minWidth: 26)
                Button {
                    state.applyStyle(in: &workbook) { $0.indent = min(250, $0.indent + 1) }
                } label: {
                    Image(systemName: "increase.indent")
                }
            }
            .buttonStyle(.borderless)
        }
    }

    private var rotationPicker: some View {
        Picker("Format.Alignment.Rotation", selection: Binding(
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

    private var bordersSection: some View {
        Section("Format.Section.Borders") {
            BorderBoxPicker(style: style) { target in toggle(target) }
                .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 0) {
                CarouselCaption(key: "Format.Border.ApplyTo")
                BorderScopePicker(scope: $borderScope)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
            .listRowInsets(EdgeInsets())

            VStack(alignment: .leading, spacing: 0) {
                BorderLineStylePicker(selection: style.lineStyle(in: borderScope)) { value in
                    state.applyStyle(in: &workbook) { $0.setLineStyle(value, in: borderScope) }
                }
                .padding(.top, 8)
            }
            .listRowInsets(EdgeInsets())

            VStack(alignment: .leading, spacing: 0) {
                SystemColorSwatches(
                    role: .border,
                    selectedHex: style.colorHex(in: borderScope),
                    customColor: Binding(
                        get: { Color(argbHex: style.colorHex(in: borderScope)) ?? .primary },
                        set: { newValue in
                            state.applyStyle(in: &workbook) {
                                $0.setColorHex(newValue.argbHex, in: borderScope)
                            }
                        }
                    ),
                    onSelect: { swatch in
                        state.applyStyle(in: &workbook) {
                            $0.setColorHex(swatch.argbHex, in: borderScope)
                        }
                    },
                    onClear: {
                        state.applyStyle(in: &workbook) { $0.setColorHex(nil, in: borderScope) }
                    }
                )
            }
            .listRowInsets(EdgeInsets())
        }
    }

    private func styleToggle(
        _ symbol: String, label: LocalizedStringKey, isOn: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .medium))
                .frame(width: 46, height: 46)
                .background(isOn ? Color.accentColor.opacity(0.2) : .clear, in: .circle)
                .foregroundStyle(isOn ? Color.accentColor : .primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// Draws or clears whichever part of the box was touched in the diagram.
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
}

/// Number format presets plus a free-form OOXML format code field.
struct NumberFormatPanel: View {
    @Binding var workbook: Workbook
    @Bindable var state: EditorState

    @State private var customCode = ""

    private var currentCode: String { state.representativeStyle(in: workbook).numberFormat }

    var body: some View {
        Form {
            Section("NumberFormat.Section.Presets") {
                ForEach(NumberFormatPreset.allCases) { preset in
                    Button {
                        state.applyStyle(in: &workbook) { $0.numberFormat = preset.code }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.label)
                                Text(sample(for: preset))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if currentCode == preset.code {
                                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }

            Section("NumberFormat.Section.CustomCode") {
                TextField("NumberFormat.CustomCode.Placeholder", text: $customCode)
                    .font(.system(size: 13))
                    #if os(iOS)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    #endif
                Button("Common.Apply") {
                    let code = customCode.trimmed
                    guard !code.isEmpty else { return }
                    state.applyStyle(in: &workbook) { $0.numberFormat = code }
                }
                .disabled(customCode.trimmed.isEmpty)
            }
        }
        .formStyle(.grouped)
        .onAppear { customCode = currentCode }
    }

    private func sample(for preset: NumberFormatPreset) -> String {
        let value: CellValue = preset == .text
            ? .text(String(localized: "NumberFormat.Sample.Text"))
            : .number(preset.code.contains("%") ? 0.128 : 1234.5)
        return CellFormatter.displayText(for: value, format: preset.code)
    }
}

/// Row and column structure: add, insert, delete, hide, resize.
struct RowsColumnsPanel: View {
    @Binding var workbook: Workbook
    @Bindable var state: EditorState

    private var activeSheet: Worksheet { state.activeSheet(in: workbook) }

    var body: some View {
        Form {
            Section("RowsColumns.Section.SheetSize") {
                LabeledContent("RowsColumns.Rows", value: String(activeSheet.rowCount))
                LabeledContent("RowsColumns.Columns", value: String(activeSheet.columnCount))
                Button("RowsColumns.Add.OneRow") { state.addRows(in: &workbook) }
                Button("RowsColumns.Add.TenRows") { state.addRows(10, in: &workbook) }
                Button("RowsColumns.Add.OneColumn") { state.addColumns(in: &workbook) }
                Button("RowsColumns.Add.FiveColumns") { state.addColumns(5, in: &workbook) }
            }

            Section("RowsColumns.Rows") {
                Button("RowsColumns.Rows.InsertAbove") { state.insertRows(above: true, in: &workbook) }
                Button("RowsColumns.Rows.InsertBelow") { state.insertRows(above: false, in: &workbook) }
                Button("RowsColumns.HideSelected") { state.setSelectedRows(hidden: true, in: &workbook) }
                Button("RowsColumns.ShowSelected") { state.setSelectedRows(hidden: false, in: &workbook) }
                Button("RowsColumns.DeleteSelected", role: .destructive) {
                    state.deleteSelectedRows(in: &workbook)
                }
                .disabled(activeSheet.rowCount <= 1)
            }

            Section("RowsColumns.Columns") {
                Button("RowsColumns.Columns.InsertBefore") { state.insertColumns(before: true, in: &workbook) }
                Button("RowsColumns.Columns.InsertAfter") { state.insertColumns(before: false, in: &workbook) }
                Button("RowsColumns.HideSelected") { state.setSelectedColumns(hidden: true, in: &workbook) }
                Button("RowsColumns.ShowSelected") { state.setSelectedColumns(hidden: false, in: &workbook) }
                Button("RowsColumns.DeleteSelected", role: .destructive) {
                    state.deleteSelectedColumns(in: &workbook)
                }
                .disabled(activeSheet.columnCount <= 1)
            }

            Section {
                let hiddenCount = activeSheet.hiddenRows.count + activeSheet.hiddenColumns.count
                Button(String(
                    format: String(localized: "RowsColumns.ShowAllHidden"), hiddenCount
                )) {
                    state.unhideEverything(in: &workbook)
                }
                .disabled(hiddenCount == 0)
            }
        }
        .formStyle(.grouped)
    }
}

/// A searchable list of built-in functions that seeds the formula editor.
struct FunctionsPanel: View {
    @Binding var workbook: Workbook
    @Bindable var state: EditorState

    @State private var query = ""

    private var matches: [String] {
        let trimmed = query.trimmed
        guard !trimmed.isEmpty else { return FormulaFunctions.names }
        return FormulaFunctions.names.filter { $0.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        List {
            ForEach(matches, id: \.self) { name in
                Button {
                    insert(name)
                } label: {
                    HStack {
                        Text(name).font(.system(size: 13, weight: .medium))
                        Spacer()
                        Image(systemName: "arrow.up.forward.app").foregroundStyle(.secondary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .searchable(text: $query, prompt: "Functions.Search.Prompt")
    }

    private func insert(_ name: String) {
        let box = state.selection.normalized
        if box.isSingleCell {
            state.beginEditing(box.start, in: workbook, replacingWith: "=\(name)(")
        } else {
            state.insertAggregate(name, in: &workbook)
        }
        state.presentedPanel = nil
    }
}
