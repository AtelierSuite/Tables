import Foundation

#if canImport(Darwin)
extension Bundle {
    /// The bundle holding TablesMacros' localised strings.
    static let macros: Bundle = #bundle
}
#endif
