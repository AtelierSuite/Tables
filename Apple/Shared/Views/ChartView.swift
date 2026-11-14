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
            case .bar: barPlot
            case .column, .line, .area, .stock: categoryPlot
            case .scatter, .bubble: scatterPlot
            case .radar: RadarPlot(chart: self)
            }
        }
    }

    // MARK: Points

    /// One plotted value, with the keys Swift Charts groups by.
    ///
    /// Swift Charts merges equal categorical values, so two categories both
    /// called "Total" would draw as one. Keys are made unique with trailing
    /// zero-width spaces, which no label visibly shows.
    fileprivate struct Point: Identifiable {
        var id: Int
        var series: Int
        var seriesKey: String
        var index: Int
        var categoryKey: String
        /// Where the point is drawn: stacked, and moved onto the main axis'
        /// scale when it is measured along the second one.
        var value: Double
        /// The value the cell holds, which its label shows.
        var raw: Double
        var x: Double
        var kind: ChartKind
        /// A bubble's size.
        var size: Double?
    }

    fileprivate var seriesKeys: [String] { Self.uniqueKeys(data.series.map(\.name)) }
    fileprivate var categoryKeys: [String] { Self.uniqueKeys(data.categories) }

    private static func uniqueKeys(_ labels: [String]) -> [String] {
        var seen: [String: Int] = [:]
        return labels.map { label in
            let count = seen[label, default: 0]
            seen[label] = count + 1
            return label + String(repeating: "\u{200B}", count: count)
        }
    }

    fileprivate static func label(_ key: String) -> String {
        key.replacingOccurrences(of: "\u{200B}", with: "")
    }

    /// The scales of a chart with a second value axis: the main one, and the
    /// far one, given as many steps so that both share the gridlines.
    fileprivate var dualScales: (primary: ChartAxisScale, secondary: ChartAxisScale)? {
        guard let axis = chart.secondaryValueAxis, data.series.contains(where: \.usesSecondaryAxis) else { return nil }
        let primary = ChartAxisScale.nice(
            data.valueExtent(secondary: false, grouping: chart.grouping, kind: chart.kind),
            axis: chart.valueAxis, includesZero: chart.kind != .stock
        )
        let secondary = ChartAxisScale.nice(
            data.valueExtent(secondary: true, grouping: chart.grouping, kind: chart.kind),
            axis: axis, includesZero: !data.series.contains { $0.usesSecondaryAxis && $0.kind == .stock },
            intervals: max(1, primary.ticks.count - 1)
        )
        return (primary, secondary)
    }

    /// A value as the plot draws it: on the second axis, moved to where the
    /// main axis has the same height.
    fileprivate func plotted(_ value: Double, secondary: Bool) -> Double {
        guard secondary, let scales = dualScales else { return value }
        return scales.primary.minimum
            + scales.secondary.fraction(value) * (scales.primary.maximum - scales.primary.minimum)
    }

    /// Every plottable point, with stacked lines accumulated here because
    /// line marks, unlike bars and areas, do not stack themselves.
    fileprivate var points: [Point] {
        let categories = categoryKeys
        let seriesNames = seriesKeys
        let stacksLines = chart.kind == .line && chart.grouping != .standard
        func stacks(_ series: ResolvedChart.Series) -> Bool {
            stacksLines && series.kind == .line && !series.usesSecondaryAxis
        }
        var running = [Double](repeating: 0, count: categories.count)
        var totals = [Double](repeating: 0, count: categories.count)
        if stacksLines, chart.grouping == .percentStacked {
            for series in data.series where stacks(series) {
                for (index, value) in series.values.enumerated() where index < totals.count {
                    totals[index] += abs(value ?? 0)
                }
            }
        }

        var result: [Point] = []
        for (seriesIndex, series) in data.series.enumerated() {
            for (index, value) in series.values.enumerated() {
                guard let value, index < categories.count else { continue }
                var plottedValue = value
                if stacks(series) {
                    running[index] += value
                    plottedValue = running[index]
                    if chart.grouping == .percentStacked {
                        plottedValue = totals[index] == 0 ? 0 : plottedValue / totals[index]
                    }
                }
                plottedValue = plotted(plottedValue, secondary: series.usesSecondaryAxis)
                let x = series.xValues.indices.contains(index) ? series.xValues[index] : nil
                let size = series.sizes.indices.contains(index) ? series.sizes[index] : nil
                result.append(Point(
                    id: result.count, series: seriesIndex, seriesKey: seriesNames[seriesIndex],
                    index: index, categoryKey: categories[index], value: plottedValue, raw: value,
                    x: x ?? Double(index + 1), kind: series.kind, size: size
                ))
            }
        }
        return result
    }

    /// One colour per point instead of per series: Excel's "vary colours by
    /// point", which only means anything with a single series.
    private var colorsByPoint: Bool {
        chart.kind.isRadial
            || (chart.variesColors && data.series.count == 1 && !chart.kind.plotsXY && chart.kind != .radar)
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

    private func model(_ index: Int) -> ChartSeries {
        chart.series.indices.contains(index) ? chart.series[index] : ChartSeries()
    }

    // MARK: Bars

    private var barStacking: MarkStackingMethod {
        switch chart.grouping {
        case .standard: return .standard
        case .stacked: return .standard
        case .percentStacked: return .normalized
        }
    }

    /// Horizontal bars.
    private var barPlot: some View {
        let isClustered = chart.grouping == .standard && data.series.count > 1
        return Charts.Chart(points) { point in
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
        }
        .modifier(CartesianStyle(chart: self, categoryIsVertical: true))
    }

    // MARK: Columns, lines, areas and stock

    /// Every chart that lays its categories along the bottom, each series
    /// drawn as its own kind, so that combination charts draw too.
    private var categoryPlot: some View {
        let columnSeries = Set(data.series.indices.filter { data.series[$0].kind == .column })
        let isClustered = chart.grouping == .standard && columnSeries.count > 1
        let areaStacking: MarkStackingMethod = switch chart.grouping {
        case .standard: .unstacked
        case .stacked: .standard
        case .percentStacked: .normalized
        }
        let stackOwn = chart.kind == .column || chart.kind == .area
        return Charts.Chart {
            ForEach(points) { point in
                let series = model(point.series)
                switch point.kind {
                case .column:
                    if isClustered {
                        BarMark(x: .value("Category", point.categoryKey), y: .value("Value", point.value))
                            .foregroundStyle(by: .value("Color", colorKey(point)))
                            .position(by: .value("Series", point.seriesKey))
                            .annotation(position: .top) { dataLabel(point) }
                    } else {
                        BarMark(
                            x: .value("Category", point.categoryKey), y: .value("Value", point.value),
                            stacking: stackOwn && point.kind == chart.kind ? barStacking : .unstacked
                        )
                        .foregroundStyle(by: .value("Color", colorKey(point)))
                        .annotation(position: chart.grouping == .standard ? .top : .overlay) { dataLabel(point) }
                    }
                case .area:
                    AreaMark(
                        x: .value("Category", point.categoryKey), y: .value("Value", point.value),
                        series: .value("Series", point.seriesKey),
                        stacking: stackOwn && point.kind == chart.kind ? areaStacking : .unstacked
                    )
                    .foregroundStyle(by: .value("Color", point.seriesKey))
                    .annotation(position: .top) { dataLabel(point) }
                default:
                    if series.showsLine {
                        LineMark(
                            x: .value("Category", point.categoryKey), y: .value("Value", point.value),
                            series: .value("Series", point.seriesKey)
                        )
                        .foregroundStyle(by: .value("Color", point.seriesKey))
                        .lineStyle(StrokeStyle(lineWidth: (series.lineWidth ?? 2.25) * zoom, lineCap: .round))
                        .interpolationMethod(series.isSmooth ? .catmullRom : .linear)
                    }
                    PointMark(x: .value("Category", point.categoryKey), y: .value("Value", point.value))
                        .foregroundStyle(by: .value("Color", point.seriesKey))
                        .symbolSize(series.showsMarkers ? 28 * zoom * zoom : 0)
                        .annotation(position: .top) { dataLabel(point) }
                }
            }
            ForEach(stockDays) { day in
                if chart.hasHighLowLines, let high = day.high, let low = day.low {
                    RuleMark(
                        x: .value("Category", day.category),
                        yStart: .value("Value", low), yEnd: .value("Value", high)
                    )
                    .foregroundStyle(Color.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1 * zoom))
                }
                if let bars = chart.upDownBars, let open = day.open, let close = day.close {
                    RectangleMark(
                        x: .value("Category", day.category),
                        yStart: .value("Value", min(open, close)), yEnd: .value("Value", max(open, close)),
                        width: .ratio(1 / (1 + Double(bars.gapWidth) / 100))
                    )
                    .foregroundStyle(close >= open ? upBarColor(bars) : downBarColor(bars))
                }
            }
            extras(xIsNumber: false)
        }
        .modifier(CartesianStyle(chart: self, categoryIsVertical: false))
    }

    /// One day of a stock chart, from its series in Excel's order: high,
    /// low, close, with open first when there are four.
    fileprivate struct StockDay: Identifiable {
        var id: Int
        var category: String
        var open: Double?
        var high: Double?
        var low: Double?
        var close: Double?
    }

    private var stockDays: [StockDay] {
        let stock = data.series.filter { $0.kind == .stock }
        guard stock.count >= 3 else { return [] }
        let roles: [ResolvedChart.Series?] = stock.count >= 4
            ? stock.prefix(4).map { $0 } : [nil] + stock.prefix(3).map { $0 }
        let categories = categoryKeys
        func value(_ series: ResolvedChart.Series?, _ index: Int) -> Double? {
            guard let series, series.values.indices.contains(index), let value = series.values[index] else { return nil }
            return plotted(value, secondary: series.usesSecondaryAxis)
        }
        return categories.indices.map { index in
            StockDay(
                id: index, category: categories[index], open: value(roles[0], index), high: value(roles[1], index),
                low: value(roles[2], index), close: value(roles[3], index)
            )
        }
    }

    /// Excel's up bars are white and its down bars black; drawn without the
    /// outline that makes a white bar visible, a light grey stands in.
    private func upBarColor(_ bars: ChartUpDownBars) -> Color {
        Color(argbHex: bars.upColorHex) ?? Color(white: 0.85)
    }

    private func downBarColor(_ bars: ChartUpDownBars) -> Color {
        Color(argbHex: bars.downColorHex) ?? Color(white: 0.25)
    }

    // MARK: Scatter and bubble

    private var scatterPlot: some View {
        let sizes = data.series.filter { $0.kind == .bubble }.flatMap { $0.sizes.compactMap { $0 } }
        let largest = sizes.map(abs).max() ?? 0
        return Charts.Chart {
            ForEach(points) { point in
                let series = model(point.series)
                if point.kind == .bubble {
                    PointMark(x: .value("X", point.x), y: .value("Y", point.value))
                        .foregroundStyle(by: .value("Color", point.seriesKey))
                        .symbolSize(bubbleArea(point.size, largest: largest))
                        .opacity(0.8)
                        .annotation(position: .overlay) { dataLabel(point) }
                } else {
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
            }
            extras(xIsNumber: true)
        }
        .modifier(CartesianStyle(chart: self, categoryIsVertical: false))
    }

    /// A bubble's area in square points. Excel sizes the largest bubble to a
    /// quarter of the plot's shorter side; a fixed size stands in for that,
    /// scaled as the chart asks. Sizes measure area unless they measure width.
    private func bubbleArea(_ size: Double?, largest: Double) -> CGFloat {
        guard let size, size > 0, largest > 0 else { return 0 }
        let diameter = 44 * zoom * Double(chart.bubbleScale) / 100
        let ratio = size / largest
        let scaled = chart.bubbleSizeIsWidth ? diameter * ratio : diameter * ratio.squareRoot()
        return scaled * scaled
    }

    // MARK: Trendlines and error bars

    fileprivate struct TrendPoint: Identifiable {
        var id: Int
        var line: String
        var category: String
        var x: Double
        var y: Double
        var color: Color
        var width: Double
        /// The equation and R², on the line's last point.
        var label: String?
    }

    fileprivate struct ErrorBar: Identifiable {
        var id: Int
        var seriesKey: String
        var category: String
        var x: Double
        var y: Double
        var low: Double
        var high: Double
        var isHorizontal: Bool
        var hasEndCaps: Bool
        var color: Color
    }

    private var trendPoints: [TrendPoint] {
        let categories = categoryKeys
        var result: [TrendPoint] = []
        for (seriesIndex, series) in data.series.enumerated() {
            for (lineIndex, line) in series.trendlines.enumerated() {
                let color = Color(argbHex: line.colorHex) ?? .accentColor
                for (pointIndex, point) in line.points.enumerated() {
                    let position = Int(point.x.rounded()) - 1
                    guard series.kind.plotsXY || categories.indices.contains(position) else { continue }
                    result.append(TrendPoint(
                        id: result.count, line: "trend-\(seriesIndex)-\(lineIndex)",
                        category: series.kind.plotsXY ? "" : categories[position], x: point.x,
                        y: plotted(point.y, secondary: series.usesSecondaryAxis), color: color,
                        width: (line.lineWidth ?? 1.5) * zoom,
                        label: pointIndex == line.points.count - 1 ? line.label : nil
                    ))
                }
            }
        }
        return result
    }

    private var errorBars: [ErrorBar] {
        let categories = categoryKeys
        let keys = seriesKeys
        var result: [ErrorBar] = []
        for (seriesIndex, series) in data.series.enumerated() {
            for set in series.errorBars {
                let color = set.colorHex.flatMap { Color(argbHex: $0) } ?? Color.primary.opacity(0.75)
                for bar in set.bars where bar.index < categories.count {
                    guard series.values.indices.contains(bar.index), let value = series.values[bar.index] else { continue }
                    let x = series.xValues.indices.contains(bar.index) ? series.xValues[bar.index] : nil
                    let isHorizontal = set.direction == .x
                    result.append(ErrorBar(
                        id: result.count, seriesKey: keys[seriesIndex], category: categories[bar.index],
                        x: x ?? Double(bar.index + 1),
                        y: plotted(value, secondary: series.usesSecondaryAxis),
                        low: isHorizontal ? bar.low : plotted(bar.low, secondary: series.usesSecondaryAxis),
                        high: isHorizontal ? bar.high : plotted(bar.high, secondary: series.usesSecondaryAxis),
                        isHorizontal: isHorizontal, hasEndCaps: set.hasEndCaps, color: color
                    ))
                }
            }
        }
        return result
    }

    /// Trendlines and error bars, over whatever the plot drew. On a chart
    /// with categories they sit at the categories; error bars on clustered
    /// columns move to their own column.
    @ChartContentBuilder
    private func extras(xIsNumber: Bool) -> some ChartContent {
        let clusters = chart.grouping == .standard && data.series.filter({ $0.kind == .column }).count > 1
        let cap = 7 * zoom
        ForEach(errorBars) { bar in
            if xIsNumber {
                if bar.isHorizontal {
                    RuleMark(xStart: .value("X", bar.low), xEnd: .value("X", bar.high), y: .value("Y", bar.y))
                        .foregroundStyle(bar.color)
                        .lineStyle(StrokeStyle(lineWidth: 1 * zoom))
                } else {
                    RuleMark(x: .value("X", bar.x), yStart: .value("Y", bar.low), yEnd: .value("Y", bar.high))
                        .foregroundStyle(bar.color)
                        .lineStyle(StrokeStyle(lineWidth: 1 * zoom))
                }
            } else if clusters {
                RuleMark(x: .value("Category", bar.category), yStart: .value("Value", bar.low), yEnd: .value("Value", bar.high))
                    .foregroundStyle(bar.color)
                    .lineStyle(StrokeStyle(lineWidth: 1 * zoom))
                    .position(by: .value("Series", bar.seriesKey))
            } else {
                RuleMark(x: .value("Category", bar.category), yStart: .value("Value", bar.low), yEnd: .value("Value", bar.high))
                    .foregroundStyle(bar.color)
                    .lineStyle(StrokeStyle(lineWidth: 1 * zoom))
            }
            if bar.hasEndCaps, !clusters || xIsNumber {
                ForEach([bar.low, bar.high], id: \.self) { end in
                    if xIsNumber && bar.isHorizontal {
                        PointMark(x: .value("X", end), y: .value("Y", bar.y))
                            .symbol { Rectangle().fill(bar.color).frame(width: 1 * zoom, height: cap) }
                    } else if xIsNumber {
                        PointMark(x: .value("X", bar.x), y: .value("Y", end))
                            .symbol { Rectangle().fill(bar.color).frame(width: cap, height: 1 * zoom) }
                    } else {
                        PointMark(x: .value("Category", bar.category), y: .value("Value", end))
                            .symbol { Rectangle().fill(bar.color).frame(width: cap, height: 1 * zoom) }
                    }
                }
            }
        }
        ForEach(trendPoints) { point in
            if xIsNumber {
                LineMark(x: .value("X", point.x), y: .value("Y", point.y), series: .value("Trend", point.line))
                    .foregroundStyle(point.color)
                    .lineStyle(StrokeStyle(lineWidth: point.width, dash: [3 * zoom, 2 * zoom]))
            } else {
                LineMark(
                    x: .value("Category", point.category), y: .value("Value", point.y),
                    series: .value("Trend", point.line)
                )
                .foregroundStyle(point.color)
                .lineStyle(StrokeStyle(lineWidth: point.width, dash: [3 * zoom, 2 * zoom]))
            }
        }
        // The equation and R² hang off an unseen point at the line's end:
        // a line that names its own series draws no annotations.
        ForEach(trendPoints.filter { $0.label != nil }) { point in
            if xIsNumber {
                PointMark(x: .value("X", point.x), y: .value("Y", point.y))
                    .symbolSize(0)
                    .annotation(position: .bottom, alignment: .trailing) { trendLabel(point) }
            } else {
                PointMark(x: .value("Category", point.category), y: .value("Value", point.y))
                    .symbolSize(0)
                    .annotation(position: .bottom, alignment: .trailing) { trendLabel(point) }
            }
        }
    }

    @ViewBuilder
    private func trendLabel(_ point: TrendPoint) -> some View {
        if let label = point.label {
            Text(label)
                .font(font(labelStyle, defaultSize: 9))
                .foregroundStyle(textColor(labelStyle))
                .multilineTextAlignment(.trailing)
                .fixedSize()
        }
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
        let labels = data.series.indices.contains(point.series) ? data.series[point.series].dataLabels : chart.dataLabels
        if labels.isVisible {
            let parts = [
                labels.showsSeriesName ? Self.label(point.seriesKey) : nil,
                labels.showsCategoryName && !point.kind.plotsXY ? Self.label(point.categoryKey) : nil,
                labels.showsCategoryName && point.kind.plotsXY ? formatX(point.x) : nil,
                labels.showsValue ? formatValue(point.raw) : nil,
                labels.showsBubbleSize ? point.size.map { formatValue($0) } : nil,
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

    /// The second value axis' tick label at a height on the main one.
    fileprivate func secondaryLabel(_ value: Double) -> String {
        guard let scales = dualScales, let axis = chart.secondaryValueAxis else { return "" }
        let secondary = scales.secondary.minimum
            + scales.primary.fraction(value) * (scales.secondary.maximum - scales.secondary.minimum)
        let format = axis.numberFormat ?? data.valueFormat
        return CellFormatter.displayText(for: .number(secondary), format: format)
    }

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
                    for: horizontalAxis, isValueAxis: categoryIsVertical || model.kind.plotsXY,
                    isScatterX: model.kind.plotsXY
                )
            }
            .chartYAxis { verticalMarks }
            .chartXAxisLabel(position: .bottom, alignment: .center) {
                axisTitle(horizontalAxis)
            }
            .chartYAxisLabel(position: .leading, alignment: .center) {
                axisTitle(verticalAxis)
            }
            .chartYAxisLabel(position: .trailing, alignment: .center) {
                if let secondary = model.secondaryValueAxis, chart.dualScalesValue != nil {
                    axisTitle(secondary)
                }
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

    /// The value axis, and on a chart with a second one, that axis on the
    /// far side, its labels placed at the main axis' gridlines.
    @AxisContentBuilder
    private var verticalMarks: some AxisContent {
        if let scales = chart.dualScalesValue, !categoryIsVertical {
            // The main axis takes the near side, as Excel draws it, so the
            // two sets of labels do not land on each other.
            marks(
                for: verticalAxis, isValueAxis: true, isScatterX: false, ticks: scales.primary.ticks,
                position: .leading
            )
            if let secondary = model.secondaryValueAxis, secondary.isVisible {
                let style = chart.axisStyle(secondary)
                AxisMarks(position: .trailing, values: scales.primary.ticks) { value in
                    AxisValueLabel {
                        Text(value.as(Double.self).map(chart.secondaryLabel) ?? "")
                            .font(chart.font(style, defaultSize: 9))
                            .foregroundStyle(chart.textColor(style))
                    }
                }
            }
        } else {
            marks(for: verticalAxis, isValueAxis: !categoryIsVertical, isScatterX: false)
        }
    }

    private func marks(
        for axis: ChartAxis, isValueAxis: Bool, isScatterX: Bool, ticks: [Double]? = nil,
        position: AxisMarkPosition = .automatic
    ) -> some AxisContent {
        let values: AxisMarkValues = if isValueAxis, let unit = axis.majorUnit {
            .stride(by: unit)
        } else {
            .automatic
        }
        let style = chart.axisStyle(axis)
        return AxisMarks(position: position, values: ticks.map { AxisMarkValues.stride(by: ($0.count > 1 ? $0[1] - $0[0] : 1)) } ?? values) { value in
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
        if model.kind.plotsXY {
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
            // A chart with a second axis has both scales worked out ahead,
            // so that they can share gridlines; a stock chart's prices need
            // not start from zero.
            let dual = chart.dualScalesValue.map { $0.primary.minimum...$0.primary.maximum }
            content
                .chartXScale(domain: model.categoryAxis.isReversed ? categories.reversed() : categories)
                .modifier(NumericScale(
                    isHorizontal: false, range: dual ?? domain(for: model.valueAxis, values: allValues),
                    reversed: model.valueAxis.isReversed, includesZero: model.kind != .stock
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
    fileprivate var dualScalesValue: (primary: ChartAxisScale, secondary: ChartAxisScale)? { dualScales }
}

// MARK: - Radar

/// A radar chart, drawn by hand: Swift Charts has no polar plot. One spoke
/// per category, clockwise from the top, the values measured out from the
/// centre on one scale for every spoke.
private struct RadarPlot: View {
    let chart: ChartView

    private var model: TablesEngine.Chart { chart.chart }
    private var zoom: Double { chart.zoom }

    var body: some View {
        switch model.legend {
        case nil: web
        case .bottom?: VStack(spacing: 6 * zoom) { web; HStack(spacing: 10 * zoom) { legendEntries } }
        case .top?, .topRight?:
            VStack(alignment: model.legend == .topRight ? .trailing : .center, spacing: 6 * zoom) {
                HStack(spacing: 10 * zoom) { legendEntries }
                web
            }
        case .left?: HStack(spacing: 8 * zoom) { VStack(alignment: .leading, spacing: 4 * zoom) { legendEntries }; web }
        case .right?: HStack(spacing: 8 * zoom) { web; VStack(alignment: .leading, spacing: 4 * zoom) { legendEntries } }
        }
    }

    private func color(_ index: Int) -> Color {
        Color(argbHex: chart.data.series[index].colorHex) ?? .accentColor
    }

    @ViewBuilder
    private var legendEntries: some View {
        ForEach(chart.data.series.indices, id: \.self) { index in
            HStack(spacing: 4 * zoom) {
                Circle().fill(color(index)).frame(width: 7 * zoom, height: 7 * zoom)
                Text(chart.data.series[index].name)
                    .font(chart.font(chart.legendStyle, defaultSize: 9))
                    .foregroundStyle(chart.textColor(chart.legendStyle))
            }
        }
    }

    private var scale: ChartAxisScale {
        ChartAxisScale.nice(chart.data.series.flatMap { $0.values.compactMap { $0 } }, axis: model.valueAxis)
    }

    private var web: some View {
        Canvas { context, size in
            let categories = chart.data.categories
            guard !categories.isEmpty else { return }
            let scale = scale
            let labelRoom = 22 * zoom
            let radius = max(10, min(size.width, size.height) / 2 - labelRoom)
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let direction: Double = model.categoryAxis.isReversed ? -1 : 1
            let step: Double = 2 * Double.pi / Double(categories.count)
            func angle(_ index: Int) -> Double {
                let turned: Double = direction * step * Double(index)
                return turned - Double.pi / 2
            }
            func point(_ index: Int, _ value: Double) -> CGPoint {
                let fraction: Double = min(max(scale.fraction(value), 0), 1.05)
                let distance: Double = radius * fraction
                let x: Double = center.x + cos(angle(index)) * distance
                let y: Double = center.y + sin(angle(index)) * distance
                return CGPoint(x: x, y: y)
            }
            func ring(_ value: Double) -> Path {
                Path { path in
                    for index in categories.indices {
                        if index == 0 { path.move(to: point(index, value)) } else { path.addLine(to: point(index, value)) }
                    }
                    path.closeSubpath()
                }
            }
            let grid = Color.secondary.opacity(0.35)
            if model.valueAxis.showsMajorGridlines {
                for tick in scale.ticks where tick > scale.minimum {
                    context.stroke(ring(tick), with: .color(grid), lineWidth: 0.5)
                }
            }
            if model.categoryAxis.isVisible {
                for index in categories.indices {
                    var spoke = Path()
                    spoke.move(to: center)
                    spoke.addLine(to: point(index, scale.maximum))
                    context.stroke(spoke, with: .color(grid), lineWidth: 0.5)
                    let style = chart.axisStyle(model.categoryAxis)
                    let at = CGPoint(
                        x: center.x + cos(angle(index)) * (radius + 6 * zoom),
                        y: center.y + sin(angle(index)) * (radius + 6 * zoom)
                    )
                    let anchor = UnitPoint(x: 0.5 - cos(angle(index)) / 2, y: 0.5 - sin(angle(index)) / 2)
                    context.draw(
                        Text(categories[index]).font(chart.font(style, defaultSize: 9))
                            .foregroundStyle(chart.textColor(style)),
                        at: at, anchor: anchor
                    )
                }
            }
            if model.valueAxis.isVisible {
                let style = chart.axisStyle(model.valueAxis)
                for tick in scale.ticks {
                    let at = point(0, tick)
                    context.draw(
                        Text(chart.formatValue(tick, axis: model.valueAxis)).font(chart.font(style, defaultSize: 8))
                            .foregroundStyle(chart.textColor(style)),
                        at: CGPoint(x: at.x + 3 * zoom, y: at.y), anchor: .leading
                    )
                }
            }

            for (seriesIndex, series) in chart.data.series.enumerated() {
                let entry = model.series.indices.contains(seriesIndex) ? model.series[seriesIndex] : ChartSeries()
                // A gap is drawn as the axis' minimum, as Excel draws it.
                func value(_ index: Int) -> Double {
                    guard series.values.indices.contains(index), let value = series.values[index] else {
                        return scale.minimum
                    }
                    return value
                }
                let corners: [CGPoint] = categories.indices.map { point($0, value($0)) }
                let shape = Path { path in
                    for (index, corner) in corners.enumerated() {
                        if index == 0 { path.move(to: corner) } else { path.addLine(to: corner) }
                    }
                    path.closeSubpath()
                }
                if model.radarStyle == .filled {
                    context.fill(shape, with: .color(color(seriesIndex).opacity(0.85)))
                } else if entry.showsLine {
                    context.stroke(shape, with: .color(color(seriesIndex)), lineWidth: (entry.lineWidth ?? 2.25) * zoom)
                }
                if entry.showsMarkers, model.radarStyle != .filled {
                    for corner in corners {
                        let dot = CGRect(x: corner.x - 3 * zoom, y: corner.y - 3 * zoom, width: 6 * zoom, height: 6 * zoom)
                        context.fill(Path(ellipseIn: dot), with: .color(color(seriesIndex)))
                    }
                }
                if series.dataLabels.showsValue {
                    for (index, corner) in corners.enumerated() {
                        guard series.values.indices.contains(index), let value = series.values[index] else { continue }
                        context.draw(
                            Text(chart.formatValue(value)).font(chart.font(chart.labelStyle, defaultSize: 9))
                                .foregroundStyle(chart.textColor(chart.labelStyle)),
                            at: CGPoint(x: corner.x, y: corner.y - 4 * zoom), anchor: .bottom
                        )
                    }
                }
            }
        }
    }
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
