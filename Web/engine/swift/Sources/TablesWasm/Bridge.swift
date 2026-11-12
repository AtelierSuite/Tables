import Foundation
import TablesEngine

/// Turns JSON requests from the page into session calls, and the session's
/// state back into JSON.
///
/// Every response carries the selection's state and two version counters:
/// `content` (the cells changed, so redraw) and `layout` (rows, columns or the
/// active sheet changed, so fetch the layout again).
final class Bridge {
    nonisolated(unsafe) static let shared = Bridge()

    private var session = WebSession(document: WebDocument(fileName: "Untitled"))

    struct Failure: Error {
        var message: String
    }

    func handle(_ data: Data, payload: Data?) -> (json: Data, payload: Data?) {
        var output: Data?
        var body: [String: Any]
        do {
            guard let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let command = request["cmd"] as? String else { throw Failure(message: "Malformed request.") }
            let result = try perform(command, request, payload: payload, output: &output)
            body = ["ok": true, "state": state()]
            if let result { body["result"] = result }
        } catch let failure as Failure {
            body = ["ok": false, "error": failure.message, "state": state()]
        } catch {
            body = ["ok": false, "error": error.localizedDescription, "state": state()]
        }
        let json = (try? JSONSerialization.data(withJSONObject: body)) ?? Data(#"{"ok":false,"error":"Unencodable response."}"#.utf8)
        return (json, output)
    }

    // MARK: - Commands

    private func perform(_ command: String, _ r: [String: Any], payload: Data?, output: inout Data?) throws -> Any? {
        switch command {
        case "init":
            if let strings = r["strings"] as? [String: String] { PortableStrings.load(strings) }
            if let locale = r["locale"] as? String {
                PortableStrings.localeIdentifier = locale.replacingOccurrences(of: "-", with: "_")
            }
            return nil
        case "new":
            let name = r["name"] as? String ?? "Untitled"
            session = WebSession(document: WebDocument(fileName: name))
            return info()
        case "open":
            guard let payload else { throw Failure(message: "No file was given.") }
            let name = r["name"] as? String ?? "Untitled"
            session = WebSession(document: try WebDocument(data: payload, fileName: name))
            return info()
        case "save":
            let requested = (r["format"] as? String).flatMap(WebDocument.SaveFormat.init(rawValue:))
            let format = requested ?? session.document.defaultSaveFormat
            output = try session.document.data(as: format, sheetIndex: session.activeIndex)
            if r["keep"] as? Bool != true { session.markSaved() }
            let base = (session.document.fileName as NSString).deletingPathExtension
            return ["fileName": "\(base.isEmpty ? "Untitled" : base).\(format.fileExtension)", "format": format.rawValue]
        case "rename":
            if let name = r["name"] as? String { session.document.fileName = name }
            return info()
        case "environment":
            // The locale and time zone the engine works in, for diagnostics.
            return ["locale": PortableStrings.localeIdentifier, "timeZone": TimeZone.current.identifier]
        case "documentFonts":
            // The families the workbook's cells use, for the font pop-up.
            var families = Set<String>()
            for sheet in session.workbook.sheets {
                for cell in sheet.cells.values {
                    if let family = cell.style.displayFontName { families.insert(family) }
                }
            }
            return families.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        case "info":
            return info()
        case "layout":
            return layout(of: sheet(r))
        case "render":
            return render(r)

        // Selection
        case "selectSheet":
            if let id = sheetID(r) { session.selectSheet(id) }
        case "select":
            let address = try self.address(r)
            if r["add"] as? Bool == true {
                session.addRange(startingAt: address)
            } else {
                session.select(address, extending: r["extend"] as? Bool ?? false)
            }
        case "selectRange":
            let start = try self.address(r, "row", "column")
            let end = try self.address(r, "endRow", "endColumn")
            session.anchor = start
            session.selection = session.activeSheet.expandedToMerges(CellRange(start: start, end: end))
            session.additionalSelections = []
        case "selectRows":
            let from = r["from"] as? Int ?? 0, to = r["to"] as? Int ?? from
            session.selectEntireRows(min(from, to)...max(from, to))
        case "selectColumns":
            let from = r["from"] as? Int ?? 0, to = r["to"] as? Int ?? from
            session.selectEntireColumns(min(from, to)...max(from, to))
        case "selectAll":
            session.selectAll()
        case "move":
            guard let direction = (r["dir"] as? String).flatMap(WebSession.MoveDirection.init(rawValue:)) else { break }
            if r["edge"] as? Bool == true {
                session.moveToEdge(direction, extending: r["extend"] as? Bool ?? false)
            } else {
                session.move(direction, extending: r["extend"] as? Bool ?? false)
            }

        // Editing
        case "commit":
            let address = (try? self.address(r)) ?? session.selectedAddress
            let advance = (r["advance"] as? String).flatMap(WebSession.MoveDirection.init(rawValue:))
            session.commit(r["text"] as? String ?? "", at: address, then: advance)
        case "toggleCheckbox":
            session.toggleCheckbox(at: try address(r))
        case "clear":
            session.clearContents()
        case "clearFormatting":
            session.clearFormatting()
        case "style":
            applyStyle(r)
        case "border":
            applyBorder(r)
        case "aggregate":
            guard let function = r["function"] as? String else { break }
            if let text = session.insertAggregate(function) { return ["editText": text] }

        // Structure
        case "insertRows": session.insertRows(above: r["above"] as? Bool ?? true)
        case "insertColumns": session.insertColumns(before: r["before"] as? Bool ?? true)
        case "deleteRows": session.deleteSelectedRows()
        case "deleteColumns": session.deleteSelectedColumns()
        case "hideRows": session.setSelectedRows(hidden: r["hidden"] as? Bool ?? true)
        case "hideColumns": session.setSelectedColumns(hidden: r["hidden"] as? Bool ?? true)
        case "unhideAll": session.unhideEverything()
        case "addRows": session.addRows(r["count"] as? Int ?? 1)
        case "addColumns": session.addColumns(r["count"] as? Int ?? 1)
        case "resizeColumn":
            if let column = r["column"] as? Int, let width = number(r["width"]) { session.resizeColumn(column, to: width) }
        case "resizeRow":
            if let row = r["row"] as? Int, let height = number(r["height"]) { session.resizeRow(row, to: height) }
        case "fitColumn":
            if let column = r["column"] as? Int { session.fitColumn(column, measuredWidth: number(r["width"])) }
        case "columnTexts":
            // The displayed text of a column's cells, for the page to measure when fitting it.
            guard let column = r["column"] as? Int else { break }
            let sheet = session.activeSheet
            return sheet.cells.compactMap { address, cell -> [String: Any]? in
                guard address.column == column, !sheet.hiddenRows.contains(address.row) else { return nil }
                let text = CellFormatter.displayText(for: cell)
                guard !text.isEmpty else { return nil }
                var entry: [String: Any] = ["t": text, "fs": cell.style.fontSize, "b": cell.style.isBold, "i": cell.style.isItalic]
                if let family = cell.style.displayFontName { entry["ff"] = family }
                return entry
            }
        case "merge": session.mergeSelection()
        case "unmerge": session.unmergeSelection()
        case "freeze":
            session.freezePanes(rows: r["rows"] as? Int ?? 0, columns: r["columns"] as? Int ?? 0)
        case "freezeSelection": session.freezePanesAtSelection()

        // Clipboard
        case "copy": return ["text": session.copySelection()]
        case "cut": return ["text": session.cutSelection()]
        case "paste": session.paste(text: r["text"] as? String)

        // Fill and move
        case "fillTarget":
            let toward = try address(r)
            let target = AutoFill.target(extending: session.selection.normalized, toward: toward)
            return range(target)
        case "fill":
            let start = try address(r, "row", "column"), end = try address(r, "endRow", "endColumn")
            session.fillSelection(to: CellRange(start: start, end: end))
        case "moveCells":
            session.moveSelection(to: try address(r), copying: r["copy"] as? Bool ?? false)

        // Sheets
        case "addSheet": session.addSheet()
        case "duplicateSheet": session.duplicateActiveSheet()
        case "deleteSheet": if let id = sheetID(r) { session.deleteSheet(id) }
        case "renameSheet":
            if let id = sheetID(r), let name = r["name"] as? String {
                let sanitized = Worksheet.sanitizedName(name)
                guard !sanitized.isEmpty else { throw Failure(message: String(localized: "Web.Error.SheetName")) }
                session.renameSheet(id, to: sanitized)
            }
        case "hideSheet": if let id = sheetID(r) { session.setSheet(id, hidden: r["hidden"] as? Bool ?? true) }
        case "sheetColor": if let id = sheetID(r) { session.setSheetColor(id, hex: r["color"] as? String) }
        case "moveSheet": if let id = sheetID(r), let index = r["index"] as? Int { session.moveSheet(id, to: index) }

        // Canvases
        case "addTable": session.addTable()
        case "placeSheet":
            if let id = sheetID(r), let target = (r["target"] as? String).flatMap(UUID.init(uuidString:)) {
                session.placeSheet(id, onCanvasWith: target)
            }
        case "removeFromCanvas": if let id = sheetID(r) { session.removeFromCanvas(id) }
        case "moveTable":
            if let id = sheetID(r), let x = number(r["x"]), let y = number(r["y"]) { session.moveTable(id, toX: x, y: y) }
        case "showTableName": if let id = sheetID(r) { session.setTableNameShown(r["shown"] as? Bool ?? true, for: id) }
        case "renameTable": if let id = sheetID(r), let name = r["name"] as? String { session.renameTable(id, to: name) }
        case "renameCanvas": if let id = sheetID(r), let name = r["name"] as? String { session.renameCanvas(containing: id, to: name) }

        // History
        case "undo": session.undo()
        case "redo": session.redo()

        case "state":
            return nil
        default:
            throw Failure(message: "Unknown command \(command).")
        }
        return nil
    }

    // MARK: - Arguments

    private func number(_ value: Any?) -> Double? {
        (value as? Double) ?? (value as? Int).map(Double.init)
    }

    private func address(_ r: [String: Any], _ rowKey: String = "row", _ columnKey: String = "column") throws -> CellAddress {
        guard let row = r[rowKey] as? Int, let column = r[columnKey] as? Int else { throw Failure(message: "No cell was given.") }
        return CellAddress(row: row, column: column)
    }

    private func sheetID(_ r: [String: Any]) -> Worksheet.ID? {
        (r["id"] as? String).flatMap(UUID.init(uuidString:))
    }

    /// The sheet a request names, for drawing the other tables on a canvas;
    /// the active one when it names none.
    private func sheet(_ r: [String: Any]) -> Worksheet {
        sheetID(r).flatMap { session.workbook[$0] } ?? session.activeSheet
    }

    private func range(_ range: CellRange) -> [Int] {
        let box = range.normalized
        return [box.start.row, box.start.column, box.end.row, box.end.column]
    }

    // MARK: - Formatting

    private func applyStyle(_ r: [String: Any]) {
        let formatting = session.formatting
        let current = session.representativeStyle
        if let toggle = r["toggle"] as? String, formatting.contains(.styles) {
            switch toggle {
            case "bold": session.applyStyle { $0.isBold = !current.isBold }
            case "italic": session.applyStyle { $0.isItalic = !current.isItalic }
            case "underline": session.applyStyle { $0.isUnderlined = !current.isUnderlined }
            case "strike": session.applyStyle { $0.isStruckThrough = !current.isStruckThrough }
            case "wrap": session.applyStyle { $0.wrapsText = !current.wrapsText }
            default: break
            }
            return
        }
        if formatting.contains(.styles) {
            if let value = r["h"] as? String, let alignment = HorizontalTextAlignment(rawValue: value) {
                session.applyStyle { $0.horizontalAlignment = alignment }
            }
            if let value = r["v"] as? String, let alignment = VerticalTextAlignment(rawValue: value) {
                session.applyStyle { $0.verticalAlignment = alignment }
            }
            if let wrap = r["wrap"] as? Bool { session.applyStyle { $0.wrapsText = wrap } }
            if let size = number(r["fontSize"]) { session.applyStyle { $0.fontSize = min(max(size, 4), 400) } }
            if let delta = number(r["fontSizeDelta"]) {
                session.applyStyle { $0.fontSize = min(max($0.fontSize + delta, 4), 400) }
            }
            if r.keys.contains("textColor") { session.applyStyle { $0.textColorHex = Self.argb(r["textColor"] as? String) } }
            if r.keys.contains("fill") { session.applyStyle { $0.setSolidFill(Self.argb(r["fill"] as? String)) } }
        }
        if formatting.contains(.fonts), r.keys.contains("fontName") {
            // A family name, or null for the system font.
            let family = (r["fontName"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            session.applyStyle { $0.fontName = family.isEmpty ? CellStyle.systemFontName : family }
        }
        if formatting.contains(.numberFormats), let code = r["numberFormat"] as? String {
            session.applyStyle { $0.numberFormat = code }
        }
        if formatting.contains(.indents), let delta = r["indentDelta"] as? Int {
            session.applyStyle { $0.indent = min(max($0.indent + delta, 0), 15) }
        }
        if formatting.contains(.rotation), let rotation = r["rotation"] as? Int {
            session.applyStyle { $0.textRotation = rotation }
        }
        if formatting.contains(.styles), let checkbox = r["checkbox"] as? Bool {
            session.applyStyle { $0.showsCheckbox = checkbox }
        }
    }

    /// "#RRGGBB" from a colour input into OOXML's "FFRRGGBB"; nil clears.
    private static func argb(_ css: String?) -> String? {
        guard var text = css?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if text.hasPrefix("#") { text.removeFirst() }
        if text.count == 6 { text = "FF" + text }
        return text.count == 8 ? text.uppercased() : nil
    }

    /// Border presets across the selection: every edge, the outline, one side, or none.
    private func applyBorder(_ r: [String: Any]) {
        guard session.formatting.contains(.borders), let preset = r["preset"] as? String else { return }
        let lineStyle = (r["style"] as? String).flatMap(BorderLineStyle.init(rawValue:)) ?? .thin
        let color = Self.argb(r["color"] as? String)
        let box = session.selection.normalized
        let index = session.activeIndex
        session.change {
            box.forEachAddress { address in
                guard session.workbook.sheets[index].contains(address) else { return }
                var cell = session.workbook.sheets[index][address]
                let side = BorderSide(lineStyle: lineStyle, colorHex: color)
                let top = address.row == box.start.row, bottom = address.row == box.end.row
                let left = address.column == box.start.column, right = address.column == box.end.column
                func set(_ edge: BorderEdge, _ on: Bool) { if on { cell.style.borderSides[edge] = side } }
                switch preset {
                case "all":
                    for edge in BorderEdge.allCases { cell.style.borderSides[edge] = side }
                case "outside":
                    set(.top, top); set(.bottom, bottom); set(.leading, left); set(.trailing, right)
                case "top": set(.top, top)
                case "bottom": set(.bottom, bottom)
                case "left": set(.leading, left)
                case "right": set(.trailing, right)
                case "none":
                    cell.style.borderSides = [:]
                    cell.style.diagonalBorder = nil
                default: return
                }
                session.workbook.sheets[index][address] = cell
            }
        }
    }

    // MARK: - Responses

    private func state() -> [String: Any] {
        let sheet = session.activeSheet
        let style = session.representativeStyle
        let box = session.selection.normalized
        let active = sheet.mergedRange(containing: session.selectedAddress)?.normalized.start ?? session.selectedAddress

        var count = 0, numbers = 0, sum = 0.0
        var cellsSeen = 0
        for range in session.selectedRanges {
            for address in sheet.storedAddresses(in: range) {
                cellsSeen += 1
                guard cellsSeen <= 200_000 else { break }
                let value = sheet.displayedCell(at: address).value
                guard !value.isEmpty else { continue }
                count += 1
                if case .number(let number) = value {
                    numbers += 1
                    sum += number
                }
            }
        }

        var state: [String: Any] = [
            "sheet": sheet.id.uuidString,
            "selection": [session.selection.start.row, session.selection.start.column,
                          session.selection.end.row, session.selection.end.column],
            "ranges": session.selectedRanges.map(range),
            "anchor": [session.anchor.row, session.anchor.column],
            "active": [active.row, active.column],
            "name": box.isSingleCell || sheet.mergedRange(containing: box.start)?.normalized == box ? active.a1 : box.a1,
            "editText": session.editableText,
            "style": [
                "bold": style.isBold, "italic": style.isItalic, "underline": style.isUnderlined,
                "strike": style.isStruckThrough, "h": style.horizontalAlignment.rawValue,
                "v": style.verticalAlignment.rawValue, "wrap": style.wrapsText, "fontSize": style.fontSize,
                "textColor": style.textColorHex.map(Self.css) ?? NSNull(), "fill": style.fillColorHex.map(Self.css) ?? NSNull(),
                "numberFormat": style.numberFormat, "indent": style.indent, "checkbox": style.showsCheckbox,
                "fontName": style.displayFontName ?? NSNull(),
            ] as [String: Any],
            "status": ["count": count, "numbers": numbers, "sum": sum, "average": numbers > 0 ? sum / Double(numbers) : 0],
            "canMerge": session.canMergeSelection,
            "canUnmerge": session.canUnmergeSelection,
            "canUndo": session.canUndo,
            "canRedo": session.canRedo,
            "dirty": session.isDirty,
            "versions": ["content": session.contentVersion, "layout": session.layoutVersion],
        ]
        if let message = session.message {
            state["message"] = message
            session.message = nil
        }
        return state
    }

    /// OOXML "AARRGGBB" as CSS "#RRGGBB".
    private static func css(_ argb: String) -> String {
        "#" + String(argb.suffix(6))
    }

    private func info() -> [String: Any] {
        let document = session.document
        let formatting = session.formatting
        let report = document.unsupportedFeatures
        return [
            "fileName": document.fileName,
            "kind": document.kind.rawValue,
            "saveFormats": document.saveFormats.map(\.rawValue),
            "defaultSaveFormat": document.defaultSaveFormat.rawValue,
            "sheets": document.workbook.sheets.map { sheet -> [String: Any] in
                [
                    "id": sheet.id.uuidString, "name": sheet.name, "hidden": sheet.isHidden,
                    "color": sheet.tabColorHex.map(Self.css) ?? NSNull(), "chart": sheet.isChartSheet,
                ]
            },
            "formatting": [
                "numberFormats": formatting.contains(.numberFormats), "styles": formatting.contains(.styles),
                "borders": formatting.contains(.borders), "indents": formatting.contains(.indents),
                "rotation": formatting.contains(.rotation), "merging": formatting.contains(.merging),
                "fonts": formatting.contains(.fonts),
            ],
            "allowsFreeze": session.allowsFreezingPanes,
            "allowsInsertDelete": session.allowsInsertingAndDeleting,
            "allowsComments": session.allowsComments,
            "allowsLayingOutTables": session.allowsLayingOutTables,
            "allowsArrangingCanvases": session.allowsArrangingCanvases,
            "canvases": canvases(),
            "unsupported": [
                "preserved": report.preserved.sorted().map(\.label),
                "lost": report.lost.sorted().map(\.label),
            ],
            "numberFormats": NumberFormatPreset.allCases.map { ["code": $0.code, "label": $0.label] },
        ]
    }

    /// The canvases that show more than one table, each table where it sits
    /// on the page in points at 100%; hidden sheets are left off, as the
    /// Apple apps leave them.
    private func canvases() -> [[String: Any]] {
        let workbook = session.workbook
        return workbook.canvases.compactMap { canvas -> [String: Any]? in
            let sheets = workbook.sheets(on: canvas)
            guard sheets.count > 1 else { return nil }
            return [
                "id": canvas.id.uuidString,
                "name": canvas.name,
                "tables": sheets.compactMap { sheet -> [String: Any]? in
                    guard let table = canvas.table(for: sheet.id) else { return nil }
                    return [
                        "id": sheet.id.uuidString, "x": table.x, "y": table.y,
                        "showsName": table.showsName, "name": workbook.tableName(of: sheet.id),
                        "ownName": table.name != nil,
                    ]
                },
            ]
        }
    }

    private func layout(of sheet: Worksheet) -> [String: Any] {
        let columns = Set(sheet.columnWidths.keys).union(sheet.hiddenColumns).sorted()
        let rows = Set(sheet.rowHeights.keys).union(sheet.hiddenRows).sorted()
        return [
            "sheet": sheet.id.uuidString,
            "rows": sheet.rowCount,
            "columns": sheet.columnCount,
            "columnWidth": Worksheet.defaultColumnWidth,
            "rowHeight": sheet.standardRowHeight,
            "widths": columns.filter { $0 < sheet.columnCount }.flatMap { [Double($0), sheet.width(ofColumn: $0)] },
            "heights": rows.filter { $0 < sheet.rowCount }.flatMap { [Double($0), sheet.height(ofRow: $0)] },
            "frozenRows": sheet.frozenRows,
            "frozenColumns": sheet.frozenColumns,
            "chart": sheet.isChartSheet,
            "merges": sheet.mergedRanges.map(range),
        ]
    }

    private func render(_ r: [String: Any]) -> [String: Any] {
        let rect = CGRect(x: number(r["x"]) ?? 0, y: number(r["y"]) ?? 0,
                          width: number(r["w"]) ?? 0, height: number(r["h"]) ?? 0)
        // The device pixels a sheet point comes to at the page's zoom, which
        // the tile's edges and lines are snapped to.
        var renderer = Renderer(sheet: sheet(r), viewer: r["dark"] as? Bool == true ? .dark : .light,
                                pixelScale: number(r["scale"]))
        var body: [String: Any] = ["ops": renderer.render(rect)]
        if let paper = renderer.paper { body["paper"] = paper }
        return body
    }
}
