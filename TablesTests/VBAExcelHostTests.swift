import Foundation
import Testing
@testable import Tables
@testable import TablesEngine

@Suite("VBA Excel object model")
struct VBAExcelHostTests {
    /// A two-sheet workbook whose first sheet has the code name `Sheet1`.
    private func workbook() -> Workbook {
        var data = Worksheet(name: "Data")
        data.codeName = "Sheet1"
        var workbook = Workbook(sheets: [data, Worksheet(name: "Other")])
        workbook.codeName = "ThisWorkbook"
        return workbook
    }

    private final class Output: @unchecked Sendable {
        var lines: [String] = []
    }

    /// Runs `Main` and returns the workbook it left behind and what it printed.
    private func run(_ source: String, on workbook: Workbook? = nil) throws -> (Workbook, [String]) {
        let output = Output()
        let host = VBAExcelHost(workbook: workbook ?? self.workbook(), name: "Book1.xlsm",
                                interaction: VBAInteraction(debugPrint: { output.lines.append($0) }))
        let interpreter = try VBAInterpreter(modules: [("Module1", .standard, source)], host: host)
        _ = try interpreter.run("Main")
        return (host.finishedWorkbook, output.lines)
    }

    private func cell(_ workbook: Workbook, _ sheet: Int, _ a1: String) -> Cell {
        workbook.sheets[sheet][CellAddress(a1: a1)!]
    }

    @Test("Values written through Range and Cells land in the workbook, typed")
    func writesValues() throws {
        let (result, _) = try run("""
        Sub Main()
            Range("A1").Value = "Name"
            Cells(2, 1) = 42
            Cells(3, "A").Value = True
            Range("B1") = "12.5"
            Range("B2").Value = #3/15/2024#
            Worksheets("Other").Range("C3").Value = "elsewhere"
            Range("D1:E2").Value = 7
        End Sub
        """)
        #expect(cell(result, 0, "A1").value == .text("Name"))
        #expect(cell(result, 0, "A2").value == .number(42))
        #expect(cell(result, 0, "A3").value == .boolean(true))
        // Text is read as typing it would be.
        #expect(cell(result, 0, "B1").value == .number(12.5))
        #expect(cell(result, 0, "B2").value == .number(45366))
        #expect(CellFormatter.isDateFormat(cell(result, 0, "B2").style.numberFormat))
        #expect(cell(result, 1, "C3").value == .text("elsewhere"))
        #expect(cell(result, 0, "E2").value == .number(7))
    }

    @Test("Formulas are written, filled relatively, and read back calculated")
    func formulas() throws {
        let (result, printed) = try run("""
        Sub Main()
            Range("A1:A3").Value = 2
            Range("B1:B3").Formula = "=A1*10"
            Debug.Print Range("B3").Formula; Range("B3").Value
            Range("A3").Value = 5
            Debug.Print Range("B3").Value
            Range("C1").Formula = "=SUM(B1:B3)"
            Debug.Print Range("C1").Value
        End Sub
        """)
        #expect(printed == ["=A3*10 20 ", " 50 ", " 90 "])
        #expect(cell(result, 0, "B2").formula == "A2*10")
        #expect(cell(result, 0, "C1").value == .number(90))
    }

    @Test("Reading a block gives a one-based two-dimensional array, and writing one fills the block")
    func arrays() throws {
        let (result, printed) = try run("""
        Sub Main()
            Range("A1:B2").Value = Array(1, 2)
            Dim v
            v = Range("A1:B2").Value
            Debug.Print LBound(v, 1); UBound(v, 1); UBound(v, 2); v(1, 2); v(2, 1)
            Worksheets("Other").Range("A1:B2").Value = v
            Range("D1:F1").Value = Array("x", "y")
        End Sub
        """)
        #expect(printed == [" 1  2  2  2  1 "])
        #expect(cell(result, 1, "B2").value == .number(2))
        // A range larger than the array is padded with #N/A.
        #expect(cell(result, 0, "F1").value == .error(.notAvailable))
    }

    @Test("Navigation: End, Offset, Resize, CurrentRegion, UsedRange, Rows.Count")
    func navigation() throws {
        let (_, printed) = try run("""
        Sub Main()
            Range("A1:A5").Value = 1
            Range("B1:B3").Value = 2
            Debug.Print Cells(Rows.Count, 1).End(xlUp).Row; Range("A1").End(xlDown).Row; Range("A1").End(xlToRight).Column
            Debug.Print Range("A1").Offset(2, 1).Address; Range("A1").Resize(2, 3).Address(False, False)
            Debug.Print Range("A2").CurrentRegion.Address; ActiveSheet.UsedRange.Rows.Count
            Debug.Print Range("A1:C4").Rows.Count; Range("A1:C4").Columns.Count; Range("A1:C4").Count
            Debug.Print Range("B2:D4").Cells(2, 2).Address; Range("B2:D4").Rows(2).Address
        End Sub
        """)
        #expect(printed == [
            " 5  5  2 ", "$B$3A1:C2", "$A$1:$B$5 5 ", " 4  3  12 ", "$C$3$B$3:$D$3",
        ])
    }

    @Test("For Each walks a range cell by cell, row by row")
    func iteration() throws {
        let (_, printed) = try run("""
        Sub Main()
            Range("A1:B2").Formula = "=ROW()*10+COLUMN()"
            Dim c, s As String
            For Each c In Range("A1:B2")
                s = s & c.Value & " "
            Next
            Debug.Print s
            For Each c In Range("A1:B2").Rows
                Debug.Print c.Address
            Next
        End Sub
        """)
        #expect(printed == ["11 12 21 22 ", "$A$1:$B$1", "$A$2:$B$2"])
    }

    @Test("Formatting: fonts, fills, number formats, alignment, borders, widths")
    func formatting() throws {
        let (result, printed) = try run("""
        Sub Main()
            With Range("A1:B1")
                .Font.Bold = True
                .Font.Color = RGB(255, 0, 0)
                .Interior.Color = vbYellow
                .HorizontalAlignment = xlCenter
                .NumberFormat = "0.00"
            End With
            Range("A1:B2").Borders(xlEdgeBottom).LineStyle = xlContinuous
            Columns("C").ColumnWidth = 20
            Rows(4).Hidden = True
            Debug.Print Range("A1").Font.Bold; Range("A1:A2").Font.Bold; Range("A1").Interior.Color
        End Sub
        """)
        let style = cell(result, 0, "B1").style
        #expect(style.isBold)
        #expect(style.textColorHex == "FFFF0000")
        #expect(style.fillColorHex == "FFFFFF00")
        #expect(style.horizontalAlignment == .center)
        #expect(style.numberFormat == "0.00")
        #expect(cell(result, 0, "A2").style.borderSides[.bottom] != nil)
        #expect(cell(result, 0, "A1").style.borderSides[.bottom] == nil)
        #expect(abs(result.sheets[0].width(ofColumn: 2) - Worksheet.columnWidthPoints(characters: 20)) < 0.01)
        #expect(result.sheets[0].hiddenRows.contains(3))
        // Mixed values read as Null, which prints as such.
        #expect(printed == ["TrueNull 65535 "])
    }

    @Test("Sheets: by name, index and code name; added, renamed, hidden, deleted")
    func sheets() throws {
        let (result, printed) = try run("""
        Sub Main()
            Debug.Print Worksheets.Count; Worksheets(2).Name; Sheet1.Name; ThisWorkbook.Name
            Dim ws As Worksheet
            Set ws = Worksheets.Add(After:=Worksheets(Worksheets.Count))
            ws.Name = "Report"
            Debug.Print ActiveSheet.Name; ws.Index
            Worksheets("Other").Visible = False
            Sheet1.Range("A1") = "via code name"
            Worksheets("Report").Delete
            Dim s, names As String
            For Each s In Worksheets
                names = names & s.Name & ","
            Next
            Debug.Print names
        End Sub
        """)
        #expect(printed == [" 2 OtherDataBook1.xlsm", "Report 3 ", "Data,Other,"])
        #expect(result.sheets.count == 2)
        #expect(result.sheets[1].isHidden)
        #expect(cell(result, 0, "A1").value == .text("via code name"))
    }

    @Test("Copy, clear, find, sort and whole-row insertion")
    func operations() throws {
        let (sorted, output) = try run("""
        Sub Main()
            Range("A1") = "n": Range("A2") = 3: Range("A3") = 1: Range("A4") = 4: Range("A5") = 2
            Range("B2:B5").Formula = "=A2*2"
            Range("A1:B5").Sort Key1:=Range("A1"), Order1:=xlAscending, Header:=xlYes
            Debug.Print Range("A2").Value; Range("A5").Value
            Range("A1:B5").Copy Destination:=Worksheets("Other").Range("C1")
            Range("B2:B5").ClearContents
            Debug.Print Range("A:A").Find("4").Address; Range("A:A").Find("nothing here") Is Nothing
            Rows(1).Insert
            Debug.Print Range("A2").Value
        End Sub
        """)
        #expect(output == [" 1  4 ", "$A$5True", "n"])
        #expect(cell(sorted, 0, "B3").value == .empty)
        #expect(cell(sorted, 1, "D2").formula != nil)
        #expect(cell(sorted, 1, "C5").value == .number(4))
    }

    @Test("WorksheetFunction and Evaluate use the spreadsheet's own functions")
    func worksheetFunctions() throws {
        let (_, printed) = try run("""
        Sub Main()
            Range("A1:A4").Value = 5
            Range("A4").Value = 1
            Debug.Print WorksheetFunction.Sum(Range("A1:A4")); WorksheetFunction.Max(3, 9, 4)
            Debug.Print Application.WorksheetFunction.CountIf(Range("A1:A4"), ">2")
            Debug.Print WorksheetFunction.VLookup(1, Range("A1:A4"), 1, False)
            Debug.Print Evaluate("SUM(A1:A3)*2"); [A4]
            On Error Resume Next
            Dim r
            r = WorksheetFunction.VLookup(99, Range("A1:A4"), 1, False)
            Debug.Print Err.Number
        End Sub
        """)
        #expect(printed == [" 16  9 ", " 3 ", " 1 ", " 30  1 ", " 1004 "])
    }

    @Test("Selection and ActiveCell follow Select and Activate")
    func selection() throws {
        let host = VBAExcelHost(workbook: workbook(), name: "Book1.xlsm")
        let interpreter = try VBAInterpreter(modules: [("Module1", .standard, """
        Sub Main()
            Worksheets("Other").Activate
            Range("B2:C3").Select
            Selection.Value = 1
            ActiveCell.Value = "first"
        End Sub
        """)], host: host)
        _ = try interpreter.run("Main")
        #expect(host.activeSheetID == host.workbook.sheets[1].id)
        #expect(host.selection == CellRange(start: CellAddress(a1: "B2")!, end: CellAddress(a1: "C3")!))
        #expect(host.finishedWorkbook.sheets[1][CellAddress(a1: "B2")!].value == .text("first"))
        #expect(host.finishedWorkbook.sheets[1][CellAddress(a1: "C3")!].value == .number(1))
    }

    @Test("Unsupported members fail with a clear error rather than doing the wrong thing")
    func unsupported() throws {
        #expect(throws: VBAError.self) { _ = try run("Sub Main()\nRange(\"A1:B2\").AutoFilter\nEnd Sub") }
        #expect(throws: VBAError.self) { _ = try run("Sub Main()\nRange(\"A1:B2\").Delete\nEnd Sub") }
        #expect(throws: VBAError.self) { _ = try run("Sub Main()\nApplication.OnTime Now, \"X\"\nEnd Sub") }
    }
}
