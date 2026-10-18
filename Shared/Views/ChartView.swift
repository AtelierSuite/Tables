import Charts
import ImageIO
import SwiftUI
import TablesEngine

/// Draws a `Chart` with Swift Charts.
///
/// The goal is to look like the chart Excel would draw from the same file —
/// same type, same series colours, same axis settings — not a pixel copy of
/// it. Sizes follow Excel's defaults, where text is measured in points:
/// a 14pt title, 9pt labels.
struct ChartView: View, Equatable {
    let chart: TablesEngine.Chart
    let data: ResolvedChart
    /// The grid's zoom, so a chart on the sheet grows with the cells under it.
    var zoom: Double = 1

    @Environment(\.colorScheme) private var colorScheme

    nonisolated static func == (lhs: ChartView, rhs: ChartView) -> Bool {
        lhs.chart == rhs.chart && lhs.data == rhs.data && lhs.zoom == rhs.zoom
    }

    var body: some View {
        VStack(spacing: 6 * zoom) {
            if let title = data.title, !title.isEmpty {
                Text(title)
                    .font(font(titleStyle, defaultSize: 14))
                    .foregroundStyle(textColor(titleStyle))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
            plot
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(10 * zoom)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(background, in: frameShape)
        .overlay {
            if chart.hasBorder {
                frameShape.strokeBorder(Color.gridLine, lineWidth: 1)
            }
        }
        .clipShape(frameShape)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(data.title ?? chart.name)
        // The description the author wrote for exactly this, when there is one.
        .accessibilityValue(chart.altText ?? "")
    }

    private var frameShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: chart.hasRoundedCorners ? 8 * zoom : 0, style: .continuous)
    }

    private var background: Color {
        if let hex = chart.backgroundColorHex {
            if hex.hasPrefix("00") { return .clear }
            return AdaptiveColor.resolve(hex: hex, for: palette, isText: false) ?? .sheetBackground
        }
        return .sheetBackground
    }

    /// The appearance to adapt the chart's colours for. A chart drawn on a
    /// dark background of its own is dark already, so it is left as authored.
    fileprivate var palette: ColorScheme {
        AdaptiveColor.isDarkFill(hex: chart.backgroundColorHex) == true ? .light : colorScheme
    }

    // MARK: - Plot

    @ViewBuilder
    private var plot: some View {
        if data.series.isEmpty || data.series.allSatisfy({ $0.values.allSatisfy { $0 == nil } }) {
            ContentUnavailableView {
                Label("Chart.Empty", systemImage: chart.kind.symbolName)
            }
            .font(.system(size: 12 * zoom))
        } else {
            switch chart.kind {
            case .pie, .doughnut: radialPlot
            case .column, .bar: barPlot
            case .line, .area: linePlot
            case .scatter: scatterPlot
            }
        }
    }

    // MARK: Points

    /// One plotted value, with the keys Swift Charts groups by.
    ///
    /// Swift Charts merges equal categorical values, so two categories both
    /// called "Total" would draw as one. Keys are made unique with trailing
    /// zero-width spaces, which no label visibly shows.
    private struct Point: Identifiable {
        var id: Int
        var series: Int
        var seriesKey: String
        var index: Int
        var categoryKey: String
        var value: Double
        var x: Double
    }

    private var seriesKeys: [String] { Self.uniqueKeys(data.series.map(\.name)) }
    private var categoryKeys: [String] { Self.uniqueKeys(data.categories) }

    private static func uniqueKeys(_ labels: [String]) -> [String] {
        var seen: [String: Int] = [:]
        return labels.map { label in
            let count = seen[label, default: 0]
            seen[label] = count + 1
            return label + String(repeating: "\u{200B}", count: count)
        }
    }

    private static func label(_ key: String) -> String {
        key.replacingOccurrences(of: "\u{200B}", with: "")
    }

    /// Every plottable point, with stacked lines accumulated here because
    /// line marks, unlike bars and areas, do not stack themselves.
    private var points: [Point] {
        let categories = categoryKeys
        let seriesNames = seriesKeys
        let stacksLines = chart.kind == .line && chart.grouping != .standard
        var running = [Double](repeating: 0, count: categories.count)
        var totals = [Double](repeating: 0, count: categories.count)
        if stacksLines, chart.grouping == .percentStacked {
            for series in data.series {
                for (index, value) in series.values.enumerated() where index < totals.count {
                    totals[index] += abs(value ?? 0)
                }
            }
        }

        var result: [Point] = []
        for (seriesIndex, series) in data.series.enumerated() {
            for (index, value) in series.values.enumerated() {
                guard let value, index < categories.count else { continue }
                var plotted = value
                if stacksLines {
                    running[index] += value
                    plotted = running[index]
                    if chart.grouping == .percentStacked {
                        plotted = totals[index] == 0 ? 0 : plotted / totals[index]
                    }
                }
                let x = series.xValues.indices.contains(index) ? series.xValues[index] : nil
                result.append(Point(
                    id: result.count, series: seriesIndex, seriesKey: seriesNames[seriesIndex],
                    index: index, categoryKey: categories[index], value: plotted,
                    x: x ?? Double(index + 1)
                ))
            }
        }
        return result
    }

    /// One colour per point instead of per series: Excel's "vary colours by
    /// point", which only means anything with a single series.
    private var colorsByPoint: Bool {
        chart.kind.isRadial || (chart.variesColors && data.series.count == 1 && chart.kind != .scatter)
    }

    private var colorDomain: [String] { colorsByPoint ? categoryKeys : seriesKeys }

    private var colorRange: [Color] {
        if colorsByPoint {
            let series = data.series.first
            return categoryKeys.indices.map { index in
                Color(argbHex: series?.pointColors[index] ?? ChartPalette.color(at: index, accents: data.accents))
                    ?? .accentColor
            }
        }
        return data.series.map { Color(argbHex: $0.colorHex) ?? .accentColor }
    }

    private func colorKey(_ point: Point) -> String {
        colorsByPoint ? point.categoryKey : point.seriesKey
    }

    // MARK: Bars

    private var barStacking: MarkStackingMethod {
        switch chart.grouping {
        case .standard: return .standard
        case .stacked: return .standard
        case .percentStacked: return .normalized
        }
    }

    private var barPlot: some View {
        let isHorizontal = chart.kind == .bar
        let isClustered = chart.grouping == .standard && data.series.count > 1
        return Charts.Chart(points) { point in
            if isHorizontal {
                if isClustered {
                    BarMark(x: .value("Value", point.value), y: .value("Category", point.categoryKey))
                        .foregroundStyle(by: .value("Color", colorKey(point)))
                        .position(by: .value("Series", point.seriesKey))
                        .annotation(position: .trailing) { dataLabel(point) }
                } else {
                    BarMark(
                        x: .value("Value", point.value), y: .value("Category", point.categoryKey),
                        stacking: barStacking
                    )
                    .foregroundStyle(by: .value("Color", colorKey(point)))
                    .annotation(position: .overlay) { dataLabel(point) }
                }
            } else {
                if isClustered {
                    BarMark(x: .value("Category", point.categoryKey), y: .value("Value", point.value))
                        .foregroundStyle(by: .value("Color", colorKey(point)))
                        .position(by: .value("Series", point.seriesKey))
                        .annotation(position: .top) { dataLabel(point) }
                } else {
                    BarMark(
                        x: .value("Category", point.categoryKey), y: .value("Value", point.value),
                        stacking: barStacking
                    )
                    .foregroundStyle(by: .value("Color", colorKey(point)))
                    .annotation(position: chart.grouping == .standard ? .top : .overlay) { dataLabel(point) }
                }
            }
        }
        .modifier(CartesianStyle(chart: self, categoryIsVertical: isHorizontal))
    }

    // MARK: Lines and areas

    private var linePlot: some View {
        let isArea = chart.kind == .area
        let areaStacking: MarkStackingMethod = switch chart.grouping {
        case .standard: .unstacked
        case .stacked: .standard
        case .percentStacked: .normalized
        }
        return Charts.Chart(points) { point in
            let series = chart.series.indices.contains(point.series) ? chart.series[point.series] : ChartSeries()
            if isArea {
                AreaMark(
                    x: .value("Category", point.categoryKey), y: .value("Value", point.value),
                    stacking: areaStacking
                )
                .foregroundStyle(by: .value("Color", point.seriesKey))
                .annotation(position: .top) { dataLabel(point) }
            } else {
                if series.showsLine {
                    LineMark(x: .value("Category", point.categoryKey), y: .value("Value", point.value))
                        .foregroundStyle(by: .value("Color", point.seriesKey))
                        .lineStyle(StrokeStyle(lineWidth: (series.lineWidth ?? 2.25) * zoom, lineCap: .round))
                        .interpolationMethod(series.isSmooth ? .catmullRom : .linear)
                }
                if series.showsMarkers {
                    PointMark(x: .value("Category", point.categoryKey), y: .value("Value", point.value))
                        .foregroundStyle(by: .value("Color", point.seriesKey))
                        .symbolSize(28 * zoom * zoom)
                        .annotation(position: .top) { dataLabel(point) }
                } else {
                    PointMark(x: .value("Category", point.categoryKey), y: .value("Value", point.value))
                        .foregroundStyle(by: .value("Color", point.seriesKey))
                        .symbolSize(0)
                        .annotation(position: .top) { dataLabel(point) }
                }
            }
        }
        .modifier(CartesianStyle(chart: self, categoryIsVertical: false))
    }

    // MARK: Scatter

    private var scatterPlot: some View {
        Charts.Chart(points) { point in
            let series = chart.series.indices.contains(point.series) ? chart.series[point.series] : ChartSeries()
            if series.showsLine {
                LineMark(
                    x: .value("X", point.x), y: .value("Y", point.value),
                    series: .value("Series", point.seriesKey)
                )
                .foregroundStyle(by: .value("Color", point.seriesKey))
                .lineStyle(StrokeStyle(lineWidth: (series.lineWidth ?? 2.25) * zoom, lineCap: .round))
                .interpolationMethod(series.isSmooth ? .catmullRom : .linear)
            }
            PointMark(x: .value("X", point.x), y: .value("Y", point.value))
                .foregroundStyle(by: .value("Color", point.seriesKey))
                .symbolSize(series.showsMarkers ? 28 * zoom * zoom : 0)
                .annotation(position: .top) { dataLabel(point) }
        }
        .modifier(CartesianStyle(chart: self, categoryIsVertical: false))
    }

    // MARK: Pie and doughnut

    private var radialPlot: some View {
        let slices = points.filter { $0.series == 0 && $0.value > 0 }
        let total = slices.reduce(0) { $0 + $1.value }
        let inner: MarkDimension = chart.kind == .doughnut ? .ratio(Double(chart.holeSize) / 100) : .ratio(0)
        return Charts.Chart(slices) { point in
            SectorMark(angle: .value("Value", point.value), innerRadius: inner, angularInset: 0.5)
                .foregroundStyle(by: .value("Color", point.categoryKey))
                .annotation(position: .overlay) {
                    if chart.dataLabels.isVisible {
                        Text(radialLabel(point, total: total))
                            .font(font(labelStyle, defaultSize: 9))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.35), radius: 1)
                    }
                }
        }
        .chartForegroundStyleScale(domain: categoryKeys, range: colorRange)
        .modifier(LegendStyle(chart: self))
    }

    private func radialLabel(_ point: Point, total: Double) -> String {
        var parts: [String] = []
        let labels = chart.dataLabels
        if labels.showsCategoryName { parts.append(Self.label(point.categoryKey)) }
        if labels.showsValue { parts.append(formatValue(point.value)) }
        if labels.showsPercentage, total > 0 {
            parts.append(CellFormatter.displayText(for: .number(point.value / total), format: "0%"))
        }
        return parts.joined(separator: "\n")
    }

    // MARK: - Labels

    @ViewBuilder
    private func dataLabel(_ point: Point) -> some View {
        let labels = chart.dataLabels
        if labels.isVisible {
            let parts = [
                labels.showsSeriesName ? Self.label(point.seriesKey) : nil,
                labels.showsCategoryName ? Self.label(point.categoryKey) : nil,
                labels.showsValue ? formatValue(point.value) : nil,
            ].compactMap { $0 }
            Text(parts.joined(separator: ", "))
                .font(font(labelStyle, defaultSize: 9))
                .foregroundStyle(textColor(labelStyle))
        }
    }

    fileprivate func formatValue(_ value: Double, axis: ChartAxis? = nil) -> String {
        if chart.grouping == .percentStacked, axis != nil {
            return CellFormatter.displayText(for: .number(value), format: axis?.numberFormat ?? "0%")
        }
        let format = axis?.numberFormat ?? data.valueFormat
        return CellFormatter.displayText(for: .number(value), format: format)
    }

    fileprivate func formatX(_ value: Double) -> String {
        let format = chart.categoryAxis.numberFormat ?? data.categoryFormat
        return CellFormatter.displayText(for: .number(value), format: format)
    }

    // MARK: - Text

    fileprivate var titleStyle: ChartTextStyle {
        (chart.title?.textStyle ?? ChartTextStyle()).inheriting(from: chartStyle(scale: 1.4))
    }

    fileprivate var labelStyle: ChartTextStyle { chart.textStyle }

    fileprivate var legendStyle: ChartTextStyle { chart.legendTextStyle.inheriting(from: chart.textStyle) }

    fileprivate func axisStyle(_ axis: ChartAxis) -> ChartTextStyle {
        axis.textStyle.inheriting(from: chart.textStyle)
    }

    fileprivate func axisTitleStyle(_ axis: ChartAxis) -> ChartTextStyle {
        (axis.title?.textStyle ?? ChartTextStyle()).inheriting(from: chartStyle(scale: 10.0 / 9))
    }

    /// The chart-wide style with its size scaled, for elements Excel draws a
    /// step larger than the body text by default.
    private func chartStyle(scale: Double) -> ChartTextStyle {
        var style = chart.textStyle
        style.fontSize = style.fontSize.map { $0 * scale }
        return style
    }

    fileprivate func font(_ style: ChartTextStyle, defaultSize: Double) -> Font {
        let size = (style.fontSize ?? defaultSize) * zoom
        var font: Font = style.fontName.map { .custom($0, size: size) } ?? .system(size: size)
        if style.isBold == true { font = font.bold() }
        if style.isItalic == true { font = font.italic() }
        return font
    }

    fileprivate func textColor(_ style: ChartTextStyle) -> Color {
        AdaptiveColor.resolve(hex: style.colorHex, for: palette, isText: true) ?? .secondary
    }
}

// MARK: - Axes

/// The axis, scale, legend and colour settings every chart with axes shares.
private struct CartesianStyle: ViewModifier {
    let chart: ChartView
    /// Bar charts lay their categories up the side.
    let categoryIsVertical: Bool

    private var model: TablesEngine.Chart { chart.chart }
    private var horizontalAxis: ChartAxis { categoryIsVertical ? model.valueAxis : model.categoryAxis }
    private var verticalAxis: ChartAxis { categoryIsVertical ? model.categoryAxis : model.valueAxis }

    func body(content: Content) -> some View {
        content
            .chartForegroundStyleScale(domain: chart.colorDomainValue, range: chart.colorRangeValue)
            .chartXAxis(horizontalAxis.isVisible ? .automatic : .hidden)
            .chartYAxis(verticalAxis.isVisible ? .automatic : .hidden)
            .chartXAxis {
                marks(
                    for: horizontalAxis, isValueAxis: categoryIsVertical || model.kind == .scatter,
                    isScatterX: model.kind == .scatter
                )
            }
            .chartYAxis { marks(for: verticalAxis, isValueAxis: !categoryIsVertical, isScatterX: false) }
            .chartXAxisLabel(position: .bottom, alignment: .center) {
                axisTitle(horizontalAxis)
            }
            .chartYAxisLabel(position: .leading, alignment: .center) {
                axisTitle(verticalAxis)
            }
            .modifier(ScaleStyle(chart: chart, categoryIsVertical: categoryIsVertical))
            .modifier(LegendStyle(chart: chart))
    }

    @ViewBuilder
    private func axisTitle(_ axis: ChartAxis) -> some View {
        if axis.isVisible, let title = axis.title, !title.text.isEmpty {
            Text(title.text)
                .font(chart.font(chart.axisTitleStyle(axis), defaultSize: 10))
                .foregroundStyle(chart.textColor(chart.axisTitleStyle(axis)))
        }
    }

    private func marks(for axis: ChartAxis, isValueAxis: Bool, isScatterX: Bool) -> some AxisContent {
        let values: AxisMarkValues = isValueAxis && axis.majorUnit != nil
            ? .stride(by: axis.majorUnit ?? 1)
            : .automatic
        let style = chart.axisStyle(axis)
        return AxisMarks(values: values) { value in
            if axis.showsMajorGridlines {
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
            }
            AxisValueLabel {
                Text(label(for: value, axis: axis, isScatterX: isScatterX))
                    .font(chart.font(style, defaultSize: 9))
                    .foregroundStyle(chart.textColor(style))
            }
        }
    }

    /// A scatter chart's X values are numbers too, but they take the number
    /// format of the cells they came from, not of the Y values.
    private func label(for value: AxisValue, axis: ChartAxis, isScatterX: Bool) -> String {
        if let number = value.as(Double.self) {
            return isScatterX ? chart.formatX(number) : chart.formatValue(number, axis: axis)
        }
        if let text = value.as(String.self) { return text.replacingOccurrences(of: "\u{200B}", with: "") }
        return ""
    }
}

/// Fixed axis bounds and reversed axes.
private struct ScaleStyle: ViewModifier {
    let chart: ChartView
    let categoryIsVertical: Bool

    private var model: TablesEngine.Chart { chart.chart }

    func body(content: Content) -> some View {
        let categories = chart.categoryKeysValue
        if model.kind == .scatter {
            content
                .modifier(NumericScale(
                    isHorizontal: true, range: domain(for: model.categoryAxis, values: allXValues),
                    reversed: model.categoryAxis.isReversed, includesZero: false
                ))
                .modifier(NumericScale(
                    isHorizontal: false, range: domain(for: model.valueAxis, values: allValues),
                    reversed: model.valueAxis.isReversed, includesZero: true
                ))
        } else if categoryIsVertical {
            // Excel draws a bar chart's first category at the bottom.
            content
                .chartYScale(domain: model.categoryAxis.isReversed ? categories : categories.reversed())
                .modifier(NumericScale(
                    isHorizontal: true, range: domain(for: model.valueAxis, values: allValues),
                    reversed: model.valueAxis.isReversed, includesZero: true
                ))
        } else {
            content
                .chartXScale(domain: model.categoryAxis.isReversed ? categories.reversed() : categories)
                .modifier(NumericScale(
                    isHorizontal: false, range: domain(for: model.valueAxis, values: allValues),
                    reversed: model.valueAxis.isReversed, includesZero: true
                ))
        }
    }

    private var allValues: [Double] {
        chart.data.series.flatMap { $0.values.compactMap { $0 } }
    }

    private var allXValues: [Double] {
        chart.data.series.flatMap { $0.xValues.compactMap { $0 } }
    }

    /// A fixed range when the axis pins either end, the other end found from
    /// the data the way Excel finds it.
    private func domain(for axis: ChartAxis, values: [Double]) -> ClosedRange<Double>? {
        guard axis.minimum != nil || axis.maximum != nil else { return nil }
        let low = axis.minimum ?? min(0, values.min() ?? 0)
        let high = axis.maximum ?? max(values.max() ?? 1, low + 1)
        guard low < high else { return nil }
        return low...high
    }
}

/// One numeric axis' scale: pinned when the axis fixes its bounds, automatic
/// otherwise.
private struct NumericScale: ViewModifier {
    let isHorizontal: Bool
    let range: ClosedRange<Double>?
    let reversed: Bool
    let includesZero: Bool

    func body(content: Content) -> some View {
        if let range {
            if isHorizontal {
                content.chartXScale(domain: range)
            } else {
                content.chartYScale(domain: range)
            }
        } else if isHorizontal {
            content.chartXScale(domain: .automatic(includesZero: includesZero, reversed: reversed))
        } else {
            content.chartYScale(domain: .automatic(includesZero: includesZero, reversed: reversed))
        }
    }
}

private struct LegendStyle: ViewModifier {
    let chart: ChartView

    func body(content: Content) -> some View {
        switch chart.chart.legend {
        case nil:
            content.chartLegend(.hidden)
        case .right?:
            content.chartLegend(position: .trailing, alignment: .center).font(legendFont)
        case .left?:
            content.chartLegend(position: .leading, alignment: .center).font(legendFont)
        case .top?:
            content.chartLegend(position: .top, alignment: .center).font(legendFont)
        case .topRight?:
            content.chartLegend(position: .top, alignment: .trailing).font(legendFont)
        case .bottom?:
            content.chartLegend(position: .bottom, alignment: .center).font(legendFont)
        }
    }

    private var legendFont: Font { chart.font(chart.legendStyle, defaultSize: 9) }
}

extension ChartView {
    fileprivate var colorDomainValue: [String] { colorDomain }
    fileprivate var colorRangeValue: [Color] { colorRange }
    fileprivate var categoryKeysValue: [String] { categoryKeys }
}

// MARK: - Placeholders

/// Stands in for a drawing object we keep but cannot draw — a picture, a
/// shape, a chart type outside the model — so the user can see where it is
/// and knows it is still there.
/// A picture kept from the file, drawn from its own image part with the crop
/// the file gives it. Pictures are the one kind of kept object we can show
/// as they are, rather than as a placeholder.
struct PreservedPictureView: View {
    let picture: DrawingPicture
    let data: Data

    var body: some View {
        if let image = PictureCache.shared.image(for: picture, data: data) {
            Image(decorative: image, scale: 1)
                .resizable()
        } else {
            PreservedDrawingPlaceholder(isChart: false)
        }
    }
}

/// Decoded, cropped pictures, so scrolling does not decode them again.
@MainActor
final class PictureCache {
    static let shared = PictureCache()
    /// Every workbook names its images `xl/media/image1.png` and so on, so
    /// the bytes are part of the key, not just the path.
    private struct Key: Hashable {
        var picture: DrawingPicture
        var data: Data
    }

    private var images: [Key: CGImage] = [:]
    private var failed: Set<Key> = []

    func image(for picture: DrawingPicture, data: Data) -> CGImage? {
        let key = Key(picture: picture, data: data)
        if let image = images[key] { return image }
        guard !failed.contains(key) else { return nil }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let full = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            failed.insert(key)
            return nil
        }
        let width = Double(full.width)
        let height = Double(full.height)
        // Negative crops pad the image out instead; drawing it whole is the
        // nearest we come to that.
        let crop = CGRect(
            x: width * max(0, picture.cropLeft),
            y: height * max(0, picture.cropTop),
            width: width * (1 - max(0, picture.cropLeft) - max(0, picture.cropRight)),
            height: height * (1 - max(0, picture.cropTop) - max(0, picture.cropBottom))
        ).integral
        let image = crop.width > 0 && crop.height > 0 ? full.cropping(to: crop) ?? full : full
        images[key] = image
        return image
    }
}

struct PreservedDrawingPlaceholder: View {
    var isChart: Bool
    var zoom: Double = 1

    var body: some View {
        RoundedRectangle(cornerRadius: 6 * zoom, style: .continuous)
            .fill(Color.secondary.opacity(0.08))
            .overlay {
                RoundedRectangle(cornerRadius: 6 * zoom, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            .overlay {
                VStack(spacing: 4 * zoom) {
                    Image(systemName: isChart ? "chart.bar.xaxis" : "photo")
                        .font(.system(size: 20 * zoom))
                    Text(isChart ? "Chart.Preserved.Chart" : "Chart.Preserved.Object")
                        .font(.system(size: 11 * zoom))
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
                .padding(8 * zoom)
            }
    }
}
