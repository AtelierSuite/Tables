import Foundation

/// A shape on a sheet's drawing that Tables can draw: one of the basic
/// presets, with a plain fill, an outline and text.
///
/// The anchor's XML stays what is written to the file; this is only what was
/// read out of it to draw the shape with.
public struct DrawingShape: Hashable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case rectangle, roundedRectangle, ellipse, line, arrow, textBox

        /// Lines and arrows have no inside: no fill, and no text.
        public var isLine: Bool { self == .line || self == .arrow }
    }

    public enum TextAlignment: String, Sendable { case leading, center, trailing }
    public enum TextAnchor: String, Sendable { case top, center, bottom }

    public var kind: Kind
    /// Six-digit RGB, or `nil` for no fill.
    public var fillHex: String?
    /// Six-digit RGB, or `nil` for no outline.
    public var outlineHex: String?
    /// The outline's width in points.
    public var outlineWidth: Double
    /// The shape's text, its paragraphs separated by newlines.
    public var text: String
    public var textHex: String
    /// The text's size in points.
    public var fontSize: Double
    public var textAlignment: TextAlignment
    public var textAnchor: TextAnchor
    /// A line runs from the top-left of its box to the bottom-right unless
    /// it is flipped.
    public var flipsHorizontally = false
    public var flipsVertically = false
    /// Degrees clockwise about the shape's centre.
    public var rotation = 0.0
    public var hasArrowAtStart = false
    public var hasArrowAtEnd = false

    public init(
        kind: Kind, fillHex: String?, outlineHex: String?, outlineWidth: Double = 1,
        text: String = "", textHex: String = "000000", fontSize: Double = 11,
        textAlignment: TextAlignment = .leading, textAnchor: TextAnchor = .top
    ) {
        self.kind = kind
        self.fillHex = fillHex
        self.outlineHex = outlineHex
        self.outlineWidth = outlineWidth
        self.text = text
        self.textHex = textHex
        self.fontSize = fontSize
        self.textAlignment = textAlignment
        self.textAnchor = textAnchor
    }
}

// MARK: - Reading

extension DrawingShape {
    /// The shape an anchor holds, when it is one of the kinds drawn here.
    /// Anything else — a group, a preset outside the basic set, a picture
    /// or pattern fill — stays a kept object shown as a placeholder.
    public static func read(from anchor: XMLElement, theme: ThemeColorScheme) -> DrawingShape? {
        guard let object = anchor.children.first(where: { $0.name == "sp" || $0.name == "cxnSp" }),
              let properties = object.firstChild(named: "spPr"),
              let preset = properties.firstChild(named: "prstGeom")?.attribute("prst") else { return nil }
        let nonVisual = object.children.first { $0.name.hasPrefix("nv") }
        guard nonVisual?.firstChild(named: "cNvPr")?.attribute("hidden") != "1" else { return nil }
        let isTextBox = ["1", "true"].contains(nonVisual?.firstChild(named: "cNvSpPr")?.attribute("txBox") ?? "")
        let style = object.firstChild(named: "style")
        let line = properties.firstChild(named: "ln")

        let kind: Kind
        switch preset {
        case "rect": kind = isTextBox ? .textBox : .rectangle
        case "roundRect": kind = .roundedRectangle
        case "ellipse": kind = .ellipse
        case "line", "straightConnector1":
            let ends = ["headEnd", "tailEnd"].compactMap { line?.firstChild(named: $0)?.attribute("type") }
            kind = ends.contains { $0 != "none" } ? .arrow : .line
        default: return nil
        }

        func rgb(_ fill: XMLElement?) -> String? {
            guard let fill, let color = ChartReader.color(fill, theme: theme), color.count == 8,
                  !color.hasPrefix("00") else { return nil }
            return String(color.suffix(6))
        }
        /// A reference into the theme's fill or line styles: index 0 is none.
        func styled(_ name: String) -> XMLElement? {
            guard let reference = style?.firstChild(named: name),
                  (reference.attribute("idx").flatMap(Int.init) ?? 0) > 0 else { return nil }
            return reference
        }

        var fillHex: String?
        if !kind.isLine {
            let fills = properties.children.filter { Self.fillNames.contains($0.name) }
            if let fill = fills.first {
                switch fill.name {
                case "noFill": fillHex = nil
                case "solidFill": fillHex = rgb(fill)
                case "gradFill":
                    // Drawn in its first colour: near enough to see what it is.
                    fillHex = rgb(fill.firstDescendant(atPath: "gsLst/gs"))
                default: return nil
                }
            } else {
                fillHex = rgb(styled("fillRef"))
            }
        }

        var outlineHex: String?
        var outlineWidth = 0.75
        if let fill = line?.children.first(where: { Self.fillNames.contains($0.name) }) {
            outlineHex = fill.name == "solidFill" ? rgb(fill) : nil
        } else if let reference = styled("lnRef") {
            outlineHex = rgb(reference)
            // Office's themes step their three line styles up by half a point.
            outlineWidth = Double(reference.attribute("idx").flatMap(Int.init) ?? 1) * 0.5
        }
        if let width = line?.attribute("w").flatMap(Double.init) { outlineWidth = width / 12_700 }

        var shape = DrawingShape(kind: kind, fillHex: fillHex, outlineHex: outlineHex, outlineWidth: outlineWidth,
                                 textAlignment: .leading, textAnchor: .top)
        if let transform = properties.firstChild(named: "xfrm") {
            shape.flipsHorizontally = ["1", "true"].contains(transform.attribute("flipH") ?? "")
            shape.flipsVertically = ["1", "true"].contains(transform.attribute("flipV") ?? "")
            // Sixty-thousandths of a degree.
            shape.rotation = (transform.attribute("rot").flatMap(Double.init) ?? 0) / 60_000
        }
        func hasArrow(_ name: String) -> Bool {
            (line?.firstChild(named: name)?.attribute("type")).map { $0 != "none" } ?? false
        }
        shape.hasArrowAtStart = hasArrow("headEnd")
        shape.hasArrowAtEnd = hasArrow("tailEnd")

        if let body = object.firstChild(named: "txBody") {
            let paragraphs = body.children(named: "p")
            shape.text = paragraphs.map { paragraph in
                paragraph.children.map { run in
                    switch run.name {
                    case "r", "fld": run.firstChild(named: "t")?.text ?? ""
                    case "br": "\n"
                    default: ""
                    }
                }.joined()
            }.joined(separator: "\n")
            let run = paragraphs.lazy.compactMap { $0.firstChild(named: "r")?.firstChild(named: "rPr") }.first
                ?? paragraphs.first?.firstChild(named: "endParaRPr")
            if let size = run?.attribute("sz").flatMap(Double.init) { shape.fontSize = size / 100 }
            if let color = rgb(run?.firstChild(named: "solidFill")) ?? rgb(style?.firstChild(named: "fontRef")) {
                shape.textHex = color
            }
            switch paragraphs.first?.firstChild(named: "pPr")?.attribute("algn") {
            case "ctr": shape.textAlignment = .center
            case "r": shape.textAlignment = .trailing
            default: shape.textAlignment = .leading
            }
            switch body.firstChild(named: "bodyPr")?.attribute("anchor") {
            case "ctr": shape.textAnchor = .center
            case "b": shape.textAnchor = .bottom
            default: shape.textAnchor = .top
            }
        }
        return shape
    }

    static let fillNames: Set<String> = ["noFill", "solidFill", "gradFill", "blipFill", "pattFill", "grpFill"]
}
