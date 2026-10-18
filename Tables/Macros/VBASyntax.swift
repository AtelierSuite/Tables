import Foundation
import TablesEngine

// The parsed form of a VBA module.

enum VBALiteral: Hashable, Sendable {
    case integer(Int)
    case double(Double)
    case string(String)
    case date(Double)
    case boolean(Bool)
    case nothing
    case empty
    case null
}

indirect enum VBAExpression: Hashable, Sendable {
    case literal(VBALiteral)
    case identifier(String)
    /// `base.name`; a missing base is the object of the enclosing `With`.
    case member(VBAExpression?, String)
    /// Arguments applied to something: a procedure call, an array index,
    /// or an object's default member, which only running it can tell apart.
    case call(VBAExpression, [VBAArgument])
    case unary(String, VBAExpression)
    case binary(String, VBAExpression, VBAExpression)
    /// A parenthesised expression. VBA passes one of these by value even to
    /// a `ByRef` parameter, so the parentheses are kept.
    case parenthesized(VBAExpression)
    case new(String)
    case me
    case typeOfIs(VBAExpression, String)
    /// `AddressOf Name`, which only means something to Windows API calls.
    /// Parsed so the module still loads; evaluating it fails.
    case addressOf(String)
}

struct VBAArgument: Hashable, Sendable {
    /// The name of a `name:=value` argument.
    var name: String?
    /// Nothing for an omitted argument, as in `Foo 1, , 3`.
    var value: VBAExpression?
}

/// A type as declared: `Long`, `String`, `Range`, `Excel.Worksheet`.
struct VBATypeName: Hashable, Sendable {
    var name: String
    /// `As New Collection`: created on first use.
    var isNew = false

    static let variant = VBATypeName(name: "Variant")
}

struct VBAVariableDeclaration: Hashable, Sendable {
    var name: String
    var type: VBATypeName?
    /// `Dim a()` declares an array with no bounds yet; `Dim a(1 To 3)` one
    /// with them. Nil for a scalar.
    var bounds: [VBABound]?
    var isArray: Bool { bounds != nil }
    /// `Dim WithEvents x As Class`: its object's events reach this module's
    /// `x_EventName` procedures.
    var isWithEvents = false
}

struct VBABound: Hashable, Sendable {
    var lower: VBAExpression?
    var upper: VBAExpression
}

enum VBACaseCondition: Hashable, Sendable {
    case value(VBAExpression)
    case range(VBAExpression, VBAExpression)
    /// `Case Is > 5`.
    case comparison(String, VBAExpression)
}

struct VBACaseClause: Sendable {
    var conditions: [VBACaseCondition]
    var body: [VBAStatement]
}

enum VBAExitKind: String, CaseIterable, Hashable, Sendable {
    case sub = "Sub", function = "Function", property = "Property", forLoop = "For", doLoop = "Do"
}

enum VBAErrorHandling: Hashable, Sendable {
    case resumeNext
    case goTo(String)
    /// `On Error GoTo 0`: errors stop the macro again.
    case disabled
}

enum VBAResumeTarget: Hashable, Sendable {
    case same
    case next
    case label(String)
}

struct VBAStatement: Sendable {
    indirect enum Kind: Sendable {
        case declare([VBAVariableDeclaration], isStatic: Bool)
        case constant(String, VBAExpression)
        case redim(preserve: Bool, [(VBAExpression, [VBABound])])
        case assign(target: VBAExpression, value: VBAExpression, isSet: Bool)
        case call(VBAExpression)
        case ifBlock(branches: [(VBAExpression, [VBAStatement])], otherwise: [VBAStatement]?)
        case select(VBAExpression, [VBACaseClause], otherwise: [VBAStatement]?)
        case forNext(variable: VBAExpression, start: VBAExpression, end: VBAExpression, step: VBAExpression?,
                     body: [VBAStatement])
        case forEach(variable: VBAExpression, collection: VBAExpression, body: [VBAStatement])
        /// `Do While`/`Do Until` at either end, or neither for a bare `Do … Loop`.
        case doLoop(condition: VBAExpression?, isUntil: Bool, testsFirst: Bool, body: [VBAStatement])
        case with(VBAExpression, [VBAStatement])
        case exit(VBAExitKind)
        case goTo(String)
        case goSub(String)
        case returnFromGoSub
        case label(String)
        case onError(VBAErrorHandling)
        case resume(VBAResumeTarget)
        case erase([VBAExpression])
        /// `Debug.Print a; b, c` keeps its separators, which decide spacing.
        case debugPrint([VBAPrintItem])
        case file(VBAFileStatement)
        /// `LSet` and `RSet`: a string placed left or right within the length
        /// the variable already has.
        case alignedAssign(target: VBAExpression, value: VBAExpression, isRight: Bool)
        case raiseEvent(String, [VBAArgument])
        /// The `End` statement, which stops everything at once.
        case end
        case stop
        /// A statement the interpreter knows it cannot run, such as file I/O.
        /// Kept so the rest of the module still parses; running it fails.
        case unsupported(String)
    }

    var kind: Kind
    var line: Int
}

struct VBAParameter: Hashable, Sendable {
    var name: String
    var type: VBATypeName?
    var isByVal: Bool
    var isOptional: Bool
    var isParamArray: Bool
    var isArray: Bool
    var defaultValue: VBAExpression?
}

struct VBAProcedure: Sendable {
    enum Kind: Hashable, Sendable {
        case sub, function, propertyGet, propertyLet, propertySet
    }

    var name: String
    var kind: Kind
    var isPrivate: Bool
    var isStatic: Bool
    var parameters: [VBAParameter]
    var returnType: VBATypeName?
    var body: [VBAStatement]
    var line: Int

    /// Whether the macro list should offer it: a public `Sub` with no
    /// parameters, which is what Excel's Macros dialog lists.
    var isRunnableMacro: Bool { kind == .sub && !isPrivate && parameters.isEmpty }
}

struct VBAUserType: Hashable, Sendable {
    var name: String
    var fields: [VBAVariableDeclaration]
}

/// A module as parsed, before anything runs.
struct VBAModuleSyntax: Sendable {
    var name: String
    var optionExplicit = false
    var optionBase = 0
    var optionCompareText = false
    var variables: [(declaration: VBAVariableDeclaration, isPrivate: Bool)] = []
    var constants: [(name: String, value: VBAExpression, isPrivate: Bool)] = []
    var procedures: [VBAProcedure] = []
    var types: [VBAUserType] = []
    var enums: [(name: String, members: [(String, VBAExpression?)])] = []
    /// Names declared with `Declare`: calls into Windows libraries, which
    /// cannot run here. Remembered so calling one says so plainly.
    var externalProcedures: Set<String> = []
    /// Events a class module declares with `Event`.
    var events: Set<String> = []
}

/// One part of a `Print` or `Debug.Print` list.
enum VBAPrintItem: Sendable {
    case value(VBAExpression)
    /// `Spc(n)`: that many spaces.
    case spaces(VBAExpression)
    /// `Tab(n)` moves to a column; a bare `Tab` to the next print zone.
    case tab(VBAExpression?)
    /// `;` keeps on the same line; `,` moves to the next 14-column zone.
    case separator(String)
}

enum VBAFileMode: String, Sendable {
    case input, output, append, binary, random
}

/// VBA's file statements, which take a `#` file number.
enum VBAFileStatement: Sendable {
    case open(path: VBAExpression, mode: VBAFileMode, number: VBAExpression, recordLength: VBAExpression?)
    /// No numbers closes every file.
    case close([VBAExpression])
    case print(number: VBAExpression, items: [VBAPrintItem])
    case write(number: VBAExpression, items: [VBAExpression?])
    case input(number: VBAExpression, targets: [VBAExpression])
    case lineInput(number: VBAExpression, target: VBAExpression)
    case get(number: VBAExpression, record: VBAExpression?, target: VBAExpression)
    case put(number: VBAExpression, record: VBAExpression?, value: VBAExpression)
    case seek(number: VBAExpression, position: VBAExpression)
    /// `Lock` and `Unlock`, which matter only between processes sharing a file.
    case lock(number: VBAExpression)
    case width(number: VBAExpression, width: VBAExpression)
    case rename(from: VBAExpression, to: VBAExpression)
}
