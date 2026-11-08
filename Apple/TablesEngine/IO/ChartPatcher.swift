import Foundation

/// Writes a chart's edits into the XML it was read from.
///
/// `ChartReader` models only part of what a chart part says; writing a read
/// chart afresh from the model would quietly restyle it — gradients become
/// flat colours, markers become circles, a legend dragged into place jumps
/// back. So a chart that came from a file is saved as that file's XML with
/// two kinds of change made to it: its data — formulas and cached values,
/// which follow the sheet — always, and every modelled property the user
/// changed since it was read. Everything else is left exactly as it was.
///
/// A change the XML cannot absorb in place — a pie turned into a line chart,
/// a category axis turned into a date axis — returns `nil`, and the chart is
/// written afresh, as Excel itself rebuilds a chart whose type changes.
public enum ChartPatcher {
    public static func patch(_ original: ChartOriginal, to chart: Chart, workbook: Workbook) -> String? {
        let base = original.baseline
        let sameFamily = chart.kind == base.kind || Set([chart.kind, base.kind]) == [.column, .bar]
        guard sameFamily, chart.categoryAxis.isDateAxis == base.categoryAxis.isDateAxis,
              let root = try? XMLLite.parse(original.xml), root.name == "chartSpace",
              let chartElement = root.firstChild(named: "chart"),
              let plotArea = chartElement.firstChild(named: "plotArea"),
              let group = plotArea.children.first(where: { $0.name.hasSuffix("Chart") }),
              group.children(named: "ser").count == base.series.count
        else { return nil }

        let patch = Patch(chart: chart, base: base, workbook: workbook)
        patch.chartSpace(root)
        patch.chart(chartElement)
        guard patch.plot(group, in: plotArea), let body = XMLLite.serialize(root) else { return nil }
        return ChartWriter.declaration + body
    }

    /// Schema sequences, merged across the types that share an element name
    /// where their orders agree. `fill` stands for whichever fill is there.
    public enum Order {
        public static let chartSpace = [
            "date1904", "lang", "roundedCorners", "AlternateContent", "style", "clrMapOvr", "pivotSource",
            "protection", "chart", "spPr", "txPr", "externalData", "printSettings", "userShapes", "extLst",
        ]
        public static let chart = [
            "title", "autoTitleDeleted", "pivotFmts", "view3D", "floor", "sideWall", "backWall", "plotArea",
            "legend", "plotVisOnly", "dispBlanksAs", "showDLblsOverMax", "extLst",
        ]
        public static let group = [
            "barDir", "scatterStyle", "grouping", "varyColors", "ser", "dLbls", "dropLines", "hiLowLines",
            "upDownBars", "gapWidth", "overlap", "serLines", "marker", "smooth", "firstSliceAng", "holeSize",
            "axId", "extLst",
        ]
        public static let series = [
            "idx", "order", "tx", "spPr", "invertIfNegative", "pictureOptions", "marker", "explosion", "dPt",
            "dLbls", "trendline", "errBars", "cat", "xVal", "val", "yVal", "shape", "smooth", "extLst",
        ]
        public static let point = ["idx", "invertIfNegative", "marker", "bubble3D", "explosion", "spPr", "pictureOptions", "extLst"]
        public static let marker = ["symbol", "size", "spPr", "extLst"]
        public static let labels = [
            "dLbl", "delete", "numFmt", "spPr", "txPr", "dLblPos", "showLegendKey", "showVal", "showCatName",
            "showSerName", "showPercent", "showBubbleSize", "separator", "showLeaderLines", "leaderLines", "extLst",
        ]
        public static let axis = [
            "axId", "scaling", "delete", "axPos", "majorGridlines", "minorGridlines", "title", "numFmt",
            "majorTickMark", "minorTickMark", "tickLblPos", "spPr", "txPr", "crossAx", "crosses", "crossesAt",
            "crossBetween", "auto", "lblAlgn", "lblOffset", "baseTimeUnit", "majorUnit", "majorTimeUnit",
            "minorUnit", "minorTimeUnit", "tickLblSkip", "tickMarkSkip", "dispUnits", "noMultiLvlLbl", "extLst",
        ]
        public static let scaling = ["logBase", "orientation", "max", "min", "extLst"]
        public static let legend = ["legendPos", "legendEntry", "layout", "overlay", "spPr", "txPr", "extLst"]
        public static let title = ["tx", "layout", "overlay", "spPr", "txPr", "extLst"]
        public static let shape = [
            "xfrm", "custGeom", "prstGeom", "fill", "ln", "effectLst", "effectDag", "scene3d", "sp3d", "extLst",
        ]
        public static let line = ["fill", "prstDash", "custDash", "round", "bevel", "miter", "headEnd", "tailEnd", "extLst"]
        public static let run = [
            "ln", "fill", "effectLst", "effectDag", "highlight", "uLnTx", "uLn", "uFillTx", "uFill", "latin", "ea",
            "cs", "sym", "hlinkClick", "hlinkMouseOver", "rtl", "extLst",
        ]
    }

    /// The elements `child(_:of:order:)` may add that live in DrawingML's
    /// own namespace rather than the chart one.
    private static let drawingMLNames: Set<String> = ["ln", "pPr"]

    private static let fills: Set<String> = ["noFill", "solidFill", "gradFill", "blipFill", "pattFill", "grpFill"]

    private static let namespaces = [
        "c": ChartWriter.chartNamespace, "a": ChartWriter.drawingMLNamespace, "r": ChartWriter.relationshipNamespace,
    ]

    // MARK: - Tree editing

    /// Parses a fragment the writer produced, ready to graft.
    public static func make(_ xml: String) -> XMLElement? {
        XMLLite.fragment(xml, namespaces: namespaces)
    }

    private static func slot(_ name: String, in order: [String]) -> Int? {
        order.firstIndex(of: fills.contains(name) ? "fill" : name)
    }

    /// Inserts `child` where the schema puts it: after everything that comes
    /// before it, ahead of anything after it and of a trailing `extLst`.
    public static func insert(_ child: XMLElement, into parent: XMLElement, order: [String]) {
        let mine = slot(child.name, in: order)
        let index = parent.children.firstIndex { other in
            guard let mine, let theirs = slot(other.name, in: order) else { return other.name == "extLst" }
            return theirs > mine
        } ?? parent.children.count
        parent.insertChild(child, at: index)
    }

    /// Puts `xml` in place of the child of the same name, or where it belongs.
    @discardableResult
    public static func replace(_ name: String, in parent: XMLElement, with xml: String, order: [String]) -> XMLElement? {
        guard let fresh = make(xml) else { return nil }
        if let existing = parent.firstChild(named: name) {
            parent.replaceChild(existing, with: fresh)
        } else {
            insert(fresh, into: parent, order: order)
        }
        return fresh
    }

    public static func remove(_ name: String, from parent: XMLElement) {
        for child in parent.children(named: name) { parent.removeChild(child) }
    }

    /// The child named `name`, made empty if it is not there.
    public static func child(_ name: String, of parent: XMLElement, order: [String]) -> XMLElement {
        if let existing = parent.firstChild(named: name) { return existing }
        let prefix = drawingMLNames.contains(name) ? "a" : "c"
        let fresh = make("<\(prefix):\(name)/>") ?? XMLElement(name: name, attributes: [:])
        insert(fresh, into: parent, order: order)
        return fresh
    }

    /// Sets a `val`-carrying child, adding it if it is missing.
    public static func setValue(_ name: String, _ value: String, in parent: XMLElement, order: [String]) {
        if let existing = parent.firstChild(named: name) {
            existing.setAttribute("val", value)
        } else if let fresh = make("<c:\(name) val=\"\(XMLLite.escape(value))\"/>") {
            insert(fresh, into: parent, order: order)
        }
    }

    public static func setOptionalValue(_ name: String, _ value: String?, in parent: XMLElement, order: [String]) {
        if let value {
            setValue(name, value, in: parent, order: order)
        } else {
            remove(name, from: parent)
        }
    }

    public static func flag(_ value: Bool) -> String { value ? "1" : "0" }

    /// Swaps whatever fill `parent` has for `xml`; `nil` leaves it unfilled,
    /// which DrawingML reads as "automatic".
    public static func replaceFill(in parent: XMLElement, with xml: String?, order: [String]) {
        for child in parent.children where fills.contains(child.name) { parent.removeChild(child) }
        if let xml, let fresh = make(xml) { insert(fresh, into: parent, order: order) }
    }

    // MARK: - Text

    /// Writes a text style's changes into run properties — `defRPr` or `rPr`.
    public static func apply(_ style: ChartTextStyle, over old: ChartTextStyle, to properties: XMLElement) {
        if style.fontSize != old.fontSize {
            properties.setAttribute("sz", style.fontSize.map { String(Int(($0 * 100).rounded())) })
        }
        if style.isBold != old.isBold { properties.setAttribute("b", style.isBold.map(flag)) }
        if style.isItalic != old.isItalic { properties.setAttribute("i", style.isItalic.map(flag)) }
        if style.colorHex != old.colorHex {
            replaceFill(in: properties, with: style.colorHex.map(ChartWriter.solidFill), order: Order.run)
        }
        if style.fontName != old.fontName {
            remove("latin", from: properties)
            if let font = style.fontName, let latin = make("<a:latin typeface=\"\(XMLLite.escape(font))\"/>") {
                insert(latin, into: properties, order: Order.run)
            }
        }
    }

    /// Patches the `txPr` of a title, legend, axis or the chart itself.
    public static func patchTextBody(
        of parent: XMLElement, to style: ChartTextStyle, from old: ChartTextStyle, order: [String]
    ) {
        guard style != old else { return }
        if let defaults = parent.firstChild(named: "txPr")?.firstDescendant(atPath: "p/pPr/defRPr") {
            apply(style, over: old, to: defaults)
            return
        }
        // No paragraph defaults to edit: a fresh body, keeping the file's
        // body properties, which carry the text's rotation.
        let bodyProperties = parent.firstChild(named: "txPr")?.firstChild(named: "bodyPr")
        guard let fresh = replace("txPr", in: parent, with: ChartWriter.textBody(style), order: order) else { return }
        if let bodyProperties, let generated = fresh.firstChild(named: "bodyPr") {
            fresh.replaceChild(generated, with: bodyProperties)
        }
    }
}

// MARK: - The patch

private final class Patch {
    typealias P = ChartPatcher
    typealias Order = ChartPatcher.Order

    let chart: Chart
    let base: Chart
    let workbook: Workbook

    init(chart: Chart, base: Chart, workbook: Workbook) {
        self.chart = chart
        self.base = base
        self.workbook = workbook
    }

    var usesLine: Bool { chart.kind == .line || chart.kind == .scatter }

    // MARK: Chart space

    func chartSpace(_ root: XMLElement) {
        // The caches written below count dates from 1900, which is the only
        // system the model holds.
        if let system = root.firstChild(named: "date1904"), ChartReader.flag(system) == true {
            system.setAttribute("val", "0")
        }
        if chart.hasRoundedCorners != base.hasRoundedCorners {
            P.setValue("roundedCorners", P.flag(chart.hasRoundedCorners), in: root, order: Order.chartSpace)
        }
        if chart.backgroundColorHex != base.backgroundColorHex || chart.hasBorder != base.hasBorder {
            let shape = P.child("spPr", of: root, order: Order.chartSpace)
            if chart.backgroundColorHex != base.backgroundColorHex {
                let background = chart.backgroundColorHex
                let fill = background.map { $0.hasPrefix("00") } == true
                    ? "<a:noFill/>" : ChartWriter.solidFill(background ?? "FFFFFFFF")
                P.replaceFill(in: shape, with: fill, order: Order.shape)
            }
            if chart.hasBorder != base.hasBorder {
                let line = P.child("ln", of: shape, order: Order.shape)
                P.replaceFill(
                    in: line, with: chart.hasBorder ? ChartWriter.solidFill("FFD9D9D9") : "<a:noFill/>",
                    order: Order.line
                )
            }
        }
        P.patchTextBody(of: root, to: chart.textStyle, from: base.textStyle, order: Order.chartSpace)
    }

    // MARK: Chart

    func chart(_ element: XMLElement) {
        chartTitle(element)
        legend(element)
        if chart.plotsVisibleCellsOnly != base.plotsVisibleCellsOnly {
            P.setValue("plotVisOnly", P.flag(chart.plotsVisibleCellsOnly), in: element, order: Order.chart)
        }
    }

    private func chartTitle(_ element: XMLElement) {
        let existing = element.firstChild(named: "title")
        guard chart.title != base.title || chart.showsAutomaticTitle != base.showsAutomaticTitle
                || chart.title?.reference != nil else { return }

        guard let title = chart.title else {
            if chart.showsAutomaticTitle {
                // A title with no text of its own is Excel's automatic one.
                if let existing {
                    P.remove("tx", from: existing)
                } else if let fresh = P.make("<c:title><c:overlay val=\"0\"/></c:title>") {
                    P.insert(fresh, into: element, order: Order.chart)
                }
                P.setValue("autoTitleDeleted", "0", in: element, order: Order.chart)
            } else {
                P.remove("title", from: element)
                P.setValue("autoTitleDeleted", "1", in: element, order: Order.chart)
            }
            return
        }
        patchTitle(title, over: base.title, isVertical: false, in: element, existing: existing, order: Order.chart)
        P.setValue("autoTitleDeleted", "0", in: element, order: Order.chart)
    }

    /// A chart or axis title. Its text is rewritten only when it changed —
    /// or reads from a cell, whose value may have — so that a title formatted
    /// run by run keeps its runs when only its size or colour changes.
    private func patchTitle(
        _ title: ChartTitle, over old: ChartTitle?, isVertical: Bool,
        in parent: XMLElement, existing: XMLElement?, order: [String]
    ) {
        let generated = ChartWriter.titleElement(title, workbook: workbook, isVertical: isVertical)
        guard let existing else {
            if let fresh = P.make(generated) { P.insert(fresh, into: parent, order: order) }
            return
        }
        let oldStyle = old?.textStyle ?? ChartTextStyle()
        let textChanged = title.text != old?.text || title.reference != old?.reference
            || title.reference != nil || existing.firstChild(named: "tx") == nil
        if textChanged {
            guard let fresh = P.make(generated), let text = fresh.firstChild(named: "tx") else { return }
            fresh.removeChild(text)
            text.declareNamespaces(fresh.namespaceDeclarations)
            if let current = existing.firstChild(named: "tx") {
                existing.replaceChild(current, with: text)
            } else {
                P.insert(text, into: existing, order: Order.title)
            }
            // A cell's text takes its style from the title's text body.
            if title.reference != nil {
                P.patchTextBody(of: existing, to: title.textStyle, from: oldStyle, order: Order.title)
            }
        } else if title.textStyle != oldStyle, let rich = existing.firstDescendant(atPath: "tx/rich") {
            for paragraph in rich.children(named: "p") {
                let defaults = P.child("pPr", of: paragraph, order: ["pPr", "r", "br", "fld", "endParaRPr"])
                if let properties = defaults.firstChild(named: "defRPr") {
                    P.apply(title.textStyle, over: oldStyle, to: properties)
                } else if let fresh = P.make(ChartWriter.runProperties("defRPr", title.textStyle)) {
                    defaults.insertChild(fresh, at: defaults.children.count)
                }
                for run in paragraph.children(named: "r") {
                    if let properties = run.firstChild(named: "rPr") {
                        P.apply(title.textStyle, over: oldStyle, to: properties)
                    }
                }
            }
        }
    }

    private func legend(_ element: XMLElement) {
        guard let position = chart.legend else {
            if base.legend != nil { P.remove("legend", from: element) }
            return
        }
        guard let legend = element.firstChild(named: "legend") else {
            let xml = ChartWriter.legendElement(position, textStyle: chart.legendTextStyle)
            if let fresh = P.make(xml) { P.insert(fresh, into: element, order: Order.chart) }
            return
        }
        if position != base.legend {
            P.setValue("legendPos", position.rawValue, in: legend, order: Order.legend)
            // A legend dragged into place stays there whatever its position
            // says, so moving it means letting go of where it was dragged.
            if let layout = legend.firstChild(named: "layout"), !layout.children.isEmpty {
                P.replace("layout", in: legend, with: "<c:layout/>", order: Order.legend)
            }
        }
        P.patchTextBody(of: legend, to: chart.legendTextStyle, from: base.legendTextStyle, order: Order.legend)
    }

    // MARK: Plot

    /// The plot and its axes. `false` when the series in the file no longer
    /// line up with the model's.
    func plot(_ group: XMLElement, in plotArea: XMLElement) -> Bool {
        if chart.kind != base.kind {
            P.setValue("barDir", chart.kind == .bar ? "bar" : "col", in: group, order: Order.group)
        }
        if chart.variesColors != base.variesColors {
            P.setValue("varyColors", P.flag(chart.variesColors), in: group, order: Order.group)
        }
        if chart.kind.supportsGrouping, chart.grouping != base.grouping {
            let isBar = chart.kind == .column || chart.kind == .bar
            let value = isBar && chart.grouping == .standard ? "clustered" : chart.grouping.rawValue
            P.setValue("grouping", value, in: group, order: Order.group)
        }
        if chart.kind == .column || chart.kind == .bar {
            if chart.gapWidth != base.gapWidth {
                P.setOptionalValue("gapWidth", chart.gapWidth.map(String.init), in: group, order: Order.group)
            }
            // Stacked bars must overlap completely, as the writer has them.
            func overlap(_ chart: Chart) -> Int? { chart.grouping == .standard ? chart.overlap : 100 }
            if overlap(chart) != overlap(base) {
                P.setOptionalValue("overlap", overlap(chart).map(String.init), in: group, order: Order.group)
            }
        }
        if chart.kind == .doughnut, chart.holeSize != base.holeSize {
            P.setValue("holeSize", String(min(max(chart.holeSize, 10), 90)), in: group, order: Order.group)
        }
        if chart.kind.isRadial, chart.firstSliceAngle != base.firstSliceAngle {
            P.setValue("firstSliceAng", String(chart.firstSliceAngle), in: group, order: Order.group)
        }

        guard series(in: group) else { return false }
        if chart.dataLabels != base.dataLabels { labels(group) }
        if !chart.kind.isRadial { axes(of: group, in: plotArea) }
        return true
    }

    // MARK: Series

    private func series(in group: XMLElement) -> Bool {
        // Matched to the model as the reader matched them: by `order`.
        let elements = group.children(named: "ser")
            .map { (order: Int($0.firstChild(named: "order")?.attribute("val") ?? "") ?? 0, element: $0) }
            .enumerated().sorted { ($0.element.order, $0.offset) < ($1.element.order, $1.offset) }
            .map(\.element.element)
        guard elements.count == base.series.count else { return false }
        var byID: [UUID: (element: XMLElement, old: ChartSeries)] = [:]
        for (element, old) in zip(elements, base.series) { byID[old.id] = (element, old) }

        var nextIndex = (elements.compactMap { $0.firstChild(named: "idx")?.attribute("val").flatMap(Int.init) }
            .max() ?? -1) + 1
        var ordered: [XMLElement] = []
        for (position, entry) in chart.series.enumerated() {
            let element: XMLElement
            if let match = byID[entry.id] {
                element = match.element
                patch(element, to: entry, from: match.old)
            } else {
                // A series added since: written whole, numbered past the rest.
                let xml = ChartWriter.seriesElement(entry, index: nextIndex, chart: chart, workbook: workbook)
                guard let fresh = P.make(xml) else { return false }
                nextIndex += 1
                element = fresh
            }
            P.setValue("order", String(position), in: element, order: Order.series)
            ordered.append(element)
        }

        // The series run as one block in the plot, in their new order.
        for element in elements { group.removeChild(element) }
        let seriesSlot = Order.group.firstIndex(of: "ser") ?? 0
        let firstIndex = group.children.firstIndex { child in
            (Order.group.firstIndex(of: child.name) ?? Order.group.count) > seriesSlot
        } ?? group.children.count
        for (offset, element) in ordered.enumerated() { group.insertChild(element, at: firstIndex + offset) }
        return true
    }

    private func patch(_ element: XMLElement, to series: ChartSeries, from old: ChartSeries) {
        // The data follows the sheet, so it is rewritten every time.
        if let name = ChartWriter.seriesName(series, chart: chart, workbook: workbook) {
            P.replace("tx", in: element, with: name, order: Order.series)
        } else {
            P.remove("tx", from: element)
        }
        let categoryName = chart.kind == .scatter ? "xVal" : "cat"
        if let categories = ChartWriter.seriesCategories(series, chart: chart, workbook: workbook) {
            P.replace(categoryName, in: element, with: categories, order: Order.series)
        } else {
            P.remove(categoryName, from: element)
        }
        let values = ChartWriter.seriesValues(series, chart: chart, workbook: workbook)
        P.replace(chart.kind == .scatter ? "yVal" : "val", in: element, with: values, order: Order.series)

        if usesLine {
            lineStyle(element, to: series, from: old)
        } else if series.colorHex != old.colorHex {
            let shape = P.child("spPr", of: element, order: Order.series)
            P.replaceFill(in: shape, with: series.colorHex.map(ChartWriter.solidFill), order: Order.shape)
        }
        pointColors(element, to: series, from: old)
    }

    private func lineStyle(_ element: XMLElement, to series: ChartSeries, from old: ChartSeries) {
        if series.showsLine != old.showsLine || series.colorHex != old.colorHex || series.lineWidth != old.lineWidth {
            let line = P.child("ln", of: P.child("spPr", of: element, order: Order.series), order: Order.shape)
            if series.showsLine != old.showsLine || series.colorHex != old.colorHex {
                let fill: String?
                if series.showsLine {
                    // A scatter chart drawn as markers alone has no line to
                    // fall back on, so a line turned on needs a colour.
                    let index = Int(element.firstChild(named: "idx")?.attribute("val") ?? "") ?? 0
                    let color = series.colorHex
                        ?? ChartPalette.color(at: index, accents: workbook.themeAccentColors)
                    fill = series.colorHex != nil || !old.showsLine ? ChartWriter.solidFill(color) : nil
                } else {
                    fill = "<a:noFill/>"
                }
                P.replaceFill(in: line, with: fill, order: Order.line)
            }
            if series.lineWidth != old.lineWidth {
                line.setAttribute("w", series.lineWidth.map { String(Int(($0 * ChartWriter.emusPerPoint).rounded())) })
            }
        }

        if series.showsMarkers != old.showsMarkers {
            let marker = P.child("marker", of: element, order: Order.series)
            let symbol = marker.firstChild(named: "symbol")?.attribute("val")
            if !series.showsMarkers {
                P.setValue("symbol", "none", in: marker, order: Order.marker)
            } else if symbol == nil || symbol == "none" {
                P.setValue("symbol", "circle", in: marker, order: Order.marker)
            }
            if chart.kind == .line, series.showsMarkers,
               let group = element.parent, let shown = group.firstChild(named: "marker"), ChartReader.flag(shown) == false {
                shown.setAttribute("val", "1")
            }
        }
        if series.showsMarkers, series.colorHex != old.colorHex || series.showsMarkers != old.showsMarkers,
           let color = series.colorHex {
            let marker = P.child("marker", of: element, order: Order.series)
            let shape = P.child("spPr", of: marker, order: Order.marker)
            P.replaceFill(in: shape, with: ChartWriter.solidFill(color), order: Order.shape)
            P.replaceFill(in: P.child("ln", of: shape, order: Order.shape), with: ChartWriter.solidFill(color), order: Order.line)
        }
        if series.isSmooth != old.isSmooth {
            P.setValue("smooth", P.flag(series.isSmooth), in: element, order: Order.series)
        }
    }

    private func pointColors(_ element: XMLElement, to series: ChartSeries, from old: ChartSeries) {
        let changed = Set(series.pointColors.keys).union(old.pointColors.keys)
            .filter { series.pointColors[$0] != old.pointColors[$0] }.sorted()
        for index in changed {
            let points = element.children(named: "dPt")
            func pointIndex(_ point: XMLElement) -> Int? {
                point.firstChild(named: "idx")?.attribute("val").flatMap(Int.init)
            }
            let existing = points.first { pointIndex($0) == index }

            guard let color = series.pointColors[index] else {
                // Back to the series colour: the override goes, and the point
                // with it if the colour was all it held.
                guard let existing, let shape = existing.firstChild(named: "spPr") else { continue }
                P.replaceFill(in: shape, with: nil, order: Order.shape)
                if usesLine, let line = shape.firstChild(named: "ln") { P.replaceFill(in: line, with: nil, order: Order.line) }
                if shape.children.allSatisfy({ $0.name == "ln" && $0.children.isEmpty }) { existing.removeChild(shape) }
                if existing.children.allSatisfy({ ["idx", "bubble3D", "invertIfNegative"].contains($0.name) }) {
                    element.removeChild(existing)
                }
                continue
            }

            let point: XMLElement
            if let existing {
                point = existing
            } else {
                var xml = "<c:dPt><c:idx val=\"\(index)\"/>"
                if chart.kind.isRadial { xml += "<c:bubble3D val=\"0\"/>" }
                guard let fresh = P.make(xml + "</c:dPt>") else { continue }
                // Kept in point order, which is how Excel lists them.
                if let next = points.first(where: { (pointIndex($0) ?? 0) > index }),
                   let position = element.children.firstIndex(where: { $0 === next }) {
                    element.insertChild(fresh, at: position)
                } else {
                    P.insert(fresh, into: element, order: Order.series)
                }
                point = fresh
            }
            let shape = P.child("spPr", of: point, order: Order.point)
            if usesLine {
                P.replaceFill(in: P.child("ln", of: shape, order: Order.shape), with: ChartWriter.solidFill(color), order: Order.line)
            } else {
                P.replaceFill(in: shape, with: ChartWriter.solidFill(color), order: Order.shape)
            }
        }
    }

    // MARK: Data labels

    /// The model has one set of labels for the chart, so a change to it is
    /// written to the plot's labels and to every series that has its own.
    /// Formatting and labels on single points are left alone.
    private func labels(_ group: XMLElement) {
        let labels = chart.dataLabels
        func apply(to element: XMLElement) {
            P.remove("delete", from: element)
            P.setValue("showVal", P.flag(labels.showsValue), in: element, order: Order.labels)
            P.setValue("showCatName", P.flag(labels.showsCategoryName), in: element, order: Order.labels)
            P.setValue("showSerName", P.flag(labels.showsSeriesName), in: element, order: Order.labels)
            P.setValue(
                "showPercent", P.flag(labels.showsPercentage && chart.kind.isRadial), in: element, order: Order.labels
            )
        }
        if let element = group.firstChild(named: "dLbls") {
            apply(to: element)
        } else if let fresh = P.make(ChartWriter.dataLabels(labels, kind: chart.kind)) {
            P.insert(fresh, into: group, order: Order.group)
        }
        for series in group.children(named: "ser") {
            if let element = series.firstChild(named: "dLbls") { apply(to: element) }
        }
    }

    // MARK: Axes

    private func axes(of group: XMLElement, in plotArea: XMLElement) {
        let ids = group.children(named: "axId").compactMap { $0.attribute("val") }
        guard ids.count == 2 else { return }
        func axis(_ id: String) -> XMLElement? {
            plotArea.children.first { element in
                ["catAx", "valAx", "dateAx"].contains(element.name)
                    && element.firstChild(named: "axId")?.attribute("val") == id
            }
        }
        let isBar = chart.kind == .bar
        if let category = axis(ids[0]) {
            patch(category, to: chart.categoryAxis, from: base.categoryAxis, isVertical: isBar)
            if chart.kind != base.kind { P.setValue("axPos", isBar ? "l" : "b", in: category, order: Order.axis) }
        }
        if let value = axis(ids[1]) {
            patch(value, to: chart.valueAxis, from: base.valueAxis, isVertical: !isBar)
            if chart.kind != base.kind { P.setValue("axPos", isBar ? "b" : "l", in: value, order: Order.axis) }
        }
    }

    private func patch(_ element: XMLElement, to axis: ChartAxis, from old: ChartAxis, isVertical: Bool) {
        if axis.isVisible != old.isVisible {
            P.setValue("delete", P.flag(!axis.isVisible), in: element, order: Order.axis)
        }
        if axis.showsMajorGridlines != old.showsMajorGridlines {
            if axis.showsMajorGridlines, let fresh = P.make(ChartWriter.majorGridlines) {
                P.insert(fresh, into: element, order: Order.axis)
            } else {
                P.remove("majorGridlines", from: element)
            }
        }
        if axis.minimum != old.minimum || axis.maximum != old.maximum || axis.isReversed != old.isReversed {
            let scaling = P.child("scaling", of: element, order: Order.axis)
            P.setValue("orientation", axis.isReversed ? "maxMin" : "minMax", in: scaling, order: Order.scaling)
            P.setOptionalValue("max", axis.maximum.map(ChartWriter.numberText), in: scaling, order: Order.scaling)
            P.setOptionalValue("min", axis.minimum.map(ChartWriter.numberText), in: scaling, order: Order.scaling)
        }
        // A category axis spaces its labels by count, not by a unit.
        if axis.majorUnit != old.majorUnit, element.name != "catAx" {
            let unit = axis.majorUnit.flatMap { $0 > 0 ? ChartWriter.numberText($0) : nil }
            P.setOptionalValue("majorUnit", unit, in: element, order: Order.axis)
        }
        if axis.numberFormat != old.numberFormat {
            if let format = axis.numberFormat {
                let xml = "<c:numFmt formatCode=\"\(XMLLite.escape(format))\" sourceLinked=\"0\"/>"
                P.replace("numFmt", in: element, with: xml, order: Order.axis)
            } else if let existing = element.firstChild(named: "numFmt") {
                existing.setAttribute("sourceLinked", "1")
            }
        }
        if axis.title != old.title {
            if let title = axis.title {
                patchTitle(
                    title, over: old.title, isVertical: isVertical, in: element,
                    existing: element.firstChild(named: "title"), order: Order.axis
                )
            } else {
                P.remove("title", from: element)
            }
        }
        P.patchTextBody(of: element, to: axis.textStyle, from: old.textStyle, order: Order.axis)
    }
}
