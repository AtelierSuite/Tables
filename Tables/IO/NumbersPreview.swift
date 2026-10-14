import SwiftUI
import UIKit

/// Draws the thumbnails Numbers keeps in a document — `preview.jpg` and its
/// smaller copies, which Files and Numbers show for it — from the workbook as
/// Tables has it, so they don't go on showing the document as it was before.
///
/// Numbers draws the top-left of the first sheet's canvas, its tables where
/// they sit on it, so that is what is drawn here: each table of the first
/// sheet, with its name where Numbers shows one, its fills, text and
/// gridlines. Only what falls inside the image is laid out, which keeps this
/// cheap enough to do on every save.
enum NumbersPreview {
    /// The previews Numbers writes, at the root of the document.
    static let names = ["preview.jpg", "preview-web.jpg", "preview-micro.jpg"]

    /// A new image for each of `originals`, at its size and in its
    /// appearance. One that can't be drawn is left out, so the original is
    /// kept rather than the save failing.
    static func previews(
        replacing originals: [String: Data], workbook: Workbook, source: NumbersSource
    ) -> [String: Data] {
        let canvas = PreviewCanvas(workbook: workbook, source: source)
        guard !canvas.tables.isEmpty else { return [:] }
        var previews: [String: Data] = [:]
        for (name, original) in originals {
            guard let image = UIImage(data: original)?.cgImage, image.width > 0, image.height > 0,
                  let rendered = canvas.jpeg(width: image.width, height: image.height, background: background(of: image))
            else { continue }
            previews[name] = rendered
        }
        return previews
    }

    /// The colour of the original's top-left corner, which is the canvas:
    /// white, or black when Numbers drew it in dark mode.
    private static func background(of image: CGImage) -> UIColor {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let corner = image.cropping(to: CGRect(x: 0, y: 0, width: 1, height: 1)),
              let context = CGContext(
                data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { return .white }
        context.draw(corner, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return UIColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
    }
}

/// The first sheet's tables, laid out as they sit on Numbers' canvas.
private struct PreviewCanvas {
    struct Table {
        var sheet: Worksheet
        /// Where the table's cells start on the canvas, in points.
        var origin: CGPoint
        var name: String?
        var defaultRowHeight: Double
    }

    var tables: [Table] = []

    /// Margins Numbers leaves round what it draws, in points.
    private static let margin = 20.0
    /// The most Numbers enlarges a sheet with little on it.
    private static let maximumScale = 1.6
    private static let nameFontSize = 12.0
    private static let nameHeight = 22.0

    init(workbook: Workbook, source: NumbersSource) {
        let firstSheet = source.archive[NumbersReader.documentIdentifier]?.message.messages(1).first?.uint(1)
        for sheet in workbook.sheets {
            guard let table = source.tables[sheet.id], table.sheetIdentifier == firstSheet else { continue }
            // A table with no place recorded goes below the one before it.
            let below = tables.last.map { $0.origin.y + Self.height(of: $0) + Self.margin } ?? Self.margin
            let fallback = CGPoint(x: Self.margin, y: below + (table.showsName ? Self.nameHeight : 0))
            tables.append(Table(
                sheet: sheet,
                origin: table.canvasOrigin ?? fallback,
                name: table.showsName ? table.tableName : nil,
                defaultRowHeight: table.defaultRowHeight
            ))
        }
    }

    private static func width(of table: Table) -> Double {
        (0..<table.sheet.columnCount).reduce(0) { $0 + table.sheet.width(ofColumn: $1) }
    }

    private static func height(of table: Table) -> Double {
        (0..<table.sheet.rowCount).reduce(0) { $0 + rowHeight(table, $1) }
    }

    private static func rowHeight(_ table: Table, _ row: Int) -> Double {
        if table.sheet.hiddenRows.contains(row) { return 0 }
        return table.sheet.rowHeights[row] ?? table.defaultRowHeight
    }

    /// The scale that fits the tables' width into the image, as Numbers
    /// fits them, up to the most it enlarges.
    private func scale(for size: CGSize) -> Double {
        let right = tables.map { $0.origin.x + Self.width(of: $0) }.max() ?? 0
        guard right > 0 else { return 1 }
        return min(Self.maximumScale, size.width / (right + Self.margin))
    }

    func jpeg(width: Int, height: Int, background: UIColor) -> Data? {
        let size = CGSize(width: width, height: height)
        let scale = scale(for: size)
        guard scale > 0 else { return nil }
        var white: CGFloat = 1
        background.getWhite(&white, alpha: nil)
        let scheme: ColorScheme = white < 0.5 ? .dark : .light

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            background.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let cg = context.cgContext
            cg.scaleBy(x: scale, y: scale)
            let visible = CGRect(x: 0, y: 0, width: size.width / scale, height: size.height / scale)
            for table in tables {
                draw(table, visible: visible, scheme: scheme, in: cg)
            }
        }
        return image.jpegData(compressionQuality: 0.8)
    }

    // MARK: - Drawing

    private func draw(_ table: Table, visible: CGRect, scheme: ColorScheme, in context: CGContext) {
        let sheet = table.sheet
        let ink: UIColor = scheme == .dark ? .white : .black
        let gridLine = UIColor(white: scheme == .dark ? 0.45 : 0.75, alpha: 1)

        if let name = table.name, !name.isEmpty {
            let font = UIFont(name: "HelveticaNeue", size: Self.nameFontSize) ?? .systemFont(ofSize: Self.nameFontSize)
            let text = NSAttributedString(string: name, attributes: [.font: font, .foregroundColor: ink])
            let measured = text.size()
            let x = table.origin.x + (Self.width(of: table) - measured.width) / 2
            text.draw(at: CGPoint(x: x, y: table.origin.y - Self.nameHeight + (Self.nameHeight - measured.height) / 2))
        }

        // The rows and columns inside the image, and where each starts.
        var columns: [(index: Int, x: Double, width: Double)] = []
        var x = table.origin.x
        for column in 0..<sheet.columnCount {
            guard x < visible.maxX else { break }
            let width = sheet.width(ofColumn: column)
            if width > 0 { columns.append((column, x, width)) }
            x += width
        }
        var rows: [(index: Int, y: Double, height: Double)] = []
        var y = table.origin.y
        for row in 0..<sheet.rowCount {
            guard y < visible.maxY else { break }
            let height = Self.rowHeight(table, row)
            if height > 0 { rows.append((row, y, height)) }
            y += height
        }
        guard let lastColumn = columns.last, let lastRow = rows.last else { return }
        let right = lastColumn.x + lastColumn.width, bottom = lastRow.y + lastRow.height
        let xs = Dictionary(columns.map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })
        let ys = Dictionary(rows.map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })

        func frame(_ range: CellRange) -> CGRect? {
            let box = range.normalized
            let left = (box.start.column...box.end.column).compactMap { xs[$0] }
            let top = (box.start.row...box.end.row).compactMap { ys[$0] }
            guard let first = left.first, let last = left.last, let upper = top.first, let lower = top.last else { return nil }
            return CGRect(x: first.x, y: upper.y, width: last.x + last.width - first.x, height: lower.y + lower.height - upper.y)
        }

        var covered: Set<CellAddress> = []
        var boxes: [(address: CellAddress, frame: CGRect)] = []
        for merge in sheet.mergedRanges {
            let box = merge.normalized
            guard let mergeFrame = frame(box) else { continue }
            for row in box.start.row...box.end.row {
                for column in box.start.column...box.end.column { covered.insert(CellAddress(row: row, column: column)) }
            }
            boxes.append((box.start, mergeFrame))
        }
        for row in rows {
            for column in columns {
                let address = CellAddress(row: row.index, column: column.index)
                guard !covered.contains(address) else { continue }
                boxes.append((address, CGRect(x: column.x, y: row.y, width: column.width, height: row.height)))
            }
        }

        for box in boxes {
            if let fill = sheet[box.address].style.fillColor(for: scheme) {
                context.setFillColor(UIColor(fill).cgColor)
                context.fill(box.frame)
            }
        }

        // Gridlines round every cell, then each cell's text over them.
        context.setStrokeColor(gridLine.cgColor)
        context.setLineWidth(0.5)
        for box in boxes { context.stroke(box.frame) }
        context.stroke(CGRect(x: table.origin.x, y: table.origin.y, width: right - table.origin.x, height: bottom - table.origin.y))

        for box in boxes {
            let cell = sheet[box.address]
            drawText(of: cell, in: box.frame, ink: ink, scheme: scheme, context: context)
            drawBorders(of: cell.style, in: box.frame, ink: ink, scheme: scheme, context: context)
        }
    }

    private func drawText(of cell: Cell, in frame: CGRect, ink: UIColor, scheme: ColorScheme, context: CGContext) {
        let text = CellFormatter.displayText(for: cell)
        guard !text.isEmpty else { return }
        let style = cell.style
        var font = UIFont(name: style.fontName, size: style.fontSize) ?? .systemFont(ofSize: style.fontSize)
        var traits: UIFontDescriptor.SymbolicTraits = []
        if style.isBold { traits.insert(.traitBold) }
        if style.isItalic { traits.insert(.traitItalic) }
        if !traits.isEmpty, let descriptor = font.fontDescriptor.withSymbolicTraits(traits) {
            font = UIFont(descriptor: descriptor, size: style.fontSize)
        }
        let color: UIColor = cell.value.errorValue != nil ? .systemRed : style.textColor(for: scheme).map { UIColor($0) } ?? ink

        let paragraph = NSMutableParagraphStyle()
        let horizontal = style.horizontalAlignment == .automatic
            ? CellFormatter.naturalAlignment(for: cell.value)
            : style.horizontalAlignment
        switch horizontal {
        case .center: paragraph.alignment = .center
        case .trailing: paragraph.alignment = .right
        default: paragraph.alignment = .left
        }
        paragraph.lineBreakMode = style.wrapsText ? .byWordWrapping : .byClipping
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        if style.isUnderlined { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if style.isStruckThrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        let string = NSAttributedString(string: text, attributes: attributes)

        let box = frame.insetBy(dx: 4, dy: 2)
        guard box.width > 0, box.height > 0 else { return }
        let measured = string.boundingRect(
            with: CGSize(width: style.wrapsText ? box.width : 100_000, height: 100_000),
            options: [.usesLineFragmentOrigin], context: nil
        )
        let height = min(measured.height, box.height)
        let top: Double
        switch style.verticalAlignment {
        case .top: top = box.minY
        case .middle: top = box.midY - height / 2
        case .bottom: top = box.maxY - height
        }
        context.saveGState()
        context.clip(to: frame)
        string.draw(with: CGRect(x: box.minX, y: top, width: box.width, height: height),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
        context.restoreGState()
    }

    private func drawBorders(of style: CellStyle, in frame: CGRect, ink: UIColor, scheme: ColorScheme, context: CGContext) {
        for (edge, side) in style.borderSides {
            let color = AdaptiveColor.resolve(hex: side.colorHex, for: scheme, isText: true).map { UIColor($0) } ?? ink
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(side.lineStyle.lineWidth)
            switch edge {
            case .top: context.strokeLineSegments(between: [CGPoint(x: frame.minX, y: frame.minY), CGPoint(x: frame.maxX, y: frame.minY)])
            case .bottom: context.strokeLineSegments(between: [CGPoint(x: frame.minX, y: frame.maxY), CGPoint(x: frame.maxX, y: frame.maxY)])
            case .leading: context.strokeLineSegments(between: [CGPoint(x: frame.minX, y: frame.minY), CGPoint(x: frame.minX, y: frame.maxY)])
            case .trailing: context.strokeLineSegments(between: [CGPoint(x: frame.maxX, y: frame.minY), CGPoint(x: frame.maxX, y: frame.maxY)])
            }
        }
    }
}
