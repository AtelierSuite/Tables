import Testing
@testable import Tables

@Suite("Sheet structure")
struct WorksheetStructureTests {
    private func grid() -> Worksheet {
        var sheet = Worksheet(name: "Sheet 1")
        for row in 0..<5 {
            for column in 0..<4 {
                sheet[CellAddress(row: row, column: column)] = Cell(
                    value: .text("\(CellAddress.columnName(column))\(row + 1)"),
                    formula: nil, style: .default
                )
            }
        }
        return sheet
    }

    @Test("New sheets start at 5 columns by 20 rows")
    func defaults() {
        let sheet = Worksheet(name: "Sheet 1")
        #expect(sheet.columnCount == 5)
        #expect(sheet.rowCount == 20)
        #expect(Workbook().sheets.count == 1)
    }

    @Test("The grid only grows when asked")
    func explicitGrowth() {
        var sheet = Worksheet(name: "Sheet 1")
        // Writing far outside the grid doesn't resize it, Numbers-style.
        sheet[CellAddress(row: 999, column: 999)] = Cell(value: .number(1), formula: nil, style: .default)
        #expect(sheet.rowCount == 20)
        #expect(sheet.columnCount == 5)

        sheet.addRows(3)
        sheet.addColumns(2)
        #expect(sheet.rowCount == 23)
        #expect(sheet.columnCount == 7)
    }

    @Test("Inserting rows shifts cells and their references")
    func insertRows() {
        var sheet = grid()
        sheet[CellAddress(a1: "D1")!] = Cell(value: .empty, formula: "SUM(A3:A5)", style: .default)

        sheet.insertRows(2, at: 1)
        #expect(sheet.rowCount == 22)
        #expect(sheet[CellAddress(a1: "A1")!].value == .text("A1"))
        #expect(sheet[CellAddress(a1: "A4")!].value == .text("A2"))
        #expect(sheet[CellAddress(a1: "A2")!].isBlank)
        #expect(sheet[CellAddress(a1: "D1")!].formula == "SUM(A5:A7)")
    }

    @Test("Deleting rows removes cells and breaks references into them")
    func deleteRows() {
        var sheet = grid()
        sheet[CellAddress(a1: "D1")!] = Cell(value: .empty, formula: "A3+A5", style: .default)

        sheet.removeRows(2...2)  // deletes row 3
        #expect(sheet.rowCount == 19)
        #expect(sheet[CellAddress(a1: "A3")!].value == .text("A4"))
        #expect(sheet[CellAddress(a1: "D1")!].formula == "#REF!+A4")
    }

    @Test("References follow the sheet they name, from any sheet")
    func referencesAcrossSheets() {
        var workbook = Workbook()
        workbook.sheets = [grid(), Worksheet(name: "Q1 Sales")]
        workbook.sheets[0][CellAddress(a1: "D1")!] = Cell(value: .empty, formula: "A3+'Q1 Sales'!A3+'Sheet 1'!A4:A5")
        workbook.sheets[1][CellAddress(a1: "A1")!] = Cell(value: .empty, formula: "'Sheet 1'!A3:B4+SUM('sheet 1'!2:3)+A3+'It''s'!A3")
        let snapshot = workbook
        workbook.sheets[0].insertRows(1, at: 1)
        workbook.chartsFollow(.insert(index: 1, count: 1), axis: .row, on: workbook.sheets[0].id, before: snapshot)
        #expect(workbook.sheets[0][CellAddress(a1: "D1")!].formula == "A4+'Q1 Sales'!A3+'Sheet 1'!A5:A6")
        #expect(workbook.sheets[1][CellAddress(a1: "A1")!].formula == "'Sheet 1'!A4:B5+SUM('sheet 1'!3:4)+A3+'It''s'!A3")
    }

    @Test("Column insert and delete shift the other axis")
    func columns() {
        var sheet = grid()
        sheet[CellAddress(a1: "A5")!] = Cell(value: .empty, formula: "SUM(B1:C1)", style: .default)

        sheet.insertColumns(1, at: 1)
        #expect(sheet.columnCount == 6)
        #expect(sheet[CellAddress(a1: "C1")!].value == .text("B1"))
        #expect(sheet[CellAddress(a1: "A5")!].formula == "SUM(C1:D1)")

        sheet.removeColumns(1...1)
        #expect(sheet.columnCount == 5)
        #expect(sheet[CellAddress(a1: "B1")!].value == .text("B1"))
        #expect(sheet[CellAddress(a1: "A5")!].formula == "SUM(B1:C1)")
    }

    @Test("Absolute anchors are preserved while shifting")
    func anchorsSurvive() {
        let shifted = FormulaReferenceShifter.rewrite(
            "SUM($A$1:$A$3)+B2", operation: .insert(index: 0, count: 2), axis: .row
        )
        #expect(shifted == "SUM($A$3:$A$5)+B4")
    }

    @Test("Function names are not mistaken for references")
    func functionNamesUntouched() {
        let shifted = FormulaReferenceShifter.rewrite(
            "LOG10(A1)+SUM(B1:B2)", operation: .insert(index: 0, count: 1), axis: .row
        )
        #expect(shifted == "LOG10(A2)+SUM(B2:B3)")
    }

    @Test("Text inside quotes is left alone")
    func quotedTextUntouched() {
        let shifted = FormulaReferenceShifter.rewrite(
            "IF(A1>0,\"see A1\",B1)", operation: .insert(index: 0, count: 1), axis: .row
        )
        #expect(shifted == "IF(A2>0,\"see A1\",B2)")
    }

    @Test("Hiding collapses a line's extent without deleting it")
    func hiding() {
        var sheet = grid()
        sheet.setRows(1...2, hidden: true)
        sheet.setColumns(0...0, hidden: true)

        #expect(sheet.height(ofRow: 1) == 0)
        #expect(sheet.width(ofColumn: 0) == 0)
        #expect(sheet[CellAddress(a1: "A2")!].value == .text("A2"))  // still there

        sheet.unhideAll()
        #expect(sheet.height(ofRow: 1) == Worksheet.defaultRowHeight)
        #expect(sheet.width(ofColumn: 0) == Worksheet.defaultColumnWidth)
    }

    @Test("A sheet always keeps at least one row and column")
    func floorGuards() {
        var sheet = Worksheet(name: "Sheet 1")
        sheet.removeRows(0...(sheet.rowCount - 1))
        sheet.removeColumns(0...(sheet.columnCount - 1))
        #expect(sheet.rowCount == 20)
        #expect(sheet.columnCount == 5)
    }

    @Test("Metrics locate rows and columns from a scroll position")
    func metrics() {
        var sheet = Worksheet(name: "Sheet 1")
        sheet.columnWidths[0] = 200
        sheet.hiddenColumns.insert(1)
        let metrics = SheetMetrics(sheet: sheet)

        #expect(metrics.x(ofColumn: 1) == 200)
        #expect(metrics.width(ofColumn: 1) == 0)
        #expect(metrics.x(ofColumn: 2) == 200)
        #expect(metrics.column(atX: 10) == 0)
        #expect(metrics.column(atX: 250) >= 2)
        #expect(metrics.totalHeight == Worksheet.defaultRowHeight * 20)
    }
}

@Suite("Workbook sheet management")
struct WorkbookTests {
    @Test("Sheet names stay unique")
    func uniqueNames() {
        var workbook = Workbook()
        _ = workbook.addSheet(named: "Sheet 1")
        _ = workbook.addSheet(named: "Sheet 1")
        #expect(Set(workbook.sheets.map(\.name)).count == workbook.sheets.count)
    }

    @Test("The last sheet cannot be removed")
    func lastSheetProtected() {
        var workbook = Workbook()
        #expect(workbook.removeSheet(workbook.sheets[0].id) == false)
        #expect(workbook.sheets.count == 1)
    }

    @Test("Duplicating copies contents under a new identity")
    func duplication() {
        var workbook = Workbook()
        workbook.sheets[0][CellAddress(a1: "A1")!] = Cell(value: .number(7), formula: nil, style: .default)

        let copyID = workbook.duplicateSheet(workbook.sheets[0].id)
        #expect(copyID != nil)
        #expect(workbook.sheets.count == 2)
        #expect(workbook.sheets[1][CellAddress(a1: "A1")!].value == .number(7))
        #expect(workbook.sheets[1].id != workbook.sheets[0].id)
    }
}

@Suite("Comments when the grid changes")
struct CommentStructureTests {
    @Test("Comments move with inserted rows and columns and go with deleted ones")
    func moving() {
        var sheet = Worksheet(name: "Sheet1")
        let b2 = CellAddress(a1: "B2")!
        let c3 = CellAddress(a1: "C3")!
        sheet.comments[b2] = .note(author: "Ann", text: "Check")
        sheet.comments[c3] = .thread(author: "Bo", text: "Why?")
        sheet.insertRows(1, at: 0)
        #expect(sheet.comments[CellAddress(a1: "B3")!]?.text == "Check")
        sheet.insertColumns(2, at: 1)
        #expect(sheet.comments[CellAddress(a1: "D3")!]?.text == "Check")
        #expect(sheet.comments[CellAddress(a1: "E4")!]?.text == "Why?")
        sheet.removeRows(2...2)
        #expect(sheet.comments[CellAddress(a1: "E3")!]?.text == "Why?")
        #expect(sheet.comments.count == 1)
        sheet.removeColumns(0...0)
        #expect(sheet.comments[CellAddress(a1: "D3")!]?.text == "Why?")
    }
}
