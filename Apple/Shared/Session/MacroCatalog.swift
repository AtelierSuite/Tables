import Foundation
import TablesMacros

/// The macros a project offers, found by parsing each module on its own so
/// that one the interpreter cannot read does not hide the rest.
struct MacroCatalog {
    struct Macro: Identifiable, Hashable {
        var module: String
        var procedure: String
        var id: String { module + "." + procedure }
    }

    private(set) var macros: [Macro] = []
    /// Modules that failed to parse, with why.
    private(set) var problems: [String: String] = [:]

    init() {}

    init(project: VBAProject) {
        for module in project.modules {
            do {
                let syntax = try VBAParser.parse(module: module.name, source: module.source)
                guard module.kind == .standard || module.kind == .document else { continue }
                macros += syntax.procedures.filter(\.isRunnableMacro).map { Macro(module: module.name, procedure: $0.name) }
            } catch {
                problems[module.name] = error.localizedDescription
            }
        }
    }
}

extension Result {
    /// What went wrong, or nil when nothing did.
    var failureDescription: String? {
        guard case .failure(let error) = self else { return nil }
        return error.localizedDescription
    }
}

extension VBAProject.Module.Kind {
    var label: String {
        switch self {
        case .standard: return String(localized: "Macros.ModuleKind.Standard")
        case .classModule: return String(localized: "Macros.ModuleKind.Class")
        case .document: return String(localized: "Macros.ModuleKind.Document")
        case .designer: return String(localized: "Macros.ModuleKind.Designer")
        }
    }
}
