import Foundation

/// One entry in the function reference: how a function is written, what it
/// does, and an example of it in use.
///
/// The syntax and example are Excel's, in English, since that is how the
/// function is typed whatever the language; the summary is translated, in
/// the `Functions` string table.
struct FunctionReference: Identifiable, Hashable, Decodable {
    let name: String
    let category: Category
    let syntax: String
    let example: String

    var id: String { name }

    var summary: String {
        String(localized: String.LocalizationValue(name), table: "Functions")
    }

    /// Excel's own grouping of its functions, which the reference is browsed by.
    enum Category: String, CaseIterable, Identifiable, Decodable {
        case math, statistical, logical, text, dateTime, lookup, financial
        case engineering, database, information, web, compatibility

        var id: String { rawValue }

        var title: String {
            switch self {
            case .math: String(localized: "FunctionCategory.Math")
            case .statistical: String(localized: "FunctionCategory.Statistical")
            case .logical: String(localized: "FunctionCategory.Logical")
            case .text: String(localized: "FunctionCategory.Text")
            case .dateTime: String(localized: "FunctionCategory.DateTime")
            case .lookup: String(localized: "FunctionCategory.Lookup")
            case .financial: String(localized: "FunctionCategory.Financial")
            case .engineering: String(localized: "FunctionCategory.Engineering")
            case .database: String(localized: "FunctionCategory.Database")
            case .information: String(localized: "FunctionCategory.Information")
            case .web: String(localized: "FunctionCategory.Web")
            case .compatibility: String(localized: "FunctionCategory.Compatibility")
            }
        }

        var symbol: String {
            switch self {
            case .math: "plus.forwardslash.minus"
            case .statistical: "chart.bar.xaxis"
            case .logical: "arrow.triangle.branch"
            case .text: "textformat"
            case .dateTime: "calendar"
            case .lookup: "magnifyingglass"
            case .financial: "dollarsign.circle"
            case .engineering: "gearshape.2"
            case .database: "cylinder.split.1x2"
            case .information: "info.circle"
            case .web: "globe"
            case .compatibility: "clock.arrow.circlepath"
            }
        }
    }

    /// Every function the engine runs, by name.
    static let all: [FunctionReference] = {
        guard let url = Bundle.main.url(forResource: "FunctionReference", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([FunctionReference].self, from: data) else { return [] }
        return entries
    }()

    /// The functions in a category, or every function, matching a search of
    /// their names and summaries.
    static func entries(in category: Category?, matching query: String) -> [FunctionReference] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return all.filter { entry in
            (category == nil || entry.category == category)
                && (trimmed.isEmpty
                    || entry.name.localizedCaseInsensitiveContains(trimmed)
                    || entry.summary.localizedCaseInsensitiveContains(trimmed))
        }
        .sorted { lhs, rhs in
            // A name starting with what was typed comes before one merely containing it.
            let left = lhs.name.lowercased().hasPrefix(trimmed.lowercased())
            let right = rhs.name.lowercased().hasPrefix(trimmed.lowercased())
            return left != right ? left : lhs.name < rhs.name
        }
    }
}
