import Foundation
import TablesEngine

/// The functions and constants of the VBA library itself — `Len`, `Mid`,
/// `DateAdd`, `vbCrLf` — which every host has, spreadsheet or not.
public enum VBALibrary {
    /// Calls a built-in function, or returns nil when there is none by that name.
    public static func call(_ name: String, _ arguments: VBAArguments, interpreter: VBAInterpreter,
                     frame: VBAInterpreter.Frame) throws -> VBAValue? {
        let call = LibraryCall(arguments: arguments, interpreter: interpreter)
        switch name.lowercased() {
        // MARK: Strings
        case "len", "lenb":
            let value = try call.raw(0)
            if case .null = value { return .null }
            return .integer(try call.string(0).utf16.count)
        case "left", "leftb", "left$":
            return .string(String(try call.string(0).prefix(max(0, try call.integer(1)))))
        case "right", "rightb", "right$":
            return .string(String(try call.string(0).suffix(max(0, try call.integer(1)))))
        case "mid", "midb", "mid$":
            let text = try call.string(0)
            let start = try call.integer(1)
            guard start >= 1 else { throw VBAError.invalidCall }
            let characters = Array(text)
            guard start <= characters.count else { return .string("") }
            let length = try call.optionalInteger(2) ?? characters.count
            guard length >= 0 else { throw VBAError.invalidCall }
            return .string(String(characters[(start - 1)..<min(characters.count, start - 1 + length)]))
        case "instr", "instrb":
            // InStr([start,] string1, string2[, compare]): the start is optional
            // and comes first, and a comparison mode needs it, so three or
            // more arguments mean it is there.
            var offset = 0
            var start = 1
            if arguments.positional.count >= 3 {
                start = try call.integer(0)
                offset = 1
            }
            guard start >= 1 else { throw VBAError.invalidCall }
            let haystack = try call.string(offset)
            let needle = try call.string(offset + 1)
            let textCompare = try call.optionalInteger(offset + 2).map { $0 == 1 } ?? frame.module.syntax.optionCompareText
            return .integer(instr(haystack, needle, start: start, textCompare: textCompare))
        case "instrrev":
            let haystack = Array(try call.string(0))
            let needle = Array(try call.string(1))
            var start = try call.optionalInteger(2) ?? -1
            if start == -1 { start = haystack.count }
            let textCompare = try call.optionalInteger(3) == 1
            guard !needle.isEmpty else { return .integer(start) }
            var position = min(start, haystack.count) - needle.count
            while position >= 0 {
                let slice = String(haystack[position..<(position + needle.count)])
                if VBAOperators.compareText(slice, String(needle), textCompare: textCompare) == .orderedSame {
                    return .integer(position + 1)
                }
                position -= 1
            }
            return .integer(0)
        case "replace":
            let text = try call.string(0)
            let find = try call.string(1)
            let replacement = try call.string(2)
            let start = try call.optionalInteger(3) ?? 1
            let count = try call.optionalInteger(4) ?? -1
            let textCompare = try call.optionalInteger(5) == 1
            return .string(replace(text, find, replacement, start: start, count: count, textCompare: textCompare))
        case "split":
            let text = try call.string(0)
            let delimiter = try call.optionalString(1) ?? " "
            let limit = try call.optionalInteger(2) ?? -1
            guard !text.isEmpty else { return .array(VBAArray.empty(of: .string)) }
            var parts = delimiter.isEmpty ? [text] : text.components(separatedBy: delimiter)
            if limit > 0, parts.count > limit {
                parts = Array(parts.prefix(limit - 1)) + [parts.dropFirst(limit - 1).joined(separator: delimiter)]
            }
            var array = VBAArray(parts.map { .string($0) })
            array.elementType = .string
            return .array(array)
        case "join":
            guard case .array(let array) = try call.raw(0) else { throw VBAError.typeMismatch }
            let delimiter = try call.optionalString(1) ?? " "
            return .string(try array.elements.map { try interpreter.letValue($0).asString() }.joined(separator: delimiter))
        case "trim", "trim$": return .string(try call.string(0).trimmingCharacters(in: CharacterSet(charactersIn: " ")))
        case "ltrim", "ltrim$": return .string(String(try call.string(0).drop { $0 == " " }))
        case "rtrim", "rtrim$":
            var text = try call.string(0)
            while text.hasSuffix(" ") { text.removeLast() }
            return .string(text)
        case "ucase", "ucase$": return .string(try call.string(0).uppercased())
        case "lcase", "lcase$": return .string(try call.string(0).lowercased())
        case "strcomp":
            let order = VBAOperators.compareText(try call.string(0), try call.string(1),
                                                 textCompare: try call.optionalInteger(2) == 1)
            return .integer(order.rawValue)
        case "strreverse": return .string(String(try call.string(0).reversed()))
        case "space", "space$": return .string(String(repeating: " ", count: max(0, try call.integer(0))))
        case "string", "string$":
            let count = max(0, try call.integer(0))
            let source = try call.raw(1)
            let character: String
            if case .string(let text) = source { character = String(text.prefix(1)) }
            else { character = String(UnicodeScalar(UInt8(truncatingIfNeeded: try source.asInteger()))) }
            return .string(String(repeating: character, count: count))
        case "chr", "chrw", "chr$", "chrw$":
            let code = try call.integer(0)
            guard let scalar = UnicodeScalar(UInt32(truncatingIfNeeded: code & 0xFFFF)) else { throw VBAError.invalidCall }
            return .string(String(Character(scalar)))
        case "asc", "ascw":
            guard let first = try call.string(0).unicodeScalars.first else { throw VBAError.invalidCall }
            return .integer(Int(first.value))
        case "strconv":
            let text = try call.string(0)
            switch try call.integer(1) {
            case 1: return .string(text.uppercased())
            case 2: return .string(text.lowercased())
            case 3: return .string(text.capitalized)
            default: return .string(text)
            }
        case "cstr": return .string(try call.string(0))
        case "str", "str$":
            let value = try call.scalar(0)
            let text = try value.asString()
            return .string(try value.asDouble() >= 0 ? " " + text : text)
        case "val":
            return value(of: try call.string(0))
        case "hex", "hex$": return .string(String(UInt64(bitPattern: Int64(try call.integer(0))) & hexMask(try call.integer(0)), radix: 16).uppercased())
        case "oct", "oct$": return .string(String(try call.integer(0), radix: 8))
        case "format", "format$":
            return .string(try format(call.scalar(0), try call.optionalString(1) ?? ""))
        case "formatnumber":
            return .string(try formatNumber(call.scalar(0).asDouble(), digits: call.optionalInteger(1) ?? 2,
                                            grouping: true))
        case "formatcurrency":
            return .string("$" + (try formatNumber(call.scalar(0).asDouble(), digits: call.optionalInteger(1) ?? 2,
                                                   grouping: true)))
        case "formatpercent":
            return .string(try formatNumber(call.scalar(0).asDouble() * 100, digits: call.optionalInteger(1) ?? 2,
                                            grouping: true) + "%")
        case "formatdatetime":
            let serial = try call.scalar(0).asDate()
            switch try call.optionalInteger(1) ?? 0 {
            case 1: return .string(try format(.date(serial), "Long Date"))
            case 2: return .string(try format(.date(serial), "Short Date"))
            case 3: return .string(try format(.date(serial), "Long Time"))
            case 4: return .string(try format(.date(serial), "Short Time"))
            default: return .string(VBAValue.formatDate(serial))
            }

        // MARK: Maths
        case "abs":
            let value = try call.scalar(0)
            if case .integer(let number) = value { return .integer(abs(number)) }
            if case .null = value { return .null }
            return .double(abs(try value.asDouble()))
        case "sgn":
            let number = try call.scalar(0).asDouble()
            let sign = if number > 0 { 1 } else if number < 0 { -1 } else { 0 }
            return .integer(sign)
        case "int":
            let value = try call.scalar(0)
            if case .integer = value { return value }
            return .double(try value.asDouble().rounded(.down))
        case "fix":
            let value = try call.scalar(0)
            if case .integer = value { return value }
            return .double(try value.asDouble().rounded(.towardZero))
        case "round":
            let number = try call.scalar(0).asDouble()
            let digits = try call.optionalInteger(1) ?? 0
            let scale = pow(10, Double(digits))
            return .double((number * scale).rounded(.toNearestOrEven) / scale)
        case "sqr":
            let number = try call.scalar(0).asDouble()
            guard number >= 0 else { throw VBAError.invalidCall }
            return .double(number.squareRoot())
        case "exp": return .double(exp(try call.scalar(0).asDouble()))
        case "log":
            let number = try call.scalar(0).asDouble()
            guard number > 0 else { throw VBAError.invalidCall }
            return .double(log(number))
        case "sin": return .double(sin(try call.scalar(0).asDouble()))
        case "cos": return .double(cos(try call.scalar(0).asDouble()))
        case "tan": return .double(tan(try call.scalar(0).asDouble()))
        case "atn": return .double(atan(try call.scalar(0).asDouble()))
        case "rnd": return .double(Double.random(in: 0..<1))

        // MARK: Conversion
        case "cbool": return .boolean(try call.scalar(0).asBoolean())
        case "cbyte": return try VBAType.byte.coerce(call.scalar(0))
        case "cint": return try VBAType.integer.coerce(call.scalar(0))
        case "clng", "clngptr": return try VBAType.long.coerce(call.scalar(0))
        case "clnglng": return try VBAType.longLong.coerce(call.scalar(0))
        case "csng", "cdbl", "cdec": return .double(try call.scalar(0).asDouble())
        case "ccur": return try VBAType.currency.coerce(call.scalar(0))
        case "cdate", "datevalue":
            let serial = try call.scalar(0).asDate()
            return .date(name.lowercased() == "datevalue" ? serial.rounded(.down) : serial)
        case "timevalue":
            let serial = try call.scalar(0).asDate()
            return .date(serial - serial.rounded(.down))
        case "cvar": return try call.raw(0)
        case "cverr": return .error(try call.integer(0))

        // MARK: Information
        case "isempty":
            if case .empty = try call.raw(0) { return .boolean(true) }
            return .boolean(false)
        case "isnull":
            if case .null = try call.raw(0) { return .boolean(true) }
            return .boolean(false)
        case "ismissing":
            if case .missing = try call.raw(0) { return .boolean(true) }
            return .boolean(false)
        case "isnumeric":
            switch try call.scalar(0) {
            case .integer, .double, .empty, .boolean: return .boolean(true)
            case .string(let text): return .boolean(VBAValue.parseNumber(text) != nil)
            default: return .boolean(false)
            }
        case "isdate":
            switch try call.scalar(0) {
            case .date: return .boolean(true)
            case .string(let text): return .boolean(VBADate.parse(text) != nil)
            default: return .boolean(false)
            }
        case "isarray":
            if case .array = try call.raw(0) { return .boolean(true) }
            return .boolean(false)
        case "isobject":
            return .boolean(try call.raw(0).isObjectLike)
        case "iserror":
            if case .error = try call.scalar(0) { return .boolean(true) }
            return .boolean(false)
        case "typename":
            return .string(try call.raw(0).typeName)
        case "vartype":
            return .integer(try call.raw(0).varType)
        case "lbound", "ubound":
            guard case .array(let array) = try call.raw(0) else { throw VBAError.typeMismatch }
            let dimension = (try call.optionalInteger(1) ?? 1) - 1
            guard array.isAllocated, dimension >= 0, dimension < array.dimensions else {
                throw VBAError.subscriptOutOfRange
            }
            return .integer(name.lowercased() == "lbound" ? array.lowerBounds[dimension] : array.upperBound(dimension))
        case "array":
            return .array(VBAArray(arguments.positional.map { $0 ?? .missing },
                                   lowerBound: frame.module.syntax.optionBase))
        case "rgb":
            let red = try call.integer(0) & 0xFF
            let green = try call.integer(1) & 0xFF
            let blue = try call.integer(2) & 0xFF
            return .integer(red | green << 8 | blue << 16)
        case "qbcolor":
            let palette = [0x000000, 0x800000, 0x008000, 0x808000, 0x000080, 0x800080, 0x008080, 0xC0C0C0,
                           0x808080, 0xFF0000, 0x00FF00, 0xFFFF00, 0x0000FF, 0xFF00FF, 0x00FFFF, 0xFFFFFF]
            let index = try call.integer(0)
            guard palette.indices.contains(index) else { throw VBAError.invalidCall }
            return .integer(palette[index])

        // MARK: Dates
        case "now": return .date(VBADate.serial(Date()) + localOffset)
        case "date", "date$": return .date((VBADate.serial(Date()) + localOffset).rounded(.down))
        case "time", "time$":
            let now = VBADate.serial(Date()) + localOffset
            return .date(now - now.rounded(.down))
        case "timer":
            let now = VBADate.serial(Date()) + localOffset
            return .double(((now - now.rounded(.down)) * 86_400 * 100).rounded() / 100)
        case "year": return .integer(VBADate.components(try call.scalar(0).asDate()).year!)
        case "month": return .integer(VBADate.components(try call.scalar(0).asDate()).month!)
        case "day": return .integer(VBADate.components(try call.scalar(0).asDate()).day!)
        case "hour": return .integer(VBADate.components(try call.scalar(0).asDate()).hour!)
        case "minute": return .integer(VBADate.components(try call.scalar(0).asDate()).minute!)
        case "second": return .integer(VBADate.components(try call.scalar(0).asDate()).second!)
        case "weekday":
            let weekday = VBADate.components(try call.scalar(0).asDate()).weekday!
            let first = try call.optionalInteger(1) ?? 1
            return .integer((weekday - (first == 0 ? 1 : first) + 7) % 7 + 1)
        case "dateserial":
            guard let serial = VBADate.serial(year: try call.integer(0), month: try call.integer(1),
                                              day: try call.integer(2)) else { throw VBAError.invalidCall }
            return .date(serial)
        case "timeserial":
            let seconds = try call.integer(0) * 3600 + call.integer(1) * 60 + call.integer(2)
            return .date(Double(seconds) / 86_400)
        case "dateadd":
            return .date(try dateAdd(call.string(0), call.scalar(1).asDouble(), call.scalar(2).asDate()))
        case "datediff":
            return .integer(try dateDiff(call.string(0), call.scalar(1).asDate(), call.scalar(2).asDate()))
        case "datepart":
            let serial = try call.scalar(1).asDate()
            let parts = VBADate.components(serial)
            switch try call.string(0).lowercased() {
            case "yyyy": return .integer(parts.year!)
            case "q": return .integer((parts.month! - 1) / 3 + 1)
            case "m": return .integer(parts.month!)
            case "y": return .integer(VBADate.calendar.ordinality(of: .day, in: .year, for: VBADate.date(serial)) ?? 1)
            case "d": return .integer(parts.day!)
            case "w": return .integer(parts.weekday!)
            case "ww": return .integer(VBADate.calendar.component(.weekOfYear, from: VBADate.date(serial)))
            case "h": return .integer(parts.hour!)
            case "n": return .integer(parts.minute!)
            case "s": return .integer(parts.second!)
            default: throw VBAError.invalidCall
            }
        case "monthname":
            let month = try call.integer(0)
            guard (1...12).contains(month) else { throw VBAError.invalidCall }
            let symbols = try call.optionalBoolean(1) == true ? englishShortMonths : englishMonths
            return .string(symbols[month - 1])
        case "weekdayname":
            let day = try call.integer(0)
            guard (1...7).contains(day) else { throw VBAError.invalidCall }
            let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
            let full = names[day - 1]
            return .string(try call.optionalBoolean(1) == true ? String(full.prefix(3)) : full)

        // MARK: Interaction
        case "iif":
            return try interpreter.isTrue(call.raw(0)) ? try call.raw(1) : try call.raw(2)
        case "choose":
            let index = try call.integer(0)
            guard index >= 1, index < arguments.positional.count else { return .null }
            return try call.raw(index)
        case "switch":
            var position = 0
            while position + 1 < arguments.positional.count {
                if try interpreter.isTrue(call.raw(position)) { return try call.raw(position + 1) }
                position += 2
            }
            return .null
        case "msgbox":
            let prompt = try call.string(0, "Prompt")
            let buttons = try call.optionalInteger(1, "Buttons") ?? 0
            let title = try call.optionalString(2, "Title")
            return .integer(interpreter.host?.messageBox(prompt: prompt, buttons: buttons, title: title) ?? 1)
        case "inputbox":
            let prompt = try call.string(0, "Prompt")
            let title = try call.optionalString(1, "Title")
            let defaultText = try call.optionalString(2, "Default") ?? ""
            return .string(interpreter.host?.inputBox(prompt: prompt, title: title, defaultText: defaultText) ?? "")
        case "createobject":
            let className = try call.string(0)
            guard let object = createObject(className) ?? interpreter.host?.createObject(className, in: interpreter)
            else { throw VBAError(number: 429, "ActiveX component can't create object (\(className))") }
            return .object(object)
        case "doevents": return .integer(0)
        case "environ", "environ$": return .string("")
        case "beep", "randomize", "appactivate":
            // Nothing to beep with, a generator that needs no seed, and no
            // other app a macro could bring forward.
            return .empty
        case "shell":
            // Web and app links only, opened once the user agrees; a command
            // line names a program, and there are none to start.
            let target = try call.string(0, "PathName").trimmingCharacters(in: .whitespaces)
            guard let url = openableURL(target) else {
                throw VBAError(number: 445, String(localized: "Macro.Unavailable.Shell", bundle: #bundle))
            }
            guard interpreter.host?.openURL(url) == true else { throw VBAFileSystem.permissionDenied }
            return .double(1)
        case "sendkeys":
            // Keystrokes cannot be typed into another app, so the user is
            // shown them instead, to type or paste where they were meant to go.
            interpreter.host?.showSendKeys(try call.string(0, "String"))
            return .empty
        case "getobject":
            throw VBAError(number: 445, String(localized: "Macro.Unavailable.GetObject", bundle: #bundle))
        case "callbyname":
            return try callByName(call, arguments, interpreter: interpreter)

        // MARK: Files, inside the workbook's working folder
        case "dir", "dir$":
            let files = try fileSystem(interpreter)
            guard let pattern = try call.optionalString(0, "PathName") else { return .string(files.nextMatch()) }
            return .string(try files.firstMatch(pattern, attributes: try call.optionalInteger(1, "Attributes") ?? 0))
        case "curdir", "curdir$":
            return .string(VBAFileSystem.displayPath(try fileSystem(interpreter).currentDirectory))
        case "chdir":
            try fileSystem(interpreter).changeDirectory(try call.string(0, "Path"))
            return .empty
        case "chdrive":
            // One drive: the working folder.
            return .empty
        case "mkdir":
            try fileSystem(interpreter).makeDirectory(try call.string(0, "Path"))
            return .empty
        case "rmdir":
            try fileSystem(interpreter).removeDirectory(try call.string(0, "Path"))
            return .empty
        case "kill":
            try fileSystem(interpreter).delete(try call.string(0, "PathName"))
            return .empty
        case "filecopy":
            try fileSystem(interpreter).copy(try call.string(0, "Source"), to: try call.string(1, "Destination"))
            return .empty
        case "filelen":
            return .integer(try fileSystem(interpreter).length(of: try call.string(0, "PathName")))
        case "filedatetime":
            let date = try fileSystem(interpreter).modificationDate(of: try call.string(0, "PathName"))
            return .date(VBADate.serial(date) + Double(TimeZone.current.secondsFromGMT(for: date)) / 86_400)
        case "getattr":
            return .integer(try fileSystem(interpreter).attributes(of: try call.string(0, "PathName")))
        case "setattr":
            try fileSystem(interpreter).setAttributes(of: try call.string(0, "PathName"),
                                                      to: try call.integer(1, "Attributes"))
            return .empty
        case "reset":
            try fileSystem(interpreter).closeAll()
            return .empty
        case "freefile":
            return .integer(try fileSystem(interpreter).freeNumber(upperRange: (try call.optionalInteger(0) ?? 0) == 1))
        case "eof":
            let file = try fileSystem(interpreter).file(try call.integer(0))
            if file.mode == .binary || file.mode == .random { return .boolean(file.readPastEnd) }
            return .boolean(file.position >= file.bytes.count)
        case "lof":
            return .integer(try fileSystem(interpreter).file(try call.integer(0)).bytes.count)
        case "loc":
            let file = try fileSystem(interpreter).file(try call.integer(0))
            switch file.mode {
            case .random: return .integer(file.position / file.recordLength)
            case .binary: return .integer(file.position)
            // Sequential files count in 128-byte blocks.
            default: return .integer((file.position + 127) / 128)
            }
        case "seek":
            let file = try fileSystem(interpreter).file(try call.integer(0))
            return .integer(file.mode == .random ? file.position / file.recordLength + 1 : file.position + 1)
        case "fileattr":
            let file = try fileSystem(interpreter).file(try call.integer(0))
            let codes: [VBAFileMode: Int] = [.input: 1, .output: 2, .random: 4, .append: 8, .binary: 32]
            return .integer(codes[file.mode] ?? 0)
        case "input", "input$":
            let count = max(0, try call.integer(0))
            let files = try fileSystem(interpreter)
            let file = try files.file(try call.integer(1))
            guard file.mode == .input || file.mode == .binary else { throw VBAFileSystem.badFileMode }
            guard file.position + count <= file.bytes.count else { throw VBAFileSystem.pastEndOfFile }
            return .string(VBAFileSystem.decode(files.readBytes(count, from: file)))
        case "__debugassert":
            if try !interpreter.isTrue(call.raw(0)) { throw VBAControl.end }
            return .empty
        default:
            return nil
        }
    }

    // MARK: - Constants

    public static func constant(named name: String) -> VBAValue? {
        switch name.lowercased() {
        case "vbcrlf", "vbnewline": return .string("\r\n")
        case "vbcr": return .string("\r")
        case "vblf": return .string("\n")
        case "vbtab": return .string("\t")
        case "vbnullstring": return .string("")
        case "vbnullchar": return .string("\u{0}")
        case "vbback": return .string("\u{8}")
        case "vbformfeed": return .string("\u{C}")
        case "vbverticaltab": return .string("\u{B}")
        case "vbtrue": return .integer(-1)
        case "vbfalse": return .integer(0)
        case "vbusedefault": return .integer(-2)
        case "vbokonly": return .integer(0)
        case "vbokcancel": return .integer(1)
        case "vbabortretryignore": return .integer(2)
        case "vbyesnocancel": return .integer(3)
        case "vbyesno": return .integer(4)
        case "vbretrycancel": return .integer(5)
        case "vbcritical": return .integer(16)
        case "vbquestion": return .integer(32)
        case "vbexclamation": return .integer(48)
        case "vbinformation": return .integer(64)
        case "vbdefaultbutton1": return .integer(0)
        case "vbdefaultbutton2": return .integer(256)
        case "vbdefaultbutton3": return .integer(512)
        case "vbapplicationmodal": return .integer(0)
        case "vbsystemmodal": return .integer(4096)
        case "vbok": return .integer(1)
        case "vbcancel": return .integer(2)
        case "vbabort": return .integer(3)
        case "vbretry": return .integer(4)
        case "vbignore": return .integer(5)
        case "vbyes": return .integer(6)
        case "vbno": return .integer(7)
        case "vbbinarycompare": return .integer(0)
        case "vbtextcompare": return .integer(1)
        case "vbuppercase": return .integer(1)
        case "vblowercase": return .integer(2)
        case "vbpropercase": return .integer(3)
        case "vbsunday": return .integer(1)
        case "vbmonday": return .integer(2)
        case "vbtuesday": return .integer(3)
        case "vbwednesday": return .integer(4)
        case "vbthursday": return .integer(5)
        case "vbfriday": return .integer(6)
        case "vbsaturday": return .integer(7)
        case "vbusesystemdayofweek": return .integer(0)
        case "vbgeneraldate": return .integer(0)
        case "vblongdate": return .integer(1)
        case "vbshortdate": return .integer(2)
        case "vblongtime": return .integer(3)
        case "vbshorttime": return .integer(4)
        case "vbempty": return .integer(0)
        case "vbnull": return .integer(1)
        case "vbinteger": return .integer(2)
        case "vblong": return .integer(3)
        case "vbsingle": return .integer(4)
        case "vbdouble": return .integer(5)
        case "vbcurrency": return .integer(6)
        case "vbdate": return .integer(7)
        case "vbstring": return .integer(8)
        case "vbobject": return .integer(9)
        case "vberror": return .integer(10)
        case "vbboolean": return .integer(11)
        case "vbvariant": return .integer(12)
        case "vbarray": return .integer(8192)
        case "vbobjecterror": return .integer(-2_147_221_504)
        case "vbmethod": return .integer(1)
        case "vbget": return .integer(2)
        case "vblet": return .integer(4)
        case "vbset": return .integer(8)
        case "vbnormal": return .integer(0)
        case "vbreadonly": return .integer(1)
        case "vbhidden": return .integer(2)
        case "vbsystem": return .integer(4)
        case "vbvolume": return .integer(8)
        case "vbdirectory": return .integer(16)
        case "vbarchive": return .integer(32)
        case "vbalias": return .integer(64)
        case "vbblack": return .integer(0x000000)
        case "vbred": return .integer(0x0000FF)
        case "vbgreen": return .integer(0x00FF00)
        case "vbyellow": return .integer(0x00FFFF)
        case "vbblue": return .integer(0xFF0000)
        case "vbmagenta": return .integer(0xFF00FF)
        case "vbcyan": return .integer(0xFFFF00)
        case "vbwhite": return .integer(0xFFFFFF)
        default: return nil
        }
    }

    public static func standardErrorDescription(_ number: Int) -> String {
        switch number {
        case 5: return "Invalid procedure call or argument"
        case 6: return "Overflow"
        case 7: return "Out of memory"
        case 9: return "Subscript out of range"
        case 11: return "Division by zero"
        case 13: return "Type mismatch"
        case 91: return "Object variable or With block variable not set"
        case 424: return "Object required"
        case 438: return "Object doesn't support this property or method"
        case 457: return "This key is already associated with an element of this collection"
        case 1004: return "Application-defined or object-defined error"
        default: return "Application-defined or object-defined error"
        }
    }

    public static func createObject(_ className: String) -> (any VBAObject)? {
        switch className.lowercased() {
        case "collection", "vba.collection": return VBACollection()
        case "scripting.dictionary", "dictionary": return VBADictionary()
        case "vbscript.regexp", "regexp": return VBARegExp()
        default: return nil
        }
    }

    // MARK: - Helpers

    private static func fileSystem(_ interpreter: VBAInterpreter) throws -> VBAFileSystem {
        guard let files = interpreter.fileSystem else {
            throw VBAError.notSupported(String(localized: "Macro.Unavailable.Files", bundle: #bundle))
        }
        return files
    }

    /// A link `Shell` and `FollowHyperlink` may open: one with a scheme of
    /// its own, `https://…`, `mailto:…`, `shortcuts://…`. Local files and
    /// scripts are not links for this purpose, and a one-letter scheme is
    /// a Windows drive.
    public static func openableURL(_ text: String) -> URL? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme.count > 1,
              scheme.allSatisfy({ $0.isLetter || $0.isNumber || "+-.".contains($0) }),
              !["file", "javascript", "vbscript", "data"].contains(scheme) else { return nil }
        return url
    }

    /// `CallByName(object, name, kind, arguments…)`: vbMethod 1 and vbGet 2
    /// call or read, vbLet 4 and vbSet 8 assign the last argument.
    private static func callByName(_ call: LibraryCall, _ arguments: VBAArguments,
                                   interpreter: VBAInterpreter) throws -> VBAValue {
        guard case .object(let object) = try call.raw(0, "Object") else { throw VBAError.objectRequired }
        let name = try call.string(1, "ProcName")
        let kind = try call.integer(2, "CallType")
        let rest = Array(arguments.positional.dropFirst(3))
        switch kind {
        case 1, 2:
            return try object.member(name, VBAArguments(rest), in: interpreter)
        case 4, 8:
            guard let value = rest.last, let assigned = value else { throw VBAError(number: 449, "Argument not optional") }
            try object.setMember(name, VBAArguments(Array(rest.dropLast())), to: assigned, in: interpreter)
            return .empty
        default:
            throw VBAError.invalidCall
        }
    }

    /// The device's offset from UTC, in days, so `Now` reads as a wall clock.
    private static var localOffset: Double { Double(TimeZone.current.secondsFromGMT()) / 86_400 }

    private static let englishMonths = ["January", "February", "March", "April", "May", "June", "July",
                                        "August", "September", "October", "November", "December"]
    private static let englishShortMonths = englishMonths.map { String($0.prefix(3)) }

    private static func hexMask(_ value: Int) -> UInt64 {
        // Negative Integers and Longs print in their own width, as VBA does.
        if value >= 0 { return UInt64.max }
        if value >= -32_768 { return 0xFFFF }
        if value >= -2_147_483_648 { return 0xFFFF_FFFF }
        return UInt64.max
    }

    public static func instr(_ haystack: String, _ needle: String, start: Int, textCompare: Bool) -> Int {
        let characters = Array(haystack)
        guard start <= characters.count + 1 else { return 0 }
        if needle.isEmpty { return start }
        let options: String.CompareOptions = textCompare ? [.caseInsensitive] : [.literal]
        let suffix = String(characters[(start - 1)...])
        guard let range = suffix.range(of: needle, options: options) else { return 0 }
        return start + suffix.distance(from: suffix.startIndex, to: range.lowerBound)
    }

    private static func replace(_ text: String, _ find: String, _ replacement: String, start: Int, count: Int,
                                textCompare: Bool) -> String {
        let characters = Array(text)
        guard start >= 1, start <= characters.count + 1 else { return "" }
        // Replace returns the string from `start` on, not the whole string.
        var remaining = String(characters[(start - 1)...])
        guard !find.isEmpty else { return remaining }
        let options: String.CompareOptions = textCompare ? [.caseInsensitive] : [.literal]
        var result = ""
        var replaced = 0
        while count < 0 || replaced < count, let range = remaining.range(of: find, options: options) {
            result += remaining[..<range.lowerBound] + replacement
            remaining = String(remaining[range.upperBound...])
            replaced += 1
        }
        return result + remaining
    }

    /// `Val` reads as much of a number as it can from the start, ignoring spaces.
    private static func value(of text: String) -> VBAValue {
        let compact = text.filter { $0 != " " && $0 != "\t" }
        let upper = compact.uppercased()
        if upper.hasPrefix("&H") {
            return .double(Double(Int(upper.dropFirst(2).prefix { $0.isHexDigit }, radix: 16) ?? 0))
        }
        if upper.hasPrefix("&O") {
            return .double(Double(Int(upper.dropFirst(2).prefix { ("0"..."7").contains($0) }, radix: 8) ?? 0))
        }
        var number = ""
        var seenDot = false
        var seenExponent = false
        for character in compact {
            if character.isNumber { number.append(character) }
            else if character == ".", !seenDot, !seenExponent { seenDot = true; number.append(character) }
            else if (character == "-" || character == "+"), number.isEmpty || number.last == "e" { number.append(character) }
            else if (character == "e" || character == "E"), !seenExponent, !number.isEmpty { seenExponent = true; number.append("e") }
            else { break }
        }
        while let last = number.last, !last.isNumber, last != "." { number.removeLast() }
        return .double(Double(number) ?? 0)
    }

    private static func formatNumber(_ value: Double, digits: Int, grouping: Bool) -> String {
        let code = (grouping ? "#,##0" : "0") + (digits > 0 ? "." + String(repeating: "0", count: digits) : "")
        return CellFormatter.displayText(for: .number(value), format: code)
    }

    /// `Format`, by way of the spreadsheet's own number formatter: VBA's
    /// format codes are Excel's, apart from `n` for minutes and the named
    /// formats, which are translated first.
    public static func format(_ value: VBAValue, _ code: String) throws -> String {
        let named: [String: String] = [
            "general number": "General", "currency": "$#,##0.00", "fixed": "0.00", "standard": "#,##0.00",
            "percent": "0.00%", "scientific": "0.00E+00", "general date": "", "long date": "dddd, mmmm d, yyyy",
            "medium date": "d-mmm-yy", "short date": "m/d/yyyy", "long time": "h:mm:ss AM/PM",
            "medium time": "h:mm AM/PM", "short time": "hh:mm",
        ]
        let lowered = code.lowercased()
        switch lowered {
        case "yes/no": return try value.asBoolean() ? "Yes" : "No"
        case "true/false": return try value.asBoolean() ? "True" : "False"
        case "on/off": return try value.asBoolean() ? "On" : "Off"
        default: break
        }
        var excelCode = named[lowered] ?? code
        if case .null = value { return "" }
        if excelCode.isEmpty {
            if case .date(let serial) = value { return VBAValue.formatDate(serial) }
            return try value.asString()
        }
        excelCode = excelCode.replacingOccurrences(of: "nn", with: "mm").replacingOccurrences(of: "Nn", with: "mm")
        let number: Double
        switch value {
        case .string(let text):
            if let parsed = VBAValue.parseNumber(text) { number = parsed }
            else if let serial = VBADate.parse(text) { number = serial }
            else { return CellFormatter.displayText(for: .text(text), format: excelCode) }
        case .empty:
            number = 0
        default:
            number = try value.asDouble()
        }
        return CellFormatter.displayText(for: .number(number), format: excelCode)
    }

    private static func dateAdd(_ interval: String, _ amount: Double, _ serial: Double) throws -> Double {
        let date = VBADate.date(serial)
        let whole = Int(amount.rounded(.towardZero))
        let component: Calendar.Component
        var count = whole
        switch interval.lowercased() {
        case "yyyy": component = .year
        case "q": component = .month; count = whole * 3
        case "m": component = .month
        case "y", "d", "w": component = .day
        case "ww": component = .day; count = whole * 7
        case "h": return serial + amount / 24
        case "n": return serial + amount / 1440
        case "s": return serial + amount / 86_400
        default: throw VBAError.invalidCall
        }
        guard let result = VBADate.calendar.date(byAdding: component, value: count, to: date) else {
            throw VBAError.invalidCall
        }
        return VBADate.serial(result)
    }

    private static func dateDiff(_ interval: String, _ first: Double, _ second: Double) throws -> Int {
        let a = VBADate.components(first)
        let b = VBADate.components(second)
        switch interval.lowercased() {
        case "yyyy": return b.year! - a.year!
        case "q": return (b.year! * 4 + (b.month! - 1) / 3) - (a.year! * 4 + (a.month! - 1) / 3)
        case "m": return (b.year! * 12 + b.month!) - (a.year! * 12 + a.month!)
        case "y", "d": return Int(second.rounded(.down) - first.rounded(.down))
        case "w": return Int((second.rounded(.down) - first.rounded(.down)) / 7)
        case "ww":
            // Sundays crossed, as VBA counts calendar weeks.
            let start = first.rounded(.down) - Double((a.weekday! - 1))
            let end = second.rounded(.down) - Double((b.weekday! - 1))
            return Int((end - start) / 7)
        case "h": return Int(((second - first) * 24).rounded(.towardZero))
        case "n": return Int(((second - first) * 1440).rounded(.towardZero))
        case "s": return Int(((second - first) * 86_400).rounded())
        default: throw VBAError.invalidCall
        }
    }
}

/// Argument access for library functions, coercing as VBA would.
private struct LibraryCall {
    let arguments: VBAArguments
    let interpreter: VBAInterpreter

    /// The argument as passed, where an omitted optional parameter handed
    /// on is still an argument — it is what `IsMissing` looks at.
    func raw(_ index: Int, _ name: String? = nil) throws -> VBAValue {
        if index < arguments.positional.count, case .missing? = arguments.positional[index] { return .missing }
        return try arguments.required(index, name)
    }

    /// The argument as a plain value: an object stands for its default property.
    func scalar(_ index: Int, _ name: String? = nil) throws -> VBAValue {
        try interpreter.letValue(raw(index, name))
    }

    func string(_ index: Int, _ name: String? = nil) throws -> String {
        try scalar(index, name).asString()
    }

    func integer(_ index: Int, _ name: String? = nil) throws -> Int {
        try scalar(index, name).asInteger()
    }

    func optionalString(_ index: Int, _ name: String? = nil) throws -> String? {
        guard let value = arguments.value(index, name) else { return nil }
        return try interpreter.letValue(value).asString()
    }

    func optionalInteger(_ index: Int, _ name: String? = nil) throws -> Int? {
        guard let value = arguments.value(index, name) else { return nil }
        return try interpreter.letValue(value).asInteger()
    }

    func optionalBoolean(_ index: Int, _ name: String? = nil) throws -> Bool? {
        guard let value = arguments.value(index, name) else { return nil }
        return try interpreter.letValue(value).asBoolean()
    }
}

extension VBAArray {
    /// An array with no elements whose `UBound` is -1, which is what `Split`
    /// returns for an empty string.
    public static func empty(of type: VBAType) -> VBAArray {
        VBAArray(lowerBounds: [0], upperBounds: [-1], elementType: type)
    }
}

// MARK: - Collection

/// VBA's `Collection`: one-based, optionally keyed, case-insensitive keys.
public final class VBACollection: VBAObject {
    public private(set) var items: [(key: String?, value: VBAValue)] = []
    public var typeName: String { "Collection" }

    private func index(of selector: VBAValue, in interpreter: VBAInterpreter) throws -> Int {
        let selector = try interpreter.letValue(selector)
        if case .string(let key) = selector {
            guard let index = items.firstIndex(where: { $0.key?.caseInsensitiveCompare(key) == .orderedSame }) else {
                throw VBAError.invalidCall
            }
            return index
        }
        let position = try selector.asInteger()
        guard position >= 1, position <= items.count else { throw VBAError.subscriptOutOfRange }
        return position - 1
    }

    public func member(_ name: String, _ arguments: VBAArguments, in interpreter: VBAInterpreter) throws -> VBAValue {
        switch name.lowercased() {
        case "", "item":
            return items[try index(of: arguments.required(0, "Index"), in: interpreter)].value
        case "count":
            return .integer(items.count)
        case "add":
            let value = try arguments.required(0, "Item")
            let key = try arguments.value(1, "Key").map { try interpreter.letValue($0).asString() }
            if let key, items.contains(where: { $0.key?.caseInsensitiveCompare(key) == .orderedSame }) {
                throw VBAError(number: 457, VBALibrary.standardErrorDescription(457))
            }
            var position = items.count
            if let before = arguments.value(2, "Before") { position = try index(of: before, in: interpreter) }
            if let after = arguments.value(3, "After") { position = try index(of: after, in: interpreter) + 1 }
            items.insert((key, VBAInterpreter.copyingRecords(value)), at: position)
            return .empty
        case "remove":
            items.remove(at: try index(of: arguments.required(0, "Index"), in: interpreter))
            return .empty
        default:
            throw VBAError.unsupportedMember(name)
        }
    }

    public func elements(in _: VBAInterpreter) throws -> [VBAValue] { items.map(\.value) }
}

// MARK: - Dictionary

/// `Scripting.Dictionary`, the other workhorse of real-world macros.
public final class VBADictionary: VBAObject {
    private var keys: [VBAValue] = []
    private var values: [VBAValue] = []
    private var index: [String: Int] = [:]
    private var textCompare = false
    public var typeName: String { "Dictionary" }

    /// Keys compare by type and value: the string "1" and the number 1 are
    /// different keys, as they are in Scripting.
    private func hashKey(_ key: VBAValue) throws -> String {
        switch key {
        case .string(let text): return "s:" + (textCompare ? text.lowercased() : text)
        case .integer, .double, .boolean, .date: return "n:" + VBAValue.format(try key.asDouble())
        case .empty: return "e:"
        case .object(let object): return "o:\(ObjectIdentifier(object).hashValue)"
        default: throw VBAError.typeMismatch
        }
    }

    private func set(_ key: VBAValue, _ value: VBAValue) throws {
        let hash = try hashKey(key)
        if let position = index[hash] {
            values[position] = value
        } else {
            index[hash] = keys.count
            keys.append(key)
            values.append(value)
        }
    }

    private func rebuildIndex() throws {
        index = [:]
        for (position, key) in keys.enumerated() { index[try hashKey(key)] = position }
    }

    private func key(_ value: VBAValue, _ interpreter: VBAInterpreter) throws -> VBAValue {
        if case .object = value { return value }
        return try interpreter.letValue(value)
    }

    public func member(_ name: String, _ arguments: VBAArguments, in interpreter: VBAInterpreter) throws -> VBAValue {
        switch name.lowercased() {
        case "", "item":
            let key = try key(arguments.required(0, "Key"), interpreter)
            if let position = index[try hashKey(key)] { return values[position] }
            // Reading a missing key adds it, empty — a Scripting quirk macros rely on.
            try set(key, .empty)
            return .empty
        case "add":
            let key = try key(arguments.required(0, "Key"), interpreter)
            guard index[try hashKey(key)] == nil else {
                throw VBAError(number: 457, VBALibrary.standardErrorDescription(457))
            }
            try set(key, VBAInterpreter.copyingRecords(try arguments.required(1, "Item")))
            return .empty
        case "exists":
            return .boolean(index[try hashKey(key(arguments.required(0, "Key"), interpreter))] != nil)
        case "count":
            return .integer(keys.count)
        case "keys":
            return .array(VBAArray(keys))
        case "items":
            return .array(VBAArray(values))
        case "remove":
            let hash = try hashKey(key(arguments.required(0, "Key"), interpreter))
            guard let position = index[hash] else { throw VBAError(number: 32811, "Element not found") }
            keys.remove(at: position)
            values.remove(at: position)
            try rebuildIndex()
            return .empty
        case "removeall":
            keys = []
            values = []
            index = [:]
            return .empty
        case "comparemode":
            return .integer(textCompare ? 1 : 0)
        default:
            throw VBAError.unsupportedMember(name)
        }
    }

    public func setMember(_ name: String, _ arguments: VBAArguments, to value: VBAValue,
                   in interpreter: VBAInterpreter) throws {
        switch name.lowercased() {
        case "", "item":
            try set(key(arguments.required(0, "Key"), interpreter), VBAInterpreter.copyingRecords(value))
        case "key":
            let old = try key(arguments.required(0, "Key"), interpreter)
            guard let position = index[try hashKey(old)] else { throw VBAError(number: 32811, "Element not found") }
            keys[position] = try key(value, interpreter)
            try rebuildIndex()
        case "comparemode":
            guard keys.isEmpty else { throw VBAError.invalidCall }
            textCompare = try interpreter.letValue(value).asInteger() == 1
        default:
            throw VBAError.unsupportedMember(name)
        }
    }

    public func elements(in _: VBAInterpreter) throws -> [VBAValue] { keys }
}

// MARK: - RegExp

/// `VBScript.RegExp`, mapped onto `NSRegularExpression`, whose syntax is a
/// superset of what VBScript patterns use.
public final class VBARegExp: VBAObject {
    public var pattern = ""
    public var isGlobal = false
    public var ignoreCase = false
    public var multiLine = false
    public var typeName: String { "IRegExp2" }

    private func expression() throws -> NSRegularExpression {
        var options: NSRegularExpression.Options = []
        if ignoreCase { options.insert(.caseInsensitive) }
        if multiLine { options.insert(.anchorsMatchLines) }
        do {
            return try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            throw VBAError(number: 5017, "Syntax error in regular expression")
        }
    }

    public func member(_ name: String, _ arguments: VBAArguments, in interpreter: VBAInterpreter) throws -> VBAValue {
        switch name.lowercased() {
        case "pattern": return .string(pattern)
        case "global": return .boolean(isGlobal)
        case "ignorecase": return .boolean(ignoreCase)
        case "multiline": return .boolean(multiLine)
        case "test":
            let text = try interpreter.letValue(arguments.required(0)).asString()
            let range = NSRange(text.startIndex..., in: text)
            return .boolean(try expression().firstMatch(in: text, range: range) != nil)
        case "replace":
            let text = try interpreter.letValue(arguments.required(0)).asString()
            let template = try interpreter.letValue(arguments.required(1)).asString()
            let regex = try expression()
            let range = NSRange(text.startIndex..., in: text)
            // VBScript's `$1` is NSRegularExpression's too.
            if isGlobal {
                return .string(regex.stringByReplacingMatches(in: text, range: range, withTemplate: template))
            }
            guard let match = regex.firstMatch(in: text, range: range) else { return .string(text) }
            let replacement = regex.replacementString(for: match, in: text, offset: 0, template: template)
            return .string((text as NSString).replacingCharacters(in: match.range, with: replacement))
        case "execute":
            let text = try interpreter.letValue(arguments.required(0)).asString()
            let range = NSRange(text.startIndex..., in: text)
            let regex = try expression()
            let found = isGlobal ? regex.matches(in: text, range: range) : regex.firstMatch(in: text, range: range).map { [$0] } ?? []
            let nsText = text as NSString
            let matches = found.map { match -> VBAValue in
                let groups = (1..<max(1, match.numberOfRanges)).map { group -> VBAValue in
                    let groupRange = match.range(at: group)
                    return groupRange.location == NSNotFound ? .empty : .string(nsText.substring(with: groupRange))
                }
                return .object(VBARegExpMatch(value: nsText.substring(with: match.range),
                                              firstIndex: match.range.location, subMatches: groups))
            }
            return .object(VBAListObject(typeName: "IMatchCollection2", items: matches))
        default:
            throw VBAError.unsupportedMember(name)
        }
    }

    public func setMember(_ name: String, _: VBAArguments, to value: VBAValue,
                   in interpreter: VBAInterpreter) throws {
        let value = try interpreter.letValue(value)
        switch name.lowercased() {
        case "pattern": pattern = try value.asString()
        case "global": isGlobal = try value.asBoolean()
        case "ignorecase": ignoreCase = try value.asBoolean()
        case "multiline": multiLine = try value.asBoolean()
        default: throw VBAError.unsupportedMember(name)
        }
    }
}

public final class VBARegExpMatch: VBAObject {
    public let value: String
    public let firstIndex: Int
    public let subMatches: [VBAValue]
    public var typeName: String { "IMatch2" }

    public init(value: String, firstIndex: Int, subMatches: [VBAValue]) {
        self.value = value
        self.firstIndex = firstIndex
        self.subMatches = subMatches
    }

    public func member(_ name: String, _ arguments: VBAArguments, in interpreter: VBAInterpreter) throws -> VBAValue {
        switch name.lowercased() {
        case "", "value": return .string(value)
        case "firstindex": return .integer(firstIndex)
        case "length": return .integer(value.utf16.count)
        case "submatches":
            let list = VBAListObject(typeName: "ISubMatches", items: subMatches, isZeroBased: true)
            if let index = arguments.value(0) { return try list.member("", VBAArguments([index]), in: interpreter) }
            return .object(list)
        default: throw VBAError.unsupportedMember(name)
        }
    }
}

/// A read-only list with `Count` and `Item`, for collections the library
/// hands out: regex matches and their groups.
public final class VBAListObject: VBAObject {
    public let typeName: String
    public let items: [VBAValue]
    public let isZeroBased: Bool

    public init(typeName: String, items: [VBAValue], isZeroBased: Bool = true) {
        self.typeName = typeName
        self.items = items
        self.isZeroBased = isZeroBased
    }

    public func member(_ name: String, _ arguments: VBAArguments, in interpreter: VBAInterpreter) throws -> VBAValue {
        switch name.lowercased() {
        case "", "item":
            let position = try interpreter.letValue(arguments.required(0)).asInteger() - (isZeroBased ? 0 : 1)
            guard items.indices.contains(position) else { throw VBAError.subscriptOutOfRange }
            return items[position]
        case "count":
            return .integer(items.count)
        default:
            throw VBAError.unsupportedMember(name)
        }
    }

    public func elements(in _: VBAInterpreter) throws -> [VBAValue] { items }
}
