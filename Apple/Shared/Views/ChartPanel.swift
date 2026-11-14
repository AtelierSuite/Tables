import SwiftUI
import TablesEngine

/// The chart types, as menu items that chart the selection. Shared by the
/// iOS action bar and the macOS toolbar.
struct InsertChartMenuItems: View {
    @Binding var workbook: Workbook
    let state: EditorState

    var body: some View {
        ForEach(ChartKind.creatable, id: \.self) { kind in
            Button(kind.label, systemImage: kind.symbolName) {
                state.insertChart(kind, in: &workbook)
            }
            .accessibilityIdentifier("insertChart.\(kind.rawValue)")
        }
    }
}

/// Edits the selected chart: its type, data, titles, axes, legend, labels and
/// text. Every control writes straight into the chart, so the chart on the
/// sheet behind the panel changes as the controls do.
struct ChartPanel: View {
    @Binding var workbook: Workbook
    @Bindable var state: EditorState

    var body: some View {
        if let chart = state.selectedChart(in: workbook) {
            ChartForm(chart: chart, workbook: $workbook, state: state)
                // A fresh form per chart, so drafts typed for one never land
                // on another.
                .id(chart.id)
        } else {
            ContentUnavailableView(
                "Chart.Panel.NoChart", systemImage: "chart.bar.xaxis",
                description: Text("Chart.Panel.NoChart.Description")
            )
        }
    }
}

private struct ChartForm: View {
    let chart: Chart
    @Binding var workbook: Workbook
    let state: EditorState

    @State private var rangeDraft = ""
    @State private var rangeIsInvalid = false

    private var isChartSheet: Bool { state.activeSheet(in: workbook).isChartSheet }

    var body: some View {
        Form {
            typeSection
            dataSection
            titleSection
            if !chart.kind.isRadial {
                axisSection(
                    chart.kind == .bar ? "Chart.Axis.Vertical" : "Chart.Axis.Horizontal",
                    axis: \.categoryAxis, isValueAxis: chart.kind.plotsXY
                )
                axisSection(
                    chart.kind == .bar ? "Chart.Axis.Horizontal" : "Chart.Axis.Vertical",
                    axis: \.valueAxis, isValueAxis: true
                )
            }
            legendAndLabelsSection
            textSection
            appearanceSection
            altTextSection
            actionsSection
        }
        .formStyle(.grouped)
        .onAppear { rangeDraft = currentRangeText }
    }

    // MARK: - Bindings

    private func binding<Value>(_ keyPath: WritableKeyPath<Chart, Value>) -> Binding<Value> {
        Binding(
            get: { state.selectedChart(in: workbook)?[keyPath: keyPath] ?? chart[keyPath: keyPath] },
            set: { value in state.updateSelectedChart(in: &workbook) { $0[keyPath: keyPath] = value } }
        )
    }

    // MARK: - Type

    private var typeSection: some View {
        Section("Chart.Section.Type") {
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    // A kind that cannot be made from a selection is shown
                    // only on a chart that already is one.
                    ForEach(ChartKind.allCases.filter { ChartKind.creatable.contains($0) || $0 == chart.kind }, id: \.self) { kind in
                        kindButton(kind)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .scrollIndicators(.hidden)
            .listRowInsets(EdgeInsets())

            if chart.kind.supportsGrouping {
                Picker("Chart.Grouping", selection: binding(\.grouping)) {
                    ForEach(ChartGrouping.allCases, id: \.self) { grouping in
                        Text(grouping.label).tag(grouping)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private func kindButton(_ kind: ChartKind) -> some View {
        let isSelected = chart.kind == kind
        return Button {
            changeKind(to: kind)
        } label: {
            VStack(spacing: 6) {
                Image(systemName: kind.symbolName)
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 52, height: 40)
                    .background(
                        isSelected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1),
                        in: .rect(cornerRadius: 10, style: .continuous)
                    )
                    .foregroundStyle(isSelected ? Color.accentColor : .primary)
                Text(kind.label)
                    .font(.caption)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chartKind.\(kind.rawValue)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// Changing type keeps the data and the formatting, and adjusts only what
    /// the new type means differently — pies colour by slice, scatters plot
    /// markers without lines by default.
    private func changeKind(to kind: ChartKind) {
        state.updateSelectedChart(in: &workbook) { chart in
            let wasRadial = chart.kind.isRadial
            // A bubble chart keeps its sizes beside each series; any other
            // kind draws those columns as series of their own.
            if kind == .bubble, chart.kind != .bubble {
                chart.series = ChartBuilder.bubbles(from: chart.series)
            } else if chart.kind == .bubble, kind != .bubble {
                chart.series = chart.series.flatMap { series -> [ChartSeries] in
                    guard !series.bubbleSizes.isEmpty else { return [series] }
                    var bare = series
                    bare.bubbleSizes = ChartSource()
                    return [bare, ChartSeries(categories: series.categories, values: series.bubbleSizes)]
                }
            }
            chart.kind = kind
            // Every series is drawn as the chart's new kind, on one value axis.
            chart.secondaryValueAxis = nil
            for index in chart.series.indices {
                chart.series[index].plotKind = nil
                chart.series[index].usesSecondaryAxis = false
                if !kind.takesTrendlines {
                    chart.series[index].trendlines = []
                    chart.series[index].errorBars = []
                }
            }
            if kind.isRadial {
                chart.variesColors = true
                if chart.legend == nil { chart.legend = .right }
            } else if wasRadial {
                chart.variesColors = false
            }
            if !kind.supportsGrouping { chart.grouping = .standard }
            for index in chart.series.indices {
                switch kind {
                case .scatter:
                    chart.series[index].showsLine = false
                    chart.series[index].showsMarkers = true
                case .line:
                    chart.series[index].showsLine = true
                default:
                    chart.series[index].showsLine = true
                }
            }
        }
    }

    // MARK: - Data

    private var currentRangeText: String {
        EditorState.dataRange(of: chart)?.displayText(in: workbook) ?? ""
    }

    private var seriesInColumns: Bool {
        chart.series.first?.values.reference?.isVertical ?? true
    }

    private var dataSection: some View {
        Section {
            LabeledContent("Chart.Data.Range") {
                TextField("Chart.Data.Range.Placeholder", text: $rangeDraft)
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.characters)
                    #endif
                    .foregroundStyle(rangeIsInvalid ? Color.red : .primary)
                    .onSubmit { applyRange(seriesInColumns: nil) }
                    .accessibilityIdentifier("chartDataRange")
            }
            if !chart.kind.plotsXY {
                Picker("Chart.Data.SeriesIn", selection: Binding(
                    get: { seriesInColumns },
                    set: { applyRange(seriesInColumns: $0) }
                )) {
                    Text("Chart.Data.SeriesIn.Columns").tag(true)
                    Text("Chart.Data.SeriesIn.Rows").tag(false)
                }
                .disabled(EditorState.dataRange(of: chart) == nil)
            }

            ForEach(Array(chart.series.enumerated()), id: \.element.id) { index, series in
                seriesRow(series, index: index)
            }
        } header: {
            Text("Chart.Section.Data")
        } footer: {
            if rangeIsInvalid {
                Text("Chart.Data.Range.Invalid")
            }
        }
    }

    private func applyRange(seriesInColumns: Bool?) {
        let text = rangeDraft.isEmpty ? currentRangeText : rangeDraft
        rangeIsInvalid = !state.setSelectedChartData(text, seriesInColumns: seriesInColumns, in: &workbook)
        if !rangeIsInvalid { rangeDraft = currentRangeText }
    }

    private func seriesRow(_ series: ChartSeries, index: Int) -> some View {
        let resolved = chart.resolved(in: workbook)
        let name = resolved.series.indices.contains(index) ? resolved.series[index].name : ""
        let defaultColor = ChartPalette.color(at: index, accents: workbook.themeAccentColors)
        return HStack {
            ColorPicker(selection: Binding(
                get: { Color(argbHex: series.colorHex ?? defaultColor) ?? .accentColor },
                set: { color in
                    state.updateSelectedChart(in: &workbook) { chart in
                        guard chart.series.indices.contains(index) else { return }
                        chart.series[index].colorHex = color.argbHex
                    }
                }
            ), supportsOpacity: false) {
                Label {
                    Text(name)
                } icon: {
                    Circle()
                        .fill(Color(argbHex: series.colorHex ?? defaultColor) ?? .accentColor)
                        .frame(width: 12, height: 12)
                }
            }
            if series.kind(in: chart) == .line || series.kind(in: chart) == .scatter {
                Menu {
                    Toggle("Chart.Series.ShowLine", isOn: seriesFlag(index, \.showsLine))
                    Toggle("Chart.Series.ShowMarkers", isOn: seriesFlag(index, \.showsMarkers))
                    Toggle("Chart.Series.Smooth", isOn: seriesFlag(index, \.isSmooth))
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Chart.Series.Options")
            }
        }
    }

    private func seriesFlag(_ index: Int, _ keyPath: WritableKeyPath<ChartSeries, Bool>) -> Binding<Bool> {
        Binding(
            get: {
                let series = state.selectedChart(in: workbook)?.series ?? chart.series
                return series.indices.contains(index) ? series[index][keyPath: keyPath] : false
            },
            set: { value in
                state.updateSelectedChart(in: &workbook) { chart in
                    guard chart.series.indices.contains(index) else { return }
                    chart.series[index][keyPath: keyPath] = value
                }
            }
        )
    }

    // MARK: - Title

    private var titleSection: some View {
        Section("Chart.Section.Title") {
            TextField("Chart.Title.Placeholder", text: Binding(
                get: { state.selectedChart(in: workbook)?.title?.text ?? "" },
                set: { text in
                    state.updateSelectedChart(in: &workbook) { chart in
                        if text.isEmpty {
                            chart.title = nil
                            chart.showsAutomaticTitle = false
                        } else if chart.title == nil {
                            chart.title = ChartTitle(text: text)
                        } else {
                            // Typed text replaces a title read from a cell.
                            chart.title?.text = text
                            chart.title?.reference = nil
                        }
                    }
                }
            ), prompt: automaticTitlePrompt)
            .accessibilityIdentifier("chartTitle")

            if chart.title != nil {
                TextStyleControls(style: Binding(
                    get: { state.selectedChart(in: workbook)?.title?.textStyle ?? ChartTextStyle() },
                    set: { style in state.updateSelectedChart(in: &workbook) { $0.title?.textStyle = style } }
                ), defaultSize: 14)
            } else if chart.series.count == 1 {
                Toggle("Chart.Title.Automatic", isOn: binding(\.showsAutomaticTitle))
            }
        }
    }

    private var automaticTitlePrompt: Text {
        if chart.title == nil, chart.showsAutomaticTitle,
           let name = chart.resolved(in: workbook).series.first?.name, chart.series.count == 1 {
            return Text(name)
        }
        return Text("Chart.Title.Placeholder")
    }

    // MARK: - Axes

    private func axisSection(
        _ title: LocalizedStringKey, axis keyPath: WritableKeyPath<Chart, ChartAxis>, isValueAxis: Bool
    ) -> some View {
        let axis = binding(keyPath)
        return Section(title) {
            Toggle("Chart.Axis.Show", isOn: axis.isVisible)
            TextField("Chart.Axis.Title", text: Binding(
                get: { axis.wrappedValue.title?.text ?? "" },
                set: { text in
                    var updated = axis.wrappedValue
                    if text.isEmpty {
                        updated.title = nil
                    } else if updated.title == nil {
                        updated.title = ChartTitle(text: text)
                    } else {
                        updated.title?.text = text
                    }
                    axis.wrappedValue = updated
                }
            ))
            Toggle("Chart.Axis.Gridlines", isOn: axis.showsMajorGridlines)
            Toggle("Chart.Axis.Reversed", isOn: axis.isReversed)
            if isValueAxis {
                LabeledContent("Chart.Axis.Minimum") {
                    TextField("Chart.Axis.Automatic", value: axis.minimum, format: .number)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Chart.Axis.Maximum") {
                    TextField("Chart.Axis.Automatic", value: axis.maximum, format: .number)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Chart.Axis.MajorUnit") {
                    TextField("Chart.Axis.Automatic", value: axis.majorUnit, format: .number)
                        .multilineTextAlignment(.trailing)
                }
                Picker("Chart.Axis.NumberFormat", selection: axis.numberFormat) {
                    Text("Chart.Axis.NumberFormat.Linked").tag(String?.none)
                    ForEach(Self.axisFormats, id: \.self) { code in
                        Text(CellFormatter.displayText(for: .number(1234.5), format: code)).tag(Optional(code))
                    }
                    if let custom = axis.wrappedValue.numberFormat, !Self.axisFormats.contains(custom) {
                        Text(custom).tag(Optional(custom))
                    }
                }
            }
            TextStyleControls(style: axis.textStyle, defaultSize: 9, showsColor: false)
        }
    }

    private static let axisFormats = ["0", "0.0", "#,##0", "#,##0.00", "0%", "0.0%", "$#,##0", "0.00E+00"]

    // MARK: - Legend and labels

    private var legendAndLabelsSection: some View {
        Section("Chart.Section.Legend") {
            Picker("Chart.Legend", selection: binding(\.legend)) {
                Text("Chart.Legend.None").tag(ChartLegendPosition?.none)
                ForEach(ChartLegendPosition.allCases, id: \.self) { position in
                    Text(position.label).tag(Optional(position))
                }
            }
            Toggle("Chart.Labels.Values", isOn: labelsBinding(\.showsValue))
            if chart.kind.isRadial {
                Toggle("Chart.Labels.Percentages", isOn: labelsBinding(\.showsPercentage))
            }
            Toggle("Chart.Labels.Categories", isOn: labelsBinding(\.showsCategoryName))
            if !chart.kind.isRadial {
                Toggle("Chart.Labels.SeriesNames", isOn: labelsBinding(\.showsSeriesName))
            }
            if chart.kind == .doughnut {
                LabeledContent("Chart.HoleSize") {
                    Stepper(value: binding(\.holeSize), in: 10...90, step: 5) {
                        Text("\(chart.holeSize)%").monospacedDigit()
                    }
                }
            }
            if !chart.kind.isRadial, chart.series.count == 1, !chart.kind.plotsXY, chart.kind != .radar,
               chart.kind != .stock {
                Toggle("Chart.VaryColors", isOn: binding(\.variesColors))
            }
        }
    }

    /// The chart's labels. The panel has one set of switches for the whole
    /// chart, so turning one makes every series follow it, including those
    /// the file gave labels of their own.
    private func labelsBinding(_ keyPath: WritableKeyPath<ChartDataLabels, Bool>) -> Binding<Bool> {
        Binding(
            get: { (state.selectedChart(in: workbook) ?? chart).dataLabels[keyPath: keyPath] },
            set: { value in
                state.updateSelectedChart(in: &workbook) { chart in
                    chart.dataLabels[keyPath: keyPath] = value
                    for index in chart.series.indices { chart.series[index].dataLabels = nil }
                }
            }
        )
    }

    // MARK: - Text and appearance

    private var textSection: some View {
        Section("Chart.Section.Text") {
            TextStyleControls(style: binding(\.textStyle), defaultSize: 9)
        }
    }

    private var appearanceSection: some View {
        Section("Chart.Section.Background") {
            SystemColorSwatches(
                role: .fill,
                selectedHex: chart.backgroundColorHex,
                customColor: Binding(
                    get: { Color(argbHex: chart.backgroundColorHex) ?? .white },
                    set: { color in
                        state.updateSelectedChart(in: &workbook) { $0.backgroundColorHex = color.argbHex }
                    }
                ),
                onSelect: { swatch in
                    state.updateSelectedChart(in: &workbook) { $0.backgroundColorHex = swatch.argbHex }
                },
                onClear: {
                    state.updateSelectedChart(in: &workbook) { $0.backgroundColorHex = nil }
                }
            )
            Toggle("Chart.Border", isOn: binding(\.hasBorder))
            Toggle("Chart.RoundedCorners", isOn: binding(\.hasRoundedCorners))
            Toggle("Chart.HiddenCells", isOn: Binding(
                get: { !(state.selectedChart(in: workbook)?.plotsVisibleCellsOnly ?? chart.plotsVisibleCellsOnly) },
                set: { value in state.updateSelectedChart(in: &workbook) { $0.plotsVisibleCellsOnly = !value } }
            ))
        }
    }

    // MARK: - Alt text

    private var altTextSection: some View {
        Section {
            TextField("Chart.AltText.Placeholder", text: Binding(
                get: { state.selectedChart(in: workbook)?.altText ?? "" },
                set: { text in state.updateSelectedChart(in: &workbook) { $0.altText = text.isEmpty ? nil : text } }
            ), axis: .vertical)
            .lineLimit(2...5)
            .accessibilityIdentifier("chartAltText")
        } header: {
            Text("Chart.Section.AltText")
        } footer: {
            Text("Chart.AltText.Footer")
        }
    }

    // MARK: - Actions

    private var actionsSection: some View {
        Section {
            if isChartSheet {
                let worksheets = workbook.sheets.filter { !$0.isChartSheet }
                Menu("Chart.Menu.MoveToSheet") {
                    ForEach(worksheets) { sheet in
                        Button(sheet.name) { state.moveChartSheetIntoWorksheet(sheet.id, in: &workbook) }
                    }
                }
                .disabled(worksheets.isEmpty)
            } else {
                Button("Chart.Menu.MoveToNewSheet") { state.moveSelectedChartToNewSheet(in: &workbook) }
            }
            Button("Chart.Menu.Delete", role: .destructive) { state.deleteSelectedChart(in: &workbook) }
                .accessibilityIdentifier("deleteChart")
        }
    }
}

/// Size, weight, slant and colour for one piece of chart text. Unset values
/// show what the chart actually draws, so the controls never claim a default
/// the chart is not using.
private struct TextStyleControls: View {
    @Binding var style: ChartTextStyle
    var defaultSize: Double
    var showsColor = true

    var body: some View {
        LabeledContent("Chart.Text.Size") {
            Stepper(value: Binding(
                get: { style.fontSize ?? defaultSize },
                set: { style.fontSize = $0 }
            ), in: 6...72, step: 1) {
                Text(String(format: String(localized: "Chart.Text.Points"), Int(style.fontSize ?? defaultSize)))
                    .monospacedDigit()
            }
        }
        HStack(spacing: 12) {
            toggle("bold", label: "Toolbar.Bold", isOn: style.isBold == true) {
                style.isBold = !(style.isBold ?? false)
            }
            toggle("italic", label: "Toolbar.Italic", isOn: style.isItalic == true) {
                style.isItalic = !(style.isItalic ?? false)
            }
        }
        if showsColor {
            SystemColorSwatches(
                role: .text,
                selectedHex: style.colorHex,
                customColor: Binding(
                    get: { Color(argbHex: style.colorHex) ?? .primary },
                    set: { style.colorHex = $0.argbHex }
                ),
                onSelect: { style.colorHex = $0.argbHex },
                onClear: { style.colorHex = nil }
            )
        }
    }

    private func toggle(
        _ symbol: String, label: LocalizedStringKey, isOn: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 40, height: 40)
                .background(isOn ? Color.accentColor.opacity(0.2) : .clear, in: .circle)
                .foregroundStyle(isOn ? Color.accentColor : .primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
