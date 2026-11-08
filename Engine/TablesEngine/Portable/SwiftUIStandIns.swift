#if !canImport(SwiftUI)
import Foundation

// The few SwiftUI types the engine model uses (colours, appearance and fonts),
// for platforms without SwiftUI such as WebAssembly. They keep the same names
// and initialisers so model code compiles unchanged; a web front end reads the
// colour components back out through `argbHex`.

public enum ColorScheme: Hashable, Sendable {
    case light
    case dark
}

public struct Color: Hashable, Sendable {
    public enum RGBColorSpace: Sendable {
        case sRGB
    }

    public var red: Double
    public var green: Double
    public var blue: Double
    public var opacity: Double

    public init(_ colorSpace: RGBColorSpace = .sRGB, red: Double, green: Double, blue: Double, opacity: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.opacity = opacity
    }

    public static let black = Color(red: 0, green: 0, blue: 0)
    public static let white = Color(red: 1, green: 1, blue: 1)
    public static let clear = Color(red: 0, green: 0, blue: 0, opacity: 0)
    /// SwiftUI's secondary label colour in light appearance.
    public static let secondary = Color(red: 0.235, green: 0.235, blue: 0.263, opacity: 0.6)
    public static let accentColor = Color(red: 0.18, green: 0.65, blue: 0.40)
}

public struct Font: Hashable, Sendable {
    /// The family, or nil for the system font.
    public var family: String?
    public var size: Double
    public var isBold = false
    public var isItalic = false

    public static func system(size: Double) -> Font {
        Font(size: size)
    }

    public static func custom(_ name: String, size: Double) -> Font {
        Font(family: name, size: size)
    }

    public func bold() -> Font {
        var font = self
        font.isBold = true
        return font
    }

    public func italic() -> Font {
        var font = self
        font.isItalic = true
        return font
    }
}
#endif
