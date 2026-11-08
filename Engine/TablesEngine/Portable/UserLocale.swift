import Foundation

extension Locale {
    /// The user's own locale: Foundation's on Apple platforms, and the one the
    /// host reported where Foundation can't tell (WebAssembly).
    static var user: Locale {
        #if canImport(Darwin)
        .current
        #else
        Locale(identifier: PortableStrings.localeIdentifier)
        #endif
    }
}
