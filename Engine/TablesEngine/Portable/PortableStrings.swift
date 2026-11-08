#if !canImport(Darwin)
import Foundation

/// Localised strings on platforms whose Foundation has no string catalogues,
/// such as WebAssembly. The host loads the strings for the user's language,
/// converted from the same .xcstrings catalogues the Apple apps use, and
/// `String(localized:bundle:)` reads them from here, falling back to the key.
public enum PortableStrings {
    nonisolated(unsafe) public static var table: [String: String] = [:]

    /// Installs the strings for the user's language.
    public static func load(_ strings: [String: String]) {
        table = Int.bitWidth == 64 ? strings : strings.mapValues(nativeIntegers)
    }

    /// Catalogues write integer placeholders as `%lld`, 64 bits wide. Where
    /// `Int` is 32 bits (wasm32), `String(format:)` would read past the
    /// argument, so those become `%ld`, which is the platform's word size.
    static func nativeIntegers(_ format: String) -> String {
        format.replacing(/%(\d+\$)?([-+ #0]*\d*(?:\.\d+)?)ll([dux])/) { match in
            "%\(match.1 ?? "")\(match.2)l\(match.3)"
        }
    }
}

extension String {
    /// Stands in for Foundation's type: here a localisation value is just its key.
    public struct LocalizationValue: ExpressibleByStringLiteral, Sendable {
        public let key: String

        public init(_ key: String) {
            self.key = key
        }

        public init(stringLiteral value: String) {
            key = value
        }
    }

    public init(localized value: LocalizationValue, bundle: PortableBundle? = nil) {
        self = PortableStrings.table[value.key] ?? value.key
    }
}

/// Where a string comes from, kept so call sites read the same on every
/// platform. Here every module's strings share one table, and Foundation's
/// `Bundle` is never touched: `Bundle.main` traps under WASI.
public struct PortableBundle: Sendable {
    public static let engine = PortableBundle()
    public static let macros = PortableBundle()
}
#endif
