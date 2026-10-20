import Foundation
import Testing
@testable import Tables
@testable import TablesEngine
@testable import TablesMacros

/// Covers the indirect colour references real workbooks use: theme slots with
/// their tints, the legacy indexed palette, and the references that mean
/// "whatever the application's default is".
@Suite("Theme and indexed colours")
struct ThemeColorTests {

    // MARK: - Package building

    /// The 2007-era Office scheme. Its accents differ from the built-in
    /// fallback, so a colour resolving to one of these proves the theme part
    /// was actually read rather than assumed.
    private static let themePart = """
    <?xml version="1.0" encoding="UTF-8"?>
    <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Test">\
    <a:themeElements><a:clrScheme name="Office">\
    <a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1>\
    <a:lt1><a:sysClr val="window" lastClr="FFFFFF"/></a:lt1>\
    <a:dk2><a:srgbClr val="1F497D"/></a:dk2>\
    <a:lt2><a:srgbClr val="EEECE1"/></a:lt2>\
    <a:accent1><a:srgbClr val="4F81BD"/></a:accent1>\
    <a:accent2><a:srgbClr val="C0504D"/></a:accent2>\
    <a:accent3><a:srgbClr val="9BBB59"/></a:accent3>\
    <a:accent4><a:srgbClr val="8064A2"/></a:accent4>\
    <a:accent5><a:srgbClr val="4BACC6"/></a:accent5>\
    <a:accent6><a:srgbClr val="F79646"/></a:accent6>\
    <a:hlink><a:srgbClr val="0000FF"/></a:hlink>\
    <a:folHlink><a:srgbClr val="800080"/></a:folHlink>\
    </a:clrScheme></a:themeElements></a:theme>
    """

    /// Builds a one-sheet package around a caller-supplied `styles.xml`, with
    /// the theme part included unless the caller is testing its absence.
    private func styledPackage(styles: String, sheet: String, includesTheme: Bool = true) throws -> Data {
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
        <sheets><sheet name="S" sheetId="1" r:id="rId1"/></sheets></workbook>
        """
        let workbookRelationships = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" \
        Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" \
        Target="worksheets/sheet1.xml"/>\
        <Relationship Id="rId2" \
        Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" \
        Target="styles.xml"/>\
        <Relationship Id="rId3" \
        Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" \
        Target="theme/theme1.xml"/></Relationships>
        """
        var parts: [(String, Data)] = [
            ("[Content_Types].xml", Data(contentTypes.utf8)),
            ("_rels/.rels", Data(rootRelationships.utf8)),
            ("xl/workbook.xml", Data(workbook.utf8)),
            ("xl/_rels/workbook.xml.rels", Data(workbookRelationships.utf8)),
            ("xl/styles.xml", Data(styles.utf8)),
            ("xl/worksheets/sheet1.xml", Data(sheet.utf8)),
        ]
        if includesTheme { parts.append(("xl/theme/theme1.xml", Data(Self.themePart.utf8))) }
        return try ZipArchive.archive(entries: parts)
    }

    /// Wraps font and fill definitions in the surrounding style sheet, pairing
    /// font *n* with fill *n* in cell format *n*.
    private func styleSheet(fonts: [String], fills: [String]) -> String {
        let fontXML = fonts.map { "<font><sz val=\"11\"/>\($0)</font>" }.joined()
        let fillXML = fills.map { "<fill>\($0)</fill>" }.joined()
        let formatCount = max(fonts.count, fills.count)
        let formats = (0..<formatCount).map { index in
            "<xf numFmtId=\"0\" fontId=\"\(min(index, fonts.count - 1))\" "
                + "fillId=\"\(min(index, fills.count - 1))\" borderId=\"0\" xfId=\"0\"/>"
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
        <fonts count="\(fonts.count)">\(fontXML)</fonts>\
        <fills count="\(fills.count)">\(fillXML)</fills>\
        <borders count="1"><border/></borders>\
        <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
        <cellXfs count="\(formatCount)">\(formats)</cellXfs></styleSheet>
        """
    }

    /// One cell per cell format, laid out across row 1.
    private func row(formatCount: Int) -> String {
        let cells = (0..<formatCount).map { index in
            let column = String(UnicodeScalar(UInt8(65 + index)))
            return "<c r=\"\(column)1\" s=\"\(index)\" t=\"inlineStr\"><is><t>x</t></is></c>"
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
        <sheetData><row r="1">\(cells)</row></sheetData></worksheet>
        """
    }

    private func style(_ workbook: Workbook, _ reference: String) -> CellStyle {
        workbook.sheets[0][CellAddress(a1: reference)!].style
    }

    // MARK: - Theme references

    @Test("Theme slots resolve, with the first two pairs swapped")
    func themeSlots() throws {
        // theme="1" is what Excel writes for ordinary black body text, which is
        // dk1 — proof the styles' index order is lt1, dk1, lt2, dk2, accents.
        let styles = styleSheet(
            fonts: [
                "<color theme=\"1\"/>", "<color theme=\"0\"/>",
                "<color theme=\"3\"/>", "<color theme=\"4\"/>", "<color theme=\"9\"/>",
            ],
            fills: ["<patternFill patternType=\"none\"/>"]
        )
        let workbook = try XLSXReader.workbook(from: styledPackage(styles: styles, sheet: row(formatCount: 5)))

        #expect(style(workbook, "A1").textColorHex == "FF000000")
        #expect(style(workbook, "B1").textColorHex == "FFFFFFFF")
        #expect(style(workbook, "C1").textColorHex == "FF1F497D")
        #expect(style(workbook, "D1").textColorHex == "FF4F81BD")
        #expect(style(workbook, "E1").textColorHex == "FFF79646")
    }

    @Test("A tint shifts luminance without moving the hue")
    func themeTint() throws {
        let styles = styleSheet(
            fonts: ["<color theme=\"4\" tint=\"-0.25\"/>", "<color theme=\"4\" tint=\"0.4\"/>"],
            fills: [
                "<patternFill patternType=\"solid\"><fgColor theme=\"4\" tint=\"0.4\"/></patternFill>",
                "<patternFill patternType=\"solid\"><fgColor theme=\"1\" tint=\"0.5\"/></patternFill>",
            ]
        )
        let workbook = try XLSXReader.workbook(from: styledPackage(styles: styles, sheet: row(formatCount: 2)))

        #expect(style(workbook, "A1").textColorHex == "FF376092")
        #expect(style(workbook, "B1").textColorHex == "FF95B3D7")
        #expect(style(workbook, "A1").fillColorHex == "FF95B3D7")
        // Grey has no hue to preserve; lightening black lands mid-grey.
        #expect(style(workbook, "B1").fillColorHex == "FF808080")
    }

    @Test("Tint maths clamps and matches OOXML's endpoints")
    func tintEndpoints() {
        #expect(ThemeColorPalette.tinted("4F81BD", by: 0) == "4F81BD")
        #expect(ThemeColorPalette.tinted("4F81BD", by: 1) == "FFFFFF")
        #expect(ThemeColorPalette.tinted("4F81BD", by: -1) == "000000")
        #expect(ThemeColorPalette.tinted("4F81BD", by: 3) == "FFFFFF")
    }

    // MARK: - Indexed references

    @Test("The legacy indexed palette resolves")
    func indexedColors() throws {
        let styles = styleSheet(
            fonts: ["<color indexed=\"10\"/>", "<color indexed=\"55\"/>", "<color indexed=\"200\"/>"],
            fills: ["<patternFill patternType=\"solid\"><fgColor indexed=\"13\"/></patternFill>"]
        )
        let workbook = try XLSXReader.workbook(from: styledPackage(styles: styles, sheet: row(formatCount: 3)))

        #expect(style(workbook, "A1").textColorHex == "FFFF0000")
        #expect(style(workbook, "B1").textColorHex == "FF969696")
        // Out of range: nothing sensible to show, so the default applies.
        #expect(style(workbook, "C1").textColorHex == nil)
        #expect(style(workbook, "A1").fillColorHex == "FFFFFF00")
    }

    @Test("System and automatic colours defer to the app's own default")
    func systemAndAutomaticColors() throws {
        let styles = styleSheet(
            fonts: ["<color indexed=\"64\"/>", "<color indexed=\"65\"/>", "<color auto=\"1\"/>"],
            fills: ["<patternFill patternType=\"solid\"><fgColor indexed=\"64\"/></patternFill>"]
        )
        let workbook = try XLSXReader.workbook(from: styledPackage(styles: styles, sheet: row(formatCount: 3)))

        // Hardcoding black or white here would be wrong in one appearance.
        #expect(style(workbook, "A1").textColorHex == nil)
        #expect(style(workbook, "B1").textColorHex == nil)
        #expect(style(workbook, "C1").textColorHex == nil)
        #expect(style(workbook, "A1").fillColorHex == nil)
    }

    // MARK: - Direct and missing references

    @Test("A direct rgb colour still wins and is widened to ARGB")
    func directColors() throws {
        let styles = styleSheet(
            fonts: ["<color rgb=\"FF3366CC\"/>", "<color rgb=\"3366CC\"/>"],
            fills: ["<patternFill patternType=\"none\"/>"]
        )
        let workbook = try XLSXReader.workbook(from: styledPackage(styles: styles, sheet: row(formatCount: 2)))

        #expect(style(workbook, "A1").textColorHex == "FF3366CC")
        #expect(style(workbook, "B1").textColorHex == "FF3366CC")
    }

    @Test("A workbook with no theme part falls back to the standard scheme")
    func missingThemePart() throws {
        let styles = styleSheet(
            fonts: ["<color theme=\"4\"/>", "<color theme=\"1\"/>"],
            fills: ["<patternFill patternType=\"none\"/>"]
        )
        let workbook = try XLSXReader.workbook(
            from: styledPackage(styles: styles, sheet: row(formatCount: 2), includesTheme: false)
        )

        #expect(style(workbook, "A1").textColorHex == "FF4472C4")
        #expect(style(workbook, "B1").textColorHex == "FF000000")
    }

    @Test("Borders take their colour through the same resolver")
    func borderColors() throws {
        let styles = """
        <?xml version="1.0" encoding="UTF-8"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
        <fonts count="1"><font><sz val="11"/></font></fonts>\
        <fills count="1"><fill><patternFill patternType="none"/></fill></fills>\
        <borders count="2"><border/>\
        <border><bottom style="thin"><color theme="4"/></bottom></border></borders>\
        <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
        <cellXfs count="1">\
        <xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyBorder="1"/>\
        </cellXfs></styleSheet>
        """
        let workbook = try XLSXReader.workbook(from: styledPackage(styles: styles, sheet: row(formatCount: 1)))

        #expect(style(workbook, "A1").borderColorHex == "FF4F81BD")
        #expect(style(workbook, "A1").borders.contains(.bottom))
    }
}
