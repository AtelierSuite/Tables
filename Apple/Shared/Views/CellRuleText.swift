import SwiftUI
import TablesEngine

/// How the cell rules editor names rules, values and ranges.
enum CellRuleText {
    static func symbol(of comparison: ConditionalRule.Comparison) -> String {
        switch comparison {
        case .lessThan: return "<"
        case .lessThanOrEqual: return "≤"
        case .equal: return "="
        case .notEqual: return "≠"
        case .greaterThanOrEqual: return "≥"
        case .greaterThan: return ">"
        case .between, .notBetween: return ""
        }
    }

    private static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: String(localized: String.LocalizationValue(key)), arguments: arguments)
    }

    /// What a comparison asks of a value, as "> 100" or "between 1 and 10".
    static func condition(_ comparison: ConditionalRule.Comparison, _ first: String, _ second: String) -> String {
        switch comparison {
        case .between: return format("CellRules.Summary.Between", first, second)
        case .notBetween: return format("CellRules.Summary.NotBetween", first, second)
        default: return "\(symbol(of: comparison)) \(first)"
        }
    }

    static func summary(of rule: ConditionalRule) -> String {
        switch rule.kind {
        case .test:
            let values = rule.formulas.map { DataValidation.input(for: $0) }
            guard let comparison = rule.comparison else {
                return "=" + (rule.formulas.first ?? "")
            }
            let first = values.first ?? ""
            let second = values.count > 1 ? values[1] : ""
            return format("CellRules.Summary.CellValue", condition(comparison, first, second))
        case .rank(let count, let isPercent, let isBottom):
            let amount = isPercent ? "\(count)%" : "\(count)"
            return format(isBottom ? "CellRules.Summary.Bottom" : "CellRules.Summary.Top", amount)
        case .average(let isAbove, _, _):
            return String(localized: isAbove ? "CellRules.Kind.AboveAverage" : "CellRules.Kind.BelowAverage")
        case .duplicates(let isUnique):
            return String(localized: isUnique ? "CellRules.Kind.Unique" : "CellRules.Kind.Duplicates")
        case .colorScale(let thresholds, _):
            return String(localized: thresholds.count > 2 ? "CellRules.Summary.ThreeColorScale" : "CellRules.Summary.TwoColorScale")
        case .dataBar:
            return String(localized: "CellRules.Kind.DataBar")
        case .iconSet:
            return String(localized: "CellRules.Kind.IconSet")
        }
    }

    static func summary(of rule: DataValidation) -> String {
        let kind = ValidationRuleEditor.name(of: rule.kind)
        switch rule.kind {
        case .any: return kind
        case .list:
            if let items = rule.literalItems { return "\(kind): " + items.joined(separator: ", ") }
            return "\(kind): " + DataValidation.input(for: rule.formula1)
        case .custom:
            return "\(kind): " + DataValidation.input(for: rule.formula1)
        case .whole, .decimal, .date, .time, .textLength:
            let first = DataValidation.input(for: rule.formula1)
            let second = DataValidation.input(for: rule.formula2)
            return "\(kind) " + condition(rule.comparison, first, second)
        }
    }

    static func ranges(_ ranges: [CellRange]) -> String {
        ranges.map { $0.normalized.a1 }.joined(separator: ", ")
    }

    /// Ranges as typed: references separated by commas or spaces, `$` signs
    /// allowed. Nil when any of them is not a reference.
    static func parseRanges(_ text: String) -> [CellRange]? {
        let parts = text.replacingOccurrences(of: "$", with: "").uppercased()
            .split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace })
        guard !parts.isEmpty else { return nil }
        var ranges: [CellRange] = []
        for part in parts {
            let text = String(part)
            guard let range = CellRange(a1Range: text) ?? CellAddress(a1: text).map({ CellRange($0) }) else { return nil }
            ranges.append(range.normalized)
        }
        return ranges
    }
}

/// A small picture of what a conditional format does to a cell: "Aa" in
/// its colours, or a scale, bar or icons.
struct ConditionalRuleSwatch: View {
    let rule: ConditionalRule
    var size = CGSize(width: 44, height: 28)

    var body: some View {
        content
            .frame(width: size.width, height: size.height)
            .clipShape(.rect(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var content: some View {
        switch rule.kind {
        case .colorScale(_, let colors):
            LinearGradient(colors: colors.map { Color(argbHex: $0) ?? .clear }, startPoint: .leading, endPoint: .trailing)
        case .dataBar(let bar):
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Color.white
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach([0.85, 0.5, 0.25], id: \.self) { fraction in
                            Rectangle()
                                .fill(Color(argbHex: bar.colorHex) ?? .blue)
                                .frame(width: (proxy.size.width - 6) * fraction)
                        }
                    }
                    .padding(3)
                }
            }
        case .iconSet(let set):
            IconSetStrip(name: set.name, isReversed: set.isReversed)
                .padding(.horizontal, 3)
                .background(Color.white)
        default:
            StyleSample(style: rule.style)
        }
    }
}

/// "Aa" drawn in a conditional style's fill, colour and emphasis.
struct StyleSample: View {
    let style: ConditionalStyle
    var text = "Aa"

    var body: some View {
        ZStack {
            Color(argbHex: style.fillColorHex) ?? Color.white
            Text(text)
                .font(.system(size: 14, weight: style.isBold == true ? .bold : .regular))
                .italic(style.isItalic == true)
                .underline(style.isUnderlined == true)
                .strikethrough(style.isStruckThrough == true)
                .foregroundStyle(Color(argbHex: style.textColorHex) ?? Color.black)
        }
    }
}

/// The icons of one of Excel's sets, lowest first, side by side.
struct IconSetStrip: View {
    let name: String
    var isReversed = false

    var body: some View {
        let icons = ConditionalIcon.icons(ofSet: name)
        Canvas { context, size in
            guard !icons.isEmpty else { return }
            let side = min(size.height - 4, (size.width - CGFloat(icons.count - 1) * 2) / CGFloat(icons.count))
            let total = side * CGFloat(icons.count) + CGFloat(icons.count - 1) * 2
            var x = (size.width - total) / 2
            for icon in isReversed ? icons.reversed() : icons {
                let square = CGRect(x: x, y: (size.height - side) / 2, width: side, height: side)
                for mark in icon.marks(in: square) { context.fill(mark.path, with: .color(Color(argbHex: mark.colorHex) ?? .gray)) }
                x += side + 2
            }
        }
    }
}

extension ConditionalMark {
    var path: Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        path.closeSubpath()
        return path
    }
}
