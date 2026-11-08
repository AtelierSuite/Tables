import Foundation

/// A control from Excel's Form Controls — a button, check box, option button,
/// drop-down or edit box — floating over the sheet.
///
/// Excel keeps each one as a shape in the sheet's VML drawing, mirrors its
/// settings in a `ctrlProps` part, and gives it a hidden twin in the sheet's
/// DrawingML drawing. The VML shape is kept as the file had it; only what we
/// model is written back into it, and only when it changed.
public struct FormControl: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case button
        case checkBox
        case optionButton
        case dropDown
        case editBox
        case groupBox
        case label
        /// List boxes, spinners, scroll bars and ActiveX controls: kept and
        /// shown as objects we cannot draw.
        case unsupported
    }

    public enum CheckState: Hashable, Sendable {
        case unchecked
        case checked
        /// Excel's grey "mixed" state, which a linked cell shows as `#N/A`.
        case mixed
    }

    public enum HorizontalAlignment: Hashable, Sendable {
        case leading
        case center
        case trailing
    }

    public enum VerticalAlignment: Hashable, Sendable {
        case top
        case center
        case bottom
    }

    /// The face the caption is written in, from the first `<font>` of the
    /// shape's text box.
    public struct Font: Hashable, Sendable {
        public var size: Double
        public var isBold = false
        /// `RRGGBB`, without the `#`.
        public var colorHex: String?
    }

    /// The control as it was read, so a save writes back only what changed.
    public struct Source: Hashable, Sendable {
        /// The `<v:shape>` element, verbatim.
        public var vml: String
        /// The control's `ctrlProps` part, when the file had one.
        public var propertiesPart: String?
        public var placement: ChartPlacement
        public var text: String
        public var linkedCell: ChartReference?
        public var listRange: ChartReference?
        public var checkState: CheckState
        public var selection: Int
    }

    /// The VML shape id, `_x0000_s1025`. The DrawingML twin and the sheet's
    /// `<controls>` entry name the control by its number.
    public var id: String
    public var kind: Kind
    public var placement: ChartPlacement
    /// The caption, or what an edit box holds.
    public var text = ""
    /// The macro the control runs when clicked, as Excel wrote it: `[0]!Go`,
    /// `Module1.Go`, `'Book.xlsm'!Go`.
    public var macro: String?
    /// The cell a check box, option button or drop-down writes its state to.
    public var linkedCell: ChartReference?
    /// The cells a drop-down lists.
    public var listRange: ChartReference?
    /// A check box's or option button's own state, used when no cell is linked.
    public var checkState = CheckState.unchecked
    /// The chosen entry of a drop-down, counted from 1; 0 for none.
    public var selection = 0
    /// How many entries an open drop-down shows before it scrolls.
    public var dropLines = 8
    public var isHidden = false
    public var font: Font
    public var horizontalAlignment = HorizontalAlignment.leading
    public var verticalAlignment = VerticalAlignment.center
    public var source: Source

    /// The procedure the macro names, and the module when it names one.
    public var macroTarget: (module: String?, procedure: String)? {
        guard var name = macro?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
        // A workbook qualifier — `[0]!`, `'Book.xlsm'!`, `Book.xlsm!` — always
        // means this workbook here.
        if let bang = name.lastIndex(of: "!") { name = String(name[name.index(after: bang)...]) }
        let parts = name.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard let procedure = parts.last, !procedure.isEmpty else { return nil }
        return (parts.count > 1 ? parts.dropLast().joined(separator: ".") : nil, procedure)
    }
}

// MARK: - State through linked cells

extension FormControl {
    /// What the linked cell holds, when the control has one that still exists.
    private func linkedValue(in workbook: Workbook) -> CellValue? {
        guard let linkedCell, let sheet = workbook[linkedCell.sheetID] else { return nil }
        return sheet[linkedCell.range.normalized.start].value
    }

    /// A check box shows its linked cell: `TRUE` or a non-zero number ticks
    /// it, `#N/A` greys it, anything else clears it.
    public func checkState(in workbook: Workbook) -> CheckState {
        guard let value = linkedValue(in: workbook) else { return checkState }
        switch value {
        case .boolean(let on): return on ? .checked : .unchecked
        case .number(let number): return number != 0 ? .checked : .unchecked
        case .error(.notAvailable): return .mixed
        default: return .unchecked
        }
    }

    /// A drop-down's chosen entry: the number in its linked cell, if it has one.
    public func selection(in workbook: Workbook) -> Int {
        guard linkedCell != nil else { return selection }
        guard let number = linkedValue(in: workbook)?.numericValue, number >= 1 else { return 0 }
        return Int(number)
    }

    /// The entries a drop-down offers, as their cells display them.
    public func items(in workbook: Workbook) -> [String] {
        guard let listRange, let sheet = workbook[listRange.sheetID] else { return [] }
        let box = listRange.range.normalized
        var items: [String] = []
        for row in box.start.row...box.end.row {
            for column in box.start.column...box.end.column {
                items.append(CellFormatter.displayText(for: sheet[CellAddress(row: row, column: column)]))
            }
        }
        return items
    }
}

extension Worksheet {
    /// The option buttons that switch each other off, by index into
    /// `formControls`: those inside the same group box, and the rest of the
    /// sheet's as one group, each in drawing order.
    public func optionGroups() -> [[Int]] {
        let boxes = formControls.indices.filter { formControls[$0].kind == .groupBox }
        var groups: [Int?: [Int]] = [:]
        var order: [Int?] = []
        for index in formControls.indices where formControls[index].kind == .optionButton {
            let corner = formControls[index].placement.from
            let box = boxes.first { formControls[$0].placement.contains(corner) }
            if groups[box] == nil { order.append(box) }
            groups[box, default: []].append(index)
        }
        return order.compactMap { groups[$0] }
    }

    /// The option buttons grouped with the given one, itself included.
    public func optionGroup(containing index: Int) -> [Int] {
        optionGroups().first { $0.contains(index) } ?? [index]
    }

    /// Whether an option button is the one chosen in its group. A group with
    /// a linked cell is decided by the number in it; one without, by the
    /// buttons' own states.
    public func isOptionChosen(_ index: Int, in workbook: Workbook) -> Bool {
        let group = optionGroup(containing: index)
        guard let link = group.lazy.compactMap({ self.formControls[$0].linkedCell }).first else {
            return formControls[index].checkState == .checked
        }
        guard let sheet = workbook[link.sheetID],
              let number = sheet[link.range.normalized.start].value.numericValue else { return false }
        return group.firstIndex(of: index).map { $0 + 1 } == Int(number)
    }
}

extension ChartPlacement {
    /// Whether a point on the sheet falls inside the rectangle the corners span.
    public func contains(_ point: ChartAnchor) -> Bool {
        let row = (point.row, point.rowOffset)
        let column = (point.column, point.columnOffset)
        return row >= (from.row, from.rowOffset) && row <= (to.row, to.rowOffset)
            && column >= (from.column, from.columnOffset) && column <= (to.column, to.columnOffset)
    }
}

// MARK: - Using a control

extension Workbook {
    /// Ticks or clears a check box, writing `TRUE` or `FALSE` to its linked
    /// cell as Excel does. A mixed box clicks to ticked.
    public mutating func toggleCheckBox(_ id: FormControl.ID, on sheetID: Worksheet.ID) {
        guard let (sheet, index) = formControl(id, on: sheetID) else { return }
        let control = sheets[sheet].formControls[index]
        let checked = control.checkState(in: self) != .checked
        sheets[sheet].formControls[index].checkState = checked ? .checked : .unchecked
        writeLinkedCell(control.linkedCell, .boolean(checked))
    }

    /// Chooses an option button, clearing the others in its group and
    /// writing its place in the group, from 1, to the group's linked cell.
    public mutating func chooseOptionButton(_ id: FormControl.ID, on sheetID: Worksheet.ID) {
        guard let (sheet, index) = formControl(id, on: sheetID) else { return }
        let group = sheets[sheet].optionGroup(containing: index)
        for member in group {
            sheets[sheet].formControls[member].checkState = member == index ? .checked : .unchecked
        }
        let link = group.compactMap { sheets[sheet].formControls[$0].linkedCell }.first
        if let position = group.firstIndex(of: index) { writeLinkedCell(link, .number(Double(position + 1))) }
    }

    /// Picks a drop-down's entry, counted from 1, writing its number to the
    /// linked cell.
    public mutating func selectDropDownItem(_ item: Int, in id: FormControl.ID, on sheetID: Worksheet.ID) {
        guard let (sheet, index) = formControl(id, on: sheetID) else { return }
        sheets[sheet].formControls[index].selection = item
        writeLinkedCell(sheets[sheet].formControls[index].linkedCell, .number(Double(item)))
    }

    /// Replaces what an edit box holds.
    public mutating func setEditBoxText(_ text: String, in id: FormControl.ID, on sheetID: Worksheet.ID) {
        guard let (sheet, index) = formControl(id, on: sheetID) else { return }
        sheets[sheet].formControls[index].text = text
    }

    private func formControl(_ id: FormControl.ID, on sheetID: Worksheet.ID) -> (Int, Int)? {
        guard let sheet = index(of: sheetID),
              let control = sheets[sheet].formControls.firstIndex(where: { $0.id == id }) else { return nil }
        return (sheet, control)
    }

    /// A control's value replaces whatever the cell held, formula included,
    /// and keeps its formatting.
    private mutating func writeLinkedCell(_ reference: ChartReference?, _ value: CellValue) {
        guard let reference, let sheet = index(of: reference.sheetID) else { return }
        let address = reference.range.normalized.start
        var cell = sheets[sheet][address]
        cell.value = value
        cell.formula = nil
        sheets[sheet][address] = cell
        recalculate()
    }

    /// Lets every control's linked cell and list follow rows or columns
    /// inserted into or removed from one sheet.
    public mutating func formControlsFollow(
        _ operation: FormulaReferenceShifter.Operation, axis: FormulaReferenceShifter.Axis,
        on sheetID: Worksheet.ID
    ) {
        func follow(_ reference: inout ChartReference?) {
            guard let current = reference, current.sheetID == sheetID else { return }
            reference = current.shifted(operation, axis: axis)
        }
        for sheet in sheets.indices {
            for index in sheets[sheet].formControls.indices {
                follow(&sheets[sheet].formControls[index].linkedCell)
                follow(&sheets[sheet].formControls[index].listRange)
            }
        }
    }
}
