import Foundation

/// Kept worksheet children that name rows, columns or ranges of their own
/// sheet: page breaks, the remembered sort, protected ranges and ignored
/// errors. Tables does not model them, but carries them through a save, so
/// they have to follow the lines they name when rows or columns come and go.
extension Worksheet {
    /// Moves the kept page breaks, sort state, protected ranges and ignored
    /// errors through rows or columns inserted or removed. Anything the edit
    /// took away goes with it; a fragment the edit did not touch stays
    /// exactly as the file had it.
    mutating func shiftKeptReferences(
        _ operation: FormulaReferenceShifter.Operation, axis: FormulaReferenceShifter.Axis
    ) {
        shiftAutoFilter(operation, axis: axis)
        if case .translate = operation { return }
        preservedElements = preservedElements.compactMap { element in
            let shift: (XMLElement) -> Bool?
            switch element.name {
            case "rowBreaks":
                guard axis == .row else { return element }
                shift = { Self.shiftBreaks($0, operation, last: Self.lastFileRow) }
            case "colBreaks":
                guard axis == .column else { return element }
                shift = { Self.shiftBreaks($0, operation, last: Self.lastFileColumn) }
            case "sortState":
                shift = { Self.shiftSortState($0, operation, axis: axis) }
            case "protectedRanges":
                shift = { Self.shiftSqrefChildren($0, named: "protectedRange", operation, axis: axis) }
            case "ignoredErrors":
                shift = { Self.shiftSqrefChildren($0, named: "ignoredError", operation, axis: axis) }
            default:
                return element
            }
            guard let root = try? XMLLite.parse(Data(element.xml.utf8)) else { return element }
            // nil: nothing of it is left. false: untouched.
            guard let changed = shift(root) else { return nil }
            guard changed, let xml = XMLLite.serialize(root) else { return element }
            return PreservedElement(name: element.name, xml: xml)
        }
    }

    private static let lastFileRow = 1_048_575
    private static let lastFileColumn = 16_383

    /// A `<brk id>` is the zero-based line the break sits before, so it moves
    /// with that line. A break whose line is removed is removed with it.
    private static func shiftBreaks(
        _ root: XMLElement, _ operation: FormulaReferenceShifter.Operation, last: Int
    ) -> Bool? {
        guard !root.children(named: "brk").isEmpty else { return false }
        var changed = false
        for brk in root.children(named: "brk") {
            guard let id = brk.attribute("id").flatMap(Int.init) else { continue }
            let landed: Int?
            switch operation {
            case .insert(let index, let count): landed = id >= index ? id + count : id
            case .remove(let range):
                landed = range.contains(id) ? nil : (id > range.upperBound ? id - range.count : id)
            case .translate: landed = id
            }
            guard landed != id else { continue }
            changed = true
            if let landed, landed <= last {
                brk.setAttribute("id", String(landed))
            } else {
                root.removeChild(brk)
            }
        }
        let breaks = root.children(named: "brk")
        guard !breaks.isEmpty else { return nil }
        guard changed else { return false }
        root.setAttribute("count", String(breaks.count))
        if root.attribute("manualBreakCount") != nil {
            let manual = breaks.filter { ["1", "true"].contains($0.attribute("man") ?? "") }.count
            root.setAttribute("manualBreakCount", String(manual))
        }
        return true
    }

    /// The sorted range and each condition's column or row follow the edit.
    /// A sort whose range went loses the whole state; a condition whose own
    /// range went is dropped, and the state with it if none is left.
    static func shiftSortState(
        _ root: XMLElement, _ operation: FormulaReferenceShifter.Operation,
        axis: FormulaReferenceShifter.Axis
    ) -> Bool? {
        guard let ref = root.attribute("ref") else { return false }
        let old = ConditionalRule.ranges(sqref: ref)
        guard !old.isEmpty else { return false }
        let new = ConditionalRule.moved(old, operation, axis: axis)
        guard !new.isEmpty else { return nil }
        var changed = new != old
        if changed { root.setAttribute("ref", new.map(\.a1).joined(separator: " ")) }

        let conditions = root.children(named: "sortCondition")
        for condition in conditions {
            guard let conditionRef = condition.attribute("ref") else { continue }
            let old = ConditionalRule.ranges(sqref: conditionRef)
            guard !old.isEmpty else { continue }
            let new = ConditionalRule.moved(old, operation, axis: axis)
            guard new != old else { continue }
            changed = true
            if new.isEmpty {
                root.removeChild(condition)
            } else {
                condition.setAttribute("ref", new.map(\.a1).joined(separator: " "))
            }
        }
        if !conditions.isEmpty, root.children(named: "sortCondition").isEmpty { return nil }
        return changed
    }

    /// Children that each cover an `sqref`: one whose ranges all went is
    /// dropped, and the list with them if none is left.
    private static func shiftSqrefChildren(
        _ root: XMLElement, named name: String, _ operation: FormulaReferenceShifter.Operation,
        axis: FormulaReferenceShifter.Axis
    ) -> Bool? {
        guard !root.children(named: name).isEmpty else { return false }
        var changed = false
        for child in root.children(named: name) {
            guard let sqref = child.attribute("sqref") else { continue }
            let old = ConditionalRule.ranges(sqref: sqref)
            guard !old.isEmpty else { continue }
            let new = ConditionalRule.moved(old, operation, axis: axis)
            guard new != old else { continue }
            changed = true
            if new.isEmpty {
                root.removeChild(child)
            } else {
                child.setAttribute("sqref", new.map(\.a1).joined(separator: " "))
            }
        }
        if root.children(named: name).isEmpty { return nil }
        return changed
    }
}
