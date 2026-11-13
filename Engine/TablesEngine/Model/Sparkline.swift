import Foundation

/// A colour a sparkline group names: the attributes the file gave it, kept so
/// a save writes the same theme reference back, and the colour they came to.
public struct SparklineColor: Hashable, Sendable {
    /// `rgb`, `theme`, `tint`, `indexed` or `auto`, as the file spelled them.
    public var attributes: [String: String]
    /// The colour as `AARRGGBB`, or nil for automatic.
    public var hex: String?

    public init(attributes: [String: String], hex: String?) {
        self.attributes = attributes
        self.hex = hex
    }

    /// A plain colour, as `AARRGGBB`.
    public init(hex: String) {
        self.init(attributes: ["rgb": hex], hex: hex)
    }
}

/// One sparkline: the cell it is drawn in and the cells it plots.
public struct Sparkline: Hashable, Sendable {
    /// The data, as the file writes it: `Sheet1!A1:E1`.
    public var formula: String
    public var location: CellAddress

    public init(formula: String, location: CellAddress) {
        self.formula = formula
        self.location = location
    }
}

/// Sparklines that share a look, Excel 2010's `x14:sparklineGroup`.
public struct SparklineGroup: Hashable, Sendable {
    public enum Kind: String, Sendable { case line, column, stacked }
    public enum EmptyCells: String, Sendable { case gap, zero, span }
    public enum AxisScale: String, Sendable { case individual, group, custom }

    public var kind: Kind = .line
    /// Points, at 100%.
    public var lineWeight = 0.75
    public var emptyCells: EmptyCells = .zero
    public var markers = false
    public var high = false
    public var low = false
    public var first = false
    public var last = false
    public var negative = false
    public var displaysXAxis = false
    public var displaysHidden = false
    public var rightToLeft = false
    public var dateAxis = false
    public var minAxis: AxisScale = .individual
    public var maxAxis: AxisScale = .individual
    public var manualMin: Double?
    public var manualMax: Double?

    public var seriesColor: SparklineColor?
    public var negativeColor: SparklineColor?
    public var axisColor: SparklineColor?
    public var markersColor: SparklineColor?
    public var firstColor: SparklineColor?
    public var lastColor: SparklineColor?
    public var highColor: SparklineColor?
    public var lowColor: SparklineColor?
    /// The dates a date axis spaces the points by.
    public var dateFormula: String?
    /// Attributes we do not model, such as `xr2:uid`, written back as they were.
    public var otherAttributes: [String: String] = [:]
    public var sparklines: [Sparkline] = []

    public init() {}
}

// MARK: - Data

extension Worksheet {
    /// The sparkline drawn in `address`, with its group.
    public func sparkline(at address: CellAddress) -> (group: SparklineGroup, sparkline: Sparkline)? {
        for group in sparklineGroups {
            if let sparkline = group.sparklines.first(where: { $0.location == address }) { return (group, sparkline) }
        }
        return nil
    }

    /// Splits `Sheet1!A1:E1` or `'My data'!A1:E1` into the sheet's name and
    /// the range. A bare range is on no sheet in particular.
    static func sparklineSource(_ formula: String) -> (sheet: String?, range: CellRange)? {
        var text = formula.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("=") { text.removeFirst() }
        guard let bang = text.lastIndex(of: "!") else {
            return CellRange(a1Range: text.replacingOccurrences(of: "$", with: "")).map { (nil, $0.normalized) }
        }
        var name = String(text[..<bang])
        if name.hasPrefix("'"), name.hasSuffix("'"), name.count >= 2 {
            name = String(name.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        let rangeText = String(text[text.index(after: bang)...]).replacingOccurrences(of: "$", with: "")
        guard let range = CellRange(a1Range: rangeText) else { return nil }
        return (name, range.normalized)
    }

    /// The values a sparkline plots, in order: nil for a cell with no number.
    /// `sheets` finds the sheet the data is on by name; without it, only data
    /// on this sheet is found.
    public func sparklineValues(
        _ sparkline: Sparkline, group: SparklineGroup, sheets: ((String) -> Worksheet?)? = nil
    ) -> [Double?] {
        guard let source = Self.sparklineSource(sparkline.formula) else { return [] }
        let data: Worksheet
        if let name = source.sheet, name.caseInsensitiveCompare(self.name) != .orderedSame {
            guard let other = sheets?(name) else { return [] }
            data = other
        } else {
            data = self
        }
        var values: [Double?] = []
        for row in source.range.rowRange {
            if !group.displaysHidden, data.hiddenRows.contains(row) { continue }
            for column in source.range.columnRange {
                if !group.displaysHidden, data.hiddenColumns.contains(column) { continue }
                let cell = data[CellAddress(row: row, column: column)]
                switch cell.value {
                case .number(let number): values.append(number)
                case .boolean(let flag): values.append(flag ? 1 : 0)
                default: values.append(nil)
                }
            }
        }
        return group.rightToLeft ? values.reversed() : values
    }
}

// MARK: - Drawing

/// One mark a sparkline is drawn with, in sheet coordinates. Colours are
/// `AARRGGBB` as the file gave them, for the renderer to adapt.
public enum SparklineShape: Hashable, Sendable {
    case polyline(points: [CGPoint], width: Double, colorHex: String)
    case bar(CGRect, colorHex: String)
    case marker(center: CGPoint, radius: Double, colorHex: String)
    case axis(from: CGPoint, to: CGPoint, width: Double, colorHex: String)
}

extension SparklineGroup {
    static let defaultSeriesHex = "FF376092"
    static let defaultNegativeHex = "FFD00000"
    static let defaultAxisHex = "FF000000"

    private func hex(_ color: SparklineColor?, _ fallback: String) -> String { color?.hex ?? fallback }

    /// The lowest and highest value the vertical axis shows for `values`,
    /// given every sparkline's values in the group for a shared axis.
    func axisBounds(for values: [Double?], groupValues: [[Double?]]) -> (min: Double, max: Double)? {
        let own = values.compactMap { $0 }
        let all = groupValues.flatMap { $0.compactMap { $0 } }
        func bound(_ scale: AxisScale, manual: Double?, pick: ([Double]) -> Double?) -> Double? {
            switch scale {
            case .custom: return manual ?? pick(own)
            case .group: return pick(all)
            case .individual: return pick(own)
            }
        }
        guard var low = bound(minAxis, manual: manualMin, pick: { $0.min() }),
              var high = bound(maxAxis, manual: manualMax, pick: { $0.max() }) else { return nil }
        if emptyCells == .zero, values.contains(where: { $0 == nil }) {
            low = Swift.min(low, 0)
            high = Swift.max(high, 0)
        }
        return (low, high)
    }

    /// The marks that draw `values` inside `frame`. `groupValues` are every
    /// sparkline's values in the group, for an axis the group shares.
    public func shapes(
        for values: [Double?], groupValues: [[Double?]], in frame: CGRect, zoom: Double
    ) -> [SparklineShape] {
        guard !values.isEmpty else { return [] }
        let values = values.map { $0 ?? (emptyCells == .zero ? 0 : nil) }
        let inset = 2 * zoom
        let box = frame.insetBy(dx: inset, dy: inset)
        guard box.width > 1, box.height > 1, values.contains(where: { $0 != nil }) else { return [] }

        let numbers = values.compactMap { $0 }
        let maxValue = numbers.max() ?? 0, minValue = numbers.min() ?? 0
        let firstIndex = values.firstIndex { $0 != nil }, lastIndex = values.lastIndex { $0 != nil }
        /// The colour a point is marked with, the most particular first.
        func emphasis(_ index: Int, _ value: Double) -> String? {
            if high, value == maxValue { return hex(highColor, Self.defaultSeriesHex) }
            if low, value == minValue { return hex(lowColor, Self.defaultSeriesHex) }
            if first, index == firstIndex { return hex(firstColor, Self.defaultSeriesHex) }
            if last, index == lastIndex { return hex(lastColor, Self.defaultSeriesHex) }
            if negative, value < 0 { return hex(negativeColor, Self.defaultNegativeHex) }
            return nil
        }
        let series = hex(seriesColor, Self.defaultSeriesHex)
        var shapes: [SparklineShape] = []

        if kind == .stacked {
            // Win/loss: every point the same height, wins above the middle.
            let slot = box.width / Double(values.count)
            let middle = box.midY
            if displaysXAxis {
                shapes.append(.axis(from: CGPoint(x: box.minX, y: middle), to: CGPoint(x: box.maxX, y: middle),
                                    width: max(0.5, 0.75 * zoom), colorHex: hex(axisColor, Self.defaultAxisHex)))
            }
            for (index, value) in values.enumerated() {
                guard let value, value != 0 else { continue }
                let x = box.minX + slot * Double(index) + slot * 0.1
                let rect = value > 0
                    ? CGRect(x: x, y: box.minY, width: slot * 0.8, height: middle - box.minY - 0.5 * zoom)
                    : CGRect(x: x, y: middle + 0.5 * zoom, width: slot * 0.8, height: box.maxY - middle - 0.5 * zoom)
                let color = emphasis(index, value) ?? (value < 0 ? hex(negativeColor, Self.defaultNegativeHex) : series)
                shapes.append(.bar(rect, colorHex: color))
            }
            return shapes
        }

        guard let bounds = axisBounds(for: values, groupValues: groupValues) else { return [] }
        let span = bounds.max - bounds.min
        func y(_ value: Double) -> Double {
            guard span > 0 else { return box.midY }
            let clamped = Swift.min(Swift.max(value, bounds.min), bounds.max)
            return box.maxY - (clamped - bounds.min) / span * box.height
        }
        let zeroY: Double? = bounds.min < 0 && bounds.max > 0 ? y(0) : nil
        if displaysXAxis, let zeroY {
            shapes.append(.axis(from: CGPoint(x: box.minX, y: zeroY), to: CGPoint(x: box.maxX, y: zeroY),
                                width: max(0.5, 0.75 * zoom), colorHex: hex(axisColor, Self.defaultAxisHex)))
        }

        if kind == .column {
            let slot = box.width / Double(values.count)
            let edge: Double = bounds.min >= 0 ? Double(box.maxY) : Double(box.minY)
            let baseline: Double = zeroY ?? edge
            for (index, value) in values.enumerated() {
                guard let value else { continue }
                var top: Double = y(value)
                var bottom: Double = baseline
                if top > bottom { swap(&top, &bottom) }
                // The lowest bar of an axis that does not start at zero still shows.
                if bottom - top < zoom { top = bottom - zoom }
                let left = Double(box.minX) + Double(slot) * (Double(index) + 0.1)
                let rect = CGRect(x: left, y: top, width: Double(slot) * 0.8, height: bottom - top)
                shapes.append(.bar(rect, colorHex: emphasis(index, value) ?? series))
            }
            return shapes
        }

        // A line: one point per value, a gap breaking it unless it is spanned.
        let step = values.count > 1 ? box.width / Double(values.count - 1) : 0
        func x(_ index: Int) -> Double { values.count > 1 ? box.minX + step * Double(index) : box.midX }
        let width = max(0.5, lineWeight * zoom)
        var run: [CGPoint] = []
        for (index, value) in values.enumerated() {
            if let value {
                run.append(CGPoint(x: x(index), y: y(value)))
            } else if emptyCells == .gap, !run.isEmpty {
                shapes.append(.polyline(points: run, width: width, colorHex: series))
                run = []
            }
        }
        if !run.isEmpty { shapes.append(.polyline(points: run, width: width, colorHex: series)) }
        let radius = max(1.25, width * 1.5)
        for (index, value) in values.enumerated() {
            guard let value else { continue }
            let color = emphasis(index, value) ?? (markers ? hex(markersColor, Self.defaultSeriesHex) : nil)
            if let color { shapes.append(.marker(center: CGPoint(x: x(index), y: y(value)), radius: radius, colorHex: color)) }
        }
        return shapes
    }
}

extension Worksheet {
    /// The marks of the sparkline in `address`, drawn in `frame`, from the
    /// sheet's current values: nothing if the cell has no sparkline.
    public func sparklineShapes(
        at address: CellAddress, in frame: CGRect, zoom: Double, sheets: ((String) -> Worksheet?)? = nil
    ) -> [SparklineShape] {
        guard let (group, sparkline) = sparkline(at: address) else { return [] }
        let values = sparklineValues(sparkline, group: group, sheets: sheets)
        let shared = group.minAxis == .group || group.maxAxis == .group
        let groupValues = shared ? group.sparklines.map { sparklineValues($0, group: group, sheets: sheets) } : []
        return group.shapes(for: values, groupValues: groupValues, in: frame, zoom: zoom)
    }

    /// Every cell with a sparkline, for a renderer to find those it shows.
    public var sparklineLocations: [CellAddress] {
        sparklineGroups.flatMap { $0.sparklines.map(\.location) }
    }
}

// MARK: - Structural edits

extension Worksheet {
    /// Moves sparklines, and the ranges they plot on this sheet, through rows
    /// or columns inserted or removed. A sparkline whose cell or data went is
    /// removed with it.
    mutating func shiftSparklines(_ operation: FormulaReferenceShifter.Operation, axis: FormulaReferenceShifter.Axis) {
        if case .translate = operation { return }
        guard !sparklineGroups.isEmpty else { return }
        let ownName = name
        sparklineGroups = sparklineGroups.compactMap { group in
            var group = group
            group.sparklines = group.sparklines.compactMap { sparkline in
                guard let cell = ConditionalRule.moved([CellRange(sparkline.location)], operation, axis: axis).first
                else { return nil }
                var moved = sparkline
                moved.location = cell.start
                if let source = Self.sparklineSource(sparkline.formula),
                   source.sheet == nil || source.sheet?.caseInsensitiveCompare(ownName) == .orderedSame {
                    guard let range = ConditionalRule.moved([source.range], operation, axis: axis).first else { return nil }
                    if range != source.range {
                        let sheet = source.sheet.map { ChartReference.quotedSheetName($0) + "!" } ?? ""
                        moved.formula = sheet + range.a1
                    }
                }
                return moved
            }
            return group.sparklines.isEmpty ? nil : group
        }
    }
}
