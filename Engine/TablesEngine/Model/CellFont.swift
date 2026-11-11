#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

#if canImport(UIKit) || canImport(AppKit)
extension CellStyle {
    #if canImport(UIKit)
    public typealias PlatformFont = UIFont
    #else
    public typealias PlatformFont = NSFont
    #endif

    /// The font a cell's text is drawn in at `zoom`, shared by the grid, the
    /// cell editor and text measurement so they all agree.
    ///
    /// The cell's family is looked up as a family, ignoring case, so a name a
    /// file records such as "Times New Roman" or "Hiragino Mincho ProN" finds
    /// its regular face. A font's own name ("Courier-Bold") is accepted too.
    /// A family that isn't installed falls back to the system font. The size
    /// is fixed: like the system font, it doesn't follow Dynamic Type.
    public func platformFont(zoom: Double = 1) -> PlatformFont {
        let size = fontSize * zoom
        if let family = displayFontName, let font = Self.installedFont(named: family, size: size, style: self) {
            return font
        }
        return Self.systemFont(size: size, style: self)
    }

    /// Installed families keyed by their lowercased name, read once.
    private static let installedFamilies: [String: String] = {
        #if canImport(UIKit)
        let families = UIFont.familyNames
        #else
        let families = NSFontManager.shared.availableFontFamilies
        #endif
        return Dictionary(families.map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
    }()

    private static func installedFont(named name: String, size: Double, style: CellStyle) -> PlatformFont? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        #if canImport(UIKit)
        let base: UIFont
        if let family = installedFamilies[trimmed.lowercased()] {
            base = UIFont(descriptor: UIFontDescriptor(fontAttributes: [.family: family]), size: size)
        } else if let named = UIFont(name: trimmed, size: size) {
            base = named
        } else {
            return nil
        }
        var traits = base.fontDescriptor.symbolicTraits
        if style.isBold { traits.insert(.traitBold) }
        if style.isItalic { traits.insert(.traitItalic) }
        // A family without the asked-for face still beats the system font.
        return base.fontDescriptor.withSymbolicTraits(traits).map { UIFont(descriptor: $0, size: size) } ?? base
        #else
        var traits: NSFontTraitMask = []
        if style.isBold { traits.insert(.boldFontMask) }
        if style.isItalic { traits.insert(.italicFontMask) }
        let manager = NSFontManager.shared
        if let family = installedFamilies[trimmed.lowercased()] {
            if let font = manager.font(withFamily: family, traits: traits, weight: 5, size: size) {
                return font
            }
            // A family without the asked-for face still beats the system font.
            if let font = manager.font(withFamily: family, traits: [], weight: 5, size: size) {
                return manager.convert(font, toHaveTrait: traits)
            }
        }
        guard let named = NSFont(name: trimmed, size: size) else { return nil }
        return traits.isEmpty ? named : manager.convert(named, toHaveTrait: traits)
        #endif
    }

    private static func systemFont(size: Double, style: CellStyle) -> PlatformFont {
        #if canImport(UIKit)
        var traits: UIFontDescriptor.SymbolicTraits = []
        if style.isBold { traits.insert(.traitBold) }
        if style.isItalic { traits.insert(.traitItalic) }
        let base = UIFont.systemFont(ofSize: size)
        guard !traits.isEmpty else { return base }
        return base.fontDescriptor.withSymbolicTraits(traits).map { UIFont(descriptor: $0, size: size) } ?? base
        #else
        var traits: NSFontDescriptor.SymbolicTraits = []
        if style.isBold { traits.insert(.bold) }
        if style.isItalic { traits.insert(.italic) }
        let base = NSFont.systemFont(ofSize: size)
        guard !traits.isEmpty else { return base }
        return NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(traits), size: size) ?? base
        #endif
    }
}
#endif
