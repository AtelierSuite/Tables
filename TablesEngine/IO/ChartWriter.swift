import Foundation

/// Writes `Chart` back out as the DrawingML Excel reads: a chart part per
/// chart, the drawing part that places them on a sheet, and the chart sheet
/// part for charts that are sheets of their own.
///
/// Element order inside every DrawingML type is fixed by schema, and Excel
/// declares a file damaged at the first element out of place, so each writer
/// below follows its `CT_` type's sequence exactly. The comments name the type.
public enum ChartWriter {
    public static let chartNamespace = "http://schemas.openxmlformats.org/drawingml/2006/chart"
    public static let drawingMLNamespace = "http://schemas.openxmlformats.org/drawingml/2006/main"
    public static let spreadsheetDrawingNamespace = "http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing"
    public static let relationshipNamespace = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

    public static let chartContentType = "application/vnd.openxmlformats-officedocument.drawingml.chart+xml"
    public static let drawingContentType = "application/vnd.openxmlformats-officedocument.drawing+xml"
    public static let chartSheetContentType = "application/vnd.openxmlformats-officedocument.spreadsheetml.chartsheet+xml"
    public static let chartRelationshipType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/chart"
    public static let drawingRelationshipType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/drawing"
    public static let chartSheetRelationshipType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/chartsheet"

    public static let declaration = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
    public static let emusPerPoint = 12_700.0

    // MARK: - Chart part

    /// The chart part: the file's own XML with the chart's edits written into
    /// it when the chart came from a file, a fresh `CT_ChartSpace` otherwise.
    public static func chartSpace(_ chart: Chart, workbook: Workbook) -> String {
        if let original = chart.original,
           let patched = ChartPatcher.patch(original, to: chart, workbook: workbook) {
            return patched
        }
        return freshChartSpace(chart, workbook: workbook)
    }

    /// `CT_ChartSpace`.
    public static func freshChartSpace(_ chart: Chart, workbook: Workbook) -> String {
        var xml = declaration
        xml += "<c:chartSpace xmlns:c=\"\(chartNamespace)\" xmlns:a=\"\(drawingMLNamespace)\""
        xml += " xmlns:r=\"\(relationshipNamespace)\">"
        // We normalize every date to the 1900 system on the way in.
        xml += "<c:date1904 val=\"0\"/>"
        xml += "<c:roundedCorners val=\"\(chart.hasRoundedCorners ? 1 : 0)\"/>"
        xml += chartElement(chart, workbook: workbook)
        xml += chartAreaShape(chart)
        if !chart.textStyle.isEmpty { xml += textBody(chart.textStyle) }
        // Shapes kept from the file stay over a chart rebuilt from the model.
        if let shapes = chart.original?.companions.first(where: { $0.relationshipType == ChartCompanion.userShapesType }),
           let id = shapes.relationshipID {
            xml += "<c:userShapes r:id=\"\(XMLLite.escape(id))\"/>"
        }
        xml += "</c:chartSpace>"
        return xml
    }

    /// `CT_Chart`: title, autoTitleDeleted, plotArea, legend, plotVisOnly,
    /// dispBlanksAs.
    private static func chartElement(_ chart: Chart, workbook: Workbook) -> String {
        var xml = "<c:chart>"
        if let title = chart.title {
            xml += titleElement(title, workbook: workbook, isVertical: false)
            xml += "<c:autoTitleDeleted val=\"0\"/>"
        } else {
            xml += "<c:autoTitleDeleted val=\"\(chart.showsAutomaticTitle ? 0 : 1)\"/>"
        }
        xml += plotArea(chart, workbook: workbook)
        if let legend = chart.legend {
            xml += legendElement(legend, textStyle: chart.legendTextStyle)
        }
        xml += "<c:plotVisOnly val=\"\(chart.plotsVisibleCellsOnly ? 1 : 0)\"/>"
        xml += "<c:dispBlanksAs val=\"gap\"/>"
        xml += "</c:chart>"
        return xml
    }

    /// `CT_Legend`: legendPos, legendEntry, layout, overlay, spPr, txPr.
    public static func legendElement(_ position: ChartLegendPosition, textStyle: ChartTextStyle) -> String {
        var xml = "<c:legend><c:legendPos val=\"\(position.rawValue)\"/><c:overlay val=\"0\"/>"
        if !textStyle.isEmpty { xml += textBody(textStyle) }
        return xml + "</c:legend>"
    }

    /// The axes' ids. Arbitrary, but they must be unique within the chart
    /// part and match between the plot and its axes.
    private static let categoryAxisID = 500_000_001
    private static let valueAxisID = 500_000_002

    /// `CT_PlotArea`: layout, the plot, then its axes.
    private static func plotArea(_ chart: Chart, workbook: Workbook) -> String {
        var xml = "<c:plotArea><c:layout/>"
        xml += plot(chart, workbook: workbook)
        if !chart.kind.isRadial {
            xml += axes(chart)
        }
        xml += "</c:plotArea>"
        return xml
    }

    private static func plot(_ chart: Chart, workbook: Workbook) -> String {
        let series = chart.kind.isRadial ? Array(chart.series.prefix(1)) : chart.series
        let seriesXML = series.enumerated().map { index, entry in
            seriesElement(entry, index: index, chart: chart, workbook: workbook)
        }.joined()
        let varyColors = "<c:varyColors val=\"\(chart.variesColors ? 1 : 0)\"/>"
        let axisIDs = "<c:axId val=\"\(categoryAxisID)\"/><c:axId val=\"\(valueAxisID)\"/>"

        switch chart.kind {
        case .column, .bar:
            // `CT_BarChart`: barDir, grouping, varyColors, ser*, dLbls, gapWidth,
            // overlap, serLines*, axId+.
            let grouping: String
            switch chart.grouping {
            case .standard: grouping = "clustered"
            case .stacked: grouping = "stacked"
            case .percentStacked: grouping = "percentStacked"
            }
            var xml = "<c:barChart><c:barDir val=\"\(chart.kind == .bar ? "bar" : "col")\"/>"
            xml += "<c:grouping val=\"\(grouping)\"/>" + varyColors + seriesXML
            xml += dataLabels(chart.dataLabels, kind: chart.kind)
            xml += "<c:gapWidth val=\"\(chart.gapWidth ?? 150)\"/>"
            // Stacked bars that do not overlap completely are drawn side by
            // side and offset, which is never what anybody wants.
            if chart.grouping != .standard {
                xml += "<c:overlap val=\"100\"/>"
            } else if let overlap = chart.overlap {
                xml += "<c:overlap val=\"\(overlap)\"/>"
            }
            return xml + axisIDs + "</c:barChart>"
        case .line:
            // `CT_LineChart`: grouping, varyColors, ser*, dLbls, …, marker,
            // smooth, axId+.
            var xml = "<c:lineChart><c:grouping val=\"\(chart.grouping.rawValue)\"/>" + varyColors + seriesXML
            xml += dataLabels(chart.dataLabels, kind: chart.kind)
            xml += "<c:marker val=\"1\"/>"
            return xml + axisIDs + "</c:lineChart>"
        case .area:
            // `CT_AreaChart`: grouping, varyColors, ser*, dLbls, dropLines, axId+.
            var xml = "<c:areaChart><c:grouping val=\"\(chart.grouping.rawValue)\"/>" + varyColors + seriesXML
            xml += dataLabels(chart.dataLabels, kind: chart.kind)
            return xml + axisIDs + "</c:areaChart>"
        case .pie:
            // `CT_PieChart`: varyColors, ser*, dLbls, firstSliceAng.
            var xml = "<c:pieChart>" + varyColors + seriesXML
            xml += dataLabels(chart.dataLabels, kind: chart.kind)
            xml += "<c:firstSliceAng val=\"\(chart.firstSliceAngle)\"/>"
            return xml + "</c:pieChart>"
        case .doughnut:
            // `CT_DoughnutChart`: varyColors, ser*, dLbls, firstSliceAng, holeSize.
            var xml = "<c:doughnutChart>" + varyColors + seriesXML
            xml += dataLabels(chart.dataLabels, kind: chart.kind)
            xml += "<c:firstSliceAng val=\"\(chart.firstSliceAngle)\"/>"
            xml += "<c:holeSize val=\"\(min(max(chart.holeSize, 10), 90))\"/>"
            return xml + "</c:doughnutChart>"
        case .scatter:
            // `CT_ScatterChart`: scatterStyle, varyColors, ser*, dLbls, axId+.
            var xml = "<c:scatterChart><c:scatterStyle val=\"lineMarker\"/>" + varyColors + seriesXML
            xml += dataLabels(chart.dataLabels, kind: chart.kind)
            return xml + axisIDs + "</c:scatterChart>"
        }
    }

    /// The series types share their first few children and differ after:
    /// `CT_BarSer` idx, order, tx, spPr, invertIfNegative, dPt*, cat, val;
    /// `CT_LineSer` idx, order, tx, spPr, marker, dPt*, cat, val, smooth;
    /// `CT_ScatterSer` … marker, dPt*, xVal, yVal, smooth;
    /// `CT_PieSer` and `CT_AreaSer` … spPr, dPt*, cat, val.
    public static func seriesElement(
        _ series: ChartSeries, index: Int, chart: Chart, workbook: Workbook
    ) -> String {
        let usesLine = chart.kind == .line || chart.kind == .scatter
        var xml = "<c:ser><c:idx val=\"\(index)\"/><c:order val=\"\(index)\"/>"
        xml += seriesName(series, chart: chart, workbook: workbook) ?? ""

        if usesLine {
            if series.colorHex != nil || !series.showsLine || series.lineWidth != nil {
                xml += "<c:spPr>" + lineProperties(series) + "</c:spPr>"
            }
        } else if let color = series.colorHex {
            xml += "<c:spPr>" + solidFill(color) + "</c:spPr>"
        }

        switch chart.kind {
        case .column, .bar:
            xml += "<c:invertIfNegative val=\"0\"/>"
        case .line, .scatter:
            if series.showsMarkers {
                xml += "<c:marker><c:symbol val=\"circle\"/><c:size val=\"5\"/>"
                if let color = series.colorHex {
                    xml += "<c:spPr>" + solidFill(color) + "<a:ln w=\"9525\">" + solidFill(color) + "</a:ln></c:spPr>"
                }
                xml += "</c:marker>"
            } else {
                xml += "<c:marker><c:symbol val=\"none\"/></c:marker>"
            }
        case .area, .pie, .doughnut:
            break
        }

        // `CT_DPt`: idx, invertIfNegative, marker, bubble3D, explosion, spPr.
        for (point, color) in series.pointColors.sorted(by: { $0.key < $1.key }) {
            xml += "<c:dPt><c:idx val=\"\(point)\"/>"
            if chart.kind.isRadial { xml += "<c:bubble3D val=\"0\"/>" }
            xml += "<c:spPr>"
            if usesLine {
                xml += "<a:ln>" + solidFill(color) + "</a:ln>"
            } else {
                xml += solidFill(color)
            }
            xml += "</c:spPr></c:dPt>"
        }

        xml += seriesCategories(series, chart: chart, workbook: workbook) ?? ""
        xml += seriesValues(series, chart: chart, workbook: workbook)
        if usesLine { xml += "<c:smooth val=\"\(series.isSmooth ? 1 : 0)\"/>" }
        xml += "</c:ser>"
        return xml
    }

    /// A series' `tx`, or `nil` when it has no name. `CT_SerTx` takes a
    /// reference or a bare `v` — never a literal list.
    public static func seriesName(_ series: ChartSeries, chart: Chart, workbook: Workbook) -> String? {
        guard !series.name.isEmpty else { return nil }
        if series.name.reference != nil || series.name.formula != nil {
            return "<c:tx>" + source(series.name, asText: true, workbook: workbook, chart: chart) + "</c:tx>"
        }
        guard let text = series.name.text(in: workbook) else { return nil }
        return "<c:tx><c:v>\(XMLLite.escape(text))</c:v></c:tx>"
    }

    /// A series' `cat` — `xVal` on a scatter chart — or `nil` when it has none.
    public static func seriesCategories(_ series: ChartSeries, chart: Chart, workbook: Workbook) -> String? {
        guard !series.categories.isEmpty else { return nil }
        let name = chart.kind == .scatter ? "xVal" : "cat"
        let asText = !isNumeric(series.categories, workbook: workbook, chart: chart)
        return "<c:\(name)>" + source(series.categories, asText: asText, workbook: workbook, chart: chart) + "</c:\(name)>"
    }

    /// A series' `val` — `yVal` on a scatter chart.
    public static func seriesValues(_ series: ChartSeries, chart: Chart, workbook: Workbook) -> String {
        let name = chart.kind == .scatter ? "yVal" : "val"
        return "<c:\(name)>" + source(series.values, asText: false, workbook: workbook, chart: chart) + "</c:\(name)>"
    }

    /// `CT_LineProperties` for a line or scatter series.
    public static func lineProperties(_ series: ChartSeries) -> String {
        let width = Int(((series.lineWidth ?? 2.25) * emusPerPoint).rounded())
        guard series.showsLine else { return "<a:ln w=\"\(width)\"><a:noFill/></a:ln>" }
        var xml = "<a:ln w=\"\(width)\" cap=\"rnd\">"
        if let color = series.colorHex { xml += solidFill(color) }
        xml += "<a:round/></a:ln>"
        return xml
    }

    /// Categories are written as numbers only when every one of them is a
    /// number, which keeps dates on a date axis and text as labels.
    private static func isNumeric(_ source: ChartSource, workbook: Workbook, chart: Chart) -> Bool {
        let cells = source.cells(in: workbook, visibleOnly: chart.plotsVisibleCellsOnly)
        let filled = cells.filter { !$0.value.isEmpty }
        return !filled.isEmpty && filled.allSatisfy { $0.value.chartNumber != nil }
    }

    /// A `numRef`/`strRef` with a fresh cache when the source follows cells,
    /// the original formula and cache when it is one we cannot follow, and a
    /// literal when it has neither.
    public static func source(_ source: ChartSource, asText: Bool, workbook: Workbook, chart: Chart) -> String {
        let cells = source.cells(in: workbook, visibleOnly: chart.plotsVisibleCellsOnly)
        let formula = source.reference.flatMap { $0.formula(in: workbook) } ?? source.formula
        let format = cells.first { $0.value.chartNumber != nil }?.style.numberFormat
            ?? source.cacheFormat ?? "General"

        var cache = "<c:ptCount val=\"\(cells.count)\"/>"
        for (index, cell) in cells.enumerated() {
            if asText {
                let text = CellFormatter.displayText(for: cell)
                guard !text.isEmpty else { continue }
                cache += "<c:pt idx=\"\(index)\"><c:v>\(XMLLite.escape(text))</c:v></c:pt>"
            } else {
                guard let number = cell.value.chartNumber else { continue }
                cache += "<c:pt idx=\"\(index)\"><c:v>\(numberText(number))</c:v></c:pt>"
            }
        }
        let formatCode = "<c:formatCode>\(XMLLite.escape(format))</c:formatCode>"

        if let formula {
            let body = "<c:f>\(XMLLite.escape(formula))</c:f>"
            return asText
                ? "<c:strRef>\(body)<c:strCache>\(cache)</c:strCache></c:strRef>"
                : "<c:numRef>\(body)<c:numCache>\(formatCode)\(cache)</c:numCache></c:numRef>"
        }
        return asText
            ? "<c:strLit>\(cache)</c:strLit>"
            : "<c:numLit>\(formatCode)\(cache)</c:numLit>"
    }

    /// `CT_DLbls`: numFmt, spPr, txPr, dLblPos, then the show* flags in order.
    public static func dataLabels(_ labels: ChartDataLabels, kind: ChartKind) -> String {
        var xml = "<c:dLbls>"
        xml += "<c:showLegendKey val=\"0\"/>"
        xml += "<c:showVal val=\"\(labels.showsValue ? 1 : 0)\"/>"
        xml += "<c:showCatName val=\"\(labels.showsCategoryName ? 1 : 0)\"/>"
        xml += "<c:showSerName val=\"\(labels.showsSeriesName ? 1 : 0)\"/>"
        xml += "<c:showPercent val=\"\(labels.showsPercentage && kind.isRadial ? 1 : 0)\"/>"
        xml += "<c:showBubbleSize val=\"0\"/>"
        if kind.isRadial { xml += "<c:showLeaderLines val=\"1\"/>" }
        xml += "</c:dLbls>"
        return xml
    }

    // MARK: - Axes

    private static func axes(_ chart: Chart) -> String {
        let horizontalBars = chart.kind == .bar
        let categoryPosition = horizontalBars ? "l" : "b"
        let valuePosition = horizontalBars ? "b" : "l"
        // Area and scatter plots run edge to edge; bars and lines sit between
        // the tick marks.
        let crossBetween = chart.kind == .area || chart.kind == .scatter ? "midCat" : "between"

        var xml = ""
        if chart.kind == .scatter {
            xml += valueAxis(
                chart.categoryAxis, id: categoryAxisID, crossing: valueAxisID,
                position: "b", crossBetween: crossBetween, isVertical: false
            )
        } else {
            xml += categoryAxis(chart.categoryAxis, position: categoryPosition, isVertical: horizontalBars)
        }
        xml += valueAxis(
            chart.valueAxis, id: valueAxisID, crossing: categoryAxisID,
            position: valuePosition, crossBetween: crossBetween, isVertical: !horizontalBars,
            percent: chart.grouping == .percentStacked
        )
        return xml
    }

    /// The children every axis type opens with: `CT_CatAx`, `CT_DateAx` and
    /// `CT_ValAx` all run axId, scaling, delete, axPos, majorGridlines, title,
    /// numFmt, majorTickMark, minorTickMark, tickLblPos, spPr, txPr, crossAx.
    private static func axisHead(
        _ axis: ChartAxis, id: Int, crossing: Int, position: String, isVertical: Bool,
        defaultFormat: String? = nil
    ) -> String {
        var xml = "<c:axId val=\"\(id)\"/><c:scaling>"
        xml += "<c:orientation val=\"\(axis.isReversed ? "maxMin" : "minMax")\"/>"
        if let maximum = axis.maximum { xml += "<c:max val=\"\(numberText(maximum))\"/>" }
        if let minimum = axis.minimum { xml += "<c:min val=\"\(numberText(minimum))\"/>" }
        xml += "</c:scaling>"
        xml += "<c:delete val=\"\(axis.isVisible ? 0 : 1)\"/>"
        xml += "<c:axPos val=\"\(position)\"/>"
        if axis.showsMajorGridlines { xml += majorGridlines }
        if let title = axis.title {
            xml += titleElement(title, workbook: nil, isVertical: isVertical)
        }
        if let format = axis.numberFormat ?? defaultFormat {
            xml += "<c:numFmt formatCode=\"\(XMLLite.escape(format))\" sourceLinked=\"0\"/>"
        } else {
            xml += "<c:numFmt formatCode=\"General\" sourceLinked=\"1\"/>"
        }
        xml += "<c:majorTickMark val=\"none\"/><c:minorTickMark val=\"none\"/>"
        xml += "<c:tickLblPos val=\"nextTo\"/>"
        xml += "<c:spPr><a:noFill/><a:ln w=\"9525\">" + solidFill("FFBFBFBF") + "</a:ln></c:spPr>"
        if !axis.textStyle.isEmpty { xml += textBody(axis.textStyle) }
        xml += "<c:crossAx val=\"\(crossing)\"/>"
        return xml
    }

    public static let majorGridlines = "<c:majorGridlines><c:spPr><a:ln w=\"9525\">" + solidFill("FFD9D9D9")
        + "</a:ln></c:spPr></c:majorGridlines>"

    /// `CT_CatAx` (or `CT_DateAx`): … crossAx, crosses, auto, lblAlgn, lblOffset,
    /// noMultiLvlLbl — the date axis has baseTimeUnit where the category axis
    /// has lblAlgn.
    private static func categoryAxis(_ axis: ChartAxis, position: String, isVertical: Bool) -> String {
        let element = axis.isDateAxis ? "c:dateAx" : "c:catAx"
        var xml = "<\(element)>"
        xml += axisHead(axis, id: categoryAxisID, crossing: valueAxisID, position: position, isVertical: isVertical)
        xml += "<c:crosses val=\"autoZero\"/><c:auto val=\"1\"/>"
        if axis.isDateAxis {
            xml += "<c:lblOffset val=\"100\"/><c:baseTimeUnit val=\"days\"/>"
        } else {
            xml += "<c:lblAlgn val=\"ctr\"/><c:lblOffset val=\"100\"/><c:noMultiLvlLbl val=\"0\"/>"
        }
        xml += "</\(element)>"
        return xml
    }

    /// `CT_ValAx`: … crossAx, crosses, crossBetween, majorUnit.
    private static func valueAxis(
        _ axis: ChartAxis, id: Int, crossing: Int, position: String, crossBetween: String,
        isVertical: Bool, percent: Bool = false
    ) -> String {
        var xml = "<c:valAx>"
        xml += axisHead(
            axis, id: id, crossing: crossing, position: position, isVertical: isVertical,
            defaultFormat: percent ? "0%" : nil
        )
        xml += "<c:crosses val=\"autoZero\"/><c:crossBetween val=\"\(crossBetween)\"/>"
        if let unit = axis.majorUnit, unit > 0 { xml += "<c:majorUnit val=\"\(numberText(unit))\"/>" }
        xml += "</c:valAx>"
        return xml
    }

    // MARK: - Text

    /// `CT_Title`: tx, layout, overlay, spPr, txPr.
    public static func titleElement(_ title: ChartTitle, workbook: Workbook?, isVertical: Bool) -> String {
        var xml = "<c:title><c:tx>"
        if let reference = title.reference, let workbook, let formula = reference.formula(in: workbook) {
            let text = ChartSource(reference: reference).text(in: workbook) ?? title.text
            xml += "<c:strRef><c:f>\(XMLLite.escape(formula))</c:f><c:strCache><c:ptCount val=\"1\"/>"
            xml += "<c:pt idx=\"0\"><c:v>\(XMLLite.escape(text))</c:v></c:pt></c:strCache></c:strRef>"
            xml += "</c:tx><c:overlay val=\"0\"/>"
            if !title.textStyle.isEmpty { xml += textBody(title.textStyle, isVertical: isVertical) }
            return xml + "</c:title>"
        }
        xml += "<c:rich>" + bodyProperties(isVertical: isVertical) + "<a:lstStyle/>"
        // One paragraph per line, each carrying the style both as its default
        // and on its run, the way Excel writes a title it has formatted.
        for line in title.text.components(separatedBy: "\n") {
            xml += "<a:p><a:pPr>" + runProperties("defRPr", title.textStyle) + "</a:pPr>"
            if !line.isEmpty {
                xml += "<a:r>" + runProperties("rPr", title.textStyle, language: true)
                xml += "<a:t>\(XMLLite.escape(line))</a:t></a:r>"
            }
            xml += "</a:p>"
        }
        xml += "</c:rich></c:tx><c:overlay val=\"0\"/></c:title>"
        return xml
    }

    /// A `txPr` text body carrying only default run properties.
    public static func textBody(_ style: ChartTextStyle, isVertical: Bool = false) -> String {
        "<c:txPr>" + bodyProperties(isVertical: isVertical) + "<a:lstStyle/><a:p><a:pPr>"
            + runProperties("defRPr", style) + "</a:pPr><a:endParaRPr lang=\"en-US\"/></a:p></c:txPr>"
    }

    private static func bodyProperties(isVertical: Bool) -> String {
        isVertical ? "<a:bodyPr rot=\"-5400000\" vert=\"horz\"/>" : "<a:bodyPr/>"
    }

    /// `CT_TextCharacterProperties`: attributes, then a fill, then the Latin
    /// typeface — the schema puts the fill first.
    public static func runProperties(_ name: String, _ style: ChartTextStyle, language: Bool = false) -> String {
        var xml = "<a:\(name)"
        if language { xml += " lang=\"en-US\"" }
        if let size = style.fontSize { xml += " sz=\"\(Int((size * 100).rounded()))\"" }
        if let bold = style.isBold { xml += " b=\"\(bold ? 1 : 0)\"" }
        if let italic = style.isItalic { xml += " i=\"\(italic ? 1 : 0)\"" }
        guard style.colorHex != nil || style.fontName != nil else { return xml + "/>" }
        xml += ">"
        if let color = style.colorHex { xml += solidFill(color) }
        if let font = style.fontName { xml += "<a:latin typeface=\"\(XMLLite.escape(font))\"/>" }
        return xml + "</a:\(name)>"
    }

    // MARK: - Shapes

    /// The chart area: paper and frame.
    private static func chartAreaShape(_ chart: Chart) -> String {
        var xml = "<c:spPr>"
        if let background = chart.backgroundColorHex, background.hasPrefix("00") {
            xml += "<a:noFill/>"
        } else {
            xml += solidFill(chart.backgroundColorHex ?? "FFFFFFFF")
        }
        if chart.hasBorder {
            xml += "<a:ln w=\"9525\" cap=\"flat\" cmpd=\"sng\" algn=\"ctr\">" + solidFill("FFD9D9D9") + "</a:ln>"
        } else {
            xml += "<a:ln><a:noFill/></a:ln>"
        }
        return xml + "</c:spPr>"
    }

    /// A DrawingML solid fill from "AARRGGBB".
    public static func solidFill(_ argb: String) -> String {
        var hex = argb.uppercased()
        var alpha = 255
        if hex.count == 8 {
            alpha = Int(hex.prefix(2), radix: 16) ?? 255
            hex.removeFirst(2)
        }
        var xml = "<a:solidFill><a:srgbClr val=\"\(XMLLite.escape(hex))\""
        if alpha < 255 {
            xml += "><a:alpha val=\"\(alpha * 100_000 / 255)\"/></a:srgbClr></a:solidFill>"
        } else {
            xml += "/></a:solidFill>"
        }
        return xml
    }

    public static func numberText(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return String(format: "%.15g", value)
    }

    // MARK: - Drawing part

    /// `CT_Drawing`: the anchors carried over from the file, then one
    /// `twoCellAnchor` per chart — or, on a chart sheet, one `absoluteAnchor`.
    public static func drawing(
        charts: [(chart: Chart, relationshipID: String)],
        preserved: [PreservedDrawingAnchor],
        isChartSheet: Bool
    ) -> String {
        var xml = declaration
        xml += "<xdr:wsDr xmlns:xdr=\"\(spreadsheetDrawingNamespace)\" xmlns:a=\"\(drawingMLNamespace)\">"
        for anchor in preserved { xml += anchor.xml }

        var shapeID = (preserved.map(\.largestShapeID).max() ?? 1) + 1
        for (chart, relationshipID) in charts {
            if isChartSheet {
                // Excel's own chart sheet anchor: the page, which it scales to
                // the window anyway.
                xml += "<xdr:absoluteAnchor><xdr:pos x=\"0\" y=\"0\"/><xdr:ext cx=\"8666667\" cy=\"6293304\"/>"
            } else {
                let placement = chart.placement
                xml += "<xdr:twoCellAnchor"
                if let editAs = placement.editAs { xml += " editAs=\"\(XMLLite.escape(editAs))\"" }
                xml += ">" + marker("from", placement.from) + marker("to", placement.to)
            }
            let name = chart.name.isEmpty ? "Chart \(shapeID - 1)" : chart.name
            xml += "<xdr:graphicFrame macro=\"\">"
            xml += frameProperties(of: chart, id: shapeID, name: name)
            xml += "<xdr:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"0\" cy=\"0\"/></xdr:xfrm>"
            xml += "<a:graphic><a:graphicData uri=\"\(DrawingReader.chartURI)\">"
            xml += "<c:chart xmlns:c=\"\(chartNamespace)\" xmlns:r=\"\(relationshipNamespace)\" r:id=\"\(relationshipID)\"/>"
            xml += "</a:graphicData></a:graphic></xdr:graphicFrame>"
            // Whether the chart prints and locks with the sheet lives here.
            xml += chart.original?.clientData
                .flatMap { reemit($0, root: "clientData") } ?? "<xdr:clientData/>"
            xml += isChartSheet ? "</xdr:absoluteAnchor>" : "</xdr:twoCellAnchor>"
            shapeID += 1
        }
        xml += "</xdr:wsDr>"
        return xml
    }

    private static let drawingNamespaces = ["xdr": spreadsheetDrawingNamespace, "a": drawingMLNamespace]

    /// `CT_GraphicalObjectFrameNonVisual`: the file's own, when there is one,
    /// so locks and Office's extensions stay put, with the id, name and alt
    /// text the chart has now.
    private static func frameProperties(of chart: Chart, id: Int, name: String) -> String {
        if let saved = chart.original?.frameProperties,
           let element = try? XMLLite.parse(Data(saved.utf8)),
           let properties = element.firstChild(named: "cNvPr") {
            properties.setAttribute("id", String(id))
            properties.setAttribute("name", name)
            properties.setAttribute("descr", chart.altText.flatMap { $0.isEmpty ? nil : $0 })
            if let xml = XMLLite.serialize(element, inheritedNamespaces: drawingNamespaces) { return xml }
        }
        var xml = "<xdr:nvGraphicFramePr><xdr:cNvPr id=\"\(id)\" name=\"\(XMLLite.escape(name))\""
        if let altText = chart.altText, !altText.isEmpty { xml += " descr=\"\(XMLLite.escape(altText))\"" }
        xml += "/><xdr:cNvGraphicFramePr><a:graphicFrameLocks noGrp=\"1\"/></xdr:cNvGraphicFramePr>"
        return xml + "</xdr:nvGraphicFramePr>"
    }

    /// A saved fragment, written back with only the declarations it needs.
    private static func reemit(_ saved: String, root: String) -> String? {
        guard let element = try? XMLLite.parse(Data(saved.utf8)), element.name == root else { return nil }
        return XMLLite.serialize(element, inheritedNamespaces: drawingNamespaces)
    }

    /// `CT_Marker`: col, colOff, row, rowOff — offsets in EMUs.
    private static func marker(_ name: String, _ anchor: ChartAnchor) -> String {
        "<xdr:\(name)><xdr:col>\(max(0, anchor.column))</xdr:col>"
            + "<xdr:colOff>\(Int((max(0, anchor.columnOffset) * emusPerPoint).rounded()))</xdr:colOff>"
            + "<xdr:row>\(max(0, anchor.row))</xdr:row>"
            + "<xdr:rowOff>\(Int((max(0, anchor.rowOffset) * emusPerPoint).rounded()))</xdr:rowOff></xdr:\(name)>"
    }

    // MARK: - Chart sheet part

    /// The children `CT_Chartsheet` allows from what a worksheet carries over,
    /// in its order: sheetPr, sheetViews, sheetProtection, customSheetViews,
    /// pageMargins, pageSetup, headerFooter, drawing.
    public static let chartSheetChildOrder = [
        "sheetPr", "sheetViews", "sheetProtection", "customSheetViews",
        "pageMargins", "pageSetup", "headerFooter", "drawing",
    ]

    public static func chartSheet(
        drawingRelationshipID: String?, preserved: [PreservedElement], mainNamespace: String
    ) -> String {
        var fragments: [(order: Int, xml: String)] = []
        for element in preserved {
            guard let order = chartSheetChildOrder.firstIndex(of: element.name),
                  element.name != "drawing" else { continue }
            fragments.append((order, element.xml))
        }
        if !preserved.contains(where: { $0.name == "sheetViews" }) {
            fragments.append((1, "<sheetViews><sheetView zoomToFit=\"1\" workbookViewId=\"0\"/></sheetViews>"))
        }
        if let drawingRelationshipID {
            fragments.append((7, "<drawing r:id=\"\(drawingRelationshipID)\"/>"))
        }
        fragments.sort { $0.order < $1.order }
        return declaration
            + "<chartsheet xmlns=\"\(mainNamespace)\" xmlns:r=\"\(relationshipNamespace)\">"
            + fragments.map(\.xml).joined()
            + "</chartsheet>"
    }
}
