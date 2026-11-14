import CryptoKit
import Foundation
import Testing
@testable import Tables
@testable import TablesEngine

/// Sheet and workbook protection: what the reader makes of it, what the
/// writer puts back, which passwords open it, and which edits it lets through.
@Suite("Sheet and workbook protection")
struct ProtectionTests {

    // MARK: - Helpers

    /// A one-sheet package. A1 is locked and holds text, B1 is unlocked, C1
    /// is locked with its formula hidden. `sheetTail` follows `<sheetData>`
    /// and `workbookHead` comes before `<sheets>`.
    private func package(sheetTail: String = "", workbookHead: String = "") throws -> Data {
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/></Types>
        """
        let rootRelationships = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" \
        Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" \
        Target="xl/workbook.xml"/></Relationships>
        """
        let workbook = """
        <?xml version="1.0" encoding="UTF-8"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
        \(workbookHead)<sheets><sheet name="S" sheetId="1" r:id="rId1"/></sheets></workbook>
        """
        let workbookRelationships = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" \
        Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" \
        Target="worksheets/sheet1.xml"/>\
        <Relationship Id="rId2" \
        Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" \
        Target="styles.xml"/></Relationships>
        """
        let styles = """
        <?xml version="1.0" encoding="UTF-8"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
        <fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts>\
        <fills count="2"><fill><patternFill patternType="none"/></fill>\
        <fill><patternFill patternType="gray125"/></fill></fills>\
        <borders count="1"><border/></borders>\
        <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
        <cellXfs count="3"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>\
        <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0" applyProtection="1">\
        <protection locked="0"/></xf>\
        <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0" applyProtection="1">\
        <protection hidden="1"/></xf></cellXfs></styleSheet>
        """
        let sheet = """
        <?xml version="1.0" encoding="UTF-8"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
        <sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>locked</t></is></c>\
        <c r="B1" s="1"><v>1</v></c><c r="C1" s="2"><f>B1*2</f><v>2</v></c></row></sheetData>\
        \(sheetTail)</worksheet>
        """
        return try ZipArchive.archive(entries: [
            ("[Content_Types].xml", Data(contentTypes.utf8)),
            ("_rels/.rels", Data(rootRelationships.utf8)),
            ("xl/workbook.xml", Data(workbook.utf8)),
            ("xl/_rels/workbook.xml.rels", Data(workbookRelationships.utf8)),
            ("xl/styles.xml", Data(styles.utf8)),
            ("xl/worksheets/sheet1.xml", Data(sheet.utf8)),
        ])
    }

    private func part(_ path: String, of workbook: Workbook) throws -> String {
        let entries = try ZipArchive.entries(in: XLSXWriter.data(from: workbook))
        return String(decoding: try #require(entries[path]), as: UTF8.self)
    }

    private let a1 = CellAddress(row: 0, column: 0)
    private let b1 = CellAddress(row: 0, column: 1)
    private let c1 = CellAddress(row: 0, column: 2)

    /// The package above, read, with its sheet protected.
    private func protected(allowing allowed: Set<SheetProtection.Action> = SheetProtection.defaultAllowed) throws -> Workbook {
        var workbook = try XLSXReader.workbook(from: package())
        workbook.sheets[0].protect(allowing: allowed)
        return workbook
    }

    // Salt 00…0F, hashed by Python's hashlib as ECMA-376 describes.
    private let salt = "AAECAwQFBgcICQoLDA0ODw=="
    private let sha512OfSecret =
        "M5SOVnbQG4SHyBnRVAYzAx8mPtxyyzMuWxcMv7tkyFO3MBXX9OJjklwPglNHdoHVkKPm4MPfUblqHmAsXfF5HA=="

    // MARK: - Hashing

    @Test("SHA-512 and SHA-384 agree with CryptoKit at every padding length")
    func digestsMatchCryptoKit() {
        for length in [0, 1, 3, 55, 111, 112, 113, 127, 128, 129, 240, 1000] {
            let bytes = (0..<length).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }
            #expect(SHA512Digest.hash(bytes) == Array(SHA512.hash(data: Data(bytes))), "SHA-512 of \(length) bytes")
            #expect(SHA512Digest.hash384(bytes) == Array(SHA384.hash(data: Data(bytes))), "SHA-384 of \(length) bytes")
        }
    }

    @Test("The legacy hash matches the values Excel writes")
    func legacyHash() {
        #expect(ProtectionPassword.legacyHash(of: "password") == 0x83AF)
        #expect(ProtectionPassword.legacyHash(of: "test") == 0xCBEB)
        var password = ProtectionPassword()
        password.legacyHash = "DAA7"
        #expect(password.isSet)
        #expect(password.matches("secret"))
        #expect(!password.matches("Secret"))
        #expect(!password.matches(""))
    }

    @Test("A salted, spun hash is checked with the algorithm the file names")
    func spunHashes() {
        var password = ProtectionPassword()
        password.algorithmName = "SHA-512"
        password.saltValue = salt
        password.spinCount = 100_000
        password.hashValue = sha512OfSecret
        #expect(password.matches("secret"))
        #expect(!password.matches("secrets"))

        password.algorithmName = "SHA-256"
        password.spinCount = 1000
        password.hashValue = "U42oNmelAMGCeSDftB5qFnyrQzGHdHL4x+Vn0ZWQekk="
        #expect(password.matches("pässword"))
        #expect(!password.matches("password"))

        password.algorithmName = "SHA-384"
        password.spinCount = 10
        password.hashValue = "084FZe7w+MtgZUjqwSb1n6xSWqJ/DFB8cahHC0xcyxKkNKgZe6L+yEMdzPU4dT/c"
        #expect(password.matches("secret"))

        // An algorithm Tables doesn't have opens for nothing.
        password.algorithmName = "WHIRLPOOL"
        #expect(!password.matches("secret"))
    }

    @Test("A new password is hashed as Excel hashes one today, and opens again")
    func newPassword() {
        let password = ProtectionPassword(password: "tables")
        #expect(password.algorithmName == "SHA-512")
        #expect(password.spinCount == 100_000)
        #expect(password.legacyHash == nil)
        #expect(Data(base64Encoded: password.saltValue ?? "")?.count == 16)
        #expect(password.matches("tables"))
        #expect(!password.matches("table"))
        #expect(!ProtectionPassword().isSet)
        #expect(ProtectionPassword().matches("anything"))
    }

    // MARK: - Reading and writing

    @Test("Sheet protection is read: whether it is on, its password and what it allows")
    func readsSheetProtection() throws {
        let tail = "<sheetProtection algorithmName=\"SHA-512\" hashValue=\"\(sha512OfSecret)\" saltValue=\"\(salt)\" "
            + "spinCount=\"100000\" sheet=\"1\" objects=\"1\" scenarios=\"1\" formatCells=\"0\" insertRows=\"0\"/>"
        let sheet = try XLSXReader.workbook(from: package(sheetTail: tail)).sheets[0]
        let protection = try #require(sheet.protection)
        #expect(sheet.isProtected)
        #expect(protection.allowed == [.selectLockedCells, .selectUnlockedCells, .formatCells, .insertRows])
        #expect(protection.password.matches("secret"))
        #expect(!protection.password.matches("wrong"))
        // Modelled now, so no longer kept as a fragment or named as unsupported.
        #expect(!sheet.preservedElements.contains { $0.name == "sheetProtection" })
        #expect(sheet.isReadOnly(at: a1))
        #expect(!sheet.isReadOnly(at: b1))
        #expect(sheet.hidesFormula(at: c1))
        #expect(sheet.editableText(at: c1).isEmpty)
        #expect(sheet.editableText(at: a1) == "locked")
    }

    @Test("Settings of a protection that is switched off protect nothing")
    func readsDisabledProtection() throws {
        let sheet = try XLSXReader.workbook(from: package(sheetTail: "<sheetProtection password=\"83AF\"/>")).sheets[0]
        #expect(sheet.protection != nil)
        #expect(!sheet.isProtected)
        #expect(!sheet.isReadOnly(at: a1))
        #expect(sheet.editableText(at: c1) == "=B1*2")
    }

    @Test("Sheet protection survives a save, attribute for attribute")
    func keepsSheetProtection() throws {
        let tail = "<sheetProtection password=\"83AF\" algorithmName=\"SHA-512\" hashValue=\"\(sha512OfSecret)\" "
            + "saltValue=\"\(salt)\" spinCount=\"100000\" sheet=\"1\" objects=\"1\" scenarios=\"1\" sort=\"0\" "
            + "selectLockedCells=\"1\"/>"
        let read = try XLSXReader.workbook(from: package(sheetTail: tail))
        let xml = try part("xl/worksheets/sheet1.xml", of: read)
        let written = try #require(xml.range(of: "<sheetProtection[^>]*/>", options: .regularExpression).map { String(xml[$0]) })
        for attribute in [
            "password=\"83AF\"", "algorithmName=\"SHA-512\"", "hashValue=\"\(sha512OfSecret)\"",
            "saltValue=\"\(salt)\"", "spinCount=\"100000\"", "sheet=\"1\"", "objects=\"1\"", "scenarios=\"1\"",
            "sort=\"0\"", "selectLockedCells=\"1\"",
        ] {
            #expect(written.contains(attribute), "\(attribute) missing from \(written)")
        }
        // In its schema slot: after the cells, before anything else kept.
        let data = try #require(xml.range(of: "</sheetData>")?.upperBound)
        #expect(xml[data...].hasPrefix("<sheetProtection"))

        let again = try XLSXReader.workbook(from: XLSXWriter.data(from: read))
        #expect(again.sheets[0].protection == read.sheets[0].protection)
    }

    @Test("Workbook protection is read and survives a save")
    func keepsWorkbookProtection() throws {
        let head = "<workbookProtection workbookAlgorithmName=\"SHA-512\" workbookHashValue=\"\(sha512OfSecret)\" "
            + "workbookSaltValue=\"\(salt)\" workbookSpinCount=\"100000\" lockStructure=\"1\" lockWindows=\"1\"/>"
        var workbook = try XLSXReader.workbook(from: package(workbookHead: head))
        #expect(workbook.isStructureLocked)
        #expect(workbook.protection?.password.matches("secret") == true)

        let xml = try part("xl/workbook.xml", of: workbook)
        #expect(xml.contains("lockStructure=\"1\""))
        #expect(xml.contains("lockWindows=\"1\""))
        #expect(xml.contains("workbookHashValue=\"\(sha512OfSecret)\""))
        #expect(xml.contains("workbookSpinCount=\"100000\""))

        let unprotected1 = workbook.unprotect(password: "wrong")
        #expect(!unprotected1)
        #expect(workbook.isStructureLocked)
        let unprotected2 = workbook.unprotect(password: "secret")
        #expect(unprotected2)
        #expect(!workbook.isStructureLocked)
        // The window lock was never the password's to lift.
        let after = try part("xl/workbook.xml", of: workbook)
        #expect(after.contains("lockWindows=\"1\""))
        #expect(!after.contains("lockStructure"))
        #expect(!after.contains("workbookHashValue"))
    }

    @Test("Protecting and unprotecting write what Excel reads")
    func protectsAndUnprotects() throws {
        var workbook = try XLSXReader.workbook(from: package())
        workbook.sheets[0].protect(password: "tables", allowing: SheetProtection.defaultAllowed.union([.formatCells]))
        workbook.protect(password: "")

        let sheetXML = try part("xl/worksheets/sheet1.xml", of: workbook)
        #expect(sheetXML.contains("<sheetProtection algorithmName=\"SHA-512\""))
        #expect(sheetXML.contains("sheet=\"1\""))
        #expect(sheetXML.contains("formatCells=\"0\""))
        #expect(try part("xl/workbook.xml", of: workbook).contains("<workbookProtection lockStructure=\"1\"/>"))

        var read = try XLSXReader.workbook(from: XLSXWriter.data(from: workbook))
        #expect(read.isStructureLocked)
        #expect(read.sheets[0].isProtected)
        #expect(read.sheets[0].protection?.allows(.formatCells) == true)
        #expect(read.sheets[0].protection?.allows(.insertRows) == false)
        let unprotected3 = read.sheets[0].unprotect(password: "wrong")
        #expect(!unprotected3)
        #expect(read.sheets[0].isProtected)
        let unprotected4 = read.sheets[0].unprotect(password: "tables")
        #expect(unprotected4)
        #expect(read.sheets[0].protection == nil)
        let unprotected5 = read.unprotect()
        #expect(unprotected5)
        #expect(read.protection == nil)
        #expect(!(try part("xl/worksheets/sheet1.xml", of: read)).contains("sheetProtection"))
        #expect(!(try part("xl/workbook.xml", of: read)).contains("workbookProtection"))
    }
}
