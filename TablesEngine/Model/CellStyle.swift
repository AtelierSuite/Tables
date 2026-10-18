import Foundation
import SwiftUI

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
        case .automatic: return String(localized: "Alignment.Horizontal.Automatic", bundle: #bundle)
        case .leading: return String(localized: "Alignment.Horizontal.Left", bundle: #bundle)
        case .center: return String(localized: "Alignment.Horizontal.Center", bundle: #bundle)
        case .trailing: return String(localized: "Alignment.Horizontal.Right", bundle: #bundle)
        }
    }
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
        case .top: return String(localized: "Alignment.Vertical.Top", bundle: #bundle)
        case .middle: return String(localized: "Alignment.Vertical.Middle", bundle: #bundle)
        case .bottom: return String(localized: "Alignment.Vertical.Bottom", bundle: #bundle)
        }
    }

    public var alignment: Alignment {
        switch self {
        case .top: return .top
        case .middle: return .center
        case .bottom: return .bottom
        }
    }
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
        case .hair: return String(localized: "BorderLineStyle.Hairline", bundle: #bundle)
        case .thin: return String(localized: "BorderLineStyle.Thin", bundle: #bundle)
        case .medium: return String(localized: "BorderLineStyle.Medium", bundle: #bundle)
        case .thick: return String(localized: "BorderLineStyle.Thick", bundle: #bundle)
        case .double: return String(localized: "BorderLineStyle.Double", bundle: #bundle)
        case .dotted: return String(localized: "BorderLineStyle.Dotted", bundle: #bundle)
        case .dashed: return String(localized: "BorderLineStyle.Dashed", bundle: #bundle)
        case .dashDot: return String(localized: "BorderLineStyle.DashDot", bundle: #bundle)
        case .dashDotDot: return String(localized: "BorderLineStyle.DashDotDot", bundle: #bundle)
        case .mediumDashed: return String(localized: "BorderLineStyle.MediumDashed", bundle: #bundle)
        case .mediumDashDot: return String(localized: "BorderLineStyle.MediumDashDot", bundle: #bundle)
        case .mediumDashDotDot: return String(localized: "BorderLineStyle.MediumDashDotDot", bundle: #bundle)
        case .slantDashDot: return String(localized: "BorderLineStyle.SlantDashDot", bundle: #bundle)
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
        case .all: return String(localized: "Format.Border.Scope.All", bundle: #bundle)
        case .top: return String(localized: "Format.Border.Top", bundle: #bundle)
        case .leading: return String(localized: "Format.Border.Left", bundle: #bundle)
        case .bottom: return String(localized: "Format.Border.Bottom", bundle: #bundle)
        case .trailing: return String(localized: "Format.Border.Right", bundle: #bundle)
        case .diagonal: return String(localized: "Format.Border.Scope.Diagonal", bundle: #bundle)
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
    public var fillColorHex: String?
    public var horizontalAlignment: HorizontalTextAlignment = .automatic
    public var verticalAlignment: VerticalTextAlignment = .middle
    public var wrapsText = false
    public var numberFormat: String = NumberFormatPreset.general.code
    /// Per-edge line style and colour. An absent key means that edge has no rule.
    public var borderSides: [BorderEdge: BorderSide] = [:]
    public var diagonalBorder: DiagonalBorder?
    /// Indent steps, each roughly three characters of padding on the text's leading edge.
    public var indent: Int = 0
    /// OOXML text rotation: 0–90 is counter-clockwise degrees, 91–180 is
    /// clockwise as `value - 90`, and 255 means the glyphs stack vertically.
    public var textRotation: Int = 0

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

    /// True when the cell's glyphs should be stacked one above the next.
    public var isTextStacked: Bool { textRotation == CellStyle.stackedTextRotation }

    /// Rotation in degrees counter-clockwise, with OOXML's split range flattened.
    public var rotationDegrees: Double {
        guard !isTextStacked else { return 0 }
        let clamped = min(max(textRotation, 0), 180)
        return clamped <= 90 ? Double(clamped) : -Double(clamped - 90)
    }

    public func font(zoom: Double = 1) -> Font {
        var font = Font.system(size: fontSize * zoom)
        if isBold { font = font.bold() }
        if isItalic { font = font.italic() }
        return font
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
        case .general: return String(localized: "NumberFormat.Preset.Automatic", bundle: #bundle)
        case .number: return String(localized: "NumberFormat.Preset.Number", bundle: #bundle)
        case .numberTwoPlaces: return String(localized: "NumberFormat.Preset.NumberTwoPlaces", bundle: #bundle)
        case .thousands: return String(localized: "NumberFormat.Preset.Thousands", bundle: #bundle)
        case .currency: return String(localized: "NumberFormat.Preset.Currency", bundle: #bundle)
        case .accounting: return String(localized: "NumberFormat.Preset.Accounting", bundle: #bundle)
        case .percent: return String(localized: "NumberFormat.Preset.Percentage", bundle: #bundle)
        case .percentTwoPlaces: return String(localized: "NumberFormat.Preset.PercentageTwoPlaces", bundle: #bundle)
        case .scientific: return String(localized: "NumberFormat.Preset.Scientific", bundle: #bundle)
        case .date: return String(localized: "NumberFormat.Preset.Date", bundle: #bundle)
        case .time: return String(localized: "NumberFormat.Preset.Time", bundle: #bundle)
        case .dateTime: return String(localized: "NumberFormat.Preset.DateTime", bundle: #bundle)
        case .text: return String(localized: "NumberFormat.Preset.Text", bundle: #bundle)
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
    }
}
