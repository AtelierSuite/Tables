import Foundation
import Testing
@testable import Tables
@testable import TablesEngine

/// A host that records links and keys instead of acting on them.
private final class FileTestHost: VBAHost {
    var printed: [String] = []
    var openedURLs: [URL] = []
    var allowsLinks = true
    var sentKeys: [String] = []

    func globalMember(_: String, _: VBAArguments, in _: VBAInterpreter) throws -> VBAValue? { nil }
    func setGlobalMember(_: String, _: VBAArguments, to _: VBAValue,
                         in _: VBAInterpreter) throws -> Bool { false }
    func documentObject(codeName _: String, in _: VBAInterpreter) -> (any VBAObject)? { nil }
    func constant(named _: String) -> VBAValue? { nil }
    func createObject(_: String, in _: VBAInterpreter) -> (any VBAObject)? { nil }
    func messageBox(prompt _: String, buttons _: Int, title _: String?) -> Int { 1 }
    func inputBox(prompt _: String, title _: String?, defaultText _: String) -> String? { nil }
    func debugPrint(_ text: String) { printed.append(text) }
    func openURL(_ url: URL) -> Bool {
        openedURLs.append(url)
        return allowsLinks
    }
    func showSendKeys(_ keys: String) { sentKeys.append(keys) }
}

@Suite("VBA files")
struct VBAFileTests {
    /// A fresh working folder inside a fresh parent, so escapes have
    /// somewhere real to try to reach.
    private func workingFolder() throws -> (parent: URL, folder: URL) {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("VBAFiles-\(UUID().uuidString)")
        let folder = parent.appendingPathComponent("Book")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: parent.appendingPathComponent("outside.txt"))
        return (parent, folder)
    }

    /// Runs `Main` with the working folder set, returning what it printed.
    private func run(
        _ source: String, in folder: URL, host: FileTestHost = FileTestHost(),
        extraModules: [(String, VBAProject.Module.Kind, String)] = []
    ) throws -> [String] {
        let interpreter = try VBAInterpreter(modules: [("Module1", .standard, source)] + extraModules, host: host)
        interpreter.fileSystem = try VBAFileSystem(root: folder)
        defer { interpreter.fileSystem?.closeAll() }
        _ = try interpreter.run("Main")
        return host.printed
    }

    private func error(running source: String, in folder: URL, host: FileTestHost = FileTestHost()) throws -> VBAError? {
        do {
            _ = try run(source, in: folder, host: host)
            return nil
        } catch let error as VBAError {
            return error
        }
    }

    // MARK: - The sandbox

    @Test("Paths that leave the working folder are refused", arguments: [
        "..\\outside.txt", "../outside.txt", "sub/../../outside.txt", "/etc/hosts", "C:\\Windows\\win.ini",
        "c:/temp/x.txt", "\\\\server\\share\\x.txt", "//server/share/x.txt",
    ])
    func refusesEscapes(_ path: String) throws {
        let (_, folder) = try workingFolder()
        let error = try error(running: """
        Sub Main()
            Open "\(path)" For Input As #1
        End Sub
        """, in: folder)
        #expect(error?.number == 75, "\(path) should be refused")
    }

    @Test("A link inside the folder that points out of it is refused")
    func refusesLinksOut() throws {
        let (parent, folder) = try workingFolder()
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("escape"), withDestinationURL: parent)
        let error = try error(running: """
        Sub Main()
            Open "escape\\outside.txt" For Input As #1
        End Sub
        """, in: folder)
        #expect(error?.number == 75)
        let killError = try self.error(running: "Sub Main()\n    Kill \"escape/*.txt\"\nEnd Sub", in: folder)
        #expect(killError?.number == 75)
        #expect(FileManager.default.fileExists(atPath: parent.appendingPathComponent("outside.txt").path))
    }

    @Test("Relative, backslashed and absolute paths inside the folder all work")
    func acceptsInsidePaths() throws {
        let (_, folder) = try workingFolder()
        let printed = try run("""
        Sub Main()
            MkDir "data"
            Open "data\\a.txt" For Output As #1
            Print #1, "one"
            Close #1
            Open ThisWorkbookFolder() & "/data/a.txt" For Input As #2
            Dim s As String
            Line Input #2, s
            Close #2
            Debug.Print s
            ChDir "data"
            Debug.Print Dir("*.txt"); FileLen("a.txt")
            ChDir ".."
            Debug.Print CurDir() = ThisWorkbookFolder()
        End Sub

        Function ThisWorkbookFolder() As String
            ThisWorkbookFolder = CurDir()
        End Function
        """, in: folder)
        #expect(printed == ["one", "a.txt 5 ", "True"])
    }

    // MARK: - Sequential files

    @Test("Print, Write, Input and Line Input round-trip")
    func sequential() throws {
        let (_, folder) = try workingFolder()
        let printed = try run("""
        Sub Main()
            Dim f As Integer, a As String, n As Long, b As Boolean, d As Date, line1 As String
            f = FreeFile
            Open "data.txt" For Output As #f
            Write #f, "Pens, blue", 42, True, #3/15/2024#
            Print #f, "plain"; Spc(2); "text"
            Close #f
            Open "data.txt" For Append As #f
            Print #f, "appended"
            Close f
            Open "data.txt" For Input As #f
            Input #f, a, n, b, d
            Line Input #f, line1
            Debug.Print a; "|"; n; "|"; b; "|"; Year(d)
            Debug.Print line1
            Line Input #f, line1
            Debug.Print line1; EOF(f)
            Close #f
        End Sub
        """, in: folder)
        #expect(printed == ["Pens, blue| 42 |True| 2024 ", "plain  text", "appendedTrue"])
        let text = try String(contentsOf: folder.appendingPathComponent("data.txt"), encoding: .utf8)
        #expect(text == "\"Pens, blue\",42,#TRUE#,#2024-03-15#\r\nplain  text\r\nappended\r\n")
    }

    @Test("Print positions items with commas, Tab and Width")
    func printLayout() throws {
        let (_, folder) = try workingFolder()
        _ = try run("""
        Sub Main()
            Open "layout.txt" For Output As #1
            Print #1, "a", "b"
            Print #1, "x"; Tab(5); "y"
            Print #1, 1; -2
            Width #1, 4
            Print #1, "abc"; "def"
            Close #1
        End Sub
        """, in: folder)
        let text = try String(contentsOf: folder.appendingPathComponent("layout.txt"), encoding: .utf8)
        #expect(text == "a             b\r\nx   y\r\n 1 -2 \r\nabc\r\ndef\r\n")
    }

    @Test("Reading past the end, bad numbers and modes fail as VBA's do")
    func sequentialErrors() throws {
        let (_, folder) = try workingFolder()
        try Data("only\n".utf8).write(to: folder.appendingPathComponent("one.txt"))
        #expect(try error(running: "Sub Main()\nDim s\nOpen \"one.txt\" For Input As #1\nLine Input #1, s\nLine Input #1, s\nEnd Sub", in: folder)?.number == 62)
        #expect(try error(running: "Sub Main()\nOpen \"missing.txt\" For Input As #1\nEnd Sub", in: folder)?.number == 53)
        #expect(try error(running: "Sub Main()\nPrint #3, \"x\"\nEnd Sub", in: folder)?.number == 52)
        #expect(try error(running: "Sub Main()\nOpen \"one.txt\" For Input As #1\nPrint #1, \"x\"\nEnd Sub", in: folder)?.number == 54)
        #expect(try error(running: "Sub Main()\nOpen \"a.txt\" For Output As #1\nOpen \"b.txt\" For Output As #1\nEnd Sub", in: folder)?.number == 55)
    }

    @Test("Files left open are written when the macro ends")
    func closesAtEnd() throws {
        let (_, folder) = try workingFolder()
        _ = try run("Sub Main()\nOpen \"left.txt\" For Output As #1\nPrint #1, \"kept\"\nEnd Sub", in: folder)
        #expect(try String(contentsOf: folder.appendingPathComponent("left.txt"), encoding: .utf8) == "kept\r\n")
    }

    // MARK: - Binary and random access

    @Test("Get and Put move typed values, strings and records")
    func binary() throws {
        let (_, folder) = try workingFolder()
        let printed = try run("""
        Type Item
            Code As Long
            Price As Double
        End Type

        Sub Main()
            Dim n As Long, x As Double, s As String, it As Item, back As Item, v As Variant
            Open "data.bin" For Binary As #1
            n = 123456: x = 2.5
            Put #1, , n
            Put #1, , x
            Put #1, , "ABCD"
            Debug.Print LOF(1); Loc(1); Seek(1)
            Get #1, 1, n
            Get #1, , x
            s = String(4, " ")
            Get #1, , s
            Debug.Print n; x; s
            Close #1

            Open "records.dat" For Random As #2 Len = 12
            it.Code = 7: it.Price = 9.5
            Put #2, 3, it
            v = "variant"
            Get #2, 3, back
            Debug.Print back.Code; back.Price; LOF(2)
            Close #2
        End Sub
        """, in: folder)
        #expect(printed == [" 16  16  17 ", " 123456  2.5 ABCD", " 7  9.5  36 "])
        let bytes = [UInt8](try Data(contentsOf: folder.appendingPathComponent("data.bin")))
        #expect(Array(bytes.prefix(4)) == [0x40, 0xE2, 0x01, 0x00])
    }

    @Test("A Variant variable is written with its type, and read back the same")
    func binaryVariant() throws {
        let (_, folder) = try workingFolder()
        let printed = try run("""
        Sub Main()
            Dim a As Variant, b As Variant, c As Variant
            a = "text": b = 3.25
            Open "v.bin" For Binary As #1
            Put #1, , a
            Put #1, , b
            Get #1, 1, c
            Debug.Print TypeName(c); c
            Get #1, , c
            Debug.Print TypeName(c); c
            Close #1
        End Sub
        """, in: folder)
        #expect(printed == ["Stringtext", "Double 3.25 "])
    }

    // MARK: - Folders and listings

    @Test("Dir lists matches one at a time, folders only when asked")
    func listing() throws {
        let (_, folder) = try workingFolder()
        let printed = try run("""
        Sub Main()
            Dim i As Integer, name As String
            For i = 1 To 3
                Open "report" & i & ".csv" For Output As #1
                Close #1
            Next
            Open "notes.txt" For Output As #1
            Close #1
            MkDir "archive"
            name = Dir("*.csv")
            Do While name <> ""
                Debug.Print name
                name = Dir()
            Loop
            Debug.Print Dir("report?.CSV"); Dir("missing*") = ""
            Debug.Print Dir("archive", vbDirectory); Dir("archive") = ""
            Debug.Print GetAttr("archive") And vbDirectory
        End Sub
        """, in: folder)
        #expect(printed == ["report1.csv", "report2.csv", "report3.csv", "report1.csvTrue", "archiveTrue", " 16 "])
    }

    @Test("Kill, FileCopy, Name, MkDir and RmDir stay inside the folder")
    func fileCommands() throws {
        let (parent, folder) = try workingFolder()
        let printed = try run("""
        Sub Main()
            Open "a.txt" For Output As #1
            Print #1, "hello"
            Close #1
            FileCopy "a.txt", "b.txt"
            Name "b.txt" As "c.txt"
            MkDir "sub"
            Name "c.txt" As "sub\\c.txt"
            Debug.Print Dir("b.txt") = ""; FileLen("sub\\c.txt")
            Kill "*.txt"
            Debug.Print Dir("*.txt") = ""
            Kill "sub\\c.txt"
            RmDir "sub"
            Debug.Print Dir("sub", vbDirectory) = ""
        End Sub
        """, in: folder)
        #expect(printed == ["True 7 ", "True", "True"])
        #expect(try error(running: "Sub Main()\nName \"..\\outside.txt\" As \"stolen.txt\"\nEnd Sub", in: folder)?.number == 75)
        #expect(try error(running: "Sub Main()\nRmDir \".\"\nEnd Sub", in: folder)?.number == 75)
        #expect(try error(running: "Sub Main()\nChDir \"..\"\nEnd Sub", in: folder)?.number == 75)
        #expect(FileManager.default.fileExists(atPath: parent.appendingPathComponent("outside.txt").path))
    }

    @Test("Without a working folder, file statements say files are unavailable")
    func noFolder() throws {
        let interpreter = try VBAInterpreter(modules: [("Module1", .standard,
                                                         "Sub Main()\nOpen \"a\" For Output As #1\nEnd Sub")], host: nil)
        let error = try #require(throws: VBAError.self) { try interpreter.run("Main") }
        #expect(error.number == 445)
    }

    // MARK: - Shell, SendKeys, AppActivate

    @Test("Shell opens web and app links with the user's agreement, and nothing else")
    func shell() throws {
        let (_, folder) = try workingFolder()
        let host = FileTestHost()
        _ = try run("Sub Main()\nShell \"https://example.com/a?b=1\"\nShell \"mailto:a@example.com\"\nEnd Sub",
                    in: folder, host: host)
        #expect(host.openedURLs.map(\.absoluteString) == ["https://example.com/a?b=1", "mailto:a@example.com"])
        for command in ["notepad.exe", "cmd /c del *.*", "file:///etc/hosts", "C:/Windows/notepad.exe", "javascript:alert(1)"] {
            #expect(try error(running: "Sub Main()\nShell \"\(command)\"\nEnd Sub", in: folder)?.number == 445, "\(command)")
        }
        let declining = FileTestHost()
        declining.allowsLinks = false
        #expect(try error(running: "Sub Main()\nShell \"https://example.com\"\nEnd Sub", in: folder, host: declining)?.number == 70)
    }

    @Test("SendKeys shows its keys; AppActivate does nothing")
    func keys() throws {
        let (_, folder) = try workingFolder()
        let host = FileTestHost()
        _ = try run("Sub Main()\nAppActivate \"Notepad\"\nSendKeys \"Hello{ENTER}\", True\nEnd Sub", in: folder, host: host)
        #expect(host.sentKeys == ["Hello{ENTER}"])
    }
}

@Suite("VBA language additions")
struct VBALanguageAdditionTests {
    private func run(_ source: String, extraModules: [(String, VBAProject.Module.Kind, String)] = []) throws -> [String] {
        let host = FileTestHost()
        let interpreter = try VBAInterpreter(modules: [("Module1", .standard, source)] + extraModules, host: host)
        _ = try interpreter.run("Main")
        return host.printed
    }

    @Test("CallByName calls, reads and assigns members by name")
    func callByName() throws {
        let counter = "Public Count As Long\nPublic Sub Add(n As Long)\nCount = Count + n\nEnd Sub"
        let printed = try run("""
        Sub Main()
            Dim c As New Counter, col As New Collection
            CallByName c, "Add", vbMethod, 5
            CallByName c, "Count", vbLet, CallByName(c, "Count", vbGet) * 10
            col.Add "x"
            Debug.Print c.Count; CallByName(col, "Count", vbGet)
        End Sub
        """, extraModules: [("Counter", .classModule, counter)])
        #expect(printed == [" 50  1 "])
    }

    @Test("LSet and RSet fit text into a string's existing length")
    func alignedAssign() throws {
        let printed = try run("""
        Sub Main()
            Dim s As String
            s = "12345"
            LSet s = "ab"
            Debug.Print "[" & s & "]"
            RSet s = "ab"
            Debug.Print "[" & s & "]"
            LSet s = "abcdefgh"
            Debug.Print "[" & s & "]"
        End Sub
        """)
        #expect(printed == ["[ab   ]", "[   ab]", "[abcde]"])
    }

    @Test("GoSub runs to Return and carries on after itself")
    func goSub() throws {
        let printed = try run("""
        Sub Main()
            Dim n As Integer
            n = 1
            GoSub Double
            GoSub Double
            Debug.Print n
            Exit Sub
        Double:
            n = n * 2
            Return
        End Sub
        """)
        #expect(printed == [" 4 "])
        let interpreter = try VBAInterpreter(modules: [("Module1", .standard, "Sub Main()\nReturn\nEnd Sub")], host: nil)
        #expect((try #require(throws: VBAError.self) { try interpreter.run("Main") }).number == 3)
    }

    @Test("RaiseEvent reaches WithEvents variables in classes and document modules, ByRef arguments included")
    func events() throws {
        let source = """
        Public Event Changed(ByVal value As Long, Cancel As Boolean)
        Private mValue As Long

        Public Property Let Value(ByVal v As Long)
            Dim cancel As Boolean
            RaiseEvent Changed(v, cancel)
            If Not cancel Then mValue = v
        End Property

        Public Property Get Value() As Long
            Value = mValue
        End Property
        """
        let watcher = """
        Private WithEvents mSource As Source
        Public Log As String

        Public Sub Watch(s As Source)
            Set mSource = s
        End Sub

        Private Sub mSource_Changed(ByVal value As Long, Cancel As Boolean)
            Log = Log & value & ";"
            If value < 0 Then Cancel = True
        End Sub
        """
        let sheet = """
        Public WithEvents Feed As Source

        Private Sub Feed_Changed(ByVal value As Long, Cancel As Boolean)
            Debug.Print "sheet saw"; value
        End Sub
        """
        let printed = try run("""
        Sub Main()
            Dim s As New Source, w As New Watcher
            w.Watch s
            Set Sheet1.Feed = s
            s.Value = 5
            s.Value = -1
            Debug.Print s.Value; w.Log
        End Sub
        """, extraModules: [("Source", .classModule, source), ("Watcher", .classModule, watcher),
                            ("Sheet1", .document, sheet)])
        #expect(printed == ["sheet saw 5 ", "sheet saw-1 ", " 5 5;-1;"])
    }

    @Test("AddressOf, Declare, UserForms and GetObject are explicitly unavailable, without stopping the module")
    func unavailable() throws {
        let source = """
        Private Declare PtrSafe Function GetTickCount Lib "kernel32" () As Long

        Sub Main()
            Debug.Print "runs"
        End Sub

        Sub UsesAddressOf()
            Dim p
            p = AddressOf Main
        End Sub

        Sub UsesDeclare()
            Debug.Print GetTickCount()
        End Sub

        Sub UsesForm()
            Load UserForm1
        End Sub

        Sub UsesGetObject()
            Dim o
            Set o = GetObject(, "Excel.Application")
        End Sub
        """
        #expect(try run(source) == ["runs"])
        let interpreter = try VBAInterpreter(modules: [("Module1", .standard, source)], host: FileTestHost())
        for procedure in ["UsesAddressOf", "UsesDeclare", "UsesForm", "UsesGetObject"] {
            let error = try #require(throws: VBAError.self, "\(procedure)") { try interpreter.run(procedure) }
            #expect(error.number == 445, "\(procedure)")
        }
    }
}
