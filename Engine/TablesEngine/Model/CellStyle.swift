import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif

public enum HorizontalTextAlignment: String, Hashable, Sendable, CaseIterable {
    case automatic, leading, center, trailing

    public var symbolName: String {
        switch self {
        case .automatic: return "text.alignleft"
        case .leading: return "text.alignleft"
        case .center: return "text.aligncenter"
        case .trailing: return "text.alignright"
        }
    }

    public var label: String {
        switch self {
        case .automatic: return String(localized: "Alignment.Horizontal.Automatic", bundle: .engine)
        case .leading: return String(localized: "Alignment.Horizontal.Left", bundle: .engine)
        case .center: return String(localized: "Alignment.Horizontal.Center", bundle: .engine)
        case .trailing: return String(localized: "Alignment.Horizontal.Right", bundle: .engine)
        }
    }
}

/// Excel's horizontal alignments beyond left, centre and right. A style
/// with one keeps the nearest of those in `horizontalAlignment`, which
/// whatever does not know the spread falls back to, and which the
/// alignment pickers show.
public enum HorizontalTextSpread: String, Hashable, Sendable {
    /// Wrapped, and each line but a paragraph's last stretched to both edges.
    case justify
    /// Wrapped, and every line stretched to both edges: between its words,
    /// or between its characters when it has a single word, as Japanese is.
    /// One that cannot be stretched is centred. Indents both edges.
    case distributed
    /// Centred across the cell and the empty cells after it that are set
    /// the same way, OOXML's `centerContinuous`.
    case centerAcrossSelection
}

/// Excel's vertical alignments beyond top, middle and bottom: wrapped text
/// whose lines are spread from the top of the cell to its bottom. A single
/// line sits at the top for `justify` and in the middle for `distributed`,
/// which `verticalAlignment` holds.
public enum VerticalTextSpread: String, Hashable, Sendable {
    case justify, distributed
}

public enum VerticalTextAlignment: String, Hashable, Sendable, CaseIterable {
    case top, middle, bottom

    public var symbolName: String {
        switch self {
        case .top: return "arrow.up.to.line"
        case .middle: return "arrow.down.and.line.horizontal.and.arrow.up"
        case .bottom: return "arrow.down.to.line"
        }
    }

    public var label: String {
        switch self {
        case .top: return String(localized: "Alignment.Vertical.Top", bundle: .engine)
        case .middle: return String(localized: "Alignment.Vertical.Middle", bundle: .engine)
        case .bottom: return String(localized: "Alignment.Vertical.Bottom", bundle: .engine)
        }
    }

    #if canImport(SwiftUI)
    public var alignment: Alignment {
        switch self {
        case .top: return .top
        case .middle: return .center
        case .bottom: return .bottom
        }
    }
    #endif
}

public struct BorderEdges: OptionSet, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }
    public static let top = BorderEdges(rawValue: 1 << 0)
    public static let leading = BorderEdges(rawValue: 1 << 1)
    public static let bottom = BorderEdges(rawValue: 1 << 2)
    public static let trailing = BorderEdges(rawValue: 1 << 3)
    public static let all: BorderEdges = [.top, .leading, .bottom, .trailing]
}

/// A single side of a cell's border box, as a discrete case rather than a set.
///
/// `BorderEdges` stays the API the formatting UI works in, but a per-edge line
/// style and colour need a hashable key, and an OptionSet member is a poor one.
public enum BorderEdge: String, Hashable, Sendable, CaseIterable {
    case top, leading, bottom, trailing

    /// The matching `BorderEdges` member, for bridging between the two.
    public var edges: BorderEdges {
        switch self {
        case .top: return .top
        case .leading: return .leading
        case .bottom: return .bottom
        case .trailing: return .trailing
        }
    }

    /// The OOXML element name for this side inside `<border>`.
    public var ooxmlTag: String {
        switch self {
        case .top: return "top"
        case .leading: return "left"
        case .bottom: return "bottom"
        case .trailing: return "right"
        }
    }
}

/// OOXML's `ST_BorderStyle` less `none`, which is modelled as the absence of a side.
///
/// Raw values are the OOXML tokens verbatim so reading and writing are a
/// straight `init(rawValue:)` / `rawValue` and no lossy mapping table is needed.
public enum BorderLineStyle: String, Hashable, Sendable, CaseIterable {
    case hair, thin, medium, thick, double
    case dotted, dashed, dashDot, dashDotDot
    case mediumDashed, mediumDashDot, mediumDashDotDot, slantDashDot

    /// Stroke width in points at 100% zoom.
    public var lineWidth: Double {
        switch self {
        case .hair: return 0.5
        case .thin, .dotted, .dashed, .dashDot, .dashDotDot: return 1
        case .medium, .mediumDashed, .mediumDashDot, .mediumDashDotDot, .slantDashDot: return 2
        case .thick: return 3
        case .double: return 1
        }
    }

    /// Dash lengths in points, empty for a solid stroke.
    public var dashPattern: [Double] {
        switch self {
        case .dotted: return [1, 2]
        case .dashed: return [3, 2]
        case .dashDot: return [4, 2, 1, 2]
        case .dashDotDot: return [4, 2, 1, 2, 1, 2]
        case .mediumDashed: return [4, 3]
        case .mediumDashDot: return [5, 3, 1, 3]
        case .mediumDashDotDot: return [5, 3, 1, 3, 1, 3]
        case .slantDashDot: return [5, 2, 1, 2]
        default: return []
        }
    }

    /// A double rule is drawn as two thin strokes this far apart, in points.
    public var doubleLineGap: Double? { self == .double ? 2 : nil }

    public var label: String {
        switch self {
        case .hair: return String(localized: "BorderLineStyle.Hairline", bundle: .engine)
        case .thin: return String(localized: "BorderLineStyle.Thin", bundle: .engine)
        case .medium: return String(localized: "BorderLineStyle.Medium", bundle: .engine)
        case .thick: return String(localized: "BorderLineStyle.Thick", bundle: .engine)
        case .double: return String(localized: "BorderLineStyle.Double", bundle: .engine)
        case .dotted: return String(localized: "BorderLineStyle.Dotted", bundle: .engine)
        case .dashed: return String(localized: "BorderLineStyle.Dashed", bundle: .engine)
        case .dashDot: return String(localized: "BorderLineStyle.DashDot", bundle: .engine)
        case .dashDotDot: return String(localized: "BorderLineStyle.DashDotDot", bundle: .engine)
        case .mediumDashed: return String(localized: "BorderLineStyle.MediumDashed", bundle: .engine)
        case .mediumDashDot: return String(localized: "BorderLineStyle.MediumDashDot", bundle: .engine)
        case .mediumDashDotDot: return String(localized: "BorderLineStyle.MediumDashDotDot", bundle: .engine)
        case .slantDashDot: return String(localized: "BorderLineStyle.SlantDashDot", bundle: .engine)
        }
    }
}

/// Which part of a cell's border box a formatting change addresses.
///
/// OOXML gives every side its own style and colour, so "the border colour" is
/// not a single value — this is how the formatting UI says which sides it means.
public enum BorderScope: String, Hashable, Identifiable, CaseIterable, Sendable {
    case all, top, leading, bottom, trailing, diagonal

    public var id: String { rawValue }

    public init(_ edge: BorderEdge) {
        switch edge {
        case .top: self = .top
        case .leading: self = .leading
        case .bottom: self = .bottom
        case .trailing: self = .trailing
        }
    }

    /// The box edge this scope names, or nil for `all` and `diagonal`.
    public var edge: BorderEdge? {
        switch self {
        case .top: return .top
        case .leading: return .leading
        case .bottom: return .bottom
        case .trailing: return .trailing
        case .all, .diagonal: return nil
        }
    }

    public var label: String {
        switch self {
        case .all: return String(localized: "Format.Border.Scope.All", bundle: .engine)
        case .top: return String(localized: "Format.Border.Top", bundle: .engine)
        case .leading: return String(localized: "Format.Border.Left", bundle: .engine)
        case .bottom: return String(localized: "Format.Border.Bottom", bundle: .engine)
        case .trailing: return String(localized: "Format.Border.Right", bundle: .engine)
        case .diagonal: return String(localized: "Format.Border.Scope.Diagonal", bundle: .engine)
        }
    }
}

/// One drawn border stroke: how it looks and what colour it is.
public struct BorderSide: Hashable, Sendable {
    public var lineStyle: BorderLineStyle = .thin
    /// OOXML "AARRGGBB". `nil` means the generator left the colour to the reader.
    public var colorHex: String?

    public init(lineStyle: BorderLineStyle = .thin, colorHex: String? = nil) {
        self.lineStyle = lineStyle
        self.colorHex = colorHex
    }
}

/// The `<diagonal>` rule, which is independent of the four box edges.
public struct DiagonalBorder: Hashable, Sendable {
    public var lineStyle: BorderLineStyle = .thin
    public var colorHex: String?
    /// Runs from the bottom-left corner to the top-right one.
    public var goesUp = false
    /// Runs from the top-left corner to the bottom-right one.
    public var goesDown = false

    /// A diagonal with neither direction set draws nothing, which is how Excel
    /// stores a `<diagonal>` whose style was cleared but whose element remains.
    public var isVisible: Bool { goesUp || goesDown }
}

/// Visual formatting for a single cell. Colours are stored as OOXML "AARRGGBB" hex.
public struct CellStyle: Hashable, Sendable {
    public var isBold = false
    public var isItalic = false
    public var isUnderlined = false
    public var isStruckThrough = false
    public var fontSize: Double = 12
    public var fontName: String = "Helvetica Neue"
    public var textColorHex: String?
    /// The cell's fill colour: the solid colour, the background a pattern is
    /// drawn over, or a gradient's first colour, for whatever cannot draw it.
    public var fillColorHex: String?
    /// A pattern drawn over `fillColorHex`. `nil` for a solid fill.
    public var fillPattern: FillPattern?
    /// A gradient drawn instead of `fillColorHex`.
    public var fillGradient: FillGradient?
    public var horizontalAlignment: HorizontalTextAlignment = .automatic {
        // Picking left, centre or right replaces a justify or distributed.
        didSet { horizontalSpread = nil }
    }
    public var verticalAlignment: VerticalTextAlignment = .middle {
        didSet { verticalSpread = nil }
    }
    /// Justify, distributed or centre across selection, set after
    /// `horizontalAlignment`, which setting clears it.
    public var horizontalSpread: HorizontalTextSpread?
    /// Justify or distributed, set after `verticalAlignment`, which setting
    /// clears it.
    public var verticalSpread: VerticalTextSpread?
    public var wrapsText = false
    /// Whether text too wide for its cell is set smaller to fit it rather
    /// than run on, OOXML's `shrinkToFit`. Wrapped text does not shrink.
    public var shrinksToFit = false
    public var numberFormat: String = NumberFormatPreset.general.code
    /// Per-edge line style and colour. An absent key means that edge has no rule.
    public var borderSides: [BorderEdge: BorderSide] = [:]
    public var diagonalBorder: DiagonalBorder?
    /// Indent steps, each roughly three characters of padding on the text's leading edge.
    public var indent: Int = 0
    /// OOXML text rotation: 0–90 is counter-clockwise degrees, 91–180 is
    /// clockwise as `value - 90`, and 255 means the glyphs stack vertically.
    public var textRotation: Int = 0
    /// Draws the cell's TRUE or FALSE as a box, ticked or not, which a tap
    /// turns on and off: a Numbers checkbox. Excel has none, and shows the
    /// value as it is.
    public var showsCheckbox = false
    /// The direction the cell's text reads in, OOXML's `readingOrder`.
    public var readingOrder: ReadingOrder = .context
    /// Whether a protected sheet keeps the cell from being changed. OOXML's
    /// `<protection locked>`, which is on unless a file turns it off.
    public var isLocked = true
    /// Whether a protected sheet hides the cell's formula, showing only its
    /// value. OOXML's `<protection hidden>`.
    public var isFormulaHidden = false
    /// Whether the cell's text was entered with a leading apostrophe, which
    /// keeps text that looks like a number or a formula as text. OOXML's
    /// `quotePrefix`; the apostrophe itself is not part of the value.
    public var hasQuotePrefix = false

    /// The rotation value OOXML reserves for stacked (top-to-bottom) text.
    public static let stackedTextRotation = 255

    public static let `default` = CellStyle()

    public var isDefault: Bool { self == CellStyle.default }

    /// Which edges carry a rule, as the OptionSet the formatting UI works in.
    ///
    /// Assigning through this drops any per-edge line style, which is what the
    /// UI's "toggle this edge on" gesture means; per-edge detail survives every
    /// read that does not go on to write.
    public var borders: BorderEdges {
        get {
            BorderEdge.allCases.reduce(into: BorderEdges()) { result, edge in
                if borderSides[edge] != nil { result.insert(edge.edges) }
            }
        }
        set {
            let inheritedColor = borderColorHex
            for edge in BorderEdge.allCases {
                if newValue.contains(edge.edges) {
                    if borderSides[edge] == nil {
                        borderSides[edge] = BorderSide(lineStyle: .thin, colorHex: inheritedColor)
                    }
                } else {
                    borderSides[edge] = nil
                }
            }
        }
    }

    /// The border colour shared by the whole cell.
    ///
    /// OOXML colours each side separately, so this reports the first side that
    /// has one and, when assigned, repaints every side that exists. Callers that
    /// need true per-edge colour should go through `borderSides`.
    public var borderColorHex: String? {
        get {
            for edge in BorderEdge.allCases {
                if let color = borderSides[edge]?.colorHex { return color }
            }
            return diagonalBorder?.colorHex
        }
        set {
            for edge in BorderEdge.allCases where borderSides[edge] != nil {
                borderSides[edge]?.colorHex = newValue
            }
            diagonalBorder?.colorHex = newValue
        }
    }

    // MARK: - Scoped border editing

    /// The line style in force for a scope.
    ///
    /// `all` answers from a fixed edge order rather than from the dictionary's,
    /// so a cell whose sides disagree reports the same one every time it is
    /// asked instead of flickering between them.
    public func lineStyle(in scope: BorderScope) -> BorderLineStyle? {
        switch scope {
        case .diagonal: return diagonalBorder?.lineStyle
        case .all:
            return BorderEdge.allCases.compactMap { borderSides[$0]?.lineStyle }.first
                ?? diagonalBorder?.lineStyle
        default: return scope.edge.flatMap { borderSides[$0]?.lineStyle }
        }
    }

    public func colorHex(in scope: BorderScope) -> String? {
        switch scope {
        case .diagonal: return diagonalBorder?.colorHex
        case .all: return borderColorHex
        default: return scope.edge.flatMap { borderSides[$0]?.colorHex }
        }
    }

    /// Draws or clears a set of edges, together.
    ///
    /// New sides inherit whatever style and colour the cell's other borders
    /// already carry, so adding an edge to a thick red box gets a thick red edge
    /// rather than a stray thin black one. Existing sides keep their own detail.
    public mutating func toggleBorder(_ edges: BorderEdges) {
        let isTurningOff = borders.isSuperset(of: edges)
        let inherited = BorderSide(lineStyle: lineStyle(in: .all) ?? .thin, colorHex: borderColorHex)
        for edge in BorderEdge.allCases where edges.contains(edge.edges) {
            borderSides[edge] = isTurningOff ? nil : (borderSides[edge] ?? inherited)
        }
    }

    /// Sets the line style for a scope, raising the rule where there was none:
    /// choosing how a side should look is asking for that side. `all` is the
    /// exception — it restyles what is already drawn rather than boxing the cell.
    public mutating func setLineStyle(_ value: BorderLineStyle, in scope: BorderScope) {
        switch scope {
        case .all:
            for edge in BorderEdge.allCases where borderSides[edge] != nil {
                borderSides[edge]?.lineStyle = value
            }
            diagonalBorder?.lineStyle = value
        case .diagonal:
            if diagonalBorder?.isVisible == true {
                diagonalBorder?.lineStyle = value
            } else {
                diagonalBorder = DiagonalBorder(
                    lineStyle: value, colorHex: borderColorHex, goesDown: true
                )
            }
        default:
            guard let edge = scope.edge else { return }
            var side = borderSides[edge] ?? BorderSide(colorHex: borderColorHex)
            side.lineStyle = value
            borderSides[edge] = side
        }
    }

    /// Sets — or, with nil, clears — the colour for a scope. Clearing never
    /// raises a rule that was not already there.
    public mutating func setColorHex(_ value: String?, in scope: BorderScope) {
        switch scope {
        case .all:
            borderColorHex = value
        case .diagonal:
            diagonalBorder?.colorHex = value
        default:
            guard let edge = scope.edge else { return }
            if borderSides[edge] != nil {
                borderSides[edge]?.colorHex = value
            } else if value != nil {
                borderSides[edge] = BorderSide(
                    lineStyle: lineStyle(in: .all) ?? .thin, colorHex: value
                )
            }
        }
    }

    /// Turns the diagonal rule on or off, keeping whatever style it already had
    /// and clearing it outright once neither direction is wanted.
    public mutating func setDiagonal(up: Bool, down: Bool) {
        guard up || down else {
            diagonalBorder = nil
            return
        }
        var diagonal = diagonalBorder ?? DiagonalBorder(colorHex: borderColorHex)
        diagonal.goesUp = up
        diagonal.goesDown = down
        diagonalBorder = diagonal
    }

    public var textColor: Color? { Color(argbHex: textColorHex) }
    public var fillColor: Color? { Color(argbHex: fillColorHex) }
    public var borderColor: Color { Color(argbHex: borderColorHex) ?? .secondary }

    /// Leading padding the indent steps add, in points at 100% zoom. OOXML
    /// defines a step as three spaces of the workbook's default font, not the
    /// cell's, so it is the same whatever size the cell's text is: about ten
    /// pixels in Excel's 11pt Calibri.
    public var indentPoints: Double { Double(indent) * Self.indentStepPoints }
    public static let indentStepPoints: Double = 7.5

    /// Whether the text is set line by line and spread across the cell:
    /// justify or distributed either way. Those always wrap.
    public var spreadsText: Bool {
        verticalSpread != nil || horizontalSpread == .justify || horizontalSpread == .distributed
    }

    /// True when the cell's glyphs should be stacked one above the next.
    public var isTextStacked: Bool { textRotation == CellStyle.stackedTextRotation }

    /// Rotation in degrees counter-clockwise, with OOXML's split range flattened.
    public var rotationDegrees: Double {
        guard !isTextStacked else { return 0 }
        let clamped = min(max(textRotation, 0), 180)
        return clamped <= 90 ? Double(clamped) : -Double(clamped - 90)
    }

    /// The font family name that stands for the system font. It is the default
    /// for new cells, and what files record for them: Helvetica Neue was the
    /// system font when the format of new Tables documents was settled.
    public static let systemFontName = "Helvetica Neue"

    /// Whether the cell's text is set in the platform's system font.
    public var usesSystemFont: Bool {
        fontName.isEmpty || fontName == Self.systemFontName
    }

    /// The font family to draw the cell's text in, or nil for the system font.
    /// A family that isn't installed falls back to the system font when drawn.
    public var displayFontName: String? {
        usesSystemFont ? nil : fontName
    }

    /// The SwiftUI font for the cell's text at `zoom`, the same face as
    /// `platformFont(zoom:)` gives where UIKit or AppKit can resolve one.
    public func font(zoom: Double = 1) -> Font {
        #if canImport(UIKit) || canImport(AppKit)
        return Font(platformFont(zoom: zoom))
        #else
        var font = displayFontName.map { Font.custom($0, size: fontSize * zoom) } ?? Font.system(size: fontSize * zoom)
        if isBold { font = font.bold() }
        if isItalic { font = font.italic() }
        return font
        #endif
    }
}

/// The number format codes the formatting UI offers.
public enum NumberFormatPreset: String, CaseIterable, Identifiable, Sendable {
    case general, number, numberTwoPlaces, thousands, currency, accounting
    case percent, percentTwoPlaces, scientific, date, time, dateTime, text

    public var id: String { rawValue }

    public var code: String {
        switch self {
        case .general: return "General"
        case .number: return "0"
        case .numberTwoPlaces: return "0.00"
        case .thousands: return "#,##0"
        case .currency: return "$#,##0.00"
        case .accounting: return "#,##0.00;(#,##0.00)"
        case .percent: return "0%"
        case .percentTwoPlaces: return "0.00%"
        case .scientific: return "0.00E+00"
        case .date: return "yyyy-mm-dd"
        case .time: return "h:mm:ss"
        case .dateTime: return "yyyy-mm-dd h:mm"
        case .text: return "@"
        }
    }

    public var label: String {
        switch self {
        case .general: return String(localized: "NumberFormat.Preset.Automatic", bundle: .engine)
        case .number: return String(localized: "NumberFormat.Preset.Number", bundle: .engine)
        case .numberTwoPlaces: return String(localized: "NumberFormat.Preset.NumberTwoPlaces", bundle: .engine)
        case .thousands: return String(localized: "NumberFormat.Preset.Thousands", bundle: .engine)
        case .currency: return String(localized: "NumberFormat.Preset.Currency", bundle: .engine)
        case .accounting: return String(localized: "NumberFormat.Preset.Accounting", bundle: .engine)
        case .percent: return String(localized: "NumberFormat.Preset.Percentage", bundle: .engine)
        case .percentTwoPlaces: return String(localized: "NumberFormat.Preset.PercentageTwoPlaces", bundle: .engine)
        case .scientific: return String(localized: "NumberFormat.Preset.Scientific", bundle: .engine)
        case .date: return String(localized: "NumberFormat.Preset.Date", bundle: .engine)
        case .time: return String(localized: "NumberFormat.Preset.Time", bundle: .engine)
        case .dateTime: return String(localized: "NumberFormat.Preset.DateTime", bundle: .engine)
        case .text: return String(localized: "NumberFormat.Preset.Text", bundle: .engine)
        }
    }

    public static func preset(forCode code: String) -> NumberFormatPreset? {
        allCases.first { $0.code == code }
    }
}

extension Color {
    /// Builds a colour from an OOXML "AARRGGBB" (or "RRGGBB") hex string.
    public init?(argbHex hex: String?) {
        guard var text = hex?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if text.hasPrefix("#") { text.removeFirst() }
        if text.count == 6 { text = "FF" + text }
        guard text.count == 8, let raw = UInt32(text, radix: 16) else { return nil }
        self.init(
            .sRGB,
            red: Double((raw >> 16) & 0xFF) / 255,
            green: Double((raw >> 8) & 0xFF) / 255,
            blue: Double(raw & 0xFF) / 255,
            opacity: Double((raw >> 24) & 0xFF) / 255
        )
    }

    /// "AARRGGBB" representation, for round-tripping through OOXML.
    public var argbHex: String? {
        #if !canImport(SwiftUI)
        let components = [opacity, red, green, blue].map { UInt8(max(0, min(1, $0)) * 255) }
        return components.map { String(format: "%02X", $0) }.joined()
        #else
        #if canImport(UIKit)
        typealias PlatformColor = UIColor
        #else
        typealias PlatformColor = NSColor
        #endif
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        #if canImport(UIKit)
        guard PlatformColor(self).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        #else
        guard let converted = PlatformColor(self).usingColorSpace(.sRGB) else { return nil }
        converted.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        #endif
        let components = [alpha, red, green, blue].map { UInt8(max(0, min(1, $0)) * 255) }
        return components.map { String(format: "%02X", $0) }.joined()
        #endif
    }
}

extension CellStyle {
    /// How big a checkbox is, in points at 100%.
    public static let checkboxSize = 12.0

    /// Where a checkbox sits in its cell: a square, centred unless the cell
    /// is aligned to one side, and never larger than the cell leaves room for.
    public func checkboxFrame(in frame: CGRect, zoom: Double) -> CGRect {
        let padding = 6 * zoom
        let side = min(Self.checkboxSize * zoom, frame.height - 4 * zoom, frame.width - 2 * padding)
        guard side > 0 else { return .zero }
        let x: Double
        switch horizontalAlignment {
        case .leading: x = frame.minX + padding
        case .trailing: x = frame.maxX - padding - side
        default: x = frame.midX - side / 2
        }
        let y: Double
        switch verticalAlignment {
        case .top: y = frame.minY + 2 * zoom
        case .bottom: y = frame.maxY - 2 * zoom - side
        default: y = frame.midY - side / 2
        }
        return CGRect(x: x, y: y, width: side, height: side)
    }

    /// The tick in a checkbox at `box`, as the points of its two strokes.
    public static func checkmark(in box: CGRect) -> [CGPoint] {
        [
            CGPoint(x: box.minX + box.width * 0.24, y: box.minY + box.height * 0.52),
            CGPoint(x: box.minX + box.width * 0.42, y: box.minY + box.height * 0.72),
            CGPoint(x: box.minX + box.width * 0.78, y: box.minY + box.height * 0.30),
        ]
    }
}
