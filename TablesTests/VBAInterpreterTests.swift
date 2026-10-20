import Foundation
import Testing
@testable import Tables
@testable import TablesEngine
@testable import TablesMacros

/// A host with no application behind it, recording what the macro said.
private final class RecordingHost: VBAHost {
    var printed: [String] = []
    var messages: [String] = []
    var messageReply = 1
    var inputReply: String? = "typed"

    func globalMember(_: String, _: VBAArguments, in _: VBAInterpreter) throws -> VBAValue? { nil }
    func setGlobalMember(_: String, _: VBAArguments, to _: VBAValue,
                         in _: VBAInterpreter) throws -> Bool { false }
    func documentObject(codeName _: String, in _: VBAInterpreter) -> (any VBAObject)? { nil }
    func constant(named _: String) -> VBAValue? { nil }
    func createObject(_: String, in _: VBAInterpreter) -> (any VBAObject)? { nil }
    func messageBox(prompt: String, buttons _: Int, title _: String?) -> Int {
        messages.append(prompt)
        return messageReply
    }
    func inputBox(prompt _: String, title _: String?, defaultText _: String) -> String? { inputReply }
    func debugPrint(_ text: String) { printed.append(text) }
}

@Suite("VBA interpreter")
struct VBAInterpreterTests {
    /// Runs `Main` in a module made of `source`, returning what it printed.
    private func run(
        _ source: String, extraModules: [(String, VBAProject.Module.Kind, String)] = [],
        host: RecordingHost = RecordingHost()
    ) throws -> [String] {
        let interpreter = try VBAInterpreter(
            modules: [("Module1", .standard, source)] + extraModules.map { ($0.0, $0.1, $0.2) }, host: host
        )
        _ = try interpreter.run("Main")
        return host.printed
    }

    /// Evaluates one expression through `Debug.Print`, trimming VBA's number padding.
    private func evaluate(_ expression: String) throws -> String {
        try run("Sub Main()\nDebug.Print \(expression)\nEnd Sub").first?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    @Test("Arithmetic follows VBA's precedence and types", arguments: [
        ("1 + 2 * 3", "7"), ("-2 ^ 2", "-4"), ("7 \\ 2", "3"), ("7 Mod 3", "1"), ("7 / 2", "3.5"),
        ("2 ^ 0.5 > 1.41", "True"), ("\"1\" + 2", "3"), ("\"a\" & 1 & True", "a1True"),
        ("Not 1 = 2", "True"), ("5 And 3", "1"), ("True Or False", "True"), ("1 = 1 And 2 < 1", "False"),
        ("10 - 2 - 3", "5"), ("0.1 + 0.2", "0.3"), ("1E+20 * 10", "1E+21"),
    ])
    func arithmetic(_ expression: String, _ expected: String) throws {
        #expect(try evaluate(expression) == expected)
    }

    @Test("String functions", arguments: [
        ("Len(\"hello\")", "5"), ("Left(\"hello\", 2)", "he"), ("Mid(\"hello\", 2, 3)", "ell"),
        ("Mid(\"hello\", 3)", "llo"), ("InStr(\"hello\", \"l\")", "3"), ("InStr(4, \"hello\", \"l\")", "4"),
        ("InStrRev(\"hello\", \"l\")", "4"), ("Replace(\"a-b-c\", \"-\", \"+\")", "a+b+c"),
        ("UCase(\"abc\") & LCase(\"DEF\")", "ABCdef"), ("Trim(\"  x  \") & \"|\"", "x|"),
        ("Join(Split(\"a,b,c\", \",\"), \";\")", "a;b;c"), ("UBound(Split(\"a,b,c\", \",\"))", "2"),
        ("StrReverse(\"abc\")", "cba"), ("Chr(65) & Asc(\"a\")", "A97"), ("Val(\"12.5kg\")", "12.5"),
        ("Format(1234.5, \"#,##0.00\")", "1,234.50"), ("Format(0.25, \"0%\")", "25%"),
        ("\"abc\" Like \"a*\"", "True"), ("\"a1\" Like \"[a-c]#\"", "True"), ("\"abc\" Like \"?b\"", "False"),
        ("StrComp(\"a\", \"B\", vbTextCompare)", "-1"), ("String(3, \"x\")", "xxx"), ("Hex(255)", "FF"),
    ])
    func strings(_ expression: String, _ expected: String) throws {
        #expect(try evaluate(expression) == expected)
    }

    @Test("Conversions and information functions", arguments: [
        ("CInt(2.5)", "2"), ("CInt(3.5)", "4"), ("CLng(\"42\")", "42"), ("CDbl(\"1.5\")", "1.5"),
        ("CStr(1.5)", "1.5"), ("CBool(\"True\")", "True"), ("IsNumeric(\"12\")", "True"),
        ("IsNumeric(\"x\")", "False"), ("TypeName(1)", "Integer"), ("TypeName(\"s\")", "String"),
        ("TypeName(1.5)", "Double"), ("IsEmpty(Empty)", "True"), ("IsNull(Null)", "True"),
        ("VarType(\"s\")", "8"), ("Round(2.5)", "2"), ("Round(0.125, 2)", "0.12"), ("Int(-1.5)", "-2"),
        ("Fix(-1.5)", "-1"), ("Abs(-3)", "3"), ("Sgn(-3)", "-1"), ("IIf(1 > 2, \"a\", \"b\")", "b"),
        ("Choose(2, \"a\", \"b\", \"c\")", "b"), ("RGB(255, 0, 0)", "255"),
    ])
    func conversions(_ expression: String, _ expected: String) throws {
        #expect(try evaluate(expression) == expected)
    }

    @Test("Dates", arguments: [
        ("Year(#3/15/2024#)", "2024"), ("Month(#3/15/2024#)", "3"), ("Day(DateSerial(2024, 2, 30))", "1"),
        ("DateAdd(\"m\", 1, #1/31/2024#)", "2/29/2024"), ("DateDiff(\"d\", #1/1/2024#, #3/1/2024#)", "60"),
        ("Weekday(#1/7/2024#)", "1"), ("Format(#3/15/2024#, \"yyyy-mm-dd\")", "2024-03-15"),
        ("#1/2/2024 13:30#", "1/2/2024 1:30:00 PM"), ("CLng(#1/1/2024#)", "45292"), ("MonthName(2)", "February"),
    ])
    func dates(_ expression: String, _ expected: String) throws {
        #expect(try evaluate(expression) == expected)
    }

    @Test("Loops, conditions and Select Case")
    func controlFlow() throws {
        let printed = try run("""
        Sub Main()
            Dim i As Long, total As Long, s As String
            For i = 1 To 10
                If i Mod 2 = 0 Then total = total + i
            Next i
            Debug.Print total
            For i = 10 To 1 Step -3: s = s & i & ",": Next
            Debug.Print s
            i = 0
            Do
                i = i + 1
                If i >= 5 Then Exit Do
            Loop
            Debug.Print i
            Do Until i = 0
                i = i - 1
            Loop
            While i < 3
                i = i + 1
            Wend
            Debug.Print i
            For Each v In Array("a", "bb", "ccc")
                Select Case Len(v)
                    Case 1: Debug.Print "one"
                    Case 2 To 3, 9
                        If v = "bb" Then
                            Debug.Print "two"
                        ElseIf Len(v) = 3 Then
                            Debug.Print "three"
                        Else
                            Debug.Print "?"
                        End If
                    Case Is > 3: Debug.Print "many"
                End Select
            Next
        End Sub
        """)
        #expect(printed == [" 30 ", "10,7,4,1,", " 5 ", " 3 ", "one", "two", "three"])
    }

    @Test("ByRef and ByVal, functions, optional and named arguments")
    func procedures() throws {
        let printed = try run("""
        Sub Main()
            Dim n As Long, a(1 To 2) As Long
            n = 1
            Bump n
            Debug.Print n
            Keep n
            Debug.Print n
            Bump a(2)
            Debug.Print a(2)
            Debug.Print Describe("x")
            Debug.Print Describe("x", count:=3)
            Debug.Print Total(1, 2, 3)
            Debug.Print Factorial(5)
            Debug.Print Module1.Factorial(3)
        End Sub

        Sub Bump(ByRef value As Long)
            value = value + 1
        End Sub

        Sub Keep(ByVal value As Long)
            value = value + 100
        End Sub

        Function Describe(text As String, Optional count As Integer = 1, Optional extra) As String
            Describe = String(count, text) & IIf(IsMissing(extra), "", "!")
        End Function

        Function Total(ParamArray values()) As Long
            Dim v
            For Each v In values
                Total = Total + v
            Next
        End Function

        Function Factorial(n As Long) As Long
            If n <= 1 Then Factorial = 1 Else Factorial = n * Factorial(n - 1)
        End Function
        """)
        #expect(printed == [" 2 ", " 2 ", " 1 ", "x", "xxx", " 6 ", " 120 ", " 6 "])
    }

    @Test("Arrays: bounds, ReDim Preserve, multiple dimensions, Erase")
    func arrays() throws {
        let printed = try run("""
        Sub Main()
            Dim a() As String, grid(1 To 2, 1 To 3) As Integer, i As Integer
            ReDim a(2)
            a(0) = "x": a(2) = "z"
            ReDim Preserve a(3)
            a(3) = "w"
            Debug.Print LBound(a); UBound(a); a(0) & a(2) & a(3)
            grid(2, 3) = 7
            Debug.Print UBound(grid, 2); grid(2, 3)
            Erase a
            On Error Resume Next
            i = UBound(a)
            Debug.Print Err.Number
        End Sub
        """)
        #expect(printed == [" 0  3 xzw", " 3  7 ", " 9 "])
    }

    @Test("On Error: Resume Next, handlers with Resume Next, and Err.Raise")
    func errorHandling() throws {
        let printed = try run("""
        Sub Main()
            On Error Resume Next
            Debug.Print 1 / 0
            Debug.Print Err.Number; Err.Description
            Err.Clear
            On Error GoTo Handler
            Dim x As Integer
            x = 40000
            Debug.Print "resumed"; x
            Risky
            Debug.Print "after risky"
            Exit Sub
        Handler:
            Debug.Print "caught"; Err.Number
            Resume Next
        End Sub

        Sub Risky()
            Err.Raise 1004, , "custom"
        End Sub
        """)
        #expect(printed == [" 11 Division by zero", "caught 6 ", "resumed 0 ", "caught 1004 ", "after risky"])
    }

    @Test("An unhandled error stops the macro and says where")
    func unhandled() throws {
        let interpreter = try VBAInterpreter(modules: [("Module1", .standard, """
        Sub Main()
            Dim x As Long
            x = 1
            x = x / 0
        End Sub
        """)], host: RecordingHost())
        let error = try #require(throws: VBAError.self) { try interpreter.run("Main") }
        #expect(error.number == 11)
        #expect(error.module == "Module1")
        #expect(error.line == 4)
    }

    @Test("Class modules: properties, methods, Me and initialisation")
    func classes() throws {
        let counter = """
        Private mCount As Long
        Public Label As String

        Private Sub Class_Initialize()
            mCount = 10
        End Sub

        Public Property Get Count() As Long
            Count = mCount
        End Property

        Public Property Let Count(ByVal value As Long)
            mCount = value
        End Property

        Public Sub Increment(Optional by As Long = 1)
            mCount = mCount + by
        End Sub

        Public Function Twice() As Long
            Twice = Me.Count * 2
        End Function
        """
        let printed = try run("""
        Sub Main()
            Dim c As Counter, d As New Counter
            Set c = New Counter
            c.Increment
            c.Increment 5
            Debug.Print c.Count
            c.Count = 3
            c.Label = "hi"
            Debug.Print c.Twice; c.Label; d.Count
            Debug.Print TypeName(c); TypeOf c Is Counter; c Is d
        End Sub
        """, extraModules: [("Counter", .classModule, counter)])
        #expect(printed == [" 16 ", " 6 hi 10 ", "CounterTrueFalse"])
    }

    @Test("Collections and dictionaries")
    func collections() throws {
        let printed = try run("""
        Sub Main()
            Dim c As New Collection, d As Object, k
            c.Add "one"
            c.Add "two", "second"
            c.Add "zero", Before:=1
            Debug.Print c.Count; c(1); c("SECOND")
            c.Remove 1
            Set d = CreateObject("Scripting.Dictionary")
            d.Add "a", 1
            d("b") = 2
            d("a") = d("a") + 10
            Debug.Print d.Count; d.Exists("b"); d.Exists("z")
            For Each k In d.Keys
                Debug.Print k; d(k)
            Next
        End Sub
        """)
        #expect(printed == [" 3 zerotwo", " 2 TrueFalse", "a 11 ", "b 2 "])
    }

    @Test("User types copy on assignment; Static variables persist")
    func typesAndStatics() throws {
        let printed = try run("""
        Type Point
            X As Long
            Y As Long
        End Type

        Sub Main()
            Dim p As Point, q As Point
            p.X = 1
            q = p
            q.X = 5
            Debug.Print p.X; q.X
            Tick
            Tick
            Tick
        End Sub

        Sub Tick()
            Static calls As Long
            calls = calls + 1
            Debug.Print calls
        End Sub
        """)
        #expect(printed == [" 1  5 ", " 1 ", " 2 ", " 3 "])
    }

    @Test("Module constants, enums and Option Explicit")
    func declarations() throws {
        let printed = try run("""
        Option Explicit
        Private Const Rate As Double = 0.5
        Public Enum Size
            Small = 1
            Medium
            Large = 10
        End Enum
        Public total As Long

        Sub Main()
            total = Medium + Large
            Debug.Print total * Rate
        End Sub
        """)
        #expect(printed == [" 6 "])

        let interpreter = try VBAInterpreter(modules: [("Module1", .standard, """
        Option Explicit
        Sub Main()
            undeclared = 1
        End Sub
        """)], host: RecordingHost())
        #expect(throws: VBAError.self) { try interpreter.run("Main") }
    }

    @Test("MsgBox and InputBox go through the host")
    func interaction() throws {
        let host = RecordingHost()
        host.messageReply = 6
        let printed = try run("""
        Sub Main()
            If MsgBox("Continue?", vbYesNo) = vbYes Then Debug.Print InputBox("Name?")
            MsgBox "done"
        End Sub
        """, host: host)
        #expect(host.messages == ["Continue?", "done"])
        #expect(printed == ["typed"])
    }

    @Test("Regular expressions")
    func regularExpressions() throws {
        let printed = try run("""
        Sub Main()
            Dim re As Object, m
            Set re = CreateObject("VBScript.RegExp")
            re.Pattern = "(\\d+)-(\\d+)"
            re.Global = True
            Debug.Print re.Test("call 555-1234")
            Debug.Print re.Replace("1-2 and 3-4", "$2-$1")
            For Each m In re.Execute("10-20, 30-40")
                Debug.Print m.Value; m.SubMatches(1)
            Next
        End Sub
        """)
        #expect(printed == ["True", "2-1 and 4-3", "10-2020", "30-4040"])
    }

    @Test("The macro list shows public parameterless Subs")
    func runnableMacros() throws {
        let interpreter = try VBAInterpreter(modules: [
            ("Module1", .standard, "Sub A()\nEnd Sub\nPrivate Sub B()\nEnd Sub\nSub C(x)\nEnd Sub\nFunction D()\nEnd Function"),
            ("Sheet1", .document, "Sub OnSheet()\nEnd Sub"),
            ("Klass", .classModule, "Sub Method()\nEnd Sub"),
        ], host: nil)
        #expect(interpreter.runnableMacros.map { "\($0.module).\($0.procedure)" } == ["Module1.A", "Sheet1.OnSheet"])
    }

    @Test("Syntax errors name their line")
    func syntaxErrors() throws {
        let error = #expect(throws: VBASyntaxError.self) {
            _ = try VBAInterpreter(modules: [("Module1", .standard, "Sub Main()\n  x = (1 +\nEnd Sub")], host: nil)
        }
        #expect(error?.line == 2)
        #expect(error?.module == "Module1")
        // Messages come from the string catalog, in whatever language the
        // device uses, with the offending token filled in.
        let message = try #require(error?.message)
        #expect(!message.hasPrefix("Macro."))
        #expect(message.contains(String(localized: "Macro.EndOfLine", bundle: .macros)))
    }

    @Test("File I/O parses, and fails only when it runs")
    func fileStatements() throws {
        let source = """
        Sub Main()
            Debug.Print "before"
        End Sub

        Sub WriteLog()
            Open "log.txt" For Append As #1
            Print #1, "entry"
            Close #1
        End Sub
        """
        #expect(try run(source) == ["before"])
        let interpreter = try VBAInterpreter(modules: [("Module1", .standard, source)], host: RecordingHost())
        let error = try #require(throws: VBAError.self) { try interpreter.run("WriteLog") }
        #expect(error.number == 445)
    }

    @Test("A runaway loop can be cancelled")
    func cancellation() throws {
        let interpreter = try VBAInterpreter(modules: [("Module1", .standard, "Sub Main()\nDo\nLoop\nEnd Sub")],
                                             host: nil)
        var checks = 0
        interpreter.isCancelled = {
            checks += 1
            return checks > 3
        }
        #expect(throws: VBAControl.self) { try interpreter.run("Main") }
    }
}
