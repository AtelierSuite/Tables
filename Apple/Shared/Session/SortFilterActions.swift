import Foundation
import TablesEngine

/// Sorting rows and filtering them, as the menus and panels ask for it.
extension EditorState {
    /// Whether the document keeps a filter: a workbook does, delimited text
    /// and a Numbers document do not.
    var allowsFiltering: Bool { !isNumbersDocument && !formatting.isEmpty }

    /// The range a sort or a new filter would take from the selection, and
    /// whether its first row is a header.
    func dataRange(in workbook: Workbook) -> (range: CellRange, hasHeader: Bool) {
        workbook.dataRange(for: selection, onSheetAt: activeIndex(in: workbook))
    }

    /// Sorts the rows of `range`, the first key counting most. Says why when
    /// it cannot.
    func sort(_ range: CellRange, by keys: [SortKey], hasHeader: Bool, in workbook: inout Workbook) {
        let index = activeIndex(in: workbook)
        do {
            try workbook.sheets[index].sortRows(in: range, by: keys, hasHeader: hasHeader)
        } catch {
            switch error {
            case .mergedCells: errorMessage = String(localized: "Sort.Failed.MergedCells")
            case .arrayFormula: errorMessage = String(localized: "Sort.Failed.ArrayFormula")
            }
            return
        }
        finishFilterEdit(in: &workbook)
    }

    /// Sorts the data around the selection by the selected cell's column.
    func sortSelection(ascending: Bool, in workbook: inout Workbook) {
        let (range, hasHeader) = dataRange(in: workbook)
        let column = min(max(selectedAddress.column, range.start.column), range.end.column)
        sort(range, by: [SortKey(column: column, isAscending: ascending)], hasHeader: hasHeader, in: &workbook)
    }

    /// Puts a filter on the data around the selection, or takes the sheet's
    /// filter away.
    func toggleAutoFilter(in workbook: inout Workbook) {
        guard allowsFiltering else { return }
        let index = activeIndex(in: workbook)
        if workbook.sheets[index].autoFilter != nil {
            workbook.sheets[index].setAutoFilter(on: nil)
            filterColumn = nil
            if presentedPanel == .filter { presentedPanel = nil }
        } else {
            let range = dataRange(in: workbook).range
            workbook.sheets[index].setAutoFilter(on: range)
            filterColumn = min(max(selectedAddress.column, range.start.column), range.end.column)
        }
        finishFilterEdit(in: &workbook)
    }

    func setFilter(_ criterion: AutoFilter.Criterion?, forColumn column: Int, in workbook: inout Workbook) {
        workbook.sheets[activeIndex(in: workbook)].setFilter(criterion, forColumn: column)
        finishFilterEdit(in: &workbook)
    }

    /// Shows every row again, keeping the filter's buttons.
    func clearFilters(in workbook: inout Workbook) {
        workbook.sheets[activeIndex(in: workbook)].clearFilterCriteria()
        finishFilterEdit(in: &workbook)
    }

    /// Opens the filter panel on a column of the filter: the given one, or
    /// the selected cell's.
    func showFilter(forColumn column: Int? = nil, in workbook: Workbook) {
        guard allowsFiltering else { return }
        if let range = activeSheet(in: workbook).autoFilter?.range {
            let wanted = column ?? selectedAddress.column
            filterColumn = min(max(wanted, range.start.column), range.end.column)
        }
        presentedPanel = .filter
    }

    /// `SUBTOTAL` answers for the rows now showing, and the grid is measured
    /// without the ones now hidden.
    private func finishFilterEdit(in workbook: inout Workbook) {
        workbook.recalculate()
        clampSelection(to: activeSheet(in: workbook))
        refreshMetrics(in: workbook)
    }
}

/// The conditions the filter panel offers for one column.
enum FilterConditionKind: String, CaseIterable, Identifiable {
    case equals, doesNotEqual, greaterThan, greaterThanOrEqual, lessThan, lessThanOrEqual
    case contains, doesNotContain, beginsWith, endsWith, top, bottom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .equals: return String(localized: "Filter.Condition.Equals")
        case .doesNotEqual: return String(localized: "Filter.Condition.DoesNotEqual")
        case .greaterThan: return String(localized: "Filter.Condition.GreaterThan")
        case .greaterThanOrEqual: return String(localized: "Filter.Condition.GreaterThanOrEqual")
        case .lessThan: return String(localized: "Filter.Condition.LessThan")
        case .lessThanOrEqual: return String(localized: "Filter.Condition.LessThanOrEqual")
        case .contains: return String(localized: "Filter.Condition.Contains")
        case .doesNotContain: return String(localized: "Filter.Condition.DoesNotContain")
        case .beginsWith: return String(localized: "Filter.Condition.BeginsWith")
        case .endsWith: return String(localized: "Filter.Condition.EndsWith")
        case .top: return String(localized: "Filter.Condition.Top")
        case .bottom: return String(localized: "Filter.Condition.Bottom")
        }
    }

    /// Text taken literally inside a wildcard pattern.
    private static func escaped(_ text: String) -> String {
        var result = ""
        for character in text {
            if "*?~".contains(character) { result.append("~") }
            result.append(character)
        }
        return result
    }

    private static func unescaped(_ text: String) -> String? {
        var result = ""
        var isEscaping = false
        for character in text {
            if isEscaping {
                result.append(character)
                isEscaping = false
            } else if character == "~" {
                isEscaping = true
            } else if character == "*" || character == "?" {
                return nil
            } else {
                result.append(character)
            }
        }
        return isEscaping ? nil : result
    }

    /// The criterion this condition and the typed value stand for, or nil
    /// when the value does not suit it.
    func criterion(for value: String) -> AutoFilter.Criterion? {
        let value = value.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        switch self {
        case .equals: return .conditions(.init(.equal, value))
        case .doesNotEqual: return .conditions(.init(.notEqual, value))
        case .greaterThan: return .conditions(.init(.greaterThan, value))
        case .greaterThanOrEqual: return .conditions(.init(.greaterThanOrEqual, value))
        case .lessThan: return .conditions(.init(.lessThan, value))
        case .lessThanOrEqual: return .conditions(.init(.lessThanOrEqual, value))
        case .contains: return .conditions(.init(.equal, "*" + Self.escaped(value) + "*"))
        case .doesNotContain: return .conditions(.init(.notEqual, "*" + Self.escaped(value) + "*"))
        case .beginsWith: return .conditions(.init(.equal, Self.escaped(value) + "*"))
        case .endsWith: return .conditions(.init(.equal, "*" + Self.escaped(value)))
        case .top, .bottom:
            guard let count = Double(value), count >= 1 else { return nil }
            return .top(count: count.rounded(.down), isBottom: self == .bottom)
        }
    }

    /// The condition and value the panel shows for a criterion, when it is
    /// one the panel can offer: a single condition, or so many items.
    static func described(_ criterion: AutoFilter.Criterion?) -> (kind: FilterConditionKind, value: String)? {
        switch criterion {
        case .conditions(let condition, nil, _):
            let value = condition.value
            switch condition.comparison {
            case .greaterThan: return (.greaterThan, value)
            case .greaterThanOrEqual: return (.greaterThanOrEqual, value)
            case .lessThan: return (.lessThan, value)
            case .lessThanOrEqual: return (.lessThanOrEqual, value)
            case .equal, .notEqual:
                let isEqual = condition.comparison == .equal
                if let plain = unescaped(value) { return (isEqual ? .equals : .doesNotEqual, plain) }
                if value.hasPrefix("*"), value.hasSuffix("*"), value.count > 2,
                   let inner = unescaped(String(value.dropFirst().dropLast())) {
                    return (isEqual ? .contains : .doesNotContain, inner)
                }
                if isEqual, value.hasSuffix("*"), let inner = unescaped(String(value.dropLast())) {
                    return (.beginsWith, inner)
                }
                if isEqual, value.hasPrefix("*"), let inner = unescaped(String(value.dropFirst())) {
                    return (.endsWith, inner)
                }
                return (isEqual ? .equals : .doesNotEqual, value)
            }
        case .top(let count, false, let isBottom):
            return (isBottom ? .bottom : .top, CellValue.plainNumberString(count))
        default:
            return nil
        }
    }
}
