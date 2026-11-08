import Foundation

/// A workbook's colour scheme, as `xl/theme/theme1.xml` defines it.
///
/// Slots are stored in the order the `theme` attribute of a `<color>` uses,
/// which is *not* the order the theme file lists them in: the file runs
/// dk1, lt1, dk2, lt2, … but styles index 0 as lt1 and 1 as dk1 (and likewise
/// swap lt2/dk2), so that 0 and 2 are backgrounds and 1 and 3 are text.
/// Reading the slots by name rather than by position keeps that straight.
public struct ThemeColorScheme: Equatable, Sendable {
    /// Scheme element names in the order `theme="N"` indexes them.
    private static let slotNames = [
        "lt1", "dk1", "lt2", "dk2",
        "accent1", "accent2", "accent3", "accent4", "accent5", "accent6",
        "hlink", "folHlink",
    ]

    /// Six-digit RGB per slot, in `slotNames` order.
    private var slots: [String]

    private init(slots: [String]) {
        self.slots = slots
    }

    /// The scheme Excel applies to workbooks that carry no theme part, and the
    /// fallback when the one they carry cannot be read.
    public static let office = ThemeColorScheme(slots: [
        "FFFFFF", "000000", "E7E6E6", "44546A",
        "4472C4", "ED7D31", "A5A5A5", "FFC000", "5B9BD5", "70AD47",
        "0563C1", "954F72",
    ])

    /// Builds a scheme from a parsed `theme1.xml`. Slots the file omits keep
    /// the standard Office colour so a partial theme still resolves.
    public init(themeXML root: XMLElement) {
        let scheme = root.firstDescendant(atPath: "themeElements/clrScheme")
        slots = Self.slotNames.enumerated().map { index, name in
            guard let slot = scheme?.firstChild(named: name),
                  let color = Self.color(inSlot: slot) else { return Self.office.slots[index] }
            return color
        }
    }

    /// A slot holds either a literal colour or a system colour, and the latter
    /// carries the concrete value Office last resolved it to.
    private static func color(inSlot slot: XMLElement) -> String? {
        if let literal = slot.firstChild(named: "srgbClr")?.attribute("val") {
            return ThemeColorPalette.normalizedRGB(literal)
        }
        if let system = slot.firstChild(named: "sysClr")?.attribute("lastClr") {
            return ThemeColorPalette.normalizedRGB(system)
        }
        return nil
    }

    /// accent1 through accent6, the colours charts cycle through.
    public var accentColors: [String] { Array(slots[4...9]) }

    /// The six-digit RGB a DrawingML `schemeClr` names. The text and background
    /// aliases map onto the dark and light slots the way Office's default
    /// colour map does.
    public func color(schemeName name: String) -> String? {
        let slot: String
        switch name {
        case "tx1": slot = "dk1"
        case "bg1": slot = "lt1"
        case "tx2": slot = "dk2"
        case "bg2": slot = "lt2"
        default: slot = name
        }
        guard let index = Self.slotNames.firstIndex(of: slot) else { return nil }
        return slots[index]
    }

    /// The six-digit RGB for a `theme="N"` index, or `nil` when out of range.
    public func color(atThemeIndex index: Int) -> String? {
        slots.indices.contains(index) ? slots[index] : nil
    }
}

/// Resolves the indirect colour references OOXML styles use — theme slots and
/// the legacy indexed palette — into concrete ARGB values.
public enum ThemeColorPalette {
    /// The legacy palette `<color indexed="N"/>` selects from.
    ///
    /// Indices 0–7 are a fixed header duplicated at 8–15; 8–63 are the
    /// 56 slots a workbook may override with its own `<indexedColors>`, which
    /// we do not read yet. 64 and 65 are the system foreground and background
    /// and deliberately have no entry here.
    public static let indexedColors = [
        "000000", "FFFFFF", "FF0000", "00FF00", "0000FF", "FFFF00", "FF00FF", "00FFFF",
        "000000", "FFFFFF", "FF0000", "00FF00", "0000FF", "FFFF00", "FF00FF", "00FFFF",
        "800000", "008000", "000080", "808000", "800080", "008080", "C0C0C0", "808080",
        "9999FF", "993366", "FFFFCC", "CCFFFF", "660066", "FF8080", "0066CC", "CCCCFF",
        "000080", "FF00FF", "FFFF00", "00FFFF", "800080", "800000", "008080", "0000FF",
        "00CCFF", "CCFFFF", "CCFFCC", "FFFF99", "99CCFF", "FF99CC", "CC99FF", "FFCC99",
        "3366FF", "33CCCC", "99CC00", "FFCC00", "FF9900", "FF6600", "666699", "969696",
        "003366", "339966", "003300", "333300", "993300", "993366", "333399", "333333",
    ]

    /// Resolves a `<color>` element to an eight-digit ARGB string.
    ///
    /// Returns `nil` whenever the file asks for the application's own default —
    /// an automatic colour, a system foreground or background, or a reference
    /// we cannot follow — so that callers leave the style unset rather than
    /// baking in a black or white that would look wrong in the other
    /// appearance.
    public static func resolvedARGB(from element: XMLElement?, theme: ThemeColorScheme) -> String? {
        guard let element else { return nil }
        if element.attribute("auto") == "1" { return nil }

        if let direct = element.attribute("rgb") {
            return normalizedARGB(direct)
        }
        if let index = element.attribute("indexed").flatMap(Int.init) {
            guard indexedColors.indices.contains(index) else { return nil }
            return "FF" + indexedColors[index]
        }
        if let index = element.attribute("theme").flatMap(Int.init) {
            guard let base = theme.color(atThemeIndex: index) else { return nil }
            let tint = element.attribute("tint").flatMap(Double.init) ?? 0
            return "FF" + tinted(base, by: tint)
        }
        return nil
    }

    // MARK: - Tint

    /// Applies a `tint` in [-1, 1] to a six-digit RGB, lightening for positive
    /// values and darkening for negative ones.
    ///
    /// OOXML defines this on the HLS luminance only, so the hue and saturation
    /// survive: a tinted accent stays recognisably the same colour.
    public static func tinted(_ rgb: String, by tint: Double) -> String {
        guard tint != 0, let components = HSLComponents(rgb: rgb) else { return rgb }
        let amount = min(max(tint, -1), 1)

        var adjusted = components
        if amount > 0 {
            adjusted.luminance = components.luminance * (1 - amount) + amount
        } else {
            adjusted.luminance = components.luminance * (1 + amount)
        }
        adjusted.luminance = min(max(adjusted.luminance, 0), 1)
        return adjusted.rgbString
    }

    /// DrawingML's `lumMod` and `lumOff`: the HLS luminance scaled, then
    /// shifted. Office's "Lighter 40%" theme variants are made this way.
    public static func modulated(_ rgb: String, luminance modulation: Double, offset: Double) -> String {
        guard var components = HSLComponents(rgb: rgb) else { return rgb }
        components.luminance = min(max(components.luminance * modulation + offset, 0), 1)
        return components.rgbString
    }

    // MARK: - Hex plumbing

    /// Trims a `#` prefix and drops any alpha, yielding six upper-case digits.
    public static func normalizedRGB(_ value: String) -> String? {
        var text = value.trimmed.uppercased()
        if text.hasPrefix("#") { text.removeFirst() }
        if text.count == 8 { text.removeFirst(2) }
        guard text.count == 6, text.allSatisfy(\.isHexDigit) else { return nil }
        return text
    }

    /// Widens a six-digit colour to eight digits; leaves valid ARGB untouched.
    private static func normalizedARGB(_ value: String) -> String? {
        var text = value.trimmed.uppercased()
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6 || text.count == 8, text.allSatisfy(\.isHexDigit) else { return nil }
        return text.count == 6 ? "FF" + text : text
    }
}

/// Hue, saturation and luminance, the space OOXML expresses tint in.
private struct HSLComponents {
    var hue: Double
    var saturation: Double
    var luminance: Double

    init?(rgb: String) {
        guard let normalized = ThemeColorPalette.normalizedRGB(rgb),
              let raw = UInt32(normalized, radix: 16) else { return nil }
        let red = Double((raw >> 16) & 0xFF) / 255
        let green = Double((raw >> 8) & 0xFF) / 255
        let blue = Double(raw & 0xFF) / 255

        let highest = max(red, green, blue)
        let lowest = min(red, green, blue)
        let span = highest - lowest
        luminance = (highest + lowest) / 2

        guard span > 0 else {
            hue = 0
            saturation = 0
            return
        }
        saturation = luminance > 0.5 ? span / (2 - highest - lowest) : span / (highest + lowest)

        let sector: Double
        switch highest {
        case red: sector = (green - blue) / span + (green < blue ? 6 : 0)
        case green: sector = (blue - red) / span + 2
        default: sector = (red - green) / span + 4
        }
        hue = sector / 6
    }

    var rgbString: String {
        guard saturation > 0 else {
            let level = channelByte(luminance)
            return String(format: "%02X%02X%02X", level, level, level)
        }
        let q = luminance < 0.5
            ? luminance * (1 + saturation)
            : luminance + saturation - luminance * saturation
        let p = 2 * luminance - q

        func channel(_ offset: Double) -> Double {
            var position = hue + offset
            if position < 0 { position += 1 }
            if position > 1 { position -= 1 }
            if position < 1.0 / 6 { return p + (q - p) * 6 * position }
            if position < 1.0 / 2 { return q }
            if position < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - position) * 6 }
            return p
        }
        return String(
            format: "%02X%02X%02X",
            channelByte(channel(1.0 / 3)), channelByte(channel(0)), channelByte(channel(-1.0 / 3))
        )
    }

    private func channelByte(_ value: Double) -> Int {
        Int((min(max(value, 0), 1) * 255).rounded())
    }
}
