import Foundation

/// A chart, modelled on the part of DrawingML charts that Excel's own chart
/// gallery produces: one plot of one type, a category axis and a value axis,
/// a title, a legend, and series drawn from ranges of cells.
///
/// Beyond that it holds bubble, radar and stock plots, combinations of
/// column, line, area and stock plots with a second value axis, and the
/// trendlines and error bars a series carries. 3-D charts are read as the
/// 2-D chart of the same type.
///
/// Anything richer — surfaces, pie-of-pie, Excel 2016's waterfall and its
/// kin — is not modelled at all. The reader leaves those charts as preserved
/// drawing anchors instead, so a file is never saved with a chart that has
/// been quietly simplified.
public struct Chart: Identifiable, Hashable, Sendable {
    public var id = UUID()
    /// What Excel's selection pane calls the chart: "Chart 1".
    public var name: String
    public var kind: ChartKind
    public var grouping: ChartGrouping = .standard
    public var series: [ChartSeries] = []

    /// An explicit title. `nil` leaves the choice to `showsAutomaticTitle`.
    public var title: ChartTitle?
    /// Excel titles a single-series chart with the series name unless told
    /// not to (`autoTitleDeleted`), so the absence of a title is not the same
    /// thing as no title.
    public var showsAutomaticTitle = false

    /// The horizontal axis of a column, line or area chart, the vertical one
    /// of a bar chart, and the X axis of a scatter chart.
    public var categoryAxis = ChartAxis()
    /// The axis the values are measured along — the Y axis of a scatter chart.
    public var valueAxis = ChartAxis(showsMajorGridlines: true)
    /// The value axis on the far side of a combination chart, which the
    /// series marked `usesSecondaryAxis` are measured along. `nil` when the
    /// chart has only the one.
    public var secondaryValueAxis: ChartAxis?

    /// `nil` hides the legend.
    public var legend: ChartLegendPosition? = .bottom
    public var dataLabels = ChartDataLabels()
    /// The chart-wide text properties every label inherits.
    public var textStyle = ChartTextStyle()
    public var legendTextStyle = ChartTextStyle()

    /// One colour per point rather than per series. Pie charts default to it;
    /// it means nothing once a chart has more than one series.
    public var variesColors = false
    /// Excel's default: rows and columns the user hid drop out of the plot.
    public var plotsVisibleCellsOnly = true
    /// The space between clusters, as a percentage of a bar's width.
    public var gapWidth: Int?
    /// How far bars in a cluster overlap, from -100 to 100.
    public var overlap: Int?
    /// The doughnut's hole, as a percentage of its diameter.
    public var holeSize = 50
    public var firstSliceAngle = 0
    /// How a radar chart draws its series: as lines, lines with markers, or
    /// filled shapes.
    public var radarStyle: ChartRadarStyle = .standard
    /// The largest bubble's size, as a percentage of Excel's default.
    public var bubbleScale = 100
    /// Whether a bubble's value is its width rather than its area.
    public var bubbleSizeIsWidth = false
    /// The line a stock chart draws from each day's low to its high.
    public var hasHighLowLines = false
    /// The bars a stock chart draws from open to close. `nil` when it has none.
    public var upDownBars: ChartUpDownBars?
    /// The file draws the chart in 3-D. It is drawn here as its 2-D
    /// equivalent, and saved as the 3-D chart it was.
    public var is3D = false

    /// The chart area's fill. `nil` is Excel's default white paper.
    public var backgroundColorHex: String?
    public var hasBorder = true
    /// The schema's default when the element is absent is *rounded*, which is
    /// why charts from other generators often show soft corners in Excel.
    public var hasRoundedCorners = false

    /// Where the chart sits on its worksheet. Ignored on a chart sheet, which
    /// the chart fills.
    public var placement = ChartPlacement()

    /// The description screen readers announce: Excel's Alt Text.
    public var altText: String?

    /// The chart as the file had it, when it came from one. Saving edits that
    /// XML rather than writing the chart afresh, so everything the model does
    /// not hold — gradients, marker shapes, manual layouts, label positions —
    /// survives a round trip untouched.
    public var original: ChartOriginal?

    public init(name: String, kind: ChartKind) {
        self.name = name
        self.kind = kind
    }
}

public enum ChartKind: String, CaseIterable, Hashable, Sendable {
    case column
    case bar
    case line
    case area
    case pie
    case doughnut
    case scatter
    case bubble
    case radar
    case stock

    /// The kinds a chart can be made as, or changed to, from a block of
    /// cells. Stock charts need their series in a set order, so they are read
    /// and drawn but not offered.
    public static let creatable: [ChartKind] = [.column, .bar, .line, .area, .pie, .doughnut, .scatter, .bubble, .radar]

    public var label: String {
        switch self {
        case .column: return String(localized: "Chart.Kind.Column", bundle: .engine)
        case .bar: return String(localized: "Chart.Kind.Bar", bundle: .engine)
        case .line: return String(localized: "Chart.Kind.Line", bundle: .engine)
        case .area: return String(localized: "Chart.Kind.Area", bundle: .engine)
        case .pie: return String(localized: "Chart.Kind.Pie", bundle: .engine)
        case .doughnut: return String(localized: "Chart.Kind.Doughnut", bundle: .engine)
        case .scatter: return String(localized: "Chart.Kind.Scatter", bundle: .engine)
        case .bubble: return String(localized: "Chart.Kind.Bubble", bundle: .engine)
        case .radar: return String(localized: "Chart.Kind.Radar", bundle: .engine)
        case .stock: return String(localized: "Chart.Kind.Stock", bundle: .engine)
        }
    }

    public var symbolName: String {
        switch self {
        case .column: return "chart.bar.xaxis"
        case .bar: return "chart.bar.horizontal.page"
        case .line: return "chart.xyaxis.line"
        case .area: return "chart.line.uptrend.xyaxis"
        case .pie: return "chart.pie"
        case .doughnut: return "circle.circle"
        case .scatter: return "chart.dots.scatter"
        case .bubble: return "circle.grid.cross"
        case .radar: return "hexagon"
        case .stock: return "chart.bar.doc.horizontal"
        }
    }

    /// Pie and doughnut charts have no axes and plot only their first series.
    public var isRadial: Bool { self == .pie || self == .doughnut }

    /// Whether the chart can stack its series, and so has a grouping to pick.
    public var supportsGrouping: Bool {
        switch self {
        case .column, .bar, .line, .area: return true
        case .pie, .doughnut, .scatter, .bubble, .radar, .stock: return false
        }
    }

    /// Scatter and bubble charts plot numbers against numbers: their series
    /// carry X values where the others carry categories.
    public var plotsXY: Bool { self == .scatter || self == .bubble }

    /// Drawn as a line through its points, so coloured by its line.
    public var drawsLines: Bool { self == .line || self == .scatter || self == .radar || self == .stock }

    /// Whether a series of this kind can carry trendlines and error bars.
    public var takesTrendlines: Bool {
        switch self {
        case .column, .bar, .line, .area, .scatter, .bubble: return true
        case .pie, .doughnut, .radar, .stock: return false
        }
    }

    /// The kinds that can share a plot area in a combination chart.
    public var combines: Bool {
        switch self {
        case .column, .line, .area, .stock: return true
        case .bar, .pie, .doughnut, .scatter, .bubble, .radar: return false
        }
    }
}

public enum ChartRadarStyle: String, CaseIterable, Hashable, Sendable {
    case standard
    case marker
    case filled
}

/// A stock chart's open-to-close bars. The file's defaults are a white bar
/// for a day that closed up and a black one for a day that closed down.
public struct ChartUpDownBars: Hashable, Sendable {
    /// The space between bars, as a percentage of a bar's width.
    public var gapWidth = 150
    public var upColorHex: String?
    public var downColorHex: String?

    public init(gapWidth: Int = 150, upColorHex: String? = nil, downColorHex: String? = nil) {
        self.gapWidth = gapWidth
        self.upColorHex = upColorHex
        self.downColorHex = downColorHex
    }
}

/// How the series of a column, bar, line or area chart share the plot.
///
/// For column and bar charts `.standard` is what the file calls `clustered`;
/// the file's own `standard` exists only for 3-D bars, which are not modelled.
public enum ChartGrouping: String, CaseIterable, Hashable, Sendable {
    case standard
    case stacked
    case percentStacked

    public var label: String {
        switch self {
        case .standard: return String(localized: "Chart.Grouping.Standard", bundle: .engine)
        case .stacked: return String(localized: "Chart.Grouping.Stacked", bundle: .engine)
        case .percentStacked: return String(localized: "Chart.Grouping.PercentStacked", bundle: .engine)
        }
    }
}

public enum ChartLegendPosition: String, CaseIterable, Hashable, Sendable {
    case right = "r"
    case left = "l"
    case top = "t"
    case bottom = "b"
    case topRight = "tr"

    public var label: String {
        switch self {
        case .right: return String(localized: "Chart.Legend.Right", bundle: .engine)
        case .left: return String(localized: "Chart.Legend.Left", bundle: .engine)
        case .top: return String(localized: "Chart.Legend.Top", bundle: .engine)
        case .bottom: return String(localized: "Chart.Legend.Bottom", bundle: .engine)
        case .topRight: return String(localized: "Chart.Legend.TopRight", bundle: .engine)
        }
    }
}

/// Font properties a chart label can carry. Every field is optional because
/// DrawingML text inherits: a label that names no size takes the chart's.
public struct ChartTextStyle: Hashable, Sendable {
    /// In points.
    public var fontSize: Double?
    public var isBold: Bool?
    public var isItalic: Bool?
    /// "AARRGGBB", like `CellStyle`'s colours.
    public var colorHex: String?
    public var fontName: String?

    public init(
        fontSize: Double? = nil,
        isBold: Bool? = nil,
        isItalic: Bool? = nil,
        colorHex: String? = nil,
        fontName: String? = nil
    ) {
        self.fontSize = fontSize
        self.isBold = isBold
        self.isItalic = isItalic
        self.colorHex = colorHex
        self.fontName = fontName
    }

    public var isEmpty: Bool { self == ChartTextStyle() }

    /// This style with anything it leaves unsaid taken from `parent`.
    public func inheriting(from parent: ChartTextStyle) -> ChartTextStyle {
        ChartTextStyle(
            fontSize: fontSize ?? parent.fontSize,
            isBold: isBold ?? parent.isBold,
            isItalic: isItalic ?? parent.isItalic,
            colorHex: colorHex ?? parent.colorHex,
            fontName: fontName ?? parent.fontName
        )
    }
}

public struct ChartTitle: Hashable, Sendable {
    public var text: String
    /// A title that reads its text from a cell, as `=Sheet1!$A$1` in Excel's
    /// title box makes. `text` then holds the value last read from it.
    public var reference: ChartReference?
    public var textStyle = ChartTextStyle()

    public init(text: String, reference: ChartReference? = nil, textStyle: ChartTextStyle = ChartTextStyle()) {
        self.text = text
        self.reference = reference
        self.textStyle = textStyle
    }
}

public struct ChartAxis: Hashable, Sendable {
    /// Excel "deletes" an axis it is not showing; the scale still applies.
    public var isVisible = true
    public var title: ChartTitle?
    public var showsMajorGridlines = false
    public var minimum: Double?
    public var maximum: Double?
    public var majorUnit: Double?
    /// A number format for the tick labels. `nil` follows the source cells.
    public var numberFormat: String?
    /// Values run from the far end: `maxMin` orientation.
    public var isReversed = false
    /// Category axes over dates are date axes in the file, which space their
    /// points by time rather than evenly.
    public var isDateAxis = false
    public var textStyle = ChartTextStyle()

    public init(showsMajorGridlines: Bool = false) {
        self.showsMajorGridlines = showsMajorGridlines
    }
}

public struct ChartDataLabels: Hashable, Sendable {
    public var showsValue = false
    public var showsPercentage = false
    public var showsCategoryName = false
    public var showsSeriesName = false

    /// A bubble's size, on a bubble chart.
    public var showsBubbleSize = false

    public var isVisible: Bool {
        showsValue || showsPercentage || showsCategoryName || showsSeriesName || showsBubbleSize
    }
}

/// A trendline fitted to a series.
public struct ChartTrendline: Hashable, Sendable {
    public enum Kind: String, CaseIterable, Hashable, Sendable {
        case linear
        case exponential = "exp"
        case logarithmic = "log"
        case polynomial = "poly"
        case power
        case movingAverage = "movingAvg"
    }

    public var kind: Kind = .linear
    /// The name its legend entry carries, when the author gave it one.
    public var name: String?
    /// A polynomial's order, from 2 to 6.
    public var order = 2
    /// How many points a moving average runs over.
    public var period = 2
    /// How far past the data the line is carried, in the X axis' units.
    public var forward = 0.0
    public var backward = 0.0
    /// Where the line is made to cross the value axis. `nil` leaves it free.
    public var intercept: Double?
    public var showsEquation = false
    public var showsRSquared = false
    /// "AARRGGBB". `nil` takes the colour of its series.
    public var colorHex: String?
    /// Line width in points, when the file named one.
    public var lineWidth: Double?

    public init(kind: Kind = .linear) {
        self.kind = kind
    }
}

/// The error bars on a series, in one direction.
public struct ChartErrorBars: Hashable, Sendable {
    public enum Direction: String, Hashable, Sendable {
        case x
        case y
    }

    public enum Side: String, Hashable, Sendable {
        case both
        case plus
        case minus
    }

    public enum Amount: String, Hashable, Sendable {
        case fixed = "fixedVal"
        case percentage
        case standardDeviation = "stdDev"
        case standardError = "stdErr"
        case custom = "cust"
    }

    public var direction: Direction = .y
    public var side: Side = .both
    public var amount: Amount = .fixed
    /// The fixed value, the percentage, or the number of deviations.
    public var value = 0.0
    public var hasEndCaps = true
    /// The amounts of custom bars, one per point or one for all of them.
    public var plus = ChartSource()
    public var minus = ChartSource()
    public var colorHex: String?

    public init(direction: Direction = .y, side: Side = .both, amount: Amount = .fixed, value: Double = 0) {
        self.direction = direction
        self.side = side
        self.amount = amount
        self.value = value
    }
}

public struct ChartSeries: Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var name = ChartSource()
    /// Category labels, or the X values of a scatter series.
    public var categories = ChartSource()
    public var values = ChartSource()
    /// "AARRGGBB". `nil` takes the theme's accent for the series' position.
    public var colorHex: String?
    /// Per-point overrides, keyed by point index — chiefly pie slices.
    public var pointColors: [Int: String] = [:]
    /// Line and scatter series only.
    public var showsLine = true
    public var showsMarkers = true
    public var isSmooth = false
    /// Line width in points, when the file named one.
    public var lineWidth: Double?
    /// The size of each bubble, on a bubble chart.
    public var bubbleSizes = ChartSource()
    /// The plot this series is drawn as in a combination chart, when it is
    /// not the chart's own kind.
    public var plotKind: ChartKind?
    /// Measured along the chart's second value axis.
    public var usesSecondaryAxis = false
    /// Labels that differ from the chart's. `nil` follows the chart.
    public var dataLabels: ChartDataLabels?
    public var trendlines: [ChartTrendline] = []
    public var errorBars: [ChartErrorBars] = []

    public init(
        id: UUID = UUID(),
        name: ChartSource = ChartSource(),
        categories: ChartSource = ChartSource(),
        values: ChartSource = ChartSource(),
        colorHex: String? = nil,
        pointColors: [Int: String] = [:],
        showsLine: Bool = true,
        showsMarkers: Bool = true,
        isSmooth: Bool = false,
        lineWidth: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.categories = categories
        self.values = values
        self.colorHex = colorHex
        self.pointColors = pointColors
        self.showsLine = showsLine
        self.showsMarkers = showsMarkers
        self.isSmooth = isSmooth
        self.lineWidth = lineWidth
    }
}

extension ChartSeries {
    /// What the series is drawn as in `chart`: its own plot in a combination
    /// chart, the chart's kind otherwise.
    public func kind(in chart: Chart) -> ChartKind { plotKind ?? chart.kind }
}

/// Where one dimension of a series — its name, categories or values — comes
/// from, in the three shapes the file allows.
public struct ChartSource: Hashable, Sendable {
    /// A range of cells the chart follows live.
    public var reference: ChartReference?
    /// A formula we cannot follow — a defined name, another workbook, a union
    /// of ranges — written back to the file exactly as it came.
    public var formula: String?
    /// Literal values, or the values cached with a reference. What the chart
    /// shows when there is nothing live to read.
    public var cache: [CellValue] = []
    /// The number format Excel stored with a numeric cache.
    public var cacheFormat: String?

    public init(reference: ChartReference? = nil, formula: String? = nil, cache: [CellValue] = []) {
        self.reference = reference
        self.formula = formula
        self.cache = cache
    }

    public var isEmpty: Bool { reference == nil && formula == nil && cache.isEmpty }

    public static func text(_ value: String) -> ChartSource { ChartSource(cache: [.text(value)]) }
}

/// A rectangular block of cells on a named sheet. The sheet is held by
/// identity, not name, so renaming it does not break the chart and the
/// reference is rebuilt with the current name whenever the file is written.
public struct ChartReference: Hashable, Sendable {
    public var sheetID: Worksheet.ID
    public var range: CellRange

    public init(sheetID: Worksheet.ID, range: CellRange) {
        self.sheetID = sheetID
        self.range = range.normalized
    }
}

/// A point on the sheet: a cell, and an offset into it in points.
public struct ChartAnchor: Hashable, Sendable {
    public var row: Int
    public var column: Int
    public var rowOffset: Double = 0
    public var columnOffset: Double = 0
}

/// Where an embedded chart sits, as the two corners Excel's `twoCellAnchor`
/// pins it by, so that it moves and stretches with the cells beneath it.
public struct ChartPlacement: Hashable, Sendable {
    public var from = ChartAnchor(row: 1, column: 1)
    public var to = ChartAnchor(row: 16, column: 7)
    /// Excel's `editAs`: whether the chart moves and sizes with its cells.
    /// Carried through rather than modelled.
    public var editAs: String?
}

/// A chart part as it was read, with what the reader made of it.
///
/// Immutable and shared between copies of a chart: what a copy has changed is
/// found by comparing it with `baseline`, and only that is written into the
/// original XML.
public final class ChartOriginal: Hashable, Sendable {
    /// The chart part's bytes.
    public let xml: Data
    /// The model the reader built from `xml`, without its own `original`.
    public let baseline: Chart
    /// The style and colour parts Excel keeps beside a chart.
    public let companions: [ChartCompanion]
    /// The anchor's `nvGraphicFramePr` — name, alt text, locks — as written.
    public let frameProperties: String?
    /// The anchor's `clientData`, which says whether the chart prints.
    public let clientData: String?

    public init(xml: Data, baseline: Chart, companions: [ChartCompanion], frameProperties: String?, clientData: String?) {
        var baseline = baseline
        baseline.original = nil
        self.xml = xml
        self.baseline = baseline
        self.companions = companions
        self.frameProperties = frameProperties
        self.clientData = clientData
    }

    public static func == (lhs: ChartOriginal, rhs: ChartOriginal) -> Bool { lhs === rhs }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

/// A part a chart relates to that we carry through untouched: its chart
/// style, its colour style, or shapes drawn over it that draw nothing.
public struct ChartCompanion: Hashable, Sendable {
    public var relationshipType: String
    public var data: Data
    /// The id the chart part names it by. The chart's XML says
    /// `<c:userShapes r:id="…"/>`, so that one has to be written back as read.
    public var relationshipID: String?

    public static let styleType = "http://schemas.microsoft.com/office/2011/relationships/chartStyle"
    public static let colorsType = "http://schemas.microsoft.com/office/2011/relationships/chartColorStyle"
    public static let userShapesType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/chartUserShapes"

    /// Where the part goes in the package, less its number, and its content
    /// type, which its type fixes.
    public var stem: String {
        switch relationshipType {
        case Self.styleType: "xl/charts/style"
        case Self.userShapesType: "xl/drawings/drawing"
        default: "xl/charts/colors"
        }
    }
    public var contentType: String {
        switch relationshipType {
        case Self.styleType: "application/vnd.ms-office.chartstyle+xml"
        case Self.userShapesType: "application/vnd.openxmlformats-officedocument.drawingml.chartshapes+xml"
        default: "application/vnd.ms-office.chartcolorstyle+xml"
        }
    }
}

/// A non-chart object on a sheet's drawing — a picture, a shape, a chart type
/// we do not model — kept exactly as the file had it.
public struct PreservedDrawingAnchor: Identifiable, Hashable, Sendable {
    public var id = UUID()
    /// The anchor element, namespace declarations and all.
    public var xml: String
    /// The relationships the fragment names, by their original id. They are
    /// written back under the same ids, which is what lets the fragment be
    /// re-emitted without being rewritten.
    public var relationships: [PreservedDrawingRelationship]
    /// The largest `cNvPr` id inside the fragment, so the shapes we add to the
    /// same drawing can be numbered clear of it.
    public var largestShapeID: Int
    /// Where it sits, for drawing a placeholder in its place.
    public var placement: ChartPlacement?
    /// Whether the fragment holds a chart rather than a picture or a shape.
    public var isChart: Bool
    /// The image the fragment shows, when it is a picture we can draw.
    public var picture: DrawingPicture?
    /// What the file forbids doing to the object by hand.
    public var locks = DrawingLocks()
    /// The VML shape this stands in for, from its `a14:compatExt`. A form
    /// control's twin carries one, and the control draws in its place.
    public var vmlShapeID: String?
    /// The shape the fragment holds, when it is one we can draw and change.
    public var shape: DrawingShape?
}

/// The `noMove`, `noResize` and `noChangeAspect` locks DrawingML puts on an
/// object. Excel sets the last on every picture it inserts, so dragging a
/// picture's corner scales it rather than stretching it.
public struct DrawingLocks: Hashable, Sendable {
    public var noMove = false
    public var noResize = false
    public var noChangeAspect = false
}

/// A picture on a sheet's drawing: which image part it shows, and how much
/// of each side of the image it crops away.
public struct DrawingPicture: Hashable, Sendable {
    /// The image part's path in the package.
    public var target: String
    /// The fractions of the image cut from each edge — DrawingML's `srcRect`.
    public var cropLeft = 0.0
    public var cropTop = 0.0
    public var cropRight = 0.0
    public var cropBottom = 0.0
}

public struct PreservedDrawingRelationship: Hashable, Sendable {
    public var id: String
    public var type: String
    /// The absolute package path of an internal target, or the URL of an
    /// external one.
    public var target: String
    public var isExternal: Bool

    /// A place in this workbook — `#'Sheet 2'!A1`, the target of a shape's
    /// in-workbook link — rather than a part of the package.
    public var isLocation: Bool { !isExternal && target.hasPrefix("#") }

    /// Whether the target is a part the package must carry.
    public var isPackagePart: Bool { !isExternal && !isLocation }
}
