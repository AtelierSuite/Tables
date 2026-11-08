import Foundation

/// Reading Form Controls out of a sheet's VML drawing and `ctrlProps` parts,
/// and writing what changed back into them.
///
/// VML is not reliably well-formed — Excel leaves `<br>` unclosed inside text
/// boxes — so its shapes are read and patched as text rather than parsed.
public enum FormControlParts {
    // MARK: - Reading

    /// The controls among a sheet's VML shapes, and the shapes that could not
    /// be placed, to be kept as they are.
    ///
    /// A control with a hidden DrawingML twin is placed where the twin is,
    /// which DrawingML records in EMUs where VML rounds to pixels.
    public static func read(
        shapes: [String], sheetIndex: Int, sheetPath: String, workbook: Workbook, entries: [String: Data]
    ) -> (controls: [FormControl], unplaced: [String]) {
        let sheet = workbook.sheets[sheetIndex]
        let properties = propertiesParts(of: sheet, sheetPath: sheetPath, entries: entries)
        var unplaced: [String] = []
        let controls = shapes.compactMap { shape -> FormControl? in
            // A shape Excel was given a name for keeps its number in `o:spid`.
            let head = String(shape.prefix { $0 != ">" })
            guard let id = attribute("o:spid", in: head) ?? attribute("id", in: head),
                  let placement = sheet.preservedDrawingAnchors.first(where: { $0.vmlShapeID == id })?.placement
                    ?? anchor(in: shape) else {
                unplaced.append(shape)
                return nil
            }

            let kind: FormControl.Kind = switch attribute("ObjectType", in: shape) {
            case "Button": .button
            case "Checkbox": .checkBox
            case "Radio": .optionButton
            case "Drop": .dropDown
            case "Edit": .editBox
            case "GBox": .groupBox
            case "Label": .label
            default: .unsupported
            }
            let propertiesPart = shapeNumber(id).flatMap { properties[$0] }
            let settings = propertiesPart.flatMap { entries[$0] }.flatMap { try? XMLLite.parse($0) }

            func reference(_ text: String?) -> ChartReference? {
                guard let text, !text.isEmpty else { return nil }
                return ChartReference(formula: text, in: workbook)
                    ?? CellRange(a1Range: text.replacingOccurrences(of: "$", with: ""))
                        .map { ChartReference(sheetID: sheet.id, range: $0) }
            }
            let checkState: FormControl.CheckState = switch settings?.attribute("checked")
                ?? value("Checked", in: shape).map({ $0 == "2" ? "Mixed" : "Checked" }) {
            case "Checked": .checked
            case "Mixed": .mixed
            default: .unchecked
            }
            let text = textBoxText(in: shape)
            let font = textBoxFont(in: shape, defaultSize: kind == .button ? 11 : 9)

            var control = FormControl(
                id: id, kind: kind, placement: placement, text: text,
                macro: value("FmlaMacro", in: shape),
                linkedCell: reference(settings?.attribute("fmlaLink") ?? value("FmlaLink", in: shape)),
                listRange: reference(settings?.attribute("fmlaRange") ?? value("FmlaRange", in: shape)),
                checkState: checkState,
                selection: (settings?.attribute("sel") ?? value("Sel", in: shape)).flatMap(Int.init) ?? 0,
                dropLines: (settings?.attribute("dropLines") ?? value("DropLines", in: shape)).flatMap(Int.init) ?? 8,
                isHidden: style(in: shape).contains("visibility:hidden"),
                font: font,
                source: FormControl.Source(
                    vml: shape, propertiesPart: propertiesPart, placement: placement, text: text,
                    linkedCell: nil, listRange: nil, checkState: checkState, selection: 0
                )
            )
            control.horizontalAlignment = switch value("TextHAlign", in: shape) {
            case "Center": .center
            case "Right": .trailing
            case "Left": .leading
            default: kind == .button ? .center : .leading
            }
            control.verticalAlignment = switch value("TextVAlign", in: shape) {
            case "Top": .top
            case "Bottom": .bottom
            default: .center
            }
            control.source.linkedCell = control.linkedCell
            control.source.listRange = control.listRange
            control.source.selection = control.selection
            return control
        }
        return (controls, unplaced)
    }

    /// Each control's `ctrlProps` part, by its shape number, from the sheet's
    /// `<controls>` list and relationships.
    private static func propertiesParts(
        of sheet: Worksheet, sheetPath: String, entries: [String: Data]
    ) -> [Int: String] {
        typealias Plan = XLSXReader.PackagePreservation
        guard let list = sheet.preservedElements.first(where: { $0.name == "controls" }),
              let root = try? XMLLite.parse(Data(list.xml.utf8)) else { return [:] }
        let relationships = Plan.relationships(in: entries[Plan.relationshipsPath(for: sheetPath)])
        var parts: [Int: String] = [:]
        visit(root) { element in
            guard element.name == "control", let shape = element.attribute("shapeId").flatMap(Int.init),
                  let id = element.attribute("id"),
                  let entry = relationships.first(where: { $0.id == id }),
                  let path = Plan.packagePath(of: entry, relativeTo: Plan.directory(of: sheetPath))
            else { return }
            parts[shape] = path
        }
        return parts
    }

    /// The number in a VML shape id: 1025 for `_x0000_s1025`.
    public static func shapeNumber(_ id: String) -> Int? {
        id.range(of: "_s", options: .backwards).flatMap { Int(id[$0.upperBound...]) }
    }

    private static func visit(_ element: XMLElement, _ body: (XMLElement) -> Void) {
        body(element)
        for child in element.children { visit(child, body) }
    }

    /// Where VML's `x:Anchor` puts the shape: column, pixel offset, row,
    /// pixel offset, for each corner.
    private static func anchor(in shape: String) -> ChartPlacement? {
        let numbers = value("Anchor", in: shape)?.split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? []
        guard numbers.count == 8 else { return nil }
        let pointsPerPixel = 0.75
        return ChartPlacement(
            from: ChartAnchor(row: numbers[2], column: numbers[0],
                              rowOffset: Double(numbers[3]) * pointsPerPixel,
                              columnOffset: Double(numbers[1]) * pointsPerPixel),
            to: ChartAnchor(row: numbers[6], column: numbers[4],
                            rowOffset: Double(numbers[7]) * pointsPerPixel,
                            columnOffset: Double(numbers[5]) * pointsPerPixel)
        )
    }

    /// An attribute of the shape's own element or of its `x:ClientData`.
    private static func attribute(_ name: String, in shape: String) -> String? {
        for quote in ["\"", "'"] {
            guard let start = shape.range(of: " \(name)=\(quote)"),
                  let end = shape.range(of: quote, range: start.upperBound..<shape.endIndex) else { continue }
            return String(shape[start.upperBound..<end.lowerBound])
        }
        return nil
    }

    private static func style(in shape: String) -> String {
        let head = shape.prefix { $0 != ">" }
        return attribute("style", in: String(head))?.replacingOccurrences(of: " ", with: "") ?? ""
    }

    /// The text of an `x:` element of the client data, or `""` for one that
    /// is only present, such as `<x:FirstButton/>`.
    public static func value(_ tag: String, in shape: String) -> String? {
        if shape.contains("<x:\(tag)/>") { return "" }
        guard let open = shape.range(of: "<x:\(tag)>"),
              let close = shape.range(of: "</x:\(tag)>", range: open.upperBound..<shape.endIndex) else { return nil }
        return decode(String(shape[open.upperBound..<close.lowerBound]))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The contents of the shape's `<v:textbox>`, markup aside.
    private static func textBoxBody(in shape: String) -> Range<String.Index>? {
        guard let open = shape.range(of: "<v:textbox"),
              let headEnd = shape.range(of: ">", range: open.upperBound..<shape.endIndex),
              shape[shape.index(before: headEnd.lowerBound)] != "/",
              let close = shape.range(of: "</v:textbox>", range: headEnd.upperBound..<shape.endIndex)
        else { return nil }
        return headEnd.upperBound..<close.lowerBound
    }

    private static func textBoxText(in shape: String) -> String {
        guard let body = textBoxBody(in: shape) else { return "" }
        var text = ""
        var index = body.lowerBound
        while index < body.upperBound {
            guard shape[index] == "<" else {
                text.append(shape[index])
                index = shape.index(after: index)
                continue
            }
            let end = shape[index..<body.upperBound].firstIndex(of: ">") ?? body.upperBound
            let tag = shape[shape.index(after: index)..<end].lowercased()
            // A line break, or a paragraph after the first.
            if tag.hasPrefix("br") || (tag.hasPrefix("div") && !text.isEmpty) { text.append("\n") }
            index = end < body.upperBound ? shape.index(after: end) : end
        }
        // The file's own line breaks are layout, not content.
        let lines = decode(text.replacingOccurrences(of: "\r", with: ""))
        return lines.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n").trimmingCharacters(in: .newlines)
    }

    private static func textBoxFont(in shape: String, defaultSize: Double) -> FormControl.Font {
        var font = FormControl.Font(size: defaultSize)
        guard let body = textBoxBody(in: shape) else { return font }
        let text = String(shape[body])
        if let open = text.range(of: "<font"), let end = text.range(of: ">", range: open.upperBound..<text.endIndex) {
            let tag = String(text[open.lowerBound..<end.upperBound])
            // Twentieths of a point, as in Excel's own rich text.
            if let size = attribute("size", in: tag).flatMap(Double.init), size > 0 { font.size = size / 20 }
            if let color = attribute("color", in: tag), color.hasPrefix("#"), color.count == 7 {
                font.colorHex = String(color.dropFirst()).uppercased()
            }
        }
        font.isBold = text.contains("<b>")
        return font
    }

    private static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "&", let semicolon = text[index...].firstIndex(of: ";"),
                  text.distance(from: index, to: semicolon) <= 10 else {
                result.append(text[index])
                index = text.index(after: index)
                continue
            }
            let entity = text[text.index(after: index)..<semicolon]
            let replacement: String? = switch entity {
            case "amp": "&"
            case "lt": "<"
            case "gt": ">"
            case "quot": "\""
            case "apos": "'"
            case "nbsp": " "
            default:
                if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                    UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else if entity.hasPrefix("#") {
                    UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else {
                    nil
                }
            }
            if let replacement {
                result += replacement
                index = text.index(after: semicolon)
            } else {
                result.append(text[index])
                index = text.index(after: index)
            }
        }
        return result
    }

    // MARK: - Writing

    /// The control's VML shape with whatever changed written into it.
    public static func vml(for control: FormControl, on sheet: Worksheet, in workbook: Workbook) -> String {
        var shape = control.source.vml
        let source = control.source

        if control.placement != source.placement {
            let pixelsPerPoint = 4.0 / 3.0
            let corners = [control.placement.from, control.placement.to].flatMap { corner in
                [corner.column, Int((corner.columnOffset * pixelsPerPoint).rounded()),
                 corner.row, Int((corner.rowOffset * pixelsPerPoint).rounded())]
            }
            shape = setting("Anchor", to: corners.map(String.init).joined(separator: ", "), in: shape)
        }
        if control.linkedCell != source.linkedCell {
            shape = setting("FmlaLink", to: formula(control.linkedCell, on: sheet, in: workbook), in: shape)
        }
        if control.listRange != source.listRange {
            shape = setting("FmlaRange", to: formula(control.listRange, on: sheet, in: workbook), in: shape)
        }
        switch control.kind {
        case .checkBox, .optionButton:
            let state = checkState(of: control, on: sheet, in: workbook)
            if state != source.checkState {
                shape = setting("Checked", to: state == .checked ? "1" : state == .mixed ? "2" : nil, in: shape)
            }
        case .dropDown:
            let selection = control.selection(in: workbook)
            if selection != source.selection {
                shape = setting("Sel", to: selection > 0 ? String(selection) : nil, in: shape)
            }
        case .editBox:
            if control.text != source.text, let body = textBoxBody(in: shape) {
                let lines = control.text.components(separatedBy: "\n").map(XMLLite.escape).joined(separator: "<br>")
                shape.replaceSubrange(body, with: "<div style='text-align:left'>\(lines)</div>")
            }
        default:
            break
        }
        return shape
    }

    /// A reference as Excel writes a control's: bare on the control's own
    /// sheet, sheet-qualified elsewhere.
    private static func formula(_ reference: ChartReference?, on sheet: Worksheet, in workbook: Workbook) -> String? {
        guard let reference, let formula = reference.formula(in: workbook) else { return nil }
        guard reference.sheetID == sheet.id, let bang = formula.lastIndex(of: "!") else { return formula }
        return String(formula[formula.index(after: bang)...])
    }

    /// A check box's state, or whether an option button is the one chosen.
    private static func checkState(of control: FormControl, on sheet: Worksheet, in workbook: Workbook)
        -> FormControl.CheckState {
        guard control.kind == .optionButton,
              let index = sheet.formControls.firstIndex(where: { $0.id == control.id }) else {
            return control.checkState(in: workbook)
        }
        return sheet.isOptionChosen(index, in: workbook) ? .checked : .unchecked
    }

    /// Sets, or with `nil` removes, an `x:` element of the client data.
    private static func setting(_ tag: String, to newValue: String?, in shape: String) -> String {
        var shape = shape
        if let open = shape.range(of: "<x:\(tag)>"),
           let close = shape.range(of: "</x:\(tag)>", range: open.upperBound..<shape.endIndex) {
            shape.removeSubrange(open.lowerBound..<close.upperBound)
        } else if let empty = shape.range(of: "<x:\(tag)/>") {
            shape.removeSubrange(empty)
        }
        guard let newValue, let end = shape.range(of: "</x:ClientData>") else { return shape }
        shape.insert(contentsOf: "<x:\(tag)>\(XMLLite.escape(newValue))</x:\(tag)>", at: end.lowerBound)
        return shape
    }

    /// A `ctrlProps` part with what changed written into it, or `nil` when
    /// nothing did.
    public static func properties(_ data: Data, for control: FormControl, on sheet: Worksheet, in workbook: Workbook)
        -> Data? {
        guard let root = try? XMLLite.parse(data) else { return nil }
        var changed = false
        func set(_ name: String, _ value: String?) {
            guard root.attribute(name) != value else { return }
            root.setAttribute(name, value)
            changed = true
        }
        let source = control.source
        if control.linkedCell != source.linkedCell {
            set("fmlaLink", formula(control.linkedCell, on: sheet, in: workbook))
        }
        if control.listRange != source.listRange {
            set("fmlaRange", formula(control.listRange, on: sheet, in: workbook))
        }
        switch control.kind {
        case .checkBox, .optionButton:
            let state = checkState(of: control, on: sheet, in: workbook)
            if state != source.checkState {
                set("checked", state == .checked ? "Checked" : state == .mixed ? "Mixed" : nil)
            }
        case .dropDown:
            let selection = control.selection(in: workbook)
            if selection != source.selection { set("sel", selection > 0 ? String(selection) : nil) }
        default:
            break
        }
        guard changed, let xml = XMLLite.serialize(root) else { return nil }
        return Data(("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" + xml).utf8)
    }

    /// The sheet's `<controls>` list with each moved control's anchor updated.
    public static func controlsElement(_ element: PreservedElement, controls: [FormControl]) -> PreservedElement {
        let moved = Dictionary(
            controls.filter { $0.placement != $0.source.placement }
                .compactMap { control in shapeNumber(control.id).map { ($0, control.placement) } },
            uniquingKeysWith: { first, _ in first }
        )
        guard !moved.isEmpty, let root = try? XMLLite.parse(Data(element.xml.utf8)) else { return element }
        func emus(_ points: Double) -> String { String(Int((points * 12_700).rounded())) }
        visit(root) { control in
            guard control.name == "control", let shape = control.attribute("shapeId").flatMap(Int.init),
                  let placement = moved[shape],
                  let anchor = control.firstDescendant(atPath: "controlPr/anchor") else { return }
            for (name, corner) in [("from", placement.from), ("to", placement.to)] {
                guard let marker = anchor.firstChild(named: name) else { continue }
                marker.firstChild(named: "col")?.setText(String(corner.column))
                marker.firstChild(named: "colOff")?.setText(emus(corner.columnOffset))
                marker.firstChild(named: "row")?.setText(String(corner.row))
                marker.firstChild(named: "rowOff")?.setText(emus(corner.rowOffset))
            }
        }
        guard let xml = XMLLite.serialize(root) else { return element }
        return PreservedElement(name: element.name, xml: xml)
    }
}
