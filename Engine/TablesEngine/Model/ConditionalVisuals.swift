import Foundation

/// A point a colour scale, data bar or icon set measures from: a `<cfvo>`.
public struct ConditionalThreshold: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case number = "num", percent, percentile, minimum = "min", maximum = "max", formula
        /// Excel 2010's data bars: the lowest value or zero, whichever is
        /// lower, and the highest or zero, whichever is higher.
        case automaticMinimum = "autoMin", automaticMaximum = "autoMax"
    }

    public var kind: Kind
    /// A number, or a formula giving one. Unused by the minimum and maximum.
    public var value: String?
    /// Whether a value equal to the threshold has reached it: `gte`.
    public var isInclusive: Bool

    public init(kind: Kind, value: String? = nil, isInclusive: Bool = true) {
        self.kind = kind
        self.value = value
        self.isInclusive = isInclusive
    }

    /// Where the threshold falls among `sorted`, the range's numbers in
    /// ascending order. `evaluate` works out a formula.
    func resolved(in sorted: [Double], evaluate: (String) -> Double?) -> Double? {
        guard let lowest = sorted.first, let highest = sorted.last else { return nil }
        func amount() -> Double? {
            guard let value else { return nil }
            return Double(value.trimmingCharacters(in: .whitespaces)) ?? evaluate(value)
        }
        switch kind {
        case .minimum: return lowest
        case .maximum: return highest
        case .automaticMinimum: return min(0, lowest)
        case .automaticMaximum: return max(0, highest)
        case .number, .formula: return amount()
        case .percent: return amount().map { lowest + (highest - lowest) * $0 / 100 }
        case .percentile:
            // As PERCENTILE.INC: a straight line between the two nearest ranks.
            guard let percent = amount() else { return nil }
            let rank = min(max(percent, 0), 100) / 100 * Double(sorted.count - 1)
            let below = Int(rank.rounded(.down))
            let above = min(below + 1, sorted.count - 1)
            return sorted[below] + (sorted[above] - sorted[below]) * (rank - Double(below))
        }
    }
}

/// A data bar as a rule describes it.
public struct ConditionalDataBar: Hashable, Sendable {
    public var minimum: ConditionalThreshold
    public var maximum: ConditionalThreshold
    public var colorHex: String
    /// The colour of a bar for a negative value, where they run back from an axis.
    public var negativeColorHex: String
    /// Whether negative values run the other way from an axis at zero, as
    /// Excel 2010's bars do. Excel 2007's all start at the leading edge.
    public var hasAxis: Bool
    /// The shortest and longest bar, as percentages of the cell's width.
    public var minimumLength: Double
    public var maximumLength: Double
    public var showsValue: Bool

    public init(
        minimum: ConditionalThreshold = .init(kind: .minimum), maximum: ConditionalThreshold = .init(kind: .maximum),
        colorHex: String, negativeColorHex: String = "FFFF0000", hasAxis: Bool = false,
        minimumLength: Double = 10, maximumLength: Double = 90, showsValue: Bool = true
    ) {
        self.minimum = minimum
        self.maximum = maximum
        self.colorHex = colorHex
        self.negativeColorHex = negativeColorHex
        self.hasAxis = hasAxis
        self.minimumLength = minimumLength
        self.maximumLength = maximumLength
        self.showsValue = showsValue
    }
}

/// An icon set as a rule describes it.
public struct ConditionalIconSet: Hashable, Sendable {
    /// Excel's name for the set, such as `3TrafficLights1`.
    public var name: String
    /// One for each icon, lowest first. The first is where the range starts
    /// and is not tested.
    public var thresholds: [ConditionalThreshold]
    public var isReversed: Bool
    public var showsValue: Bool

    public init(name: String, thresholds: [ConditionalThreshold], isReversed: Bool = false, showsValue: Bool = true) {
        self.name = name
        self.thresholds = thresholds
        self.isReversed = isReversed
        self.showsValue = showsValue
    }
}

/// The part of a cell's width a data bar covers, as fractions from the
/// leading edge.
public struct ConditionalBar: Hashable, Sendable {
    public var start: Double
    public var end: Double
    public var colorHex: String

    public init(start: Double, end: Double, colorHex: String) {
        self.start = start
        self.end = end
        self.colorHex = colorHex
    }
}

/// One icon of an icon set.
public struct ConditionalIcon: Hashable, Sendable {
    public enum Shape: Hashable, Sendable {
        /// Pointing up at 0 degrees, turning clockwise.
        case arrow(degrees: Int)
        case circle, flag, triangle, diamond
        case check, cross, exclamation
        case circledCheck, circledCross, circledExclamation
        /// Four bars of rising height, this many of them filled.
        case bars(Int)
        /// A circle with this many quarters filled.
        case quarters(Int)
    }

    public var shape: Shape
    public var colorHex: String

    public init(shape: Shape, colorHex: String) {
        self.shape = shape
        self.colorHex = colorHex
    }

    static let green = "FF43A047"
    static let yellow = "FFF2B600"
    static let red = "FFE0483C"
    static let gray = "FF7F7F7F"
    static let pink = "FFF2A29B"
    static let black = "FF3A3A3A"
    static let blue = "FF3B6FB6"

    /// The icons of one of Excel's sets, from the one for the lowest values
    /// up. Empty for a set that is not drawn here.
    public static func icons(ofSet name: String) -> [ConditionalIcon] {
        func arrows(_ angles: [Int], _ colors: [String]) -> [ConditionalIcon] {
            zip(angles, colors).map { ConditionalIcon(shape: .arrow(degrees: $0), colorHex: $1) }
        }
        func each(_ shape: Shape, _ colors: [String]) -> [ConditionalIcon] {
            colors.map { ConditionalIcon(shape: shape, colorHex: $0) }
        }
        switch name {
        case "3Arrows": return arrows([180, 90, 0], [red, yellow, green])
        case "3ArrowsGray": return arrows([180, 90, 0], [gray, gray, gray])
        case "4Arrows": return arrows([180, 135, 45, 0], [red, yellow, yellow, green])
        case "4ArrowsGray": return arrows([180, 135, 45, 0], [gray, gray, gray, gray])
        case "5Arrows": return arrows([180, 135, 90, 45, 0], [red, yellow, yellow, yellow, green])
        case "5ArrowsGray": return arrows([180, 135, 90, 45, 0], [gray, gray, gray, gray, gray])
        case "3Flags": return each(.flag, [red, yellow, green])
        case "3Signs":
            return [.init(shape: .diamond, colorHex: red), .init(shape: .triangle, colorHex: yellow),
                    .init(shape: .circle, colorHex: green)]
        case "3Symbols":
            return [.init(shape: .circledCross, colorHex: red), .init(shape: .circledExclamation, colorHex: yellow),
                    .init(shape: .circledCheck, colorHex: green)]
        case "3Symbols2":
            return [.init(shape: .cross, colorHex: red), .init(shape: .exclamation, colorHex: yellow),
                    .init(shape: .check, colorHex: green)]
        case "4RedToBlack": return each(.circle, [black, gray, pink, red])
        case "4TrafficLights": return each(.circle, [black, red, yellow, green])
        case "4Rating": return (1...4).map { ConditionalIcon(shape: .bars($0), colorHex: blue) }
        case "5Rating": return (0...4).map { ConditionalIcon(shape: .bars($0), colorHex: blue) }
        case "5Quarters": return (0...4).map { ConditionalIcon(shape: .quarters($0), colorHex: black) }
        case "3TrafficLights1", "3TrafficLights2": return each(.circle, [red, yellow, green])
        default: return []
        }
    }
}

// MARK: - Rules over a whole range

extension ConditionalRule {
    /// What a rule's test looks at.
    public enum Kind: Hashable, Sendable {
        /// The cell on its own: `comparison` and `formulas`.
        case test
        /// The highest or lowest so many values, or so many percent of them.
        case rank(count: Int, isPercent: Bool, isBottom: Bool)
        /// Above or below the mean, by `deviations` standard deviations.
        case average(isAbove: Bool, includesEqual: Bool, deviations: Int)
        /// Values that occur more than once, or only once.
        case duplicates(isUnique: Bool)
        /// A fill blended between the colours of the thresholds either side.
        case colorScale(thresholds: [ConditionalThreshold], colors: [String])
        case dataBar(ConditionalDataBar)
        case iconSet(ConditionalIconSet)
    }

    /// What a rule that measures a cell against the rest of its range gives
    /// each of `cells`, which are all the cells of its ranges.
    func rangedStyles(
        cells: [(address: CellAddress, value: CellValue)], evaluate: (String) -> Double?
    ) -> [CellAddress: ConditionalStyle] {
        var numbers: [(address: CellAddress, value: Double)] = []
        for cell in cells {
            if case .number(let number) = cell.value { numbers.append((cell.address, number)) }
        }
        let sorted = numbers.map(\.value).sorted()
        var styles: [CellAddress: ConditionalStyle] = [:]

        switch kind {
        case .test:
            break

        case .rank(let count, let isPercent, let isBottom):
            guard !sorted.isEmpty, count > 0 else { break }
            let wanted = isPercent ? max(1, sorted.count * count / 100) : count
            let index = min(wanted, sorted.count) - 1
            // Values tied with the last one in all pass, as in Excel.
            let limit = isBottom ? sorted[index] : sorted[sorted.count - 1 - index]
            for entry in numbers where isBottom ? entry.value <= limit : entry.value >= limit {
                styles[entry.address] = style
            }

        case .average(let isAbove, let includesEqual, let deviations):
            guard !sorted.isEmpty else { break }
            let mean = sorted.reduce(0, +) / Double(sorted.count)
            let spread = (sorted.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(sorted.count)).squareRoot()
            let limit = mean + (isAbove ? 1 : -1) * Double(deviations) * spread
            for entry in numbers {
                let passes = isAbove
                    ? (includesEqual ? entry.value >= limit : entry.value > limit)
                    : (includesEqual ? entry.value <= limit : entry.value < limit)
                if passes { styles[entry.address] = style }
            }

        case .duplicates(let isUnique):
            func key(_ value: CellValue) -> String? {
                switch value {
                case .number(let number): return "n\(number)"
                case .text(let text): return "t" + text.lowercased()
                case .boolean(let flag): return flag ? "b1" : "b0"
                case .empty, .error: return nil
                }
            }
            var counts: [String: Int] = [:]
            for cell in cells { if let key = key(cell.value) { counts[key, default: 0] += 1 } }
            for cell in cells {
                guard let count = key(cell.value).flatMap({ counts[$0] }) else { continue }
                if (count == 1) == isUnique { styles[cell.address] = style }
            }

        case .colorScale(let thresholds, let colors):
            let stops = zip(thresholds, colors).compactMap { threshold, color in
                threshold.resolved(in: sorted, evaluate: evaluate).map { (value: $0, color: color) }
            }
            guard stops.count == thresholds.count, stops.count >= 2 else { break }
            for entry in numbers {
                var applied = style
                applied.fillColorHex = Self.blend(stops, at: entry.value)
                styles[entry.address] = applied
            }

        case .dataBar(let bar):
            guard let low = bar.minimum.resolved(in: sorted, evaluate: evaluate),
                  let high = bar.maximum.resolved(in: sorted, evaluate: evaluate) else { break }
            func position(_ value: Double) -> Double {
                high > low ? min(max((value - low) / (high - low), 0), 1) : 1
            }
            let axis = bar.hasAxis ? position(0) : 0
            for entry in numbers {
                let reach = position(entry.value)
                var applied = style
                if axis == 0 {
                    let length = (bar.minimumLength + reach * (bar.maximumLength - bar.minimumLength)) / 100
                    applied.dataBar = ConditionalBar(start: 0, end: min(max(length, 0), 1), colorHex: bar.colorHex)
                } else {
                    applied.dataBar = ConditionalBar(
                        start: min(axis, reach), end: max(axis, reach),
                        colorHex: entry.value < 0 ? bar.negativeColorHex : bar.colorHex
                    )
                }
                if !bar.showsValue { applied.hidesValue = true }
                styles[entry.address] = applied
            }

        case .iconSet(let set):
            let icons = ConditionalIcon.icons(ofSet: set.name)
            let limits = set.thresholds.map { $0.resolved(in: sorted, evaluate: evaluate) }
            guard !icons.isEmpty, limits.count == icons.count else { break }
            for entry in numbers {
                var index = 0
                for (step, limit) in limits.enumerated().dropFirst() {
                    guard let limit else { continue }
                    if set.thresholds[step].isInclusive ? entry.value >= limit : entry.value > limit { index = step }
                }
                var applied = style
                applied.icon = icons[set.isReversed ? icons.count - 1 - index : index]
                if !set.showsValue { applied.hidesValue = true }
                styles[entry.address] = applied
            }
        }
        return styles
    }

    /// The colour of a scale at `value`: that of the nearest stop beyond
    /// either end, and between two stops a blend of theirs.
    static func blend(_ stops: [(value: Double, color: String)], at value: Double) -> String {
        guard let first = stops.first, let last = stops.last else { return "FFFFFFFF" }
        if value <= first.value { return first.color }
        if value >= last.value { return last.color }
        for (lower, upper) in zip(stops, stops.dropFirst()) where value <= upper.value {
            guard upper.value > lower.value else { return upper.color }
            let share = (value - lower.value) / (upper.value - lower.value)
            let from = channels(lower.color), to = channels(upper.color)
            let mixed = zip(from, to).map { Int((Double($0) + (Double($1) - Double($0)) * share).rounded()) }
            return "FF" + mixed.map { String(format: "%02X", $0) }.joined()
        }
        return last.color
    }

    /// Red, green and blue of an ARGB or RGB hex colour.
    private static func channels(_ hex: String) -> [Int] {
        let digits = Array(hex.suffix(6))
        guard digits.count == 6 else { return [255, 255, 255] }
        return stride(from: 0, to: 6, by: 2).map { Int(String(digits[$0...$0 + 1]), radix: 16) ?? 255 }
    }
}

// MARK: - Drawing

/// A filled polygon of a data bar or an icon, in the coordinates of the
/// frame it was made for. Every renderer draws these the same way.
public struct ConditionalMark: Hashable, Sendable {
    public var points: [CGPoint]
    public var colorHex: String
}

extension ConditionalStyle {
    /// Whether the cell has a data bar or an icon to draw over its fill.
    public var hasMarks: Bool { dataBar != nil || icon != nil }

    /// The bar and icon as polygons within a cell's frame, back to front.
    public func marks(in frame: CGRect, zoom: Double) -> [ConditionalMark] {
        var marks: [ConditionalMark] = []
        let inset = CGFloat(2 * zoom)
        if let dataBar, frame.width > inset * 2, frame.height > inset * 2 {
            let width = frame.width - inset * 2
            let left = frame.minX + inset + width * CGFloat(dataBar.start)
            let right = frame.minX + inset + width * CGFloat(dataBar.end)
            if right > left {
                marks.append(ConditionalMark(points: [
                    CGPoint(x: left, y: frame.minY + inset), CGPoint(x: right, y: frame.minY + inset),
                    CGPoint(x: right, y: frame.maxY - inset), CGPoint(x: left, y: frame.maxY - inset),
                ], colorHex: dataBar.colorHex))
            }
        }
        if let icon {
            let side = min(frame.height - inset * 2, CGFloat(13 * zoom), frame.width - inset * 2)
            if side > 2 {
                let square = CGRect(x: frame.minX + inset * 1.5, y: frame.midY - side / 2, width: side, height: side)
                marks += icon.marks(in: square)
            }
        }
        return marks
    }
}

extension ConditionalIcon {
    private typealias Outline = [(x: Double, y: Double)]

    /// The icon as polygons filling `square`, back to front.
    public func marks(in square: CGRect) -> [ConditionalMark] {
        let white = "FFFFFFFF"
        var layers: [(outline: Outline, color: String)] = []
        func add(_ outlines: [Outline], _ color: String) { layers += outlines.map { ($0, color) } }

        switch shape {
        case .arrow(let degrees):
            let arrow: Outline = [(0.5, 0.04), (0.96, 0.5), (0.68, 0.5), (0.68, 0.96), (0.32, 0.96), (0.32, 0.5), (0.04, 0.5)]
            add([Self.turned(arrow, degrees: Double(degrees))], colorHex)
        case .circle: add([Self.disc()], colorHex)
        case .flag:
            add([[(0.14, 0.04), (0.26, 0.04), (0.26, 0.96), (0.14, 0.96)]], Self.black)
            add([[(0.26, 0.08), (0.94, 0.32), (0.26, 0.58)]], colorHex)
        case .triangle: add([[(0.5, 0.06), (0.97, 0.92), (0.03, 0.92)]], colorHex)
        case .diamond: add([[(0.5, 0.02), (0.98, 0.5), (0.5, 0.98), (0.02, 0.5)]], colorHex)
        case .check: add(Self.check, colorHex)
        case .cross: add(Self.cross, colorHex)
        case .exclamation: add(Self.exclamation, colorHex)
        case .circledCheck:
            add([Self.disc()], colorHex)
            add(Self.check.map { Self.scaled($0, by: 0.62) }, white)
        case .circledCross:
            add([Self.disc()], colorHex)
            add(Self.cross.map { Self.scaled($0, by: 0.62) }, white)
        case .circledExclamation:
            add([Self.disc()], colorHex)
            add(Self.exclamation.map { Self.scaled($0, by: 0.62) }, white)
        case .bars(let filled):
            for bar in 0..<4 {
                let left = 0.04 + 0.24 * Double(bar)
                let top = 0.96 - 0.23 * Double(bar + 1)
                add([[(left, top), (left + 0.19, top), (left + 0.19, 0.96), (left, 0.96)]],
                    bar < filled ? colorHex : "FFC9C9C9")
            }
        case .quarters(let filled):
            add([Self.disc()], colorHex)
            add([Self.disc(radius: 0.37)], white)
            if filled >= 4 {
                add([Self.disc(radius: 0.37)], colorHex)
            } else if filled > 0 {
                var wedge: Outline = [(0.5, 0.5)]
                let steps = 6 * filled
                for step in 0...steps {
                    let angle = Double(step) / Double(steps) * Double(filled) * .pi / 2
                    wedge.append((0.5 + 0.37 * sin(angle), 0.5 - 0.37 * cos(angle)))
                }
                add([wedge], colorHex)
            }
        }
        return layers.map { layer in
            ConditionalMark(points: layer.outline.map {
                CGPoint(x: square.minX + square.width * CGFloat($0.x), y: square.minY + square.height * CGFloat($0.y))
            }, colorHex: layer.color)
        }
    }

    private static let check: [Outline] = [
        [(0.06, 0.56), (0.22, 0.4), (0.4, 0.58), (0.78, 0.12), (0.95, 0.27), (0.41, 0.9)],
    ]
    private static let cross: [Outline] = {
        let bar: Outline = [(0.4, 0.02), (0.6, 0.02), (0.6, 0.98), (0.4, 0.98)]
        return [turned(bar, degrees: 45), turned(bar, degrees: -45)]
    }()
    private static let exclamation: [Outline] = [
        [(0.4, 0.04), (0.6, 0.04), (0.57, 0.66), (0.43, 0.66)], disc(centerY: 0.86, radius: 0.11),
    ]

    private static func disc(centerY: Double = 0.5, radius: Double = 0.47) -> Outline {
        (0..<24).map { step in
            let angle = Double(step) / 24 * 2 * .pi
            return (0.5 + radius * cos(angle), centerY + radius * sin(angle))
        }
    }

    /// Turned clockwise about the middle of the unit square.
    private static func turned(_ outline: Outline, degrees: Double) -> Outline {
        let angle = degrees * .pi / 180
        return outline.map { point in
            let x = point.x - 0.5, y = point.y - 0.5
            return (0.5 + x * cos(angle) - y * sin(angle), 0.5 + x * sin(angle) + y * cos(angle))
        }
    }

    private static func scaled(_ outline: Outline, by factor: Double) -> Outline {
        outline.map { (0.5 + ($0.x - 0.5) * factor, 0.5 + ($0.y - 0.5) * factor) }
    }
}
