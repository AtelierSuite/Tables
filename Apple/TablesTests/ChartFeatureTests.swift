import Foundation
import Testing
@testable import Tables
@testable import TablesEngine

/// The chart types and features beyond the basic seven: bubble, radar,
/// stock and combination charts with a second value axis, trendlines, error
/// bars, and 3-D charts read as their flat equivalent. Each is read from the
/// XML Excel writes, kept through a save untouched, and written afresh.
@Suite("Chart types and features")
struct ChartFeatureTests {

    // MARK: - Fixtures

    /// Five days: a label, then four columns of numbers.
    private static func workbook() -> Workbook {
        var sheet = Worksheet(name: "Data")
        let days = ["Mon", "Tue", "Wed", "Thu", "Fri"]
        let columns: [[Double]] = [
            [1, 2, 3, 4, 5],
            [3, 5, 7, 9, 11],
            [10, 20, 30, 40, 50],
            [12, 18, 9, 30, 21],
        ]
        for (row, day) in days.enumerated() {
            sheet[CellAddress(row: row + 1, column: 0)] = Cell(value: .text(day))
            for (column, values) in columns.enumerated() {
                sheet[CellAddress(row: row + 1, column: column + 1)] = Cell(value: .number(values[row]))
            }
        }
        return Workbook(sheets: [sheet])
    }

    private static func chartSpace(_ plotArea: String, chart extra: String = "") -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <c:chartSpace xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart" \
        xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
        <c:roundedCorners val="0"/><c:chart><c:autoTitleDeleted val="1"/>\(extra)\
        <c:plotArea><c:layout/>\(plotArea)</c:plotArea><c:legend><c:legendPos val="b"/></c:legend>\
        <c:plotVisOnly val="1"/></c:chart></c:chartSpace>
        """
    }

    private static func reference(_ kind: String, _ formula: String) -> String {
        kind == "str"
            ? "<c:strRef><c:f>\(formula)</c:f></c:strRef>"
            : "<c:numRef><c:f>\(formula)</c:f></c:numRef>"
    }

    private static func axes(category: Int = 1, value: Int = 2, categoryName: String = "catAx") -> String {
        """
        <c:\(categoryName)><c:axId val="\(category)"/><c:scaling><c:orientation val="minMax"/></c:scaling>\
        <c:delete val="0"/><c:axPos val="b"/><c:crossAx val="\(value)"/></c:\(categoryName)>\
        <c:valAx><c:axId val="\(value)"/><c:scaling><c:orientation val="minMax"/></c:scaling>\
        <c:delete val="0"/><c:axPos val="l"/><c:majorGridlines/><c:crossAx val="\(category)"/></c:valAx>
        """
    }

    private static let bubbleChart = chartSpace("""
    <c:bubbleChart><c:varyColors val="0"/>\
    <c:ser><c:idx val="0"/><c:order val="0"/><c:tx><c:v>Stores</c:v></c:tx>\
    <c:spPr><a:solidFill><a:srgbClr val="70AD47"><a:alpha val="75000"/></a:srgbClr></a:solidFill></c:spPr>\
    <c:invertIfNegative val="0"/>\
    <c:dLbls><c:showLegendKey val="0"/><c:showVal val="0"/><c:showCatName val="0"/><c:showSerName val="0"/>\
    <c:showPercent val="0"/><c:showBubbleSize val="1"/></c:dLbls>\
    <c:xVal>\(reference("num", "Data!$B$2:$B$6"))</c:xVal><c:yVal>\(reference("num", "Data!$C$2:$C$6"))</c:yVal>\
    <c:bubbleSize>\(reference("num", "Data!$D$2:$D$6"))</c:bubbleSize><c:bubble3D val="0"/></c:ser>\
    <c:bubbleScale val="80"/><c:showNegBubbles val="0"/><c:axId val="1"/><c:axId val="2"/></c:bubbleChart>\
    \(axes(categoryName: "valAx").replacingOccurrences(of: "<c:majorGridlines/>", with: ""))
    """)

    private static let radarChart = chartSpace("""
    <c:radarChart><c:radarStyle val="filled"/><c:varyColors val="0"/>\
    <c:ser><c:idx val="0"/><c:order val="0"/><c:tx><c:v>Week</c:v></c:tx>\
    <c:spPr><a:solidFill><a:srgbClr val="4472C4"/></a:solidFill></c:spPr>\
    <c:cat>\(reference("str", "Data!$A$2:$A$6"))</c:cat><c:val>\(reference("num", "Data!$E$2:$E$6"))</c:val></c:ser>\
    <c:axId val="1"/><c:axId val="2"/></c:radarChart>\(axes())
    """)

    /// Open, high, low, close, with high-low lines and up-down bars.
    private static let stockChart: String = {
        let series = ["B", "E", "B", "C"].enumerated().map { index, column in
            """
            <c:ser><c:idx val="\(index)"/><c:order val="\(index)"/>\
            <c:spPr><a:ln w="19050"><a:noFill/></a:ln></c:spPr><c:marker><c:symbol val="none"/></c:marker>\
            <c:cat>\(reference("str", "Data!$A$2:$A$6"))</c:cat>\
            <c:val>\(reference("num", "Data!$\(column)$2:$\(column)$6"))</c:val><c:smooth val="0"/></c:ser>
            """
        }.joined()
        return chartSpace("""
        <c:stockChart>\(series)<c:hiLowLines/><c:upDownBars><c:gapWidth val="100"/>\
        <c:upBars><c:spPr><a:solidFill><a:srgbClr val="00B050"/></a:solidFill></c:spPr></c:upBars>\
        <c:downBars><c:spPr><a:solidFill><a:srgbClr val="FF0000"/></a:solidFill></c:spPr></c:downBars>\
        </c:upDownBars><c:axId val="1"/><c:axId val="2"/></c:stockChart>\(axes())
        """)
    }()

    /// Columns on the main axis, a line on a second axis at the far side.
    private static let comboChart = chartSpace("""
    <c:barChart><c:barDir val="col"/><c:grouping val="clustered"/><c:varyColors val="0"/>\
    <c:ser><c:idx val="0"/><c:order val="0"/><c:tx><c:v>Visits</c:v></c:tx><c:invertIfNegative val="0"/>\
    <c:cat>\(reference("str", "Data!$A$2:$A$6"))</c:cat><c:val>\(reference("num", "Data!$C$2:$C$6"))</c:val></c:ser>\
    <c:gapWidth val="150"/><c:axId val="1"/><c:axId val="2"/></c:barChart>\
    <c:lineChart><c:grouping val="standard"/><c:varyColors val="0"/>\
    <c:ser><c:idx val="1"/><c:order val="1"/><c:tx><c:v>Revenue</c:v></c:tx>\
    <c:spPr><a:ln w="28575"><a:solidFill><a:srgbClr val="ED7D31"/></a:solidFill></a:ln></c:spPr>\
    <c:marker><c:symbol val="none"/></c:marker>\
    <c:cat>\(reference("str", "Data!$A$2:$A$6"))</c:cat><c:val>\(reference("num", "Data!$D$2:$D$6"))</c:val>\
    <c:smooth val="0"/></c:ser><c:marker val="1"/><c:axId val="3"/><c:axId val="4"/></c:lineChart>\
    \(axes())\
    <c:catAx><c:axId val="3"/><c:scaling><c:orientation val="minMax"/></c:scaling><c:delete val="1"/>\
    <c:axPos val="b"/><c:crossAx val="4"/></c:catAx>\
    <c:valAx><c:axId val="4"/><c:scaling><c:orientation val="minMax"/><c:max val="100"/></c:scaling>\
    <c:delete val="0"/><c:axPos val="r"/><c:numFmt formatCode="0&quot;k&quot;" sourceLinked="0"/>\
    <c:crossAx val="3"/><c:crosses val="max"/><c:crossBetween val="between"/></c:valAx>
    """)

    /// A scatter series with a trendline showing its equation and R², and
    /// error bars both ways.
    private static let trendChart = chartSpace("""
    <c:scatterChart><c:scatterStyle val="lineMarker"/><c:varyColors val="0"/>\
    <c:ser><c:idx val="0"/><c:order val="0"/><c:spPr><a:ln w="19050"><a:noFill/></a:ln></c:spPr>\
    <c:trendline><c:name>Fit</c:name><c:spPr><a:ln w="12700"><a:solidFill><a:srgbClr val="FF0000"/></a:solidFill>\
    <a:prstDash val="sysDot"/></a:ln></c:spPr><c:trendlineType val="linear"/><c:forward val="1"/>\
    <c:dispRSqr val="1"/><c:dispEq val="1"/><c:trendlineLbl><c:numFmt formatCode="General" sourceLinked="0"/>\
    </c:trendlineLbl></c:trendline>\
    <c:trendline><c:trendlineType val="poly"/><c:order val="3"/><c:dispRSqr val="0"/><c:dispEq val="0"/></c:trendline>\
    <c:errBars><c:errDir val="y"/><c:errBarType val="both"/><c:errValType val="percentage"/>\
    <c:noEndCap val="0"/><c:val val="10"/></c:errBars>\
    <c:errBars><c:errDir val="x"/><c:errBarType val="plus"/><c:errValType val="cust"/><c:noEndCap val="1"/>\
    <c:plus>\(reference("num", "Data!$B$2:$B$6"))</c:plus></c:errBars>\
    <c:xVal>\(reference("num", "Data!$B$2:$B$6"))</c:xVal><c:yVal>\(reference("num", "Data!$C$2:$C$6"))</c:yVal>\
    <c:smooth val="0"/></c:ser><c:axId val="1"/><c:axId val="2"/></c:scatterChart>\
    \(axes(categoryName: "valAx").replacingOccurrences(of: "<c:majorGridlines/>", with: ""))
    """)

    private static let column3DChart = chartSpace("""
    <c:bar3DChart><c:barDir val="col"/><c:grouping val="clustered"/><c:varyColors val="0"/>\
    <c:ser><c:idx val="0"/><c:order val="0"/><c:tx><c:v>Sales</c:v></c:tx><c:invertIfNegative val="0"/>\
    <c:cat>\(reference("str", "Data!$A$2:$A$6"))</c:cat><c:val>\(reference("num", "Data!$C$2:$C$6"))</c:val></c:ser>\
    <c:gapWidth val="150"/><c:shape val="box"/><c:axId val="1"/><c:axId val="2"/><c:axId val="0"/></c:bar3DChart>\
    \(axes())
    """, chart: """
    <c:view3D><c:rotX val="15"/><c:rotY val="20"/><c:rAngAx val="1"/></c:view3D>\
    <c:floor><c:thickness val="0"/></c:floor>
    """)

    private func read(_ xml: String, in workbook: Workbook) throws -> Chart {
        let root = try XMLLite.parse(Data(xml.utf8))
        return try #require(ChartReader.chart(from: root, context: .init(workbook: workbook, theme: .office)))
    }

    /// The chart as saved when it came from `xml`: patched into that XML,
    /// with whatever was edited since it was read.
    private func patched(
        _ chart: Chart, from xml: String, in workbook: Workbook, read baseline: Chart? = nil
    ) throws -> String {
        var edited = chart
        edited.original = ChartOriginal(
            xml: Data(xml.utf8), baseline: baseline ?? chart, companions: [], frameProperties: nil, clientData: nil
        )
        // Saved through the patch, not rebuilt.
        #expect(ChartPatcher.patch(try #require(edited.original), to: edited, workbook: workbook) != nil)
        return ChartWriter.chartSpace(edited, workbook: workbook)
    }

    // MARK: - Bubble

    @Test("A bubble chart reads its sizes, scale and size labels, and keeps them through a save")
    func bubble() throws {
        let workbook = Self.workbook()
        let chart = try read(Self.bubbleChart, in: workbook)
        #expect(chart.kind == .bubble)
        #expect(chart.bubbleScale == 80)
        #expect(chart.dataLabels.showsBubbleSize)
        #expect(chart.series.count == 1)
        #expect(chart.series[0].bubbleSizes.reference?.range == CellRange(a1Range: "D2:D6"))
        let resolved = chart.resolved(in: workbook)
        #expect(resolved.series[0].sizes == [10, 20, 30, 40, 50])
        #expect(resolved.series[0].xValues == [1, 2, 3, 4, 5])

        // Untouched, the sizes and scale stay as they were.
        let saved = try patched(chart, from: Self.bubbleChart, in: workbook)
        #expect(saved.contains("<c:bubbleScale val=\"80\"/>"))
        #expect(saved.contains("Data!$D$2:$D$6"))

        // Written afresh, it reads back the same.
        let fresh = ChartWriter.freshChartSpace(chart, workbook: workbook)
        let order = ["<c:xVal>", "<c:yVal>", "<c:bubbleSize>", "<c:bubble3D"].compactMap { fresh.range(of: $0)?.lowerBound }
        #expect(order.count == 4 && order == order.sorted())
        let reread = try read(fresh, in: workbook)
        #expect(reread.kind == .bubble)
        #expect(reread.bubbleScale == 80)
        #expect(reread.dataLabels.showsBubbleSize)
        #expect(reread.resolved(in: workbook) == resolved)
    }

    @Test("Bubbles are made from a selection: each Y column with the sizes beside it")
    func bubbleFromSelection() throws {
        var sheet = Self.workbook().sheets[0]
        sheet[CellAddress(row: 0, column: 1)] = Cell(value: .text("X"))
        sheet[CellAddress(row: 0, column: 2)] = Cell(value: .text("Y"))
        sheet[CellAddress(row: 0, column: 3)] = Cell(value: .text("Size"))
        let range = try #require(CellRange(a1Range: "B1:D6"))
        let chart = try #require(ChartBuilder.chart(.bubble, from: range, in: sheet, named: "Chart 1"))
        #expect(chart.series.count == 1)
        #expect(chart.series[0].categories.reference?.range == CellRange(a1Range: "B2:B6"))
        #expect(chart.series[0].values.reference?.range == CellRange(a1Range: "C2:C6"))
        #expect(chart.series[0].bubbleSizes.reference?.range == CellRange(a1Range: "D2:D6"))
    }

    // MARK: - Radar

    @Test("A filled radar chart reads its style and writes it back")
    func radar() throws {
        let workbook = Self.workbook()
        let chart = try read(Self.radarChart, in: workbook)
        #expect(chart.kind == .radar)
        #expect(chart.radarStyle == .filled)
        #expect(chart.series[0].colorHex == "FF4472C4")
        #expect(chart.resolved(in: workbook).series[0].values == [12, 18, 9, 30, 21])

        var edited = chart
        edited.series[0].colorHex = "FFFF0000"
        let saved = try patched(edited, from: Self.radarChart, in: workbook, read: chart)
        #expect(saved.contains("<c:radarStyle val=\"filled\"/>"))
        #expect(try read(saved, in: workbook).series[0].colorHex == "FFFF0000")

        let fresh = try read(ChartWriter.freshChartSpace(chart, workbook: workbook), in: workbook)
        #expect(fresh.kind == .radar)
        #expect(fresh.radarStyle == .filled)
        #expect(fresh.series[0].colorHex == "FF4472C4")
    }

    // MARK: - Stock

    @Test("A stock chart reads its four series, high-low lines and up-down bars")
    func stock() throws {
        let workbook = Self.workbook()
        let chart = try read(Self.stockChart, in: workbook)
        #expect(chart.kind == .stock)
        #expect(chart.series.count == 4)
        #expect(chart.hasHighLowLines)
        #expect(chart.upDownBars == ChartUpDownBars(gapWidth: 100, upColorHex: "FF00B050", downColorHex: "FFFF0000"))
        #expect(chart.series.allSatisfy { !$0.showsLine && !$0.showsMarkers })

        let fresh = ChartWriter.freshChartSpace(chart, workbook: workbook)
        let reread = try read(fresh, in: workbook)
        #expect(reread.kind == .stock)
        #expect(reread.hasHighLowLines)
        #expect(reread.upDownBars == chart.upDownBars)
        #expect(reread.resolved(in: workbook) == chart.resolved(in: workbook))
    }

    // MARK: - Combinations

    @Test("Columns with a line on a second axis read as one chart with two value axes")
    func combination() throws {
        let workbook = Self.workbook()
        let chart = try read(Self.comboChart, in: workbook)
        #expect(chart.kind == .column)
        #expect(chart.series.map(\.plotKind) == [nil, .line])
        #expect(chart.series.map(\.usesSecondaryAxis) == [false, true])
        #expect(chart.secondaryValueAxis?.maximum == 100)
        #expect(chart.secondaryValueAxis?.numberFormat == "0\"k\"")
        #expect(chart.series[1].colorHex == "FFED7D31")
        let resolved = chart.resolved(in: workbook)
        #expect(resolved.series.map(\.kind) == [.column, .line])
        #expect(resolved.series.map(\.usesSecondaryAxis) == [false, true])

        // An edit keeps both plots and both pairs of axes where they were.
        var edited = chart
        edited.title = ChartTitle(text: "Visits and revenue")
        edited.secondaryValueAxis?.maximum = 60
        let saved = try patched(edited, from: Self.comboChart, in: workbook, read: chart)
        #expect(saved.contains("<c:lineChart>"))
        #expect(saved.contains("<c:crosses val=\"max\"/>"))
        let reread = try read(saved, in: workbook)
        #expect(reread.title?.text == "Visits and revenue")
        #expect(reread.secondaryValueAxis?.maximum == 60)
        #expect(reread.series.map(\.plotKind) == [nil, .line])

        // Written afresh, it is still a combination.
        let fresh = try read(ChartWriter.freshChartSpace(chart, workbook: workbook), in: workbook)
        #expect(fresh.kind == .column)
        #expect(fresh.series.map(\.plotKind) == [nil, .line])
        #expect(fresh.series.map(\.usesSecondaryAxis) == [false, true])
        #expect(fresh.secondaryValueAxis?.maximum == 100)
        #expect(fresh.resolved(in: workbook) == resolved)
    }

    @Test("Moving a series to another plot rebuilds the chart rather than patching it")
    func changingPlotsRebuilds() throws {
        let workbook = Self.workbook()
        var chart = try read(Self.comboChart, in: workbook)
        let read = chart
        chart.series[1].plotKind = nil
        chart.series[1].usesSecondaryAxis = false
        chart.original = ChartOriginal(
            xml: Data(Self.comboChart.utf8), baseline: read, companions: [], frameProperties: nil, clientData: nil
        )
        #expect(ChartPatcher.patch(try #require(chart.original), to: chart, workbook: workbook) == nil)
        let rebuilt = try self.read(ChartWriter.chartSpace(chart, workbook: workbook), in: workbook)
        #expect(rebuilt.series.allSatisfy { $0.plotKind == nil && !$0.usesSecondaryAxis })
    }

    // MARK: - Trendlines and error bars

    @Test("Trendlines and error bars read, draw their numbers, and write back")
    func trendlinesAndErrorBars() throws {
        let workbook = Self.workbook()
        let chart = try read(Self.trendChart, in: workbook)
        let series = try #require(chart.series.first)
        #expect(series.trendlines.count == 2)
        #expect(series.trendlines[0].kind == .linear)
        #expect(series.trendlines[0].name == "Fit")
        #expect(series.trendlines[0].forward == 1)
        #expect(series.trendlines[0].showsEquation && series.trendlines[0].showsRSquared)
        #expect(series.trendlines[0].colorHex == "FFFF0000")
        #expect(series.trendlines[1].kind == .polynomial && series.trendlines[1].order == 3)
        #expect(series.errorBars.count == 2)
        #expect(series.errorBars[0].direction == .y && series.errorBars[0].amount == .percentage)
        #expect(series.errorBars[1].direction == .x && series.errorBars[1].side == .plus)
        #expect(!series.errorBars[1].hasEndCaps)
        #expect(series.errorBars[1].plus.reference?.range == CellRange(a1Range: "B2:B6"))

        let resolved = chart.resolved(in: workbook).series[0]
        // y = 2x + 1 exactly, carried one unit past the last point.
        #expect(resolved.trendlines[0].label == "y = 2x + 1\nR² = 1")
        let ends = try #require(resolved.trendlines[0].points.first.flatMap { first in
            resolved.trendlines[0].points.last.map { (first, $0) }
        })
        #expect(ends.0.x == 1 && abs(ends.0.y - 3) < 1e-9)
        #expect(ends.1.x == 6 && abs(ends.1.y - 13) < 1e-9)
        #expect(resolved.errorBars[0].bars[0] == .init(index: 0, low: 2.7, high: 3.3))
        #expect(resolved.errorBars[1].bars[4] == .init(index: 4, low: 5, high: 10))

        // Kept untouched, including the label formatting we do not model.
        let saved = try patched(chart, from: Self.trendChart, in: workbook)
        #expect(saved.contains("<c:trendlineLbl>"))
        #expect(saved.contains("<c:errValType val=\"cust\"/>"))

        let reread = try read(ChartWriter.freshChartSpace(chart, workbook: workbook), in: workbook)
        #expect(reread.series[0].trendlines == series.trendlines)
        #expect(reread.series[0].errorBars.map(\.amount) == [.percentage, .custom])
        #expect(reread.series[0].errorBars[1].plus.reference == series.errorBars[1].plus.reference)
        #expect(reread.resolved(in: workbook) == chart.resolved(in: workbook))
    }

    /// Points that lie exactly on a curve of each kind, for x from 1 to 5,
    /// with the equation Excel labels it with.
    private static let curves: [(ChartTrendline.Kind, [Double], String)] = {
        let xs: [Double] = [1, 2, 3, 4, 5]
        let square: [Double] = xs.map { $0 * $0 }
        let growth: [Double] = xs.map { 2 * exp(0.5 * $0) }
        let power: [Double] = xs.map { 3 * $0 * $0 }
        let logarithm: [Double] = xs.map { 2 * log($0) + 1 }
        return [
            (.polynomial, square, "y = x²"),
            (.exponential, growth, "y = 2e^(0.5x)"),
            (.power, power, "y = 3x^2"),
            (.logarithmic, logarithm, "y = 2ln(x) + 1"),
        ]
    }()

    @Test("Trendlines fit as Excel fits them", arguments: Self.curves)
    func fits(kind: ChartTrendline.Kind, y: [Double], equation: String) throws {
        let fit = try #require(ChartTrendline(kind: kind).fit(x: [1, 2, 3, 4, 5], y: y))
        #expect(fit.equation == equation)
        #expect(abs(fit.rSquared - 1) < 1e-9)
    }

    @Test("A moving average, and the bars of a standard deviation")
    func movingAverageAndDeviation() {
        var average = ChartTrendline(kind: .movingAverage)
        average.period = 2
        #expect(average.movingAverage(x: [1, 2, 3, 4], y: [1, 3, 5, 7]).map(\.y) == [2, 4, 6])

        let deviation = ChartErrorBars(amount: .standardDeviation, value: 1)
        // Sample deviation of 2, 4, 6 is 2; the bars straddle the mean.
        #expect(deviation.bars(for: [2, 4, 6]).map { [$0.low, $0.high] } == [[2, 6], [2, 6], [2, 6]])
        let fixed = ChartErrorBars(side: .minus, amount: .fixed, value: 1)
        #expect(fixed.bars(for: [2, nil]).map { [$0.low, $0.high] } == [[1, 2]])
    }

    @Test("Axis scales round to tidy steps, and a second axis can match the first's")
    func axisScales() {
        let scale = ChartAxisScale.nice([3, 37])
        #expect(scale == ChartAxisScale(minimum: 0, maximum: 40, majorUnit: 10))
        let matched = ChartAxisScale.nice([12, 370], intervals: 4)
        #expect(matched == ChartAxisScale(minimum: 0, maximum: 400, majorUnit: 100))
        #expect(matched.ticks.count == 5)
    }

    // MARK: - 3-D

    @Test("A 3-D column chart reads as columns and is saved still in 3-D")
    func threeD() throws {
        let workbook = Self.workbook()
        let chart = try read(Self.column3DChart, in: workbook)
        #expect(chart.kind == .column)
        #expect(chart.is3D)
        #expect(chart.series.count == 1)

        var edited = chart
        edited.title = ChartTitle(text: "Flat")
        edited.series[0].colorHex = "FF00B0F0"
        let saved = try patched(edited, from: Self.column3DChart, in: workbook, read: chart)
        #expect(saved.contains("<c:bar3DChart>"))
        #expect(saved.contains("<c:view3D>"))
        #expect(saved.contains("<c:axId val=\"0\"/>"))
        let reread = try read(saved, in: workbook)
        #expect(reread.is3D)
        #expect(reread.title?.text == "Flat")
        #expect(reread.series[0].colorHex == "FF00B0F0")
    }

    // MARK: - Still kept whole

    @Test("Charts still outside the model are left for the file to keep", arguments: [
        // A surface, which has no flat equivalent we draw.
        "<c:surfaceChart><c:wireframe val=\"0\"/><c:axId val=\"1\"/><c:axId val=\"2\"/><c:axId val=\"3\"/></c:surfaceChart>",
        // A pie of pie.
        "<c:ofPieChart><c:ofPieType val=\"pie\"/><c:varyColors val=\"1\"/></c:ofPieChart>",
        // A pie sharing the plot with columns: not a combination Excel makes.
        "<c:pieChart><c:varyColors val=\"1\"/><c:ser><c:idx val=\"0\"/><c:order val=\"0\"/></c:ser></c:pieChart>"
            + "<c:barChart><c:barDir val=\"col\"/><c:grouping val=\"clustered\"/><c:ser><c:idx val=\"1\"/>"
            + "<c:order val=\"1\"/></c:ser><c:axId val=\"1\"/><c:axId val=\"2\"/></c:barChart>",
    ])
    func unsupportedStaysOut(plot: String) throws {
        let xml = Self.chartSpace(plot + Self.axes())
        let root = try XMLLite.parse(Data(xml.utf8))
        #expect(ChartReader.chart(from: root, context: .init(workbook: Self.workbook(), theme: .office)) == nil)
    }
}
