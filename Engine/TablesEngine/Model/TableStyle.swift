import Foundation

/// How a table is dressed: OOXML's `tableStyleInfo`. The style is named, and
/// the switches say which of its parts are shown.
public struct TableStyleInfo: Hashable, Sendable {
    /// `TableStyleMedium2` and the like, or nil for a table with no style.
    public var name: String?
    public var showsFirstColumn: Bool
    public var showsLastColumn: Bool
    public var showsRowStripes: Bool
    public var showsColumnStripes: Bool

    public init(
        name: String? = nil, showsFirstColumn: Bool = false, showsLastColumn: Bool = false,
        showsRowStripes: Bool = false, showsColumnStripes: Bool = false
    ) {
        self.name = name
        self.showsFirstColumn = showsFirstColumn
        self.showsLastColumn = showsLastColumn
        self.showsRowStripes = showsRowStripes
        self.showsColumnStripes = showsColumnStripes
    }
}

/// What a table keeps about one of its columns besides the name: what its
/// totals row cell shows, and the formula a calculated column fills in.
public struct TableColumnDetail: Hashable, Sendable {
    /// OOXML's `totalsRowFunction`: `sum`, `average`, `count`, `countNums`,
    /// `max`, `min`, `stdDev`, `var` or `custom`. Nil for none.
    public var totalsFunction: String?
    /// The text a totals row cell without a function shows, "Total" mostly.
    public var totalsLabel: String?
    /// The formula of a calculated column, without its `=`.
    public var calculatedFormula: String?

    public init(totalsFunction: String? = nil, totalsLabel: String? = nil, calculatedFormula: String? = nil) {
        self.totalsFunction = totalsFunction
        self.totalsLabel = totalsLabel
        self.calculatedFormula = calculatedFormula
    }
}

/// What one part of a table style gives the cells it covers. Colours are
/// "AARRGGBB". The four outer sides fall on the edge of the part, the inner
/// two between its cells.
public struct TableElementStyle: Hashable, Sendable {
    public var fillColorHex: String?
    public var textColorHex: String?
    public var isBold = false
    public var top: BorderSide?
    public var bottom: BorderSide?
    public var leading: BorderSide?
    public var trailing: BorderSide?
    public var innerHorizontal: BorderSide?
    public var innerVertical: BorderSide?

    public init() {}

    /// A border on all four outer sides.
    fileprivate mutating func outline(_ side: BorderSide) {
        top = side
        bottom = side
        leading = side
        trailing = side
    }
}

/// A table style with its colours worked out against a workbook's theme: the
/// parts Excel's built-in styles are made of.
public struct TableStyleDefinition: Hashable, Sendable {
    public var wholeTable = TableElementStyle()
    public var headerRow = TableElementStyle()
    public var totalRow = TableElementStyle()
    public var firstColumn = TableElementStyle()
    public var lastColumn = TableElementStyle()
    public var firstRowStripe = TableElementStyle()
    public var secondRowStripe = TableElementStyle()
    public var firstColumnStripe = TableElementStyle()
    public var secondColumnStripe = TableElementStyle()

    public init() {}

    /// One of Excel's built-in styles, `TableStyleLight1` to `21`,
    /// `TableStyleMedium1` to `28` and `TableStyleDark1` to `11`, in the
    /// colours of `theme`. Nil for any other name: a style the workbook
    /// defines itself is not read.
    ///
    /// Each family runs in groups of seven that share a design, the first in
    /// black and grey and the rest in the theme's six accents.
    public static func builtIn(named name: String, theme: ThemeColorScheme) -> TableStyleDefinition? {
        let families = [("TableStyleLight", 21), ("TableStyleMedium", 28), ("TableStyleDark", 11)]
        guard let family = families.first(where: { name.hasPrefix($0.0) }),
              let number = Int(name.dropFirst(family.0.count)), (1...family.1).contains(number) else { return nil }
        let dark = theme.color(atThemeIndex: 1) ?? "000000"
        let light = theme.color(atThemeIndex: 0) ?? "FFFFFF"
        func argb(_ rgb: String, tint: Double = 0) -> String { "FF" + ThemeColorPalette.tinted(rgb, by: tint) }
        func accent(_ index: Int) -> String { theme.color(atThemeIndex: 3 + index) ?? dark }
        func side(_ style: BorderLineStyle, _ colorHex: String) -> BorderSide {
            BorderSide(lineStyle: style, colorHex: colorHex)
        }

        let group = (number - 1) / 7
        let variant = (number - 1) % 7
        let isNeutral = variant == 0
        let base = isNeutral ? dark : accent(variant)
        // The accent itself, and the paler versions of it bands are made of;
        // the neutral styles use greys in their place.
        let strong = argb(base)
        let pale = isNeutral ? argb(light, tint: -0.15) : argb(base, tint: 0.8)
        let mid = isNeutral ? argb(light, tint: -0.35) : argb(base, tint: 0.6)
        let soft = argb(base, tint: 0.4)
        let black = argb(dark)
        let white = argb(light)

        var style = TableStyleDefinition()
        style.headerRow.isBold = true
        style.totalRow.isBold = true
        style.firstColumn.isBold = true
        style.lastColumn.isBold = true

        switch (family.0, group) {
        case ("TableStyleLight", 0):
            style.wholeTable.textColorHex = isNeutral ? black : argb(base, tint: -0.25)
            style.wholeTable.top = side(.thin, strong)
            style.wholeTable.bottom = side(.thin, strong)
            style.headerRow.bottom = side(.thin, strong)
            style.totalRow.top = side(.thin, strong)
            style.firstRowStripe.fillColorHex = pale
            style.firstColumnStripe.fillColorHex = pale
        case ("TableStyleLight", 1):
            style.wholeTable.outline(side(.thin, strong))
            style.headerRow.fillColorHex = strong
            style.headerRow.textColorHex = white
            style.totalRow.top = side(.double, strong)
            style.firstRowStripe.top = side(.thin, strong)
            style.secondRowStripe.top = side(.thin, strong)
            style.firstColumnStripe.leading = side(.thin, strong)
            style.secondColumnStripe.leading = side(.thin, strong)
        case ("TableStyleLight", _):
            style.wholeTable.outline(side(.thin, strong))
            style.wholeTable.innerHorizontal = side(.thin, strong)
            style.wholeTable.innerVertical = side(.thin, strong)
            style.headerRow.bottom = side(.medium, strong)
            style.totalRow.top = side(.double, strong)
            style.firstRowStripe.fillColorHex = pale
            style.firstColumnStripe.fillColorHex = pale
        case ("TableStyleMedium", 0):
            style.wholeTable.outline(side(.thin, soft))
            style.wholeTable.innerHorizontal = side(.thin, soft)
            style.headerRow.fillColorHex = strong
            style.headerRow.textColorHex = white
            style.totalRow.top = side(.double, strong)
            style.firstRowStripe.fillColorHex = pale
            style.firstColumnStripe.fillColorHex = pale
        case ("TableStyleMedium", 1):
            style.wholeTable.fillColorHex = pale
            style.wholeTable.outline(side(.thin, white))
            style.wholeTable.innerHorizontal = side(.thin, white)
            style.wholeTable.innerVertical = side(.thin, white)
            for part in [\TableStyleDefinition.headerRow, \.totalRow, \.firstColumn, \.lastColumn] {
                style[keyPath: part].fillColorHex = strong
                style[keyPath: part].textColorHex = white
            }
            style.headerRow.bottom = side(.thick, white)
            style.totalRow.top = side(.thick, white)
            style.firstRowStripe.fillColorHex = mid
            style.firstColumnStripe.fillColorHex = mid
        case ("TableStyleMedium", 2):
            style.wholeTable.top = side(.medium, black)
            style.wholeTable.bottom = side(.medium, black)
            for part in [\TableStyleDefinition.headerRow, \.firstColumn, \.lastColumn] {
                style[keyPath: part].fillColorHex = strong
                style[keyPath: part].textColorHex = white
            }
            style.headerRow.bottom = side(.medium, black)
            style.totalRow.top = side(.double, black)
            let grey = argb(light, tint: -0.15)
            style.firstRowStripe.fillColorHex = grey
            style.firstColumnStripe.fillColorHex = grey
        case ("TableStyleMedium", _):
            style.wholeTable.fillColorHex = pale
            let line = isNeutral ? black : soft
            style.wholeTable.outline(side(.thin, line))
            style.wholeTable.innerHorizontal = side(.thin, line)
            style.wholeTable.innerVertical = side(.thin, line)
            style.totalRow.top = side(.double, isNeutral ? black : strong)
            style.firstRowStripe.fillColorHex = mid
            style.firstColumnStripe.fillColorHex = mid
        case ("TableStyleDark", 0):
            let deep = isNeutral ? argb(dark, tint: 0.25) : argb(base, tint: -0.25)
            style.wholeTable.fillColorHex = isNeutral ? argb(dark, tint: 0.45) : strong
            style.wholeTable.textColorHex = white
            style.headerRow.fillColorHex = black
            style.headerRow.textColorHex = white
            style.headerRow.bottom = side(.medium, white)
            style.totalRow.fillColorHex = isNeutral ? argb(dark, tint: 0.15) : argb(base, tint: -0.5)
            style.totalRow.textColorHex = white
            style.totalRow.top = side(.medium, white)
            style.firstColumn.fillColorHex = deep
            style.firstColumn.textColorHex = white
            style.firstColumn.trailing = side(.medium, white)
            style.lastColumn.fillColorHex = deep
            style.lastColumn.textColorHex = white
            style.lastColumn.leading = side(.medium, white)
            style.firstRowStripe.fillColorHex = deep
            style.firstColumnStripe.fillColorHex = deep
        default:
            // Dark 8 is grey under a black header; 9 to 11 pair the accents,
            // the body in one and the header in the next.
            let body = isNeutral ? nil : accent(variant * 2 - 1)
            style.wholeTable.fillColorHex = body.map { argb($0, tint: 0.8) } ?? argb(light, tint: -0.15)
            style.headerRow.fillColorHex = isNeutral ? black : argb(accent(variant * 2))
            style.headerRow.textColorHex = white
            style.totalRow.top = side(.double, black)
            let band = body.map { argb($0, tint: 0.6) } ?? argb(light, tint: -0.35)
            style.firstRowStripe.fillColorHex = band
            style.firstColumnStripe.fillColorHex = band
        }
        return style
    }
}

/// What a table style gives one cell: laid under the cell's own formatting,
/// so each part shows only where the cell has nothing of its own.
public struct TableCellLook: Hashable, Sendable {
    public var fillColorHex: String?
    public var textColorHex: String?
    public var isBold = false
    public var borderSides: [BorderEdge: BorderSide] = [:]
}

/// A table as a sheet draws it: where it is, which of its rows are the header
/// and the totals, and its style in the workbook's colours.
public struct TableFormat: Hashable, Sendable {
    /// The whole table, header and totals rows included.
    public var range: CellRange
    public var headerRowCount: Int
    public var totalsRowCount: Int
    public var info: TableStyleInfo
    public var definition: TableStyleDefinition
    /// The colour text has when a cell was given none: a cell in that colour
    /// takes the style's instead, as one with no colour does.
    public var defaultTextColorHex: String?

    public init(
        range: CellRange, headerRowCount: Int = 1, totalsRowCount: Int = 0, info: TableStyleInfo,
        definition: TableStyleDefinition, defaultTextColorHex: String? = nil
    ) {
        self.range = range.normalized
        self.headerRowCount = headerRowCount
        self.totalsRowCount = totalsRowCount
        self.info = info
        self.definition = definition
        self.defaultTextColorHex = defaultTextColorHex
    }

    /// What the style gives the cell at `address`, or nil outside the table.
    ///
    /// The parts are laid one over the other as Excel does: the whole table,
    /// column stripes, row stripes, the last and first columns, then the
    /// header and totals rows, each settling what it sets.
    public func look(at address: CellAddress) -> TableCellLook? {
        guard range.contains(address) else { return nil }
        let firstDataRow = range.start.row + max(0, headerRowCount)
        let lastDataRow = range.end.row - max(0, totalsRowCount)
        let isHeader = address.row < firstDataRow
        let isTotal = address.row > lastDataRow
        var look = TableCellLook()

        func lay(_ part: TableElementStyle, rows: ClosedRange<Int>, columns: ClosedRange<Int>) {
            if let fill = part.fillColorHex { look.fillColorHex = fill }
            if let text = part.textColorHex { look.textColorHex = text }
            if part.isBold { look.isBold = true }
            let sides: [(BorderEdge, BorderSide?)] = [
                (.top, address.row == rows.lowerBound ? part.top : part.innerHorizontal),
                (.bottom, address.row == rows.upperBound ? part.bottom : part.innerHorizontal),
                (.leading, address.column == columns.lowerBound ? part.leading : part.innerVertical),
                (.trailing, address.column == columns.upperBound ? part.trailing : part.innerVertical),
            ]
            for (edge, side) in sides {
                if let side { look.borderSides[edge] = side }
            }
        }

        let columns = range.start.column...range.end.column
        lay(definition.wholeTable, rows: range.start.row...range.end.row, columns: columns)
        if !isHeader, !isTotal {
            if info.showsColumnStripes {
                let isFirst = (address.column - range.start.column) % 2 == 0
                lay(isFirst ? definition.firstColumnStripe : definition.secondColumnStripe,
                    rows: firstDataRow...lastDataRow, columns: address.column...address.column)
            }
            if info.showsRowStripes {
                let isFirst = (address.row - firstDataRow) % 2 == 0
                lay(isFirst ? definition.firstRowStripe : definition.secondRowStripe,
                    rows: address.row...address.row, columns: columns)
            }
        }
        if !isHeader, firstDataRow <= range.end.row {
            if info.showsLastColumn, address.column == range.end.column {
                lay(definition.lastColumn, rows: firstDataRow...range.end.row, columns: address.column...address.column)
            }
            if info.showsFirstColumn, address.column == range.start.column {
                lay(definition.firstColumn, rows: firstDataRow...range.end.row, columns: address.column...address.column)
            }
        }
        if isHeader {
            lay(definition.headerRow, rows: range.start.row...(firstDataRow - 1), columns: columns)
        } else if isTotal {
            lay(definition.totalRow, rows: (lastDataRow + 1)...range.end.row, columns: columns)
        }
        return look
    }

    /// `style` over what the table gives the cell: the table's fill where the
    /// cell has none, its text colour where the cell's was left alone, its
    /// bold. Borders are not part of it: `BorderResolver` asks for those.
    public func applied(to style: CellStyle, at address: CellAddress) -> CellStyle {
        guard let look = look(at: address) else { return style }
        var result = style
        if let fill = look.fillColorHex, style.fillColorHex == nil, style.fillPattern == nil, style.fillGradient == nil {
            result.fillColorHex = fill
        }
        if let text = look.textColorHex, style.textColorHex == nil || style.textColorHex == defaultTextColorHex {
            result.textColorHex = text
        }
        if look.isBold { result.isBold = true }
        return result
    }
}

extension Worksheet {
    /// The styled table covering an address, if any.
    public func tableFormat(at address: CellAddress) -> TableFormat? {
        guard !tableFormats.isEmpty else { return nil }
        return tableFormats.first { $0.range.contains(address) }
    }

    /// Moves the sheet's tables through rows or columns inserted or removed,
    /// so their styles stay on the cells they were on.
    mutating func shiftTableFormats(_ operation: FormulaReferenceShifter.Operation, axis: FormulaReferenceShifter.Axis) {
        guard !tableFormats.isEmpty else { return }
        tableFormats = tableFormats.compactMap { format in
            guard let range = ConditionalRule.moved([format.range], operation, axis: axis).first else { return nil }
            var moved = format
            moved.range = range
            return moved
        }
    }
}
