import Foundation

/// The password a sheet or workbook is protected with, as the file keeps it:
/// never the password itself, only what it hashes to. Excel has written two
/// forms over the years, and a file can hold either.
public struct ProtectionPassword: Hashable, Sendable {
    /// The 16-bit hash of Excel 2010 and earlier, as its hexadecimal digits.
    public var legacyHash: String?
    /// The hash Excel 2013 and later write: its algorithm, the salted and
    /// repeated hash and the salt in Base64, and how many times it was spun.
    public var algorithmName: String?
    public var hashValue: String?
    public var saltValue: String?
    public var spinCount: Int?

    public init() {
        // No password.
    }

    /// Hashes `password` afresh, as Excel does today: SHA-512 over a random
    /// salt, spun a hundred thousand times.
    public init(password: String) {
        var generator = SystemRandomNumberGenerator()
        let salt = (0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        self.init(password: password, salt: salt, spinCount: 100_000)
    }

    init(password: String, salt: [UInt8], spinCount: Int) {
        algorithmName = "SHA-512"
        saltValue = Data(salt).base64EncodedString()
        self.spinCount = spinCount
        hashValue = Data(Self.spunHash(of: password, salt: salt, spinCount: spinCount, with: SHA512Digest.hash))
            .base64EncodedString()
    }

    /// Whether there is a password to ask for at all.
    public var isSet: Bool {
        if hashValue?.isEmpty == false { return true }
        guard let legacyHash, let value = UInt16(legacyHash, radix: 16) else { return false }
        return value != 0
    }

    /// Whether `password` is the one this was made from. Nothing matches a
    /// hash made with an algorithm Tables doesn't have.
    public func matches(_ password: String) -> Bool {
        guard isSet else { return true }
        if let hashValue, !hashValue.isEmpty {
            guard let expected = Data(base64Encoded: hashValue),
                  let digest = Self.digest(named: algorithmName ?? "") else { return false }
            let salt = saltValue.flatMap { Data(base64Encoded: $0) } ?? Data()
            let spun = Self.spunHash(of: password, salt: [UInt8](salt), spinCount: max(0, spinCount ?? 0), with: digest)
            return spun == [UInt8](expected)
        }
        guard let legacyHash, let expected = UInt16(legacyHash, radix: 16) else { return false }
        return Self.legacyHash(of: password) == expected
    }

    private static func digest(named name: String) -> (([UInt8]) -> [UInt8])? {
        switch name.uppercased().replacingOccurrences(of: "-", with: "") {
        case "SHA512": return SHA512Digest.hash
        case "SHA384": return SHA512Digest.hash384
        case "SHA256": return { SHA256Digest.hash(Data($0)) }
        default: return nil
        }
    }

    /// ECMA-376 Part 1 §18.3.1.85: the salt and then the password in UTF-16
    /// are hashed, and that hash is hashed again `spinCount` times, each time
    /// followed by the number of the round as four little-endian bytes.
    static func spunHash(
        of password: String, salt: [UInt8], spinCount: Int, with digest: ([UInt8]) -> [UInt8]
    ) -> [UInt8] {
        var input = salt
        for unit in password.utf16 {
            input.append(UInt8(truncatingIfNeeded: unit))
            input.append(UInt8(truncatingIfNeeded: unit >> 8))
        }
        var hash = digest(input)
        var round = [UInt8](repeating: 0, count: hash.count + 4)
        for iteration in 0..<spinCount {
            let count = UInt32(truncatingIfNeeded: iteration)
            round.replaceSubrange(0..<hash.count, with: hash)
            for byte in 0..<4 { round[hash.count + byte] = UInt8(truncatingIfNeeded: count >> UInt32(byte * 8)) }
            hash = digest(round)
        }
        return hash
    }

    /// The hash of Excel 2010 and earlier: each character turned left within
    /// fifteen bits by its place in the password, all of them combined, then
    /// the length and a constant. Characters outside Latin-1 count as `?`,
    /// which is what the single-byte text Excel hashed made of them.
    public static func legacyHash(of password: String) -> UInt16 {
        var hash: UInt16 = 0
        var count: UInt16 = 0
        for (index, scalar) in password.unicodeScalars.enumerated() {
            let character = UInt32(scalar.value < 256 ? scalar.value : 0x3F)
            let turn = UInt32((index + 1) % 15)
            let turned = ((character << turn) | (character >> (15 - turn))) & 0x7FFF
            hash ^= UInt16(turned)
            count &+= 1
        }
        return hash ^ count ^ 0xCE4B
    }

    // MARK: - File attributes

    private static let names = ["password", "algorithmName", "hashValue", "saltValue", "spinCount"]

    private static func name(_ attribute: String, prefix: String) -> String {
        prefix.isEmpty ? attribute : prefix + attribute.prefix(1).uppercased() + attribute.dropFirst()
    }

    /// The names the password's attributes go by: bare on `<sheetProtection>`,
    /// and led by `workbook` on `<workbookProtection>`.
    static func attributeNames(prefix: String = "") -> [String] {
        names.map { name($0, prefix: prefix) }
    }

    /// Reads the password out of an element's attributes.
    init(attributes: [String: String], prefix: String = "") {
        legacyHash = attributes[Self.name("password", prefix: prefix)]
        algorithmName = attributes[Self.name("algorithmName", prefix: prefix)]
        hashValue = attributes[Self.name("hashValue", prefix: prefix)]
        saltValue = attributes[Self.name("saltValue", prefix: prefix)]
        spinCount = attributes[Self.name("spinCount", prefix: prefix)].flatMap(Int.init)
    }

    func attributes(prefix: String = "") -> [String: String] {
        var result: [String: String] = [:]
        result[Self.name("password", prefix: prefix)] = legacyHash
        result[Self.name("algorithmName", prefix: prefix)] = algorithmName
        result[Self.name("hashValue", prefix: prefix)] = hashValue
        result[Self.name("saltValue", prefix: prefix)] = saltValue
        result[Self.name("spinCount", prefix: prefix)] = spinCount.map(String.init)
        return result
    }
}

/// A sheet's protection, OOXML's `<sheetProtection>`: whether it is on, the
/// password that turns it off, and what may still be done while it is on.
public struct SheetProtection: Hashable, Sendable {
    /// Something a protected sheet can still allow. The raw values are the
    /// attributes of `<sheetProtection>`, where `1` means *not* allowed.
    public enum Action: String, Hashable, Sendable, CaseIterable {
        case selectLockedCells, selectUnlockedCells
        case formatCells, formatColumns, formatRows
        case insertColumns, insertRows, insertHyperlinks
        case deleteColumns, deleteRows
        case sort, autoFilter, pivotTables
        /// Changing charts, pictures, shapes and comments.
        case objects
        case scenarios

        /// Whether a file that doesn't mention the action allows it.
        var isAllowedByDefault: Bool {
            switch self {
            case .selectLockedCells, .selectUnlockedCells, .objects, .scenarios: return true
            default: return false
            }
        }
    }

    /// What Excel's Protect Sheet allows until told otherwise: selecting cells.
    public static let defaultAllowed: Set<Action> = [.selectLockedCells, .selectUnlockedCells]

    /// Whether the protection is on. A file can carry the settings of a
    /// protection that is switched off.
    public var isEnforced = true
    public var password = ProtectionPassword()
    public var allowed: Set<Action> = SheetProtection.defaultAllowed

    public init(password: String? = nil, allowed: Set<Action> = SheetProtection.defaultAllowed) {
        if let password, !password.isEmpty { self.password = ProtectionPassword(password: password) }
        self.allowed = allowed
    }

    public func allows(_ action: Action) -> Bool {
        !isEnforced || allowed.contains(action)
    }

    init(_ element: XMLElement) {
        isEnforced = Self.flag(element.attribute("sheet")) ?? false
        password = ProtectionPassword(attributes: element.attributes)
        allowed = Set(Action.allCases.filter { action in
            Self.flag(element.attribute(action.rawValue)).map { !$0 } ?? action.isAllowedByDefault
        })
    }

    static func flag(_ value: String?) -> Bool? {
        value.map { $0 == "1" || $0.lowercased() == "true" }
    }

    var xml: String {
        var xml = "<sheetProtection"
        let hash = password.attributes()
        for name in ProtectionPassword.attributeNames() {
            if let value = hash[name] { xml += " \(name)=\"\(XMLLite.escape(value))\"" }
        }
        if isEnforced { xml += " sheet=\"1\"" }
        for action in Action.allCases where allowed.contains(action) != action.isAllowedByDefault {
            xml += " \(action.rawValue)=\"\(allowed.contains(action) ? 0 : 1)\""
        }
        return xml + "/>"
    }
}

/// A workbook's protection: a reading of the `<workbookProtection>`
/// attributes the workbook's settings keep.
public struct WorkbookProtection: Hashable, Sendable {
    /// Sheets can't be added, deleted, renamed, hidden, shown or reordered.
    public var locksStructure = true
    public var password = ProtectionPassword()
    /// Everything else the element said — its lock on windows, which Excel
    /// itself has ignored since 2013, and change tracking's own lock — kept
    /// as the file had it.
    public var otherAttributes: [String: String] = [:]

    public init(password: String? = nil) {
        if let password, !password.isEmpty { self.password = ProtectionPassword(password: password) }
    }

    init(attributes: [String: String]) {
        locksStructure = SheetProtection.flag(attributes["lockStructure"]) ?? false
        password = ProtectionPassword(attributes: attributes, prefix: "workbook")
        let modelled = Set(ProtectionPassword.attributeNames(prefix: "workbook") + ["lockStructure"])
        otherAttributes = attributes.filter { !modelled.contains($0.key) }
    }

    /// Replaces the password, and with it the character set the old one's
    /// legacy hash was made in.
    mutating func setPassword(_ password: ProtectionPassword) {
        self.password = password
        otherAttributes["workbookPasswordCharacterSet"] = nil
    }

    var attributes: [String: String] {
        var result = otherAttributes.merging(password.attributes(prefix: "workbook")) { $1 }
        if locksStructure { result["lockStructure"] = "1" }
        return result
    }
}

extension Worksheet {
    /// Whether the sheet's protection is on.
    public var isProtected: Bool { protection?.isEnforced == true }

    /// Whether the cell at `address` can't be changed: the sheet is
    /// protected, the cell is locked, and no range anyone may edit holds it.
    public func isReadOnly(at address: CellAddress) -> Bool {
        guard isProtected, self[address].style.isLocked else { return false }
        return !editableRanges.contains { $0.contains(address) }
    }

    /// Whether the formula at `address` is kept out of sight: the sheet is
    /// protected and the cell is marked hidden.
    public func hidesFormula(at address: CellAddress) -> Bool {
        isProtected && self[address].style.isFormulaHidden
    }

    /// What the formula bar shows for the cell at `address`, and what editing
    /// it starts from: nothing where the formula is hidden.
    public func editableText(at address: CellAddress) -> String {
        hidesFormula(at: address) ? "" : self[address].editableText
    }

    /// The ranges Excel's "Allow Users to Edit Ranges" opens to everyone:
    /// those of the kept `<protectedRanges>` that ask for no password.
    var editableRanges: [CellRange] {
        guard let element = preservedElements.first(where: { $0.name == "protectedRanges" }),
              let root = try? XMLLite.parse(Data(element.xml.utf8)) else { return [] }
        return root.children(named: "protectedRange")
            .filter { !ProtectionPassword(attributes: $0.attributes).isSet && $0.attribute("securityDescriptor") == nil }
            .flatMap { ($0.attribute("sqref") ?? "").split(separator: " ") }
            .compactMap { reference -> CellRange? in
                let corners = reference.split(separator: ":").map { CellAddress(a1: String($0)) }
                guard let first = corners.first, let start = first else { return nil }
                guard corners.count > 1 else { return CellRange(start) }
                guard let end = corners[1] else { return nil }
                return CellRange(start: start, end: end).normalized
            }
    }

    /// Turns protection on. An empty password is no password.
    public mutating func protect(password: String? = nil, allowing allowed: Set<SheetProtection.Action> = SheetProtection.defaultAllowed) {
        protection = SheetProtection(password: password, allowed: allowed)
    }

    /// Turns protection off, if `password` is the one it was turned on with.
    @discardableResult
    public mutating func unprotect(password: String = "") -> Bool {
        guard let protection, protection.isEnforced else { return true }
        guard protection.password.matches(password) else { return false }
        self.protection = nil
        return true
    }
}

extension Workbook {
    /// The workbook's protection, when the file has any: kept in its
    /// settings as `<workbookProtection>`'s attributes, read from them here.
    public var protection: WorkbookProtection? {
        get { settings.protection.map(WorkbookProtection.init(attributes:)) }
        set { settings.protection = newValue?.attributes }
    }

    /// Whether sheets can't be added, deleted, renamed, hidden or reordered.
    public var isStructureLocked: Bool { protection?.locksStructure == true }

    public mutating func protect(password: String? = nil) {
        var protection = self.protection ?? WorkbookProtection()
        protection.locksStructure = true
        protection.setPassword(WorkbookProtection(password: password).password)
        self.protection = protection
    }

    /// Turns structure protection off, if `password` is the one it was turned on with.
    @discardableResult
    public mutating func unprotect(password: String = "") -> Bool {
        guard let protection, protection.locksStructure else { return true }
        guard protection.password.matches(password) else { return false }
        var remaining = protection
        remaining.locksStructure = false
        remaining.setPassword(ProtectionPassword())
        // Whatever else the element held stays, with what it needs.
        self.protection = remaining.otherAttributes.isEmpty ? nil : remaining
        return true
    }
}
