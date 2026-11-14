import Foundation

/// Reads and writes Excel 2010's sparklines: the `x14:sparklineGroups` a
/// worksheet keeps in an `ext` of its `extLst`.
public enum SparklineParts {
    public static let extensionURI = "{05C60535-1F16-4fd2-B633-F4F36F0B64E0}"
    static let x14Namespace = "http://schemas.microsoft.com/office/spreadsheetml/2009/9/main"
    static let xmNamespace = "http://schemas.microsoft.com/office/excel/2006/main"

    /// The `ext`s that hold sparklines, the ones the model takes over.
    static func isSparklineExtension(_ ext: XMLElement) -> Bool {
        ext.children.contains { $0.name == "sparklineGroups" }
    }

    // MARK: - Reading

    /// Every sparkline group in a worksheet's `extLst`.
    static func groups(in worksheet: XMLElement, theme: ThemeColorScheme, palette: [String]) -> [SparklineGroup] {
        let exts = worksheet.firstChild(named: "extLst")?.children(named: "ext") ?? []
        return exts.flatMap { ext in
            ext.children(named: "sparklineGroups").flatMap { $0.children(named: "sparklineGroup") }
        }.compactMap { group(from: $0, theme: theme, palette: palette) }
    }

    private static let modelledAttributes: Set<String> = [
        "type", "lineWeight", "displayEmptyCellsAs", "markers", "high", "low", "first", "last", "negative",
        "displayXAxis", "displayHidden", "rightToLeft", "dateAxis", "minAxisType", "maxAxisType",
        "manualMin", "manualMax",
    ]

    static func group(from element: XMLElement, theme: ThemeColorScheme, palette: [String]) -> SparklineGroup? {
        var group = SparklineGroup()
        func flag(_ name: String) -> Bool { ["1", "true"].contains(element.attribute(name) ?? "") }
        group.kind = element.attribute("type").flatMap(SparklineGroup.Kind.init) ?? .line
        group.lineWeight = element.attribute("lineWeight").flatMap(Double.init) ?? 0.75
        group.emptyCells = element.attribute("displayEmptyCellsAs").flatMap(SparklineGroup.EmptyCells.init) ?? .zero
        group.markers = flag("markers")
        group.high = flag("high")
        group.low = flag("low")
        group.first = flag("first")
        group.last = flag("last")
        group.negative = flag("negative")
        group.displaysXAxis = flag("displayXAxis")
        group.displaysHidden = flag("displayHidden")
        group.rightToLeft = flag("rightToLeft")
        group.dateAxis = flag("dateAxis")
        group.minAxis = element.attribute("minAxisType").flatMap(SparklineGroup.AxisScale.init) ?? .individual
        group.maxAxis = element.attribute("maxAxisType").flatMap(SparklineGroup.AxisScale.init) ?? .individual
        group.manualMin = element.attribute("manualMin").flatMap(Double.init)
        group.manualMax = element.attribute("manualMax").flatMap(Double.init)
        for (key, value) in element.qualifiedAttributes
        where !key.hasPrefix("xmlns") && !modelledAttributes.contains(key) {
            group.otherAttributes[key] = value
        }

        func color(_ name: String) -> SparklineColor? {
            guard let child = element.firstChild(named: name) else { return nil }
            return SparklineColor(
                attributes: child.attributes,
                hex: ThemeColorPalette.resolvedARGB(from: child, theme: theme, indexed: palette)
            )
        }
        group.seriesColor = color("colorSeries")
        group.negativeColor = color("colorNegative")
        group.axisColor = color("colorAxis")
        group.markersColor = color("colorMarkers")
        group.firstColor = color("colorFirst")
        group.lastColor = color("colorLast")
        group.highColor = color("colorHigh")
        group.lowColor = color("colorLow")
        group.dateFormula = element.firstChild(named: "f")?.text.trimmed

        for sparkline in element.firstChild(named: "sparklines")?.children(named: "sparkline") ?? [] {
            guard let formula = sparkline.firstChild(named: "f")?.text.trimmed, !formula.isEmpty,
                  let sqref = sparkline.firstChild(named: "sqref")?.text.trimmed,
                  let location = CellAddress(a1: sqref.replacingOccurrences(of: "$", with: "")) else { continue }
            group.sparklines.append(Sparkline(formula: formula, location: location))
        }
        return group.sparklines.isEmpty ? nil : group
    }

    // MARK: - Writing

    /// The `ext` holding `groups`, declaring the prefixes it uses.
    static func extensionXML(_ groups: [SparklineGroup]) -> String {
        var xml = "<ext uri=\"\(extensionURI)\" xmlns:x14=\"\(x14Namespace)\">"
        xml += "<x14:sparklineGroups xmlns:xm=\"\(xmNamespace)\">"
        for group in groups { xml += groupXML(group) }
        xml += "</x14:sparklineGroups></ext>"
        return xml
    }

    private static func format(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
    }

    static func groupXML(_ group: SparklineGroup) -> String {
        var attributes: [(String, String)] = []
        if group.manualMax != nil { attributes.append(("manualMax", format(group.manualMax!))) }
        if group.manualMin != nil { attributes.append(("manualMin", format(group.manualMin!))) }
        if group.lineWeight != 0.75 { attributes.append(("lineWeight", format(group.lineWeight))) }
        if group.kind != .line { attributes.append(("type", group.kind.rawValue)) }
        if group.dateAxis { attributes.append(("dateAxis", "1")) }
        if group.emptyCells != .zero { attributes.append(("displayEmptyCellsAs", group.emptyCells.rawValue)) }
        for (name, on) in [("markers", group.markers), ("high", group.high), ("low", group.low),
                           ("first", group.first), ("last", group.last), ("negative", group.negative),
                           ("displayXAxis", group.displaysXAxis), ("displayHidden", group.displaysHidden)] where on {
            attributes.append((name, "1"))
        }
        if group.minAxis != .individual { attributes.append(("minAxisType", group.minAxis.rawValue)) }
        if group.maxAxis != .individual { attributes.append(("maxAxisType", group.maxAxis.rawValue)) }
        if group.rightToLeft { attributes.append(("rightToLeft", "1")) }
        // Unmodelled attributes, such as revision ids, keep their namespace
        // only when it is one the fragment declares; anything else is dropped.
        for (key, value) in group.otherAttributes.sorted(by: { $0.key < $1.key })
        where !key.contains(":") || key.hasPrefix("x14:") || key.hasPrefix("xm:") {
            attributes.append((key, value))
        }

        var xml = "<x14:sparklineGroup"
        for (name, value) in attributes { xml += " \(name)=\"\(XMLLite.escape(value))\"" }
        xml += ">"
        for (name, color) in [("colorSeries", group.seriesColor), ("colorNegative", group.negativeColor),
                              ("colorAxis", group.axisColor), ("colorMarkers", group.markersColor),
                              ("colorFirst", group.firstColor), ("colorLast", group.lastColor),
                              ("colorHigh", group.highColor), ("colorLow", group.lowColor)] {
            guard let color else { continue }
            xml += "<x14:\(name)"
            for (key, value) in color.attributes.sorted(by: { $0.key < $1.key }) {
                xml += " \(key)=\"\(XMLLite.escape(value))\""
            }
            xml += "/>"
        }
        if let date = group.dateFormula, !date.isEmpty { xml += "<xm:f>\(XMLLite.escape(date))</xm:f>" }
        xml += "<x14:sparklines>"
        for sparkline in group.sparklines {
            xml += "<x14:sparkline><xm:f>\(XMLLite.escape(sparkline.formula))</xm:f>"
            xml += "<xm:sqref>\(sparkline.location.a1)</xm:sqref></x14:sparkline>"
        }
        xml += "</x14:sparklines></x14:sparklineGroup>"
        return xml
    }

    /// The extensions Excel writes ahead of sparklines; anything else follows them.
    private static let leadingExtensionURIs: Set<String> = [
        "{78C0D931-6437-407d-A8EE-F0AAD7539E65}", // conditional formats
        "{CCE6A557-97BC-4b89-ADB6-D9C93CAAB3DF}", // data validations
    ]

    /// A sheet's kept fragments with its sparklines written into the
    /// `extLst`: the one the file had, or one of our own.
    static func addingSparklines(_ groups: [SparklineGroup], to elements: [PreservedElement]) -> [PreservedElement] {
        guard !groups.isEmpty else { return elements }
        var elements = elements
        let ext = extensionXML(groups)
        if let index = elements.firstIndex(where: { $0.name == "extLst" }),
           let list = try? XMLLite.parse(Data(elements[index].xml.utf8)),
           let node = XMLLite.fragment(ext, namespaces: [:]) {
            let position = list.children.lastIndex {
                leadingExtensionURIs.contains($0.attribute("uri") ?? "")
            }.map { $0 + 1 } ?? 0
            list.insertChild(node, at: position)
            if let xml = XMLLite.serialize(list) {
                elements[index] = PreservedElement(name: "extLst", xml: xml)
                return elements
            }
        }
        elements.removeAll { $0.name == "extLst" }
        elements.append(PreservedElement(name: "extLst", xml: "<extLst>\(ext)</extLst>"))
        return elements
    }
}
