import Foundation

/// Reading and writing text made of runs: the `<r>` children of a shared
/// string's `<si>` or an inline string's `<is>`, each with the font its
/// `<rPr>` describes.
public enum RichTextParts {
    static let mainNamespace = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"

    // MARK: - Reading

    /// A workbook's shared strings: the text of each, and the runs of those
    /// that have any. Runs are held apart so a workbook of plain strings
    /// carries nothing for them.
    public struct StringTable {
        public var texts: [String] = []
        public var richTexts: [Int: RichText] = [:]
        let colors: ColorSource
    }

    /// What a run's `<color>` is resolved against. The stylesheet is only
    /// parsed for its palette when a run names a colour by index.
    final class ColorSource {
        let theme: ThemeColorScheme
        private let styleSheet: Data?
        private var palette: [String]?

        init(theme: ThemeColorScheme, styleSheet: Data?) {
            self.theme = theme
            self.styleSheet = styleSheet
        }

        func resolved(_ element: XMLElement?) -> String? {
            guard let element else { return nil }
            if element.attribute("indexed") != nil, palette == nil {
                palette = ThemeColorPalette.indexedColors(styleSheet: styleSheet.flatMap { try? XMLLite.parse($0) })
            }
            return ThemeColorPalette.resolvedARGB(
                from: element, theme: theme, indexed: palette ?? ThemeColorPalette.indexedColors
            )
        }
    }

    public static func stringTable(_ data: Data?, theme: ThemeColorScheme, styleSheet: Data?) -> StringTable {
        var table = StringTable(colors: ColorSource(theme: theme, styleSheet: styleSheet))
        guard let data, let root = try? XMLLite.parse(data) else { return table }
        let items = root.children(named: "si")
        table.texts.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            let (text, richText) = string(in: item, colors: table.colors)
            table.texts.append(text)
            if let richText { table.richTexts[index] = richText }
        }
        return table
    }

    /// The text of an `<si>` or `<is>`, and its runs when any has a font of
    /// its own. Runs that all take the cell's font are just text.
    static func string(in item: XMLElement, colors: ColorSource) -> (text: String, richText: RichText?) {
        if let direct = item.firstChild(named: "t") { return (direct.text, nil) }
        let elements = item.children(named: "r")
        guard elements.contains(where: { $0.firstChild(named: "rPr") != nil }) else {
            return (elements.compactMap { $0.firstChild(named: "t")?.text }.joined(), nil)
        }
        let runs = elements.map { element in
            TextRun(
                text: element.firstChild(named: "t")?.text ?? "",
                font: element.firstChild(named: "rPr").map { font(from: $0, colors: colors) }
            )
        }
        let richText = RichText(runs: runs)
        return (richText.plainText, richText)
    }

    private static func font(from properties: XMLElement, colors: ColorSource) -> RunFont {
        func flag(_ name: String) -> Bool {
            guard let element = properties.firstChild(named: name) else { return false }
            let value = element.attribute("val") ?? "1"
            return value != "0" && value != "false"
        }
        var font = RunFont()
        font.isBold = flag("b")
        font.isItalic = flag("i")
        font.isStruckThrough = flag("strike")
        if let underline = properties.firstChild(named: "u") {
            font.isUnderlined = underline.attribute("val") != "none"
        }
        font.fontName = properties.firstChild(named: "rFont")?.attribute("val")
        font.fontSize = properties.firstChild(named: "sz")?.attribute("val").flatMap(Double.init)
        font.colorHex = colors.resolved(properties.firstChild(named: "color"))
        if let alignment = properties.firstChild(named: "vertAlign")?.attribute("val") {
            font.verticalAlignment = RunVerticalAlignment(rawValue: alignment) ?? .baseline
        }
        font.preservedXML = XMLLite.serialize(properties, inheritedNamespaces: ["": mainNamespace])
        return font
    }

    // MARK: - Writing

    /// The `<r>` elements of a string's runs, for an `<si>`.
    static func xml(for richText: RichText) -> String {
        var xml = ""
        for run in richText.runs {
            xml += "<r>"
            if let font = run.font { xml += font.preservedXML ?? propertiesXML(for: font) }
            xml += "<t xml:space=\"preserve\">\(XMLLite.escape(run.text))</t></r>"
        }
        return xml
    }

    /// An `<rPr>` for a font that did not come with one, its children in the
    /// order Excel writes them.
    private static func propertiesXML(for font: RunFont) -> String {
        var xml = "<rPr>"
        if font.isBold { xml += "<b/>" }
        if font.isItalic { xml += "<i/>" }
        if font.isStruckThrough { xml += "<strike/>" }
        if font.isUnderlined { xml += "<u/>" }
        if font.verticalAlignment != .baseline { xml += "<vertAlign val=\"\(font.verticalAlignment.rawValue)\"/>" }
        if let size = font.fontSize { xml += "<sz val=\"\(XLSXWriter.format(size))\"/>" }
        if let color = font.colorHex { xml += "<color rgb=\"\(color)\"/>" }
        if let name = font.fontName { xml += "<rFont val=\"\(XMLLite.escape(name))\"/>" }
        return xml + "</rPr>"
    }
}
