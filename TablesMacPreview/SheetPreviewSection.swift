import AppKit
import SwiftUI
import TablesEngine

/// One sheet in the preview: its name over its used cells, with the column
/// letters and row numbers small around them.
final class SheetPreviewSection: NSStackView {
    init(sheet: Worksheet) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8

        let title = NSTextField(labelWithString: sheet.name)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let header = NSStackView(views: [title])
        header.spacing = 8
        if let color = Color(argbHex: sheet.tabColorHex).map(NSColor.init) {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.backgroundColor = color.cgColor
            dot.layer?.cornerRadius = 5
            dot.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 10), dot.heightAnchor.constraint(equalToConstant: 10),
            ])
            header.insertArrangedSubview(dot, at: 0)
        }
        addArrangedSubview(header)

        if sheet.isChartSheet {
            addArrangedSubview(note(String(localized: "Preview.ChartSheet")))
            return
        }
        let grid = SheetPreviewGrid(sheet: sheet)
        addArrangedSubview(grid)
        if grid.hiddenRowCount > 0 {
            addArrangedSubview(note(String(format: String(localized: "Preview.MoreRows"), grid.hiddenRowCount)))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func note(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }
}

/// A sheet's used cells, drawn by the app's own renderer at a reading size.
final class SheetPreviewGrid: NSView {
    private let sheet: Worksheet
    private let metrics: SheetMetrics
    /// The rows and columns shown: the used range, up to a preview's worth.
    private let rows: Int
    private let columns: Int
    /// Rows past the ones shown.
    let hiddenRowCount: Int

    private static let zoom = 0.8
    private static let maximumRows = 60
    private static let maximumColumns = 52
    private static let headerHeight: CGFloat = 18
    private static let gutterWidth: CGFloat = 32

    init(sheet: Worksheet) {
        self.sheet = sheet
        metrics = SheetMetrics(sheet: sheet, zoom: Self.zoom)
        let used = Self.usedExtent(of: sheet)
        rows = min(used.rows, Self.maximumRows)
        columns = min(used.columns, Self.maximumColumns)
        hiddenRowCount = used.rows - rows
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let size = intrinsicContentSize
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size.width), heightAnchor.constraint(equalToConstant: size.height),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.gutterWidth + metrics.x(ofColumn: columns),
               height: Self.headerHeight + metrics.y(ofRow: rows))
    }

    /// How far the sheet's content reaches: its last row and column holding
    /// anything, merged regions included, and at least a cell.
    private static func usedExtent(of sheet: Worksheet) -> (rows: Int, columns: Int) {
        var rows = 0, columns = 0
        for (address, cell) in sheet.cells where !cell.isEmptyEntirely {
            rows = max(rows, address.row + 1)
            columns = max(columns, address.column + 1)
        }
        for merge in sheet.mergedRanges {
            rows = max(rows, merge.normalized.end.row + 1)
            columns = max(columns, merge.normalized.end.column + 1)
        }
        return (min(max(rows, 1), sheet.rowCount), min(max(columns, 1), sheet.columnCount))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let gutter = Self.gutterWidth, header = Self.headerHeight
        let cells = CGRect(x: 0, y: 0, width: metrics.x(ofColumn: columns), height: metrics.y(ofRow: rows))

        // The headers, quietly.
        NSColor.labelColor.withAlphaComponent(0.05).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: header).fill()
        NSRect(x: 0, y: 0, width: gutter, height: bounds.height).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.secondaryLabelColor,
        ]
        for column in 0..<columns where metrics.width(ofColumn: column) > 0 {
            let label = NSAttributedString(string: CellAddress.columnName(column), attributes: attributes)
            let x = gutter + metrics.x(ofColumn: column) + metrics.width(ofColumn: column) / 2
            label.draw(at: CGPoint(x: x - label.size().width / 2, y: (header - label.size().height) / 2))
        }
        for row in 0..<rows where metrics.height(ofRow: row) > 0 {
            let label = NSAttributedString(string: String(row + 1), attributes: attributes)
            let y = header + metrics.y(ofRow: row) + metrics.height(ofRow: row) / 2
            label.draw(at: CGPoint(x: (gutter - label.size().width) / 2, y: y - label.size().height / 2))
        }

        // The cells, in the sheet's own coordinates.
        context.saveGState()
        context.translateBy(x: gutter, y: header)
        context.clip(to: cells)
        NSColor.textBackgroundColor.setFill()
        cells.fill()
        let renderer = CellRenderer(sheet: sheet, metrics: metrics, appearance: effectiveAppearance)
        let area = dirtyRect.offsetBy(dx: -gutter, dy: -header).intersection(cells)
        if !area.isEmpty {
            renderer.draw(in: area, context: context, gridLineColor: CellRenderer.gridLineColor(for: effectiveAppearance))
        }
        context.restoreGState()
        NSColor.separatorColor.setStroke()
        NSBezierPath(rect: cells.offsetBy(dx: gutter, dy: header).insetBy(dx: -0.5, dy: -0.5)).stroke()
    }
}
