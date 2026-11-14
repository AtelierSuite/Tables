import Foundation

/// One value of a pivot cache: a source cell as the cache remembers it.
public enum PivotValue: Hashable, Sendable {
    case blank
    case number(Double)
    case text(String)
    case boolean(Bool)
    case error(String)
    /// A date, as its serial number in the 1900 date system.
    case date(Double)

    /// The number a value field sums, for the values that are numbers.
    public var number: Double? {
        switch self {
        case .number(let value), .date(let value): return value
        default: return nil
        }
    }

    /// What two values are compared by when they are grouped into one item:
    /// Excel takes text that differs only in case as the same item.
    public var groupingKey: PivotValue {
        if case .text(let text) = self { return .text(text.lowercased()) }
        return self
    }

    /// The value as a cell holds it.
    public var cellValue: CellValue {
        switch self {
        case .blank: return .empty
        case .number(let value), .date(let value): return .number(value)
        case .text(let text): return .text(text)
        case .boolean(let flag): return .boolean(flag)
        case .error(let raw): return .error(CellError(rawValue: raw) ?? .valueError)
        }
    }

    /// The value as a field list or a filter names it.
    public var label: String {
        switch self {
        case .blank: return PivotTable.blankCaption
        case .date(let serial):
            return CellFormatter.displayText(for: .number(serial), format: serial == serial.rounded() ? "yyyy-mm-dd" : "yyyy-mm-dd hh:mm")
        default: return cellValue.stringValue
        }
    }
}

/// One column of a pivot cache's source.
public struct PivotCacheField: Hashable, Sendable {
    public var name: String
    /// The field's distinct values, which the records and a PivotTable's
    /// items name by position. Empty for a field whose records hold their
    /// values themselves, as a column of amounts does.
    public var sharedItems: [PivotValue] = []
    /// Whether the cache keeps this field's values as shared items.
    public var usesSharedItems = false
    /// A calculated or grouped field, which a refresh cannot work out.
    public var isDerived = false
    /// Whether the records hold a value for the field: all but calculated
    /// fields and the groups made of another field.
    public var isStored = true

    public init(name: String) { self.name = name }
}

/// Where a pivot cache's records come from.
public enum PivotSource: Hashable, Sendable {
    /// Cells of this workbook: a range on a sheet, or a name or a table.
    case worksheet(sheet: String?, reference: String?, name: String?)
    /// Another workbook, a database, a consolidation or a data model.
    case other(String)
}

/// A pivot cache: the copy of the source data PivotTables summarize.
public struct PivotCache: Hashable, Sendable, Identifiable {
    /// The number PivotTables and the workbook name the cache by.
    public var cacheID: Int
    public var id: Int { cacheID }
    /// The cache definition's place in the package.
    public var partPath: String
    /// And that of its records, when the file saved them.
    public var recordsPath: String?
    public var source: PivotSource
    public var fields: [PivotCacheField]
    /// The source's rows, a value for each field.
    public var records: [[PivotValue]]
}

/// How a value field summarizes the records of one cell.
public enum PivotAggregation: String, CaseIterable, Hashable, Sendable {
    case sum, count, average, max, min, product, countNums, stdDev, stdDevp, `var`, varp

    /// The five offered when a value field is changed.
    public static let common: [PivotAggregation] = [.sum, .count, .average, .max, .min]

    /// "Sum", as in the "Sum of Amount" Excel names a value field.
    public var label: String {
        switch self {
        case .sum: return "Sum"
        case .count: return "Count"
        case .average: return "Average"
        case .max: return "Max"
        case .min: return "Min"
        case .product: return "Product"
        case .countNums: return "Count Numbers"
        case .stdDev: return "StdDev"
        case .stdDevp: return "StdDevp"
        case .var: return "Var"
        case .varp: return "Varp"
        }
    }
}

/// The four areas of a PivotTable a field can be in.
public enum PivotArea: String, CaseIterable, Hashable, Sendable {
    case filters, columns, rows, values
}

/// One entry of a PivotTable field's item list.
public struct PivotItem: Hashable, Sendable {
    /// The shared item of the cache field this is; nil for a subtotal entry.
    public var sharedIndex: Int?
    /// The `t` the file gave a subtotal entry, `default` being the usual one.
    public var kind: String?
    /// Filtered out: its records are left out of the PivotTable.
    public var isHidden = false

    public init(sharedIndex: Int?, kind: String? = nil, isHidden: Bool = false) {
        self.sharedIndex = sharedIndex
        self.kind = kind
        self.isHidden = isHidden
    }
}

/// One field of a PivotTable; there is one for each field of its cache.
public struct PivotField: Hashable, Sendable {
    public var name: String
    public var items: [PivotItem] = []
    /// Whether an outer field's groups get a subtotal.
    public var hasDefaultSubtotal = true
    /// Compact form: the next row field shares this one's column.
    public var isCompact = true
    /// Outline form: a group starts with a row of its own. Tabular otherwise.
    public var isOutline = true
    /// The subtotal is on the group's first row, not after its last.
    public var subtotalOnTop = true
    /// `ascending` or `descending`, or nil for the order the items are in.
    public var sortType: String?
    /// The field has subtotals of its own choosing, which are not worked out.
    public var hasCustomSubtotals = false
    /// The field's place among the fields the file's definition lists, so a
    /// save keeps what the file said of it. Nil for a field new to the cache.
    public var fileIndex: Int?

    public init(name: String) { self.name = name }
}

/// A field in the filter area, and the one item it shows when it is not all.
public struct PivotFilter: Hashable, Sendable {
    public var field: Int
    /// A place in the field's `items`.
    public var selectedItem: Int?

    public init(field: Int, selectedItem: Int? = nil) {
        self.field = field
        self.selectedItem = selectedItem
    }
}

/// A field in the values area.
public struct PivotDataField: Hashable, Sendable {
    public var name: String
    public var field: Int
    public var aggregation: PivotAggregation
    /// "Show values as", when it is anything but the values themselves.
    public var showDataAs: String?
    public var numberFormatID: Int?

    public init(name: String, field: Int, aggregation: PivotAggregation) {
        self.name = name
        self.field = field
        self.aggregation = aggregation
    }
}

/// A PivotTable: a summary of a cache's records laid out on a sheet.
public struct PivotTable: Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var name: String
    /// The sheet the PivotTable is on.
    public var sheetID: Worksheet.ID
    /// The definition's place in the package.
    public var partPath: String
    public var cacheID: Int
    /// The cells the PivotTable fills, its filters above them left out.
    public var location: CellRange
    public var firstHeaderRow = 1
    public var firstDataRow = 1
    public var firstDataColumn = 1
    public var fields: [PivotField] = []
    /// Fields by their place in `fields`; `valuesField` stands for the
    /// value fields' names when there are several.
    public var rowFields: [Int] = []
    public var columnFields: [Int] = []
    public var filters: [PivotFilter] = []
    public var dataFields: [PivotDataField] = []
    /// A total of each row, in a column at the right.
    public var showsRowGrandTotals = true
    /// A total of each column, in a row at the bottom.
    public var showsColumnGrandTotals = true
    public var rowHeaderCaption: String?
    public var columnHeaderCaption: String?
    public var grandTotalCaption: String?
    /// Whether the layout was changed since the file was read, so that what
    /// the file says about the old one is left out of a save.
    public var hasChangedLayout = false

    /// Stands in `rowFields` or `columnFields` for the value fields.
    public static let valuesField = -2
    public static let blankCaption = "(blank)"

    /// The cells the filters take, above the PivotTable, if it has any.
    public var filterRange: CellRange? {
        guard !filters.isEmpty else { return nil }
        let top = location.start.row - filters.count - 1
        guard top >= 0 else { return nil }
        return CellRange(
            start: CellAddress(row: top, column: location.start.column),
            end: CellAddress(row: location.start.row - 2, column: location.start.column + 1))
    }

    /// The area a field is in, if it is in one. A field can be a value field
    /// as well as being in another area; the other area is the one named.
    public func area(of field: Int) -> PivotArea? {
        if rowFields.contains(field) { return .rows }
        if columnFields.contains(field) { return .columns }
        if filters.contains(where: { $0.field == field }) { return .filters }
        if dataFields.contains(where: { $0.field == field }) { return .values }
        return nil
    }

    /// The fields of an area, in order, the stand-in for the values left out.
    public func fields(in area: PivotArea) -> [Int] {
        switch area {
        case .rows: return rowFields.filter { $0 >= 0 }
        case .columns: return columnFields.filter { $0 >= 0 }
        case .filters: return filters.map(\.field)
        case .values: return dataFields.map(\.field)
        }
    }
}

/// A slicer's cache: the field it filters and the PivotTables it filters.
public struct SlicerCache: Hashable, Sendable, Identifiable {
    public var id: String { partPath }
    public var partPath: String
    /// The `uri` of the workbook extension that declared it, which tells a
    /// PivotTable's slicer from a table's.
    public var extensionURI: String
    public var name: String
    /// The name of the field it filters.
    public var sourceName: String
    /// The PivotTables it filters.
    public var targets: [Target] = []
    public var pivotCacheID: Int?
    /// Its buttons: the shared item each stands for, and whether it is on.
    public var items: [Item] = []
    /// The captions of the slicers drawn from this cache.
    public var captions: [String] = []

    public struct Item: Hashable, Sendable {
        public var sharedIndex: Int
        public var isSelected: Bool
    }

    /// A PivotTable as a slicer cache names it: by its own name and the
    /// number the file gives its sheet.
    public struct Target: Hashable, Sendable {
        public var sheetNumber: Int?
        public var name: String
    }

    public static let pivotExtensionURI = "{BBE1A952-AA13-448e-AADC-164F8A28A991}"
    public static let tableExtensionURI = "{46BE6895-7355-4a93-B00E-2C351335B9C9}"

    /// A table's slicer filters the table's rows, not a PivotTable.
    public var isTableSlicer: Bool { extensionURI == Self.tableExtensionURI }
}

extension Workbook {
    public func pivotCache(_ cacheID: Int) -> PivotCache? { pivotCaches.first { $0.cacheID == cacheID } }

    public func pivotTable(_ id: PivotTable.ID) -> PivotTable? { pivotTables.first { $0.id == id } }

    /// The PivotTable whose cells or filters `address` is among.
    public func pivotTable(at address: CellAddress, on sheetID: Worksheet.ID) -> PivotTable? {
        pivotTables.first {
            $0.sheetID == sheetID && ($0.location.contains(address) || $0.filterRange?.contains(address) == true)
        }
    }

    /// The slicers that filter a PivotTable.
    public func slicerCaches(for pivot: PivotTable) -> [SlicerCache] {
        let sheetNumber = self[pivot.sheetID]?.fileSheetID
        return slicerCaches.filter { cache in
            !cache.isTableSlicer && cache.targets.contains {
                $0.name == pivot.name && ($0.sheetNumber == nil || sheetNumber == nil || $0.sheetNumber == sheetNumber)
            }
        }
    }
}
