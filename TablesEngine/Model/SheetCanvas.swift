import Foundation

/// Sheets laid out together on one page, each shown as a table, the way a
/// Numbers sheet holds its tables.
///
/// Excel has no such thing: there, every sheet is one grid. A canvas groups
/// worksheets without changing them, so a file read by anything else still
/// has each of them as a sheet of its own; only where they sit is extra.
public struct SheetCanvas: Hashable, Sendable, Identifiable {
    /// One sheet's place on the canvas.
    public struct Table: Hashable, Sendable {
        public var sheetID: Worksheet.ID
        /// Where the table's first cell sits on the canvas, in points at
        /// 100%. Its size is the sheet's own.
        public var x: Double
        public var y: Double
        /// Whether the table's name is shown above it.
        public var showsName: Bool
        /// What the table is called when that is not its sheet's name: a
        /// Numbers table's own name, its sheet being named for both.
        public var name: String?

        public init(sheetID: Worksheet.ID, x: Double, y: Double, showsName: Bool = true, name: String? = nil) {
            self.sheetID = sheetID
            self.x = x
            self.y = y
            self.showsName = showsName
            self.name = name
        }
    }

    public var id = UUID()
    public var name: String
    /// The tables, in the order they are listed.
    public var tables: [Table]

    public init(name: String, tables: [Table]) {
        self.name = name
        self.tables = tables
    }

    public func table(for sheetID: Worksheet.ID) -> Table? {
        tables.first { $0.sheetID == sheetID }
    }

    public func contains(_ sheetID: Worksheet.ID) -> Bool {
        tables.contains { $0.sheetID == sheetID }
    }

    /// The space Tables leaves around and between what it places itself.
    public static let margin = 40.0
    /// How tall a table's name above it is, in points at 100%.
    public static let nameHeight = 26.0
}

extension Workbook {
    /// The canvas a sheet is laid out on, when it shares one.
    public func canvas(containing sheetID: Worksheet.ID) -> SheetCanvas? {
        canvases.first { $0.contains(sheetID) }
    }

    /// The sheets on a canvas, in the canvas's order, hidden ones left out.
    public func sheets(on canvas: SheetCanvas) -> [Worksheet] {
        canvas.tables.compactMap { self[$0.sheetID] }.filter { !$0.isHidden }
    }

    /// What a table on a canvas is called.
    public func tableName(of sheetID: Worksheet.ID) -> String {
        let named = canvas(containing: sheetID)?.table(for: sheetID)?.name
        return named.flatMap { $0.isEmpty ? nil : $0 } ?? self[sheetID]?.name ?? ""
    }

    /// Lays `sheetID` out on the canvas `target` is on, starting one with
    /// the two when `target` has a sheet to itself. The sheet goes below
    /// the tables already there, and moves to sit after them in the tabs.
    @discardableResult
    public mutating func placeSheet(_ sheetID: Worksheet.ID, onCanvasWith target: Worksheet.ID) -> Bool {
        guard sheetID != target, let sheet = self[sheetID], let anchor = self[target],
              !sheet.isChartSheet, !anchor.isChartSheet else { return false }
        removeFromCanvas(sheetID)
        let index: Int
        if let existing = canvases.firstIndex(where: { $0.contains(target) }) {
            index = existing
        } else {
            canvases.append(SheetCanvas(name: anchor.name, tables: [
                SheetCanvas.Table(sheetID: target, x: SheetCanvas.margin, y: SheetCanvas.margin + SheetCanvas.nameHeight),
            ]))
            index = canvases.count - 1
        }
        let bottom = canvases[index].tables.compactMap { table in
            self[table.sheetID].map { table.y + $0.totalHeight }
        }.max() ?? 0
        canvases[index].tables.append(SheetCanvas.Table(
            sheetID: sheetID, x: SheetCanvas.margin, y: bottom + SheetCanvas.margin + SheetCanvas.nameHeight))
        keepCanvasTogether(canvases[index])
        return true
    }

    /// Takes a sheet off its canvas, back to a sheet of its own. A canvas
    /// left with a single table is no longer one.
    public mutating func removeFromCanvas(_ sheetID: Worksheet.ID) {
        guard let index = canvases.firstIndex(where: { $0.contains(sheetID) }) else { return }
        canvases[index].tables.removeAll { $0.sheetID == sheetID }
        if canvases[index].tables.count < 2 { canvases.remove(at: index) }
    }

    /// Moves a table on its canvas, to a place in points at 100%.
    public mutating func moveTable(_ sheetID: Worksheet.ID, toX x: Double, y: Double) {
        guard let canvas = canvases.firstIndex(where: { $0.contains(sheetID) }),
              let table = canvases[canvas].tables.firstIndex(where: { $0.sheetID == sheetID }) else { return }
        canvases[canvas].tables[table].x = max(0, x)
        canvases[canvas].tables[table].y = max(0, y)
    }

    public mutating func renameCanvas(_ id: SheetCanvas.ID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = canvases.firstIndex(where: { $0.id == id }) else { return }
        canvases[index].name = trimmed
    }

    /// Drops what no longer exists from the canvases: sheets deleted, and
    /// canvases left with fewer than two tables.
    mutating func pruneCanvases() {
        let ids = Set(sheets.map(\.id))
        for index in canvases.indices.reversed() {
            canvases[index].tables.removeAll { !ids.contains($0.sheetID) }
            if canvases[index].tables.count < 2 { canvases.remove(at: index) }
        }
    }

    /// Puts a canvas's sheets next to one another in the tabs, where the
    /// first of them is, in the canvas's order.
    mutating func keepCanvasTogether(_ canvas: SheetCanvas) {
        let members = canvas.tables.map(\.sheetID)
        guard let first = sheets.firstIndex(where: { canvas.contains($0.id) }) else { return }
        let before = sheets[..<first].count
        let moved = members.compactMap { id in sheets.first { $0.id == id } }
        sheets.removeAll { canvas.contains($0.id) }
        sheets.insert(contentsOf: moved, at: min(before, sheets.count))
    }
}
