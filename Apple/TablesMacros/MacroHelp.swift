import Foundation
import TablesEngine

/// The contents of the macro help book: what Tables can run and what it
/// cannot, by topic. Names of things in code stay as VBA spells them; the
/// prose around them comes from the string catalog.
///
/// The lists here are checked against the interpreter by tests, so a
/// function or member listed as available really is, and one listed as
/// unavailable really says so when a macro uses it.
public enum MacroHelp {
    public struct Topic: Identifiable, Hashable, Sendable {
        public var id: String
        public var symbol: String
        /// Catalog keys of the paragraphs that open the topic.
        public var paragraphs: [String]
        public var groups: [Group] = []

        public var title: String {
            // Built first: written inline, the interpolation would become part
            // of the catalog key as a placeholder.
            let key = "Help.\(id).Title"
            return String(localized: String.LocalizationValue(key), bundle: #bundle)
        }
    }

    public struct Group: Identifiable, Hashable, Sendable {
        /// A catalog key, or a name as VBA spells it (`Range`) when `isCode`.
        public var title: String
        public var isCode = false
        public var items: [String]
        public var isAvailable = true
        /// A catalog key for a note under the group.
        public var note: String?

        public var id: String { title + (isAvailable ? "" : "-") }

        public var displayTitle: String {
            isCode ? title : String(localized: String.LocalizationValue(title), bundle: #bundle)
        }
    }

    /// One searchable entry: a name, where it is described, and whether it works.
    public struct Entry: Identifiable, Hashable, Sendable {
        public var name: String
        public var topic: Topic
        public var group: Group
        public var id: String { topic.id + "." + group.id + "." + name }
    }

    public static var entries: [Entry] {
        var entries: [Entry] = []
        for topic in topics {
            for group in topic.groups {
                entries += group.items.map { Entry(name: $0, topic: topic, group: group) }
            }
        }
        return entries
    }

    public static func search(_ query: String) -> [Entry] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return [] }
        return entries.filter { entry in
            entry.name.localizedCaseInsensitiveContains(needle)
                || (entry.group.isCode && (entry.group.title + "." + entry.name).localizedCaseInsensitiveContains(needle))
        }
    }

    // MARK: - Lists checked against the interpreter

    public static let textFunctions = [
        "Asc", "AscW", "Chr", "ChrW", "Format", "FormatCurrency", "FormatDateTime", "FormatNumber", "FormatPercent",
        "Hex", "InStr", "InStrRev", "Join", "LCase", "Left", "Len", "LTrim", "Mid", "Oct", "Replace", "Right",
        "RTrim", "Space", "Split", "Str", "StrComp", "StrConv", "String", "StrReverse", "Trim", "UCase", "Val",
    ]
    public static let mathFunctions = ["Abs", "Atn", "Cos", "Exp", "Fix", "Int", "Log", "Rnd", "Round", "Sgn", "Sin", "Sqr", "Tan"]
    public static let conversionFunctions = [
        "CBool", "CByte", "CCur", "CDate", "CDbl", "CDec", "CInt", "CLng", "CLngLng", "CLngPtr", "CSng", "CStr",
        "CVar", "CVErr",
    ]
    public static let dateFunctions = [
        "Date", "DateAdd", "DateDiff", "DatePart", "DateSerial", "DateValue", "Day", "Hour", "Minute", "Month",
        "MonthName", "Now", "Second", "Time", "Timer", "TimeSerial", "TimeValue", "Weekday", "WeekdayName", "Year",
    ]
    public static let informationFunctions = [
        "Array", "IsArray", "IsDate", "IsEmpty", "IsError", "IsMissing", "IsNull", "IsNumeric", "IsObject",
        "LBound", "QBColor", "RGB", "TypeName", "UBound", "VarType",
    ]
    public static let interactionFunctions = [
        "AppActivate", "Beep", "CallByName", "Choose", "CreateObject", "DoEvents", "Environ", "IIf", "InputBox",
        "MsgBox", "SendKeys", "Shell", "Switch",
    ]
    public static let fileFunctions = [
        "ChDir", "ChDrive", "CurDir", "Dir", "EOF", "FileAttr", "FileCopy", "FileDateTime", "FileLen", "FreeFile",
        "GetAttr", "Input", "Kill", "Loc", "LOF", "MkDir", "Reset", "RmDir", "Seek", "SetAttr",
    ]
    public static let unavailableFunctions = ["GetObject"]

    public static let applicationMembers = [
        "ActiveCell", "ActiveSheet", "ActiveWorkbook", "Calculate", "Calculation", "Cells", "Columns", "CutCopyMode",
        "DefaultFilePath",
        "DisplayAlerts", "EnableEvents", "Evaluate", "InputBox", "Intersect", "Range", "Rows", "Run", "ScreenUpdating",
        "Selection", "Sheets", "StatusBar", "ThisWorkbook", "Union", "Version", "Wait", "Workbooks", "Worksheets",
        "WorksheetFunction",
    ]
    public static let unavailableApplicationMembers = ["FileDialog", "GetOpenFilename", "GetSaveAsFilename", "OnTime", "Quit", "SendKeys"]
    public static let workbookMembers = [
        "ActiveSheet", "CodeName", "FollowHyperlink", "FullName", "Name", "Path", "Save", "Sheets", "Worksheets",
    ]
    public static let unavailableWorkbookMembers = ["Close", "PrintOut", "Protect", "SaveAs", "SaveCopyAs"]
    public static let sheetsMembers = ["Add", "Count", "Item"]
    public static let worksheetMembers = [
        "Activate", "Calculate", "Cells", "CodeName", "Columns", "Copy", "Delete", "Evaluate", "Index", "Move", "Name",
        "Next", "Parent", "Paste", "Previous", "Protect", "Range", "Rows", "Select", "Unprotect", "UsedRange", "Visible",
    ]
    public static let rangeMembers = [
        "Activate", "Address", "Areas", "AutoFit", "Borders", "Cells", "Clear", "ClearContents", "ClearFormats", "Column",
        "ColumnWidth", "Columns", "Copy", "Count", "CurrentRegion", "Cut", "Delete", "End", "EntireColumn", "EntireRow",
        "Find", "Font", "Formula", "HasFormula", "Height", "Hidden", "HorizontalAlignment", "IndentLevel", "Insert",
        "Interior", "Item", "Merge", "MergeArea", "MergeCells", "NumberFormat", "Offset", "PasteSpecial", "Range",
        "Resize", "Row", "RowHeight", "Rows", "Select", "Sort", "SpecialCells", "Text", "UnMerge", "Value", "Value2",
        "VerticalAlignment", "Width", "Worksheet", "WrapText",
    ]
    public static let unavailableRangeMembers = [
        "AddComment", "AdvancedFilter", "AutoFill", "AutoFilter", "FillDown", "FillRight", "FormatConditions",
        "FormulaArray", "FormulaR1C1", "Hyperlinks", "Name", "RemoveDuplicates", "TextToColumns", "Validation",
    ]
    public static let fontMembers = ["Bold", "Color", "ColorIndex", "Italic", "Name", "Size", "Strikethrough", "Underline"]
    public static let interiorMembers = ["Color", "ColorIndex", "Pattern"]
    public static let bordersMembers = ["Color", "ColorIndex", "LineStyle", "Weight"]

    // MARK: - Topics

    public static let topics: [Topic] = [
        Topic(id: "Running", symbol: "play.circle", paragraphs: [
            "Help.Running.Choose", "Help.Running.Undo", "Help.Running.Sandbox", "Help.Running.Files", "Help.Running.Ask",
        ]),
        Topic(id: "Files", symbol: "folder", paragraphs: [
            "Help.Files.Folder", "Help.Files.Paths", "Help.Files.Text", "Help.Files.Links", "Help.Files.Keys",
        ]),
        Topic(id: "Editor", symbol: "pencil.and.list.clipboard", paragraphs: [
            "Help.Editor.Saving", "Help.Editor.Checking", "Help.Editor.Indent", "Help.Editor.Modules",
            "Help.Editor.Output",
        ]),
        Topic(id: "Language", symbol: "curlybraces", paragraphs: ["Help.Language.Intro"], groups: [
            Group(title: "Help.Language.Procedures", items: [
                "Sub", "Function", "Property Get", "Property Let", "Property Set", "ByRef", "ByVal", "Optional",
                "ParamArray", "name:=value", "Call", "GoSub … Return",
            ]),
            Group(title: "Help.Language.Variables", items: [
                "Dim", "Static", "Const", "ReDim", "ReDim Preserve", "Erase", "LSet", "RSet", "Type", "Enum",
                "Option Explicit", "Option Base", "Option Compare",
            ]),
            Group(title: "Help.Language.Flow", items: [
                "If … Then … Else", "Select Case", "For … Next", "For Each … Next", "Do … Loop", "While … Wend", "With",
                "Exit", "GoTo", "End",
            ]),
            Group(title: "Help.Language.Errors", items: [
                "On Error Resume Next", "On Error GoTo", "Resume", "Resume Next", "Err.Number", "Err.Description",
                "Err.Raise", "Err.Clear",
            ]),
            Group(title: "Help.Language.Objects", items: [
                "Class modules", "New", "Set", "Me", "Is", "TypeOf … Is", "Nothing", "Event", "RaiseEvent",
                "WithEvents",
            ]),
            Group(title: "Help.Language.Files", items: [
                "Open … For", "Close", "Print #", "Write #", "Input #", "Line Input #", "Get", "Put", "Seek",
                "Lock", "Unlock", "Width #", "Name … As",
            ], note: "Help.Language.FilesNote"),
            Group(title: "Help.Language.Other", items: ["#If … #End If", "Debug.Print", "[A1]"]),
            Group(title: "Help.Unavailable", items: [
                "UserForms", "Load", "Unload", "Declare", "AddressOf", "Workbook_Open", "Worksheet_Change",
            ], isAvailable: false, note: "Help.Language.UnavailableNote"),
        ]),
        Topic(id: "Functions", symbol: "function", paragraphs: ["Help.Functions.Intro"], groups: [
            Group(title: "Help.Functions.Text", items: textFunctions, note: "Help.Functions.FormatNote"),
            Group(title: "Help.Functions.Math", items: mathFunctions),
            Group(title: "Help.Functions.Conversion", items: conversionFunctions),
            Group(title: "Help.Functions.Dates", items: dateFunctions),
            Group(title: "Help.Functions.Information", items: informationFunctions),
            Group(title: "Help.Functions.Interaction", items: interactionFunctions, note: "Help.Functions.InteractionNote"),
            Group(title: "Help.Functions.Files", items: fileFunctions, note: "Help.Functions.FilesNote"),
            Group(title: "Help.Functions.Objects", items: ["Collection", "Scripting.Dictionary", "VBScript.RegExp"]),
            Group(title: "Help.Unavailable", items: unavailableFunctions + ["Scripting.FileSystemObject"],
                  isAvailable: false, note: "Help.Functions.UnavailableNote"),
        ]),
        Topic(id: "Excel", symbol: "tablecells", paragraphs: ["Help.Excel.Intro", "Help.Excel.Settings"], groups: [
            Group(title: "Application", isCode: true, items: applicationMembers),
            Group(title: "Application", isCode: true, items: unavailableApplicationMembers, isAvailable: false),
            Group(title: "Workbook", isCode: true, items: workbookMembers),
            Group(title: "Workbook", isCode: true, items: unavailableWorkbookMembers, isAvailable: false),
            Group(title: "Worksheets", isCode: true, items: sheetsMembers, note: "Help.Excel.SheetsNote"),
            Group(title: "Worksheet", isCode: true, items: worksheetMembers),
            Group(title: "Range", isCode: true, items: rangeMembers, note: "Help.Excel.RangeNote"),
            Group(title: "Range", isCode: true, items: unavailableRangeMembers, isAvailable: false),
            Group(title: "Font", isCode: true, items: fontMembers),
            Group(title: "Interior", isCode: true, items: interiorMembers),
            Group(title: "Borders", isCode: true, items: bordersMembers),
            Group(title: "WorksheetFunction", isCode: true, items: ["Sum", "Average", "VLookup", "CountIf", "…"],
                  note: "Help.Excel.WorksheetFunctionNote"),
        ]),
        Topic(id: "Differences", symbol: "arrow.left.arrow.right", paragraphs: [
            "Help.Differences.Rows", "Help.Differences.Structure", "Help.Differences.Areas", "Help.Differences.Events",
            "Help.Differences.Compile", "Help.Differences.Messages",
        ]),
    ]
}
