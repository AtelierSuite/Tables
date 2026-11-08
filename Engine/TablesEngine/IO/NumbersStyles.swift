import Foundation

/// Cell formatting in a Numbers document. Each cell has a text style, a
/// `TSWP.ParagraphStyleArchive`, for its font and alignment, and a cell
/// style, a `TST.CellStyleArchive`, for its fill, wrapping and vertical
/// alignment: its own, kept in the table's list of styles, or else the
/// table's default for the part of the table it is in — header rows, header
/// columns, footer rows or body.
///
/// A style sets only some properties and leaves the rest to its parent. A
/// cell formatted by hand gets a variation of the style it had, setting just
/// what was changed, as Numbers makes one.
public enum NumbersStyles {
    public enum ObjectType {
        public static let paragraphStyle = 2022
        public static let cellStyle = 6004
    }

    /// The fields of a cell's storage holding its own styles' keys.
    public enum Field {
        public static let cellStyle: UInt32 = 0x20
        public static let textStyle: UInt32 = 0x40
    }

    /// Field numbers of the styles and their properties.
    public enum Number {
        /// `TSS.StyleArchive`, every style's first field, and in it.
        public static let base = 1
        public static let parent = 3
        public static let isVariation = 4
        public static let stylesheet = 5
        public static let overrideCount = 10
        /// A text style's character and paragraph properties.
        public static let characterProperties = 11
        public static let paragraphProperties = 12
        /// A cell style's properties.
        public static let cellProperties = 11

        public static let bold = 1
        public static let italic = 2
        public static let fontSize = 3
        public static let fontColor = 7
        public static let underline = 11
        public static let strikethrough = 12
        /// The fill text is drawn with, which newer versions of Numbers set
        /// alongside the font colour.
        public static let textFill = 46
        public static let alignment = 1

        public static let fill = 1
        public static let wraps = 3
        public static let verticalAlignment = 8
    }

    // MARK: - What can be edited

    /// The formatting Tables reads from and writes to Numbers' text styles.
    public struct TextFormat: Hashable, Sendable {
        public var isBold: Bool
        public var isItalic: Bool
        public var isUnderlined: Bool
        public var isStruckThrough: Bool
        public var fontSize: Double
        public var textColorHex: String?
        public var horizontalAlignment: HorizontalTextAlignment

        public init(_ style: CellStyle) {
            isBold = style.isBold
            isItalic = style.isItalic
            isUnderlined = style.isUnderlined
            isStruckThrough = style.isStruckThrough
            fontSize = style.fontSize
            textColorHex = style.textColorHex.map(Self.normalized)
            horizontalAlignment = style.horizontalAlignment
        }

        public func apply(to style: inout CellStyle) {
            style.isBold = isBold
            style.isItalic = isItalic
            style.isUnderlined = isUnderlined
            style.isStruckThrough = isStruckThrough
            style.fontSize = fontSize
            style.textColorHex = textColorHex
            style.horizontalAlignment = horizontalAlignment
        }

        /// A colour as `AARRGGBB`, upper case.
        public static func normalized(_ hex: String) -> String {
            let hex = hex.uppercased()
            return hex.count == 6 ? "FF" + hex : hex
        }
    }

    /// The formatting Tables reads from and writes to Numbers' cell styles.
    public struct CellFormat: Hashable, Sendable {
        public var fillColorHex: String?
        public var wrapsText: Bool
        public var verticalAlignment: VerticalTextAlignment

        public init(_ style: CellStyle) {
            fillColorHex = style.fillColorHex.map(TextFormat.normalized)
            wrapsText = style.wrapsText
            verticalAlignment = style.verticalAlignment
        }

        public func apply(to style: inout CellStyle) {
            style.fillColorHex = fillColorHex
            style.wrapsText = wrapsText
            style.verticalAlignment = verticalAlignment
        }
    }

    /// `imported` with the formatting Numbers can be given taken from
    /// `edited`, and its number format; the rest of `edited`'s formatting —
    /// fonts, borders, indents — isn't kept, nor any in a table without a
    /// list of styles to keep it in. Text formatting stays as it was in a
    /// cell of rich text, whose own runs of text are formatted.
    public static func keepingWhatCanBeSaved(
        _ edited: CellStyle, imported: CellStyle, canFormat: Bool, isRichText: Bool
    ) -> CellStyle {
        var style = imported
        style.numberFormat = edited.numberFormat
        guard canFormat else { return style }
        if !isRichText { TextFormat(edited).apply(to: &style) }
        CellFormat(edited).apply(to: &style)
        return style
    }

    // MARK: - Parts of a table

    /// A table's default styles for each part of it.
    public struct Regions: Sendable {
        public var headerRows: Int
        public var headerColumns: Int
        public var footerRows: Int
        /// Text and cell styles for header rows, header columns, footer
        /// rows and the body, in that order.
        public var text: [UInt64?]
        public var cell: [UInt64?]

        public init(model: ProtobufMessage) {
            headerRows = model.int(9) ?? 0
            headerColumns = model.int(10) ?? 0
            footerRows = model.int(11) ?? 0
            text = [25, 26, 27, 24].map { model.message($0)?.uint(1) }
            cell = [19, 20, 21, 18].map { model.message($0)?.uint(1) }
        }

        /// Which part a cell is in; header rows take the corner.
        public func part(row: Int, column: Int, rowCount: Int) -> Int {
            if row < headerRows { return 0 }
            if column < headerColumns { return 1 }
            if footerRows > 0, row >= rowCount - footerRows { return 2 }
            return 3
        }

        public var hasBodyStyles: Bool { text[3] != nil && cell[3] != nil }
    }

    // MARK: - Reading

    /// Works out what styles come to, following each one's parents for what
    /// it leaves to them.
    public struct Resolver {
        public let style: (UInt64) -> ProtobufMessage?

        /// The nearest value `read` finds in a style's properties, or its
        /// parents'.
        public func value<T>(_ identifier: UInt64?, properties: Int, _ read: (ProtobufMessage) -> T?) -> T? {
            var next = identifier
            var depth = 0
            while let identifier = next, depth < 32, let message = style(identifier) {
                if let group = message.message(properties), let value = read(group) { return value }
                next = message.message(Number.base)?.message(Number.parent)?.uint(1)
                depth += 1
            }
            return nil
        }

        /// What a text style and a cell style say; where there is no style,
        /// what Numbers draws without one.
        public func style(text: UInt64?, cell: UInt64?) -> CellStyle {
            var style = CellStyle()
            readText(text, into: &style)
            readCell(cell, into: &style)
            return style
        }

        private func flag(_ number: Int) -> (ProtobufMessage) -> Bool? {
            { $0.has(number) ? $0.bool(number) : nil }
        }

        private func readText(_ text: UInt64?, into style: inout CellStyle) {
            func character<T>(_ read: (ProtobufMessage) -> T?) -> T? {
                value(text, properties: Number.characterProperties, read)
            }
            style.isBold = character(flag(Number.bold)) ?? false
            style.isItalic = character(flag(Number.italic)) ?? false
            style.isUnderlined = (character { $0.uint(Number.underline) } ?? 0) != 0
            style.isStruckThrough = (character { $0.uint(Number.strikethrough) } ?? 0) != 0
            if let size = character({ $0.float(Number.fontSize) }), size > 0 { style.fontSize = Double(size) }
            let color = character { properties in
                properties.message(Number.fontColor).flatMap(NumbersStyles.color)
                    ?? properties.message(Number.textFill)?.message(1).flatMap(NumbersStyles.color)
            }
            // Black is what text is drawn in when nothing says otherwise.
            style.textColorHex = color == "FF000000" ? nil : color
            let alignment = value(text, properties: Number.paragraphProperties) { $0.uint(Number.alignment) }
            style.horizontalAlignment = Self.horizontalAlignment(alignment)
        }

        private func readCell(_ cell: UInt64?, into style: inout CellStyle) {
            func cellValue<T>(_ read: (ProtobufMessage) -> T?) -> T? {
                value(cell, properties: Number.cellProperties, read)
            }
            // A fill that is there but isn't a colour — a gradient, an image,
            // or none — stops the search as much as a colour does.
            let fill: String?? = cellValue { properties in
                properties.message(Number.fill).map { $0.message(1).flatMap(NumbersStyles.color) }
            }
            style.fillColorHex = fill ?? nil
            style.wrapsText = cellValue(flag(Number.wraps)) ?? true
            style.verticalAlignment = Self.verticalAlignment(cellValue { $0.uint(Number.verticalAlignment) })
        }

        public static func horizontalAlignment(_ value: UInt64?) -> HorizontalTextAlignment {
            switch value {
            case 0, 3: return .leading
            case 1: return .trailing
            case 2: return .center
            default: return .automatic
            }
        }

        public static func verticalAlignment(_ value: UInt64?) -> VerticalTextAlignment {
            switch value {
            case 1: return .middle
            case 2: return .bottom
            default: return .top
            }
        }
    }

    /// A `TSP.Color` as `AARRGGBB`, or nil for one that isn't red, green and
    /// blue or white.
    public static func color(_ message: ProtobufMessage) -> String? {
        func byte(_ value: Float?) -> Int { min(max(Int(((value ?? 0) * 255).rounded()), 0), 255) }
        let alpha = byte(message.has(6) ? message.float(6) : 1)
        switch message.uint(1) {
        case 1:
            return String(format: "%02X%02X%02X%02X", alpha, byte(message.float(3)), byte(message.float(4)), byte(message.float(5)))
        case 3:
            let white = byte(message.float(11))
            return String(format: "%02X%02X%02X%02X", alpha, white, white, white)
        default:
            return nil
        }
    }

    public static func colorMessage(_ hex: String) -> ProtobufMessage {
        let hex = TextFormat.normalized(hex)
        let value = UInt32(hex, radix: 16) ?? 0xFF00_0000
        func component(_ shift: UInt32) -> Float { Float(value >> shift & 0xFF) / 255 }
        var color = ProtobufMessage()
        color.set(1, uint: 1)
        color.set(3, float: component(16))
        color.set(4, float: component(8))
        color.set(5, float: component(0))
        color.set(6, float: component(24))
        color.set(12, uint: 1)
        return color
    }

    // MARK: - Writing

    /// Sets in a text style's own properties whatever of Tables' text
    /// formatting went from `old` to `new`, leaving out what comes to the
    /// same as the style it is a variation of, `root`.
    public static func applyText(
        from old: TextFormat, to new: TextFormat, root: TextFormat,
        character: inout ProtobufMessage, paragraph: inout ProtobufMessage
    ) {
        func set(_ number: Int, in message: inout ProtobufMessage, same: Bool, _ value: () -> [ProtobufMessage.Value]) {
            message.set(number, same ? [] : value())
        }
        if old.isBold != new.isBold {
            set(Number.bold, in: &character, same: new.isBold == root.isBold) { [.varint(new.isBold ? 1 : 0)] }
        }
        if old.isItalic != new.isItalic {
            set(Number.italic, in: &character, same: new.isItalic == root.isItalic) { [.varint(new.isItalic ? 1 : 0)] }
        }
        if old.isUnderlined != new.isUnderlined {
            set(Number.underline, in: &character, same: new.isUnderlined == root.isUnderlined) {
                [.varint(new.isUnderlined ? 1 : 0)]
            }
        }
        if old.isStruckThrough != new.isStruckThrough {
            set(Number.strikethrough, in: &character, same: new.isStruckThrough == root.isStruckThrough) {
                [.varint(new.isStruckThrough ? 1 : 0)]
            }
        }
        if old.fontSize != new.fontSize {
            set(Number.fontSize, in: &character, same: new.fontSize == root.fontSize) {
                [.fixed32(Float(new.fontSize).bitPattern)]
            }
        }
        if old.textColorHex != new.textColorHex {
            let same = new.textColorHex == root.textColorHex
            let color = colorMessage(new.textColorHex ?? "FF000000")
            var fill = ProtobufMessage()
            fill.set(1, message: color)
            set(Number.fontColor, in: &character, same: same) { [.bytes(color.encoded()[...])] }
            set(Number.textFill, in: &character, same: same) { [.bytes(fill.encoded()[...])] }
        }
        if old.horizontalAlignment != new.horizontalAlignment {
            set(Number.alignment, in: &paragraph, same: new.horizontalAlignment == root.horizontalAlignment) {
                [.varint(alignmentValue(new.horizontalAlignment))]
            }
        }
    }

    /// The same for a cell style's properties.
    public static func applyCell(from old: CellFormat, to new: CellFormat, root: CellFormat, properties: inout ProtobufMessage) {
        if old.fillColorHex != new.fillColorHex {
            if new.fillColorHex == root.fillColorHex {
                properties.set(Number.fill, [])
            } else {
                // An empty fill clears the one the style would otherwise get.
                var fill = ProtobufMessage()
                if let hex = new.fillColorHex { fill.set(1, message: colorMessage(hex)) }
                properties.set(Number.fill, message: fill)
            }
        }
        if old.wrapsText != new.wrapsText {
            properties.set(Number.wraps, new.wrapsText == root.wrapsText ? [] : [.varint(new.wrapsText ? 1 : 0)])
        }
        if old.verticalAlignment != new.verticalAlignment {
            let value: UInt64 = switch new.verticalAlignment {
            case .top: 0
            case .middle: 1
            case .bottom: 2
            }
            properties.set(Number.verticalAlignment, new.verticalAlignment == root.verticalAlignment ? [] : [.varint(value)])
        }
    }

    private static func alignmentValue(_ alignment: HorizontalTextAlignment) -> UInt64 {
        switch alignment {
        case .leading: return 0
        case .trailing: return 1
        case .center: return 2
        case .automatic: return 4
        }
    }

    /// A style made a variation of `root`, with these properties of its own.
    public static func variation(
        of root: UInt64, stylesheet: UInt64, type: Int, properties: [(number: Int, message: ProtobufMessage)]
    ) -> ProtobufMessage {
        var parent = ProtobufMessage()
        parent.set(1, uint: root)
        var sheet = ProtobufMessage()
        sheet.set(1, uint: stylesheet)
        var base = ProtobufMessage()
        base.set(Number.parent, message: parent)
        base.set(Number.isVariation, bool: true)
        base.set(Number.stylesheet, message: sheet)
        var style = ProtobufMessage()
        style.set(Number.base, message: base)
        let count = properties.reduce(0) { $0 + Set($1.message.fields.map(\.number)).count }
        style.set(Number.overrideCount, uint: UInt64(count))
        for property in properties {
            style.set(property.number, message: property.message)
        }
        return style
    }
}
