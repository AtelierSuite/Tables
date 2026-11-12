import CoreGraphics
import Foundation
import Testing
@testable import Tables
@testable import TablesEngine

/// Pattern and gradient fills: what the reader makes of them, what the writer
/// puts back, and the pattern and gradient models the renderers draw from.
@Suite("Fill patterns and gradients")
struct FillPatternTests {

    // MARK: - Helpers

    /// A one-cell package whose A1 uses the single `<fill>` given.
    private func package(fill: String) throws -> Data {
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
        Target="styles.xml"/></Relationships>
        """
        let styles = """
        <?xml version="1.0" encoding="UTF-8"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
        <fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts>\
        <fills count="3"><fill><patternFill patternType="none"/></fill>\
        <fill><patternFill patternType="gray125"/></fill><fill>\(fill)</fill></fills>\
        <borders count="1"><border/></borders>\
        <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
        <cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>\
        <xf numFmtId="0" fontId="0" fillId="2" borderId="0" xfId="0" applyFill="1"/></cellXfs></styleSheet>
        """
        let sheet = """
        <?xml version="1.0" encoding="UTF-8"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
        <sheetData><row r="1"><c r="A1" s="1" t="inlineStr"><is><t>x</t></is></c></row></sheetData></worksheet>
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

    private func read(fill: String) throws -> CellStyle {
        try XLSXReader.workbook(from: package(fill: fill)).sheets[0][CellAddress(a1: "A1")!].style
    }

    private func roundTripped(_ styles: [CellStyle]) throws -> [CellStyle] {
        var sheet = Worksheet(name: "S")
        sheet.rowCount = max(sheet.rowCount, styles.count)
        for (row, style) in styles.enumerated() {
            sheet[CellAddress(row: row, column: 0)] = Cell(value: .text("x"), formula: nil, style: style)
        }
        let data = try XLSXWriter.data(from: Workbook(sheets: [sheet]))
        let read = try XLSXReader.workbook(from: data).sheets[0]
        return styles.indices.map { read[CellAddress(row: $0, column: 0)].style }
    }

    // MARK: - Reading

    @Test("A pattern keeps its type, its colour and the background it is drawn over")
    func patternIsRead() throws {
        let style = try read(fill: """
        <patternFill patternType="darkGrid"><fgColor rgb="FF000000"/><bgColor rgb="FFFFFF00"/></patternFill>
        """)
        #expect(style.fillPattern == FillPattern(type: .darkGrid, colorHex: "FF000000"))
        // Not a solid black cell any more: the colour under the pattern is its background.
        #expect(style.fillColorHex == "FFFFFF00")
        #expect(style.fillGradient == nil)
    }

    @Test("Every OOXML pattern type is read", arguments: FillPatternType.allCases)
    func everyPatternIsRead(_ type: FillPatternType) throws {
        let style = try read(fill: "<patternFill patternType=\"\(type.rawValue)\"><fgColor indexed=\"10\"/></patternFill>")
        #expect(style.fillPattern == FillPattern(type: type, colorHex: "FFFF0000"))
        // No bgColor: the paper shows through, as it does in Excel.
        #expect(style.fillColorHex == nil)
    }

    @Test("Automatic pattern colours stay automatic")
    func automaticPatternColours() throws {
        let style = try read(fill: """
        <patternFill patternType="gray125"><fgColor indexed="64"/><bgColor indexed="65"/></patternFill>
        """)
        #expect(style.fillPattern == FillPattern(type: .gray125, colorHex: nil))
        #expect(style.fillColorHex == nil)
        #expect(style.hasFill)
    }

    @Test("Solid fills are read as before")
    func solidFillsUnchanged() throws {
        let solid = try read(fill: """
        <patternFill patternType="solid"><fgColor rgb="FF3366CC"/><bgColor indexed="64"/></patternFill>
        """)
        #expect(solid.fillColorHex == "FF3366CC")
        #expect(solid.fillPattern == nil)
        // A pattern fill that names no type but a colour has always been read as solid.
        let untyped = try read(fill: "<patternFill><fgColor rgb=\"FF3366CC\"/></patternFill>")
        #expect(untyped.fillColorHex == "FF3366CC")
        #expect(untyped.fillPattern == nil)
        #expect(try read(fill: "<patternFill patternType=\"none\"/>").hasFill == false)
    }

    @Test("An unknown pattern token degrades to 50% grey rather than vanishing")
    func unknownPatternToken() throws {
        let style = try read(fill: "<patternFill patternType=\"sparkles\"><fgColor rgb=\"FF000000\"/></patternFill>")
        #expect(style.fillPattern?.type == .mediumGray)
    }

    @Test("A linear gradient keeps its angle and stops, and falls back to its first colour")
    func linearGradientIsRead() throws {
        let style = try read(fill: """
        <gradientFill degree="90"><stop position="1"><color rgb="FF0000FF"/></stop>\
        <stop position="0"><color rgb="FFFFFFFF"/></stop></gradientFill>
        """)
        let gradient = try #require(style.fillGradient)
        #expect(gradient.kind == .linear(degree: 90))
        #expect(gradient.stops == [
            GradientStop(position: 0, colorHex: "FFFFFFFF"), GradientStop(position: 1, colorHex: "FF0000FF"),
        ])
        #expect(style.fillColorHex == "FFFFFFFF")
        #expect(style.fillPattern == nil)
    }

    @Test("A path gradient keeps the rectangle it spreads from")
    func pathGradientIsRead() throws {
        let style = try read(fill: """
        <gradientFill type="path" left="0.5" right="0.5" top="0.5" bottom="0.5">\
        <stop position="0"><color theme="0"/></stop><stop position="1"><color theme="4"/></stop></gradientFill>
        """)
        let gradient = try #require(style.fillGradient)
        #expect(gradient.kind == .path(left: 0.5, right: 0.5, top: 0.5, bottom: 0.5))
        #expect(gradient.stops.map(\.colorHex) == ["FFFFFFFF", "FF4472C4"])
        // A gradient with no angle runs left to right.
        let plain = try read(fill: "<gradientFill><stop position=\"0\"><color rgb=\"FF000000\"/></stop></gradientFill>")
        #expect(plain.fillGradient?.kind == .linear(degree: 0))
    }

    // MARK: - Writing

    @Test("Patterns, gradients and solid fills survive a round trip")
    func fillsRoundTrip() throws {
        var styles = FillPatternType.allCases.map { type in
            var style = CellStyle()
            style.fillColorHex = "FFFFFF00"
            style.fillPattern = FillPattern(type: type, colorHex: "FF0000FF")
            return style
        }
        var automatic = CellStyle()
        automatic.fillPattern = FillPattern(type: .gray125)
        styles.append(automatic)
        var linear = CellStyle()
        linear.fillGradient = FillGradient(kind: .linear(degree: 90), stops: [
            GradientStop(position: 0, colorHex: "FFFFFFFF"), GradientStop(position: 0.5, colorHex: "FF00FF00"),
            GradientStop(position: 1, colorHex: "FF0000FF"),
        ])
        linear.fillColorHex = "FFFFFFFF"
        styles.append(linear)
        var path = CellStyle()
        path.fillGradient = FillGradient(kind: .path(left: 0.2, right: 0.8, top: 0.25, bottom: 0.75), stops: [
            GradientStop(position: 0, colorHex: "FFFF0000"), GradientStop(position: 1, colorHex: "FF000000"),
        ])
        path.fillColorHex = "FFFF0000"
        styles.append(path)
        var corner = CellStyle()
        corner.fillGradient = FillGradient(kind: .path(left: 0, right: 0, top: 0, bottom: 0), stops: [
            GradientStop(position: 0, colorHex: "FFFF0000"), GradientStop(position: 1, colorHex: "FF000000"),
        ])
        corner.fillColorHex = "FFFF0000"
        styles.append(corner)
        var solid = CellStyle()
        solid.fillColorHex = "FF3366CC"
        styles.append(solid)
        var unfilled = CellStyle()
        unfilled.isBold = true
        styles.append(unfilled)

        let read = try roundTripped(styles)
        for (index, (written, back)) in zip(styles, read).enumerated() {
            #expect(back.fillColorHex == written.fillColorHex, "row \(index)")
            #expect(back.fillPattern == written.fillPattern, "row \(index)")
            #expect(back.fillGradient == written.fillGradient, "row \(index)")
        }
    }

    @Test("The written fill is what Excel expects")
    func writtenFillXML() {
        var pattern = CellStyle()
        pattern.fillPattern = FillPattern(type: .lightTrellis, colorHex: "FFFF0000")
        #expect(XLSXWriter.StyleTable.fillXML(for: pattern) == """
        <patternFill patternType="lightTrellis"><fgColor rgb="FFFF0000"/><bgColor indexed="65"/></patternFill>
        """)
        var gradient = CellStyle()
        gradient.fillGradient = FillGradient(kind: .linear(degree: 45), stops: [
            GradientStop(position: 0, colorHex: "FFFFFFFF"), GradientStop(position: 1, colorHex: nil),
        ])
        #expect(XLSXWriter.StyleTable.fillXML(for: gradient) == """
        <gradientFill degree="45"><stop position="0"><color rgb="FFFFFFFF"/></stop>\
        <stop position="1"><color indexed="65"/></stop></gradientFill>
        """)
    }

    // MARK: - Editing

    @Test("Choosing a fill colour makes the fill solid, and clearing it clears it all")
    func solidFillReplacesPattern() {
        var style = CellStyle()
        style.fillPattern = FillPattern(type: .darkUp)
        style.fillGradient = FillGradient(kind: .linear(degree: 0), stops: [GradientStop(position: 0, colorHex: "FF000000")])
        style.setSolidFill("FFFF0000")
        #expect(style.fillColorHex == "FFFF0000")
        #expect(style.fillPattern == nil && style.fillGradient == nil)
        style.fillPattern = FillPattern(type: .darkUp)
        style.setSolidFill(nil)
        #expect(!style.hasFill)
        #expect(style.isDefault)
    }

    @Test("A conditional format's fill covers the cell's pattern")
    func conditionalFillCoversPattern() {
        var style = CellStyle()
        style.fillPattern = FillPattern(type: .gray125)
        let applied = ConditionalStyle(fillColorHex: "FFFFC7CE").applied(to: style)
        #expect(applied.fillColorHex == "FFFFC7CE")
        #expect(applied.fillPattern == nil)
    }

    // MARK: - Pattern model

    @Test("The grey patterns cover the share of the cell their names say")
    func greyCoverage() {
        #expect(FillPatternType.darkGray.coverage == 0.75)
        #expect(FillPatternType.mediumGray.coverage == 0.5)
        #expect(FillPatternType.lightGray.coverage == 0.25)
        #expect(FillPatternType.gray125.coverage == 0.125)
        #expect(FillPatternType.gray0625.coverage == 0.0625)
    }

    @Test("Every pattern is an 8×8 bitmap that repeats, and none is blank or solid", arguments: FillPatternType.allCases)
    func patternsTile(_ type: FillPatternType) {
        #expect(type.rows.count == 8)
        #expect(type.coverage > 0 && type.coverage < 1)
        for row in 0..<8 {
            for column in 0..<8 {
                #expect(type.isInked(column: column, row: row) == type.isInked(column: column + 8, row: row - 8))
            }
        }
    }

    @Test("Stripes run the way their names say")
    func stripeDirections() {
        // Horizontal stripes: every bit of a row the same.
        for type in [FillPatternType.darkHorizontal, .lightHorizontal] {
            #expect(type.rows.allSatisfy { $0 == 0 || $0 == 0xFF })
        }
        // Vertical stripes: every row the same.
        for type in [FillPatternType.darkVertical, .lightVertical] {
            #expect(Set(type.rows).count == 1)
        }
        // Down falls to the right: a step down is a step right. Up rises to it.
        for type in [FillPatternType.darkDown, .lightDown] {
            #expect(type.isInked(column: 0, row: 0) && type.isInked(column: 1, row: 1))
            #expect(type.isInked(column: 4, row: 0) && type.isInked(column: 5, row: 1))
        }
        for type in [FillPatternType.darkUp, .lightUp] {
            #expect(type.isInked(column: 7, row: 0) && type.isInked(column: 6, row: 1))
        }
    }

    @Test("A pattern tile has the pattern's bits, whichever way up it is drawn")
    func tileImage() throws {
        let ink = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        for flipped in [false, true] {
            let image = try #require(FillPatternType.lightDown.tileImage(ink: ink, scale: 2, flipped: flipped))
            #expect(image.width == FillPattern.tileBits * 2)
            let data = try #require(image.dataProvider?.data as Data?)
            func alpha(column: Int, row: Int) -> UInt8 {
                // Image rows run from the top; a flipped context shows the bottom first.
                let imageRow = flipped ? image.height - 1 - row * 2 : row * 2
                return data[imageRow * image.bytesPerRow + column * 2 * 4 + 3]
            }
            #expect(alpha(column: 0, row: 0) == 255)
            #expect(alpha(column: 1, row: 1) == 255)
            #expect(alpha(column: 1, row: 0) == 0)
            #expect(alpha(column: 0, row: 1) == 0)
        }
    }

    // MARK: - Gradient model

    @Test("A gradient blends its stops in between them and holds them beyond")
    func gradientColours() {
        let gradient = FillGradient(kind: .linear(degree: 0), stops: [
            GradientStop(position: 0.25, colorHex: "FF000000"), GradientStop(position: 0.75, colorHex: "FFFFFFFF"),
        ])
        #expect(gradient.colorHex(at: 0) == "FF000000")
        #expect(gradient.colorHex(at: 0.5) == "FF808080")
        #expect(gradient.colorHex(at: 1) == "FFFFFFFF")
        let single = FillGradient(kind: .linear(degree: 0), stops: [GradientStop(position: 0, colorHex: "FF102030")])
        #expect(single.colorHex(at: 0.7) == "FF102030")
    }

    @Test("A linear gradient runs across the cell at its angle")
    func linearEndpoints() {
        let frame = CGRect(x: 10, y: 20, width: 100, height: 40)
        func ends(_ degree: Double) -> (CGPoint, CGPoint) {
            let result = FillGradient(kind: .linear(degree: degree), stops: []).linearEndpoints(in: frame)
            func round(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x.rounded(), y: point.y.rounded()) }
            return (round(result.start), round(result.end))
        }
        // 0° is left to right, 90° top to bottom: clockwise with y running down.
        #expect(ends(0) == (CGPoint(x: 10, y: 40), CGPoint(x: 110, y: 40)))
        #expect(ends(90) == (CGPoint(x: 60, y: 20), CGPoint(x: 60, y: 60)))
        #expect(ends(180) == (CGPoint(x: 110, y: 40), CGPoint(x: 10, y: 40)))
    }

    @Test("A path gradient steps in from the cell's edges to its inner rectangle")
    func pathBands() throws {
        let frame = CGRect(x: 0, y: 0, width: 40, height: 20)
        let gradient = FillGradient(kind: .path(left: 0.5, right: 0.5, top: 0.5, bottom: 0.5), stops: [
            GradientStop(position: 0, colorHex: "FFFFFFFF"), GradientStop(position: 1, colorHex: "FF000000"),
        ])
        let bands = gradient.pathBands(in: frame, step: 1)
        #expect(bands.count == 20)
        let outer = try #require(bands.first)
        let inner = try #require(bands.last)
        #expect(outer.rect == frame)
        // Outermost nearly the last colour, innermost nearly the first.
        #expect(outer.colorHex.hasPrefix("FF0"))
        #expect(inner.colorHex.hasPrefix("FFF"))
        #expect(abs(inner.rect.midX - 20) < 0.001 && abs(inner.rect.midY - 10) < 0.001)
        #expect(inner.rect.width < 3)
        // Nested: each band sits inside the one before it.
        for (bigger, smaller) in zip(bands, bands.dropFirst()) {
            #expect(bigger.rect.contains(smaller.rect))
        }
        // A linear gradient has no bands to draw.
        #expect(FillGradient(kind: .linear(degree: 0), stops: gradient.stops).pathBands(in: frame, step: 1).isEmpty)
    }

    // MARK: - Appearance

    @Test("Automatic pattern ink is black, and turns light in dark mode with the paper")
    func patternInkAdapts() throws {
        var style = CellStyle()
        style.fillPattern = FillPattern(type: .gray125)
        #expect(style.fillPatternColor(for: .light)?.argbHex == "FF000000")
        #expect(style.fillPatternColor(for: .dark)?.argbHex == "FFFFFFFF")
        #expect(CellStyle().fillPatternColor(for: .light) == nil)
    }
}
