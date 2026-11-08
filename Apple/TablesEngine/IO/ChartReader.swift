import Foundation

/// Reads DrawingML chart parts (`xl/charts/chartN.xml`) into `Chart`.
///
/// The reader is deliberately strict about what it accepts: a chart it cannot
/// represent completely returns `nil`, and the drawing that holds it keeps the
/// original XML instead. Half-reading a chart and writing the half back would
/// be a silent edit to someone's file.
public enum ChartReader {
    public struct Context: Sendable {
        /// Resolves the sheet names inside series formulas.
        public var workbook: Workbook
        public var theme: ThemeColorScheme
    }

    /// The plot types we model, by element name.
    private static let supportedGroups: Set<String> = [
        "barChart", "lineChart", "areaChart", "pieChart", "doughnutChart", "scatterChart",
    ]

    public static func chart(from root: XMLElement, context: Context) -> Chart? {
        guard root.name == "chartSpace",
              let chartElement = root.firstChild(named: "chart"),
              let plotArea = chartElement.firstChild(named: "plotArea") else { return nil }
        // Embedded source data is a part of its own that we do not write.
        // Shapes drawn over the chart are vetted with the chart's other parts.
        guard root.firstChild(named: "externalData") == nil,
              chartElement.firstChild(named: "pivotFmts") == nil,
              root.firstChild(named: "pivotSource") == nil else { return nil }

        // Exactly one plot, and no plot type we cannot draw: a second group is
        // a combination chart, and that is not something to flatten.
        let groups = plotArea.children.filter { $0.name.hasSuffix("Chart") }
        guard groups.count == 1, let group = groups.first, supportedGroups.contains(group.name) else {
            return nil
        }
        // Lines and bars hung off the series are features we would drop.
        for unsupported in ["upDownBars", "hiLowLines", "dropLines", "serLines"]
        where group.firstChild(named: unsupported) != nil {
            return nil
        }

        guard let kind = kind(of: group) else { return nil }
        var chart = Chart(name: "", kind: kind)
        chart.grouping = grouping(of: group, kind: kind)
        chart.variesColors = flag(group.firstChild(named: "varyColors")) ?? true
        chart.gapWidth = integer(group.firstChild(named: "gapWidth"))
        chart.overlap = integer(group.firstChild(named: "overlap"))
        chart.holeSize = integer(group.firstChild(named: "holeSize")) ?? 50
        chart.firstSliceAngle = integer(group.firstChild(named: "firstSliceAng")) ?? 0

        let scatterStyle = group.firstChild(named: "scatterStyle")?.attribute("val") ?? "lineMarker"
        for element in group.children(named: "ser") {
            guard let series = series(from: element, kind: kind, scatterStyle: scatterStyle, context: context) else {
                return nil
            }
            chart.series.append(series)
        }
        // Series are drawn in `order`, not in document order.
        let orders = group.children(named: "ser").map { integer($0.firstChild(named: "order")) ?? 0 }
        chart.series = zip(orders, chart.series).sorted { $0.0 < $1.0 }.map(\.1)

        chart.dataLabels = dataLabels(group.firstChild(named: "dLbls"))
            ?? group.children(named: "ser").lazy.compactMap { dataLabels($0.firstChild(named: "dLbls")) }.first
            ?? ChartDataLabels()

        // Axes are matched to roles by the ids the plot lists, first the one
        // it lays categories along — or, for a scatter chart, X.
        let axisIDs = group.children(named: "axId").compactMap { $0.attribute("val") }
        let axes = plotArea.children.filter { ["catAx", "valAx", "dateAx", "serAx"].contains($0.name) }
        if kind.isRadial {
            guard axes.isEmpty else { return nil }
        } else {
            guard axes.count == 2, axisIDs.count == 2,
                  !axes.contains(where: { $0.name == "serAx" }) else { return nil }
            func axis(_ id: String) -> XMLElement? {
                axes.first { $0.firstChild(named: "axId")?.attribute("val") == id }
            }
            guard let categoryElement = axis(axisIDs[0]), let valueElement = axis(axisIDs[1]) else { return nil }
            chart.categoryAxis = self.axis(from: categoryElement, context: context)
            chart.valueAxis = self.axis(from: valueElement, context: context)
        }

        // Titles.
        if let titleElement = chartElement.firstChild(named: "title") {
            if let title = title(from: titleElement, context: context) {
                chart.title = title
            } else {
                // A title element with no text is Excel's automatic title.
                chart.showsAutomaticTitle = true
            }
        } else {
            chart.showsAutomaticTitle = !(flag(chartElement.firstChild(named: "autoTitleDeleted")) ?? false)
        }

        if let legend = chartElement.firstChild(named: "legend") {
            let position = legend.firstChild(named: "legendPos")?.attribute("val") ?? "r"
            chart.legend = ChartLegendPosition(rawValue: position) ?? .right
            chart.legendTextStyle = textStyle(fromBody: legend.firstChild(named: "txPr"), context: context)
        } else {
            chart.legend = nil
        }
        chart.plotsVisibleCellsOnly = flag(chartElement.firstChild(named: "plotVisOnly")) ?? true

        chart.textStyle = textStyle(fromBody: root.firstChild(named: "txPr"), context: context)
        if let shape = root.firstChild(named: "spPr") {
            if shape.firstChild(named: "noFill") != nil {
                chart.backgroundColorHex = "00FFFFFF"
            } else {
                chart.backgroundColorHex = fillColor(in: shape, context: context)
            }
            if shape.firstChild(named: "ln")?.firstChild(named: "noFill") != nil { chart.hasBorder = false }
        }
        chart.hasRoundedCorners = flag(root.firstChild(named: "roundedCorners")) ?? true
        return chart
    }

    // MARK: - Plot

    private static func kind(of group: XMLElement) -> ChartKind? {
        switch group.name {
        case "barChart":
            return group.firstChild(named: "barDir")?.attribute("val") == "bar" ? .bar : .column
        case "lineChart": return .line
        case "areaChart": return .area
        case "pieChart": return .pie
        case "doughnutChart": return .doughnut
        case "scatterChart": return .scatter
        default: return nil
        }
    }

    private static func grouping(of group: XMLElement, kind: ChartKind) -> ChartGrouping {
        guard kind.supportsGrouping else { return .standard }
        switch group.firstChild(named: "grouping")?.attribute("val") {
        case "stacked": return .stacked
        case "percentStacked": return .percentStacked
        default: return .standard
        }
    }

    private static func series(
        from element: XMLElement, kind: ChartKind, scatterStyle: String, context: Context
    ) -> ChartSeries? {
        // Trendlines and error bars belong to the series; dropping them on
        // save would be exactly the silent edit this reader refuses to make.
        guard element.firstChild(named: "trendline") == nil,
              element.firstChild(named: "errBars") == nil else { return nil }

        var series = ChartSeries()
        if let tx = element.firstChild(named: "tx") {
            if let literal = tx.firstChild(named: "v") {
                series.name = .text(literal.text)
            } else if let name = source(tx, context: context) {
                series.name = name
            } else {
                return nil
            }
        }

        let categoryName = kind == .scatter ? "xVal" : "cat"
        let valueName = kind == .scatter ? "yVal" : "val"
        guard let categories = source(element.firstChild(named: categoryName), context: context),
              let values = source(element.firstChild(named: valueName), context: context) else { return nil }
        series.categories = categories
        series.values = values

        let shape = element.firstChild(named: "spPr")
        let line = shape?.firstChild(named: "ln")
        switch kind {
        case .line, .scatter:
            // A series drawn as markers alone carries its colour on the marker.
            let marker = element.firstChild(named: "marker")?.firstChild(named: "spPr")
            series.colorHex = fillColor(in: line, context: context)
                ?? fillColor(in: shape, context: context)
                ?? fillColor(in: marker, context: context)
            let defaultLine = kind == .line || !["marker", "none"].contains(scatterStyle)
            series.showsLine = line?.firstChild(named: "noFill") == nil && defaultLine
                || line?.firstChild(named: "solidFill") != nil
            if let width = line?.attribute("w").flatMap(Double.init) { series.lineWidth = width / 12_700 }
            let symbol = element.firstChild(named: "marker")?.firstChild(named: "symbol")?.attribute("val")
            let defaultMarkers = kind == .line || !["line", "smooth", "none"].contains(scatterStyle)
            series.showsMarkers = symbol.map { $0 != "none" } ?? defaultMarkers
            series.isSmooth = flag(element.firstChild(named: "smooth")) ?? false
        case .column, .bar, .area, .pie, .doughnut:
            series.colorHex = fillColor(in: shape, context: context)
        }

        for point in element.children(named: "dPt") {
            guard let index = integer(point.firstChild(named: "idx")) else { continue }
            let pointShape = point.firstChild(named: "spPr")
            if let color = fillColor(in: pointShape, context: context)
                ?? fillColor(in: pointShape?.firstChild(named: "ln"), context: context) {
                series.pointColors[index] = color
            }
        }
        return series
    }

    /// A `cat`, `val`, `xVal`, `yVal` or `tx` element. `nil` means a shape we
    /// cannot represent — multi-level categories — rather than an absent one,
    /// which is an empty source.
    private static func source(_ element: XMLElement?, context: Context) -> ChartSource? {
        guard let element else { return ChartSource() }
        if element.firstChild(named: "multiLvlStrRef") != nil { return nil }

        if let reference = element.firstChild(named: "numRef") ?? element.firstChild(named: "strRef") {
            let formula = reference.firstChild(named: "f")?.text.trimmed ?? ""
            let cacheElement = reference.firstChild(named: "numCache") ?? reference.firstChild(named: "strCache")
            var source = ChartSource(cache: cache(cacheElement))
            source.cacheFormat = cacheElement?.firstChild(named: "formatCode")?.text.trimmed
            if let resolved = ChartReference(formula: formula, in: context.workbook) {
                source.reference = resolved
            } else if !formula.isEmpty {
                source.formula = formula
            }
            return source
        }
        if let literal = element.firstChild(named: "numLit") ?? element.firstChild(named: "strLit") {
            var source = ChartSource(cache: cache(literal))
            source.cacheFormat = literal.firstChild(named: "formatCode")?.text.trimmed
            return source
        }
        return ChartSource()
    }

    private static func cache(_ element: XMLElement?) -> [CellValue] {
        guard let element else { return [] }
        let points = element.children(named: "pt")
        let declared = integer(element.firstChild(named: "ptCount")) ?? 0
        let count = max(declared, (points.compactMap { $0.attribute("idx").flatMap(Int.init) }.max() ?? -1) + 1)
        // A cache can claim an absurd count; a chart has no business with more
        // points than a sheet has rows.
        var values = [CellValue](repeating: .empty, count: min(count, Worksheet.maximumRowCount))
        let isNumeric = element.name == "numCache" || element.name == "numLit"
        for point in points {
            guard let index = point.attribute("idx").flatMap(Int.init), values.indices.contains(index),
                  let text = point.firstChild(named: "v")?.text else { continue }
            if isNumeric, let number = Double(text.trimmed) {
                values[index] = .number(number)
            } else {
                values[index] = .text(text)
            }
        }
        return values
    }

    private static func dataLabels(_ element: XMLElement?) -> ChartDataLabels? {
        guard let element else { return nil }
        if flag(element.firstChild(named: "delete")) == true { return ChartDataLabels() }
        var labels = ChartDataLabels()
        labels.showsValue = flag(element.firstChild(named: "showVal")) ?? false
        labels.showsPercentage = flag(element.firstChild(named: "showPercent")) ?? false
        labels.showsCategoryName = flag(element.firstChild(named: "showCatName")) ?? false
        labels.showsSeriesName = flag(element.firstChild(named: "showSerName")) ?? false
        return labels
    }

    // MARK: - Axes and titles

    private static func axis(from element: XMLElement, context: Context) -> ChartAxis {
        var axis = ChartAxis()
        axis.isVisible = !(flag(element.firstChild(named: "delete")) ?? false)
        axis.isDateAxis = element.name == "dateAx"
        axis.showsMajorGridlines = element.firstChild(named: "majorGridlines") != nil
        if let scaling = element.firstChild(named: "scaling") {
            axis.isReversed = scaling.firstChild(named: "orientation")?.attribute("val") == "maxMin"
            axis.minimum = number(scaling.firstChild(named: "min"))
            axis.maximum = number(scaling.firstChild(named: "max"))
        }
        axis.majorUnit = number(element.firstChild(named: "majorUnit"))
        if let format = element.firstChild(named: "numFmt"),
           format.attribute("sourceLinked") != "1",
           let code = format.attribute("formatCode") {
            axis.numberFormat = code
        }
        if let titleElement = element.firstChild(named: "title") {
            axis.title = title(from: titleElement, context: context)
                ?? ChartTitle(text: String(localized: "Chart.Axis.DefaultTitle", bundle: #bundle))
        }
        axis.textStyle = textStyle(fromBody: element.firstChild(named: "txPr"), context: context)
        return axis
    }

    /// A title's text and style, or `nil` when it carries no text of its own.
    private static func title(from element: XMLElement, context: Context) -> ChartTitle? {
        let bodyStyle = textStyle(fromBody: element.firstChild(named: "txPr"), context: context)
        guard let tx = element.firstChild(named: "tx") else { return nil }

        if let reference = tx.firstChild(named: "strRef") {
            let formula = reference.firstChild(named: "f")?.text.trimmed ?? ""
            let cached = cache(reference.firstChild(named: "strCache"))
                .compactMap { value -> String? in
                    if case .text(let text) = value { return text }
                    return nil
                }
                .joined(separator: " ")
            return ChartTitle(
                text: cached,
                reference: ChartReference(formula: formula, in: context.workbook),
                textStyle: bodyStyle
            )
        }

        guard let rich = tx.firstChild(named: "rich") else { return nil }
        let paragraphs = rich.children(named: "p")
        let text = paragraphs.map { paragraph in
            paragraph.children.compactMap { child -> String? in
                switch child.name {
                case "r", "fld": return child.firstChild(named: "t")?.text
                case "br": return "\n"
                default: return nil
                }
            }.joined()
        }.joined(separator: "\n")

        // The first run's own properties win over the paragraph defaults, which
        // win over the title's text body.
        let paragraph = paragraphs.first
        let defaults = textStyle(from: paragraph?.firstChild(named: "pPr")?.firstChild(named: "defRPr"), context: context)
        let run = textStyle(from: paragraph?.firstChild(named: "r")?.firstChild(named: "rPr"), context: context)
        return ChartTitle(text: text, textStyle: run.inheriting(from: defaults).inheriting(from: bodyStyle))
    }

    // MARK: - Text

    /// The default run properties of a `txPr` text body.
    public static func textStyle(fromBody body: XMLElement?, context: Context) -> ChartTextStyle {
        let paragraph = body?.firstChild(named: "p")
        return textStyle(from: paragraph?.firstChild(named: "pPr")?.firstChild(named: "defRPr"), context: context)
    }

    public static func textStyle(from properties: XMLElement?, context: Context) -> ChartTextStyle {
        guard let properties else { return ChartTextStyle() }
        var style = ChartTextStyle()
        // `sz` counts hundredths of a point.
        style.fontSize = properties.attribute("sz").flatMap(Double.init).map { $0 / 100 }
        style.isBold = properties.attribute("b").map { $0 == "1" || $0 == "true" }
        style.isItalic = properties.attribute("i").map { $0 == "1" || $0 == "true" }
        style.colorHex = fillColor(in: properties, context: context)
        // "+mn-lt" and friends name the theme's fonts rather than a typeface.
        if let face = properties.firstChild(named: "latin")?.attribute("typeface"),
           !face.isEmpty, !face.hasPrefix("+") {
            style.fontName = face
        }
        return style
    }

    // MARK: - Colour

    /// The `solidFill` inside a shape, line or run properties element, as ARGB.
    public static func fillColor(in parent: XMLElement?, context: Context) -> String? {
        guard let fill = parent?.firstChild(named: "solidFill") else { return nil }
        return color(fill, theme: context.theme)
    }

    private static let presetColors: [String: String] = [
        "black": "000000", "white": "FFFFFF", "red": "FF0000", "green": "008000", "blue": "0000FF",
        "yellow": "FFFF00", "orange": "FFA500", "purple": "800080", "gray": "808080", "grey": "808080",
        "darkGray": "A9A9A9", "lightGray": "D3D3D3", "navy": "000080", "teal": "008080",
    ]

    /// Resolves the single colour element inside a fill, with its modifiers.
    public static func color(_ fill: XMLElement, theme: ThemeColorScheme) -> String? {
        for element in fill.children {
            var rgb: String?
            switch element.name {
            case "srgbClr": rgb = element.attribute("val").flatMap(ThemeColorPalette.normalizedRGB)
            case "schemeClr": rgb = element.attribute("val").flatMap(theme.color(schemeName:))
            case "sysClr": rgb = (element.attribute("lastClr") ?? (element.attribute("val") == "window" ? "FFFFFF" : "000000"))
                .flatMap(ThemeColorPalette.normalizedRGB)
            case "prstClr": rgb = element.attribute("val").flatMap { presetColors[$0] }
            default: continue
            }
            guard var resolved = rgb else { return nil }
            var alpha = 1.0
            var modulation = 1.0
            var offset = 0.0
            for modifier in element.children {
                guard let value = modifier.attribute("val").flatMap(Double.init).map({ $0 / 100_000 }) else { continue }
                switch modifier.name {
                case "lumMod": modulation = value
                case "lumOff": offset = value
                case "tint": resolved = ThemeColorPalette.tinted(resolved, by: 1 - value)
                case "shade": resolved = ThemeColorPalette.tinted(resolved, by: -(1 - value))
                case "alpha": alpha = value
                default: break
                }
            }
            if modulation != 1 || offset != 0 {
                resolved = ThemeColorPalette.modulated(resolved, luminance: modulation, offset: offset)
            }
            return String(format: "%02X", Int((min(max(alpha, 0), 1) * 255).rounded())) + resolved
        }
        return nil
    }

    // MARK: - Values

    /// A `CT_Boolean`: an element present without `val` means true.
    public static func flag(_ element: XMLElement?) -> Bool? {
        guard let element else { return nil }
        guard let value = element.attribute("val") else { return true }
        return value == "1" || value == "true"
    }

    private static func integer(_ element: XMLElement?) -> Int? {
        element?.attribute("val").flatMap { Int($0) ?? Double($0).map { Int($0) } }
    }

    private static func number(_ element: XMLElement?) -> Double? {
        element?.attribute("val").flatMap(Double.init)
    }
}

// MARK: - Drawings

/// Reads a sheet's drawing part: the charts in it that `ChartReader` can model,
/// and everything else as preserved anchors.
public enum DrawingReader {
    public struct Result: Sendable {
        public var charts: [Chart] = []
        public var anchors: [PreservedDrawingAnchor] = []
        /// Chart parts — and their style and colour companions — now held in
        /// the model, which the package must not also carry.
        public var consumedParts: Set<String> = []
        /// An anchor that could not be kept, so the user hears about it.
        public var lostSomething = false
    }

    public static let chartURI = "http://schemas.openxmlformats.org/drawingml/2006/chart"
    private static let chartCompanionTypes: Set<String> = [
        ChartCompanion.styleType, ChartCompanion.colorsType, ChartCompanion.userShapesType,
    ]

    /// Whether a chart's user shapes part draws nothing — empty text boxes
    /// with no fill or line, as templates leave behind. Those we can show the
    /// chart without and carry through untouched; anything visible would be
    /// missing from what we draw, so such a chart is kept whole instead.
    public static func drawsNothing(userShapes data: Data) -> Bool {
        guard let root = try? XMLLite.parse(data), root.name == "userShapes" else { return false }
        for anchor in root.children {
            guard ["relSizeAnchor", "absSizeAnchor"].contains(anchor.name) else { return false }
            for content in anchor.children where !["from", "to", "ext"].contains(content.name) {
                guard content.name == "sp", content.firstChild(named: "style") == nil else { return false }
                let shape = content.firstChild(named: "spPr")
                for property in shape?.children ?? [] where !["xfrm", "prstGeom", "noFill"].contains(property.name) {
                    guard property.name == "ln", property.children.allSatisfy({ $0.name == "noFill" }),
                          property.firstChild(named: "noFill") != nil else { return false }
                }
                if let body = content.firstChild(named: "txBody"), hasText(body) { return false }
            }
        }
        return true
    }

    private static func hasText(_ element: XMLElement) -> Bool {
        if element.name == "t", !element.text.trimmed.isEmpty { return true }
        return element.children.contains(where: hasText)
    }

    public static func read(
        drawingPath: String, entries: [String: Data], sheet: Worksheet, context: ChartReader.Context
    ) -> Result {
        var result = Result()
        guard let payload = entries[drawingPath], let root = try? XMLLite.parse(payload) else {
            result.lostSomething = entries[drawingPath] != nil
            return result
        }
        typealias Plan = XLSXReader.PackagePreservation
        let directory = Plan.directory(of: drawingPath)
        let relationships = Plan.relationships(in: entries[Plan.relationshipsPath(for: drawingPath)])
        // Drawings routinely sit past the last cell with anything in it, and
        // the grid's geometry stops at its last line; measured against the
        // sheet as it is, every such anchor would be pinned to its edge.
        var room = sheet
        room.rowCount = min(Worksheet.maximumRowCount, sheet.rowCount + 500)
        room.columnCount = min(Worksheet.maximumColumnCount, sheet.columnCount + 100)
        let metrics = SheetMetrics(sheet: room)

        for anchor in root.children {
            // Newer objects come wrapped in markup compatibility: the anchor
            // inside the first choice, and again, for older readers, inside
            // the fallback. The wrapper is kept whole, and placed and drawn
            // by the anchors inside it.
            let inner = anchors(in: anchor)
            let placement = inner.lazy.compactMap { self.placement(of: $0, metrics: metrics, sheet: room) }.first
            if let chart = chart(
                in: anchor, placement: placement, relationships: relationships,
                directory: directory, entries: entries, context: context, consumed: &result.consumedParts
            ) {
                result.charts.append(chart)
                continue
            }

            // Kept whole. The relationships it names come with it by id; a
            // `r:`-prefixed attribute is the only place a fragment names one.
            guard let xml = XMLLite.serialize(anchor) else {
                result.lostSomething = true
                continue
            }
            var named: Set<String> = []
            var largestShapeID = 0
            var isChart = false
            var vmlShapeID: String?
            visit(anchor) { element in
                for (key, value) in element.qualifiedAttributes where key.contains(":") && !key.hasPrefix("xmlns") {
                    named.insert(value)
                }
                if element.name == "cNvPr", let id = element.attribute("id").flatMap(Int.init) {
                    largestShapeID = max(largestShapeID, id)
                }
                if element.name == "graphicFrame" { isChart = true }
                if element.name == "compatExt" { vmlShapeID = element.attribute("spid") }
            }
            let kept = relationships.compactMap { entry -> PreservedDrawingRelationship? in
                guard let id = entry.id, named.contains(id) else { return nil }
                let isExternal = entry.targetMode == "External"
                let isLocation = !isExternal && entry.target.hasPrefix("#")
                return PreservedDrawingRelationship(
                    id: id, type: entry.type,
                    target: isExternal || isLocation
                        ? entry.target : Plan.absolutePath(entry.target, relativeTo: directory),
                    isExternal: isExternal
                )
            }
            result.anchors.append(PreservedDrawingAnchor(
                xml: xml, relationships: kept, largestShapeID: largestShapeID,
                placement: placement, isChart: isChart,
                picture: inner.lazy.compactMap { picture(in: $0, relationships: kept) }.first,
                locks: inner.first.map(locks(in:)) ?? DrawingLocks(),
                vmlShapeID: vmlShapeID
            ))
        }
        return result
    }

    /// The image a picture anchor shows. Pictures inside groups are left as
    /// placeholders, as are hidden ones.
    private static func picture(
        in anchor: XMLElement, relationships: [PreservedDrawingRelationship]
    ) -> DrawingPicture? {
        guard let picture = anchor.firstChild(named: "pic"),
              picture.firstDescendant(atPath: "nvPicPr/cNvPr")?.attribute("hidden") != "1",
              let fill = picture.firstChild(named: "blipFill"),
              let id = fill.firstChild(named: "blip")?.attribute("embed"),
              let target = relationships.first(where: { $0.id == id && $0.isPackagePart })?.target
        else { return nil }
        var result = DrawingPicture(target: target)
        if let crop = fill.firstChild(named: "srcRect") {
            // Thousandths of a percent of the image's own size.
            func edge(_ name: String) -> Double {
                min(max((crop.attribute(name).flatMap(Double.init) ?? 0) / 100_000, -1), 1)
            }
            result.cropLeft = edge("l")
            result.cropTop = edge("t")
            result.cropRight = edge("r")
            result.cropBottom = edge("b")
        }
        return result
    }

    public static let anchorNames: Set<String> = ["twoCellAnchor", "oneCellAnchor", "absoluteAnchor"]

    /// The anchors an element of a drawing stands for: itself, when it is
    /// one, or those in each branch of the `mc:AlternateContent` wrapping
    /// them — the choice first, then the fallback.
    public static func anchors(in element: XMLElement) -> [XMLElement] {
        if anchorNames.contains(element.name) { return [element] }
        guard element.name == "AlternateContent" else { return [] }
        return element.children
            .filter { $0.name == "Choice" || $0.name == "Fallback" }
            .flatMap { $0.children.filter { anchorNames.contains($0.name) } }
    }

    /// The objects an anchor can hold, one of which it does.
    public static let drawingObjects: Set<String> = ["sp", "grpSp", "graphicFrame", "cxnSp", "pic", "contentPart"]

    /// The locks on the object an anchor holds: `a:picLocks`, `a:spLocks` and
    /// their kin, inside the object's non-visual properties.
    private static func locks(in anchor: XMLElement) -> DrawingLocks {
        guard let object = anchor.children.first(where: { drawingObjects.contains($0.name) }),
              let locks = object.children.first(where: { $0.name.hasPrefix("nv") })?
                .children.first(where: { $0.name.hasPrefix("cNv") && $0.name != "cNvPr" })?
                .children.first(where: { $0.name.hasSuffix("Locks") })
        else { return DrawingLocks() }
        func isOn(_ name: String) -> Bool { ["1", "true"].contains(locks.attribute(name)) }
        return DrawingLocks(noMove: isOn("noMove"), noResize: isOn("noResize"), noChangeAspect: isOn("noChangeAspect"))
    }

    /// The chart an anchor frames, when it frames one we can model.
    private static func chart(
        in anchor: XMLElement, placement: ChartPlacement?,
        relationships: [XLSXReader.PackagePreservation.RelationshipEntry],
        directory: String, entries: [String: Data], context: ChartReader.Context,
        consumed: inout Set<String>
    ) -> Chart? {
        typealias Plan = XLSXReader.PackagePreservation
        guard anchorNames.contains(anchor.name),
              let frame = anchor.firstChild(named: "graphicFrame"),
              let data = frame.firstDescendant(atPath: "graphic/graphicData"),
              data.attribute("uri") == chartURI,
              let id = data.firstChild(named: "chart")?.attribute("id"),
              let entry = relationships.first(where: { $0.id == id }), entry.targetMode != "External"
        else { return nil }

        let path = Plan.absolutePath(entry.target, relativeTo: directory)
        guard let payload = entries[path], let root = try? XMLLite.parse(payload) else { return nil }
        // A chart that reaches anything beyond its style and colour companions
        // — pictures used as fills, shapes drawn over it — is kept whole.
        let companions = Plan.relationships(in: entries[Plan.relationshipsPath(for: path)])
        guard companions.allSatisfy({ companion in
            guard chartCompanionTypes.contains(companion.type) else { return false }
            guard companion.type == ChartCompanion.userShapesType else { return true }
            let shapesPath = Plan.absolutePath(companion.target, relativeTo: Plan.directory(of: path))
            return entries[Plan.relationshipsPath(for: shapesPath)] == nil
                && entries[shapesPath].map(drawsNothing(userShapes:)) == true
        }),
              var chart = ChartReader.chart(from: root, context: context) else { return nil }

        let properties = frame.firstChild(named: "nvGraphicFramePr")
        chart.name = properties?.firstChild(named: "cNvPr")?.attribute("name") ?? ""
        chart.altText = properties?.firstChild(named: "cNvPr")?.attribute("descr").flatMap { $0.isEmpty ? nil : $0 }
        if let placement { chart.placement = placement }
        consumed.insert(path)
        var kept: [ChartCompanion] = []
        for companion in companions {
            let companionPath = Plan.absolutePath(companion.target, relativeTo: Plan.directory(of: path))
            consumed.insert(companionPath)
            if let data = entries[companionPath] {
                kept.append(ChartCompanion(relationshipType: companion.type, data: data, relationshipID: companion.id))
            }
        }
        chart.original = ChartOriginal(
            xml: payload, baseline: chart, companions: kept,
            frameProperties: properties.flatMap { XMLLite.serialize($0) },
            clientData: anchor.firstChild(named: "clientData").flatMap { XMLLite.serialize($0) }
        )
        return chart
    }

    /// Where an anchor sits, normalized to the two-cell form. One-cell and
    /// absolute anchors are converted through the sheet's geometry.
    public static func placement(of anchor: XMLElement, metrics: SheetMetrics, sheet: Worksheet) -> ChartPlacement? {
        func marker(_ element: XMLElement?) -> ChartAnchor? {
            guard let element,
                  let column = element.firstChild(named: "col").flatMap({ Int($0.text.trimmed) }),
                  let row = element.firstChild(named: "row").flatMap({ Int($0.text.trimmed) }) else { return nil }
            return ChartAnchor(
                row: row, column: column,
                rowOffset: (element.firstChild(named: "rowOff").flatMap { Double($0.text.trimmed) } ?? 0) / 12_700,
                columnOffset: (element.firstChild(named: "colOff").flatMap { Double($0.text.trimmed) } ?? 0) / 12_700
            )
        }
        func extent(_ element: XMLElement?) -> CGSize? {
            guard let element,
                  let width = element.attribute("cx").flatMap(Double.init),
                  let height = element.attribute("cy").flatMap(Double.init) else { return nil }
            return CGSize(width: width / 12_700, height: height / 12_700)
        }

        switch anchor.name {
        case "twoCellAnchor":
            guard let from = marker(anchor.firstChild(named: "from")),
                  let to = marker(anchor.firstChild(named: "to")) else { return nil }
            return ChartPlacement(from: from, to: to, editAs: anchor.attribute("editAs"))
        case "oneCellAnchor":
            guard let from = marker(anchor.firstChild(named: "from")),
                  let size = extent(anchor.firstChild(named: "ext")) else { return nil }
            let origin = CGPoint(
                x: metrics.x(ofColumn: from.column) + from.columnOffset,
                y: metrics.y(ofRow: from.row) + from.rowOffset
            )
            return ChartPlacement(frame: CGRect(origin: origin, size: size), in: sheet)
        case "absoluteAnchor":
            guard let position = anchor.firstChild(named: "pos"),
                  let x = position.attribute("x").flatMap(Double.init),
                  let y = position.attribute("y").flatMap(Double.init),
                  let size = extent(anchor.firstChild(named: "ext")) else { return nil }
            return ChartPlacement(
                frame: CGRect(origin: CGPoint(x: x / 12_700, y: y / 12_700), size: size), in: sheet
            )
        default:
            return nil
        }
    }

    private static func visit(_ element: XMLElement, _ body: (XMLElement) -> Void) {
        body(element)
        for child in element.children { visit(child, body) }
    }
}
