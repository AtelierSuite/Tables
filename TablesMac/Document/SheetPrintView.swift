import AppKit
import TablesEngine

/// A sheet laid out for printing: every row and column out to the last cell
/// with anything in it, drawn as the grid draws it, without the selection.
@MainActor
final class SheetPrintView: NSView {
    private let sheet: Worksheet
    private let metrics: SheetMetrics

    init(sheet: Worksheet) {
        self.sheet = sheet
        metrics = SheetMetrics(sheet: sheet)
        let used = sheet.cells.keys.reduce(CellAddress(row: 0, column: 0)) {
            CellAddress(row: max($0.row, $1.row), column: max($0.column, $1.column))
        }
        let frame = metrics.frame(for: CellRange(start: CellAddress(row: 0, column: 0), end: used))
        super.init(frame: CGRect(origin: .zero, size: frame.size))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        // Paper is white, whatever the screen's appearance.
        let appearance = NSAppearance(named: .aqua) ?? effectiveAppearance
        appearance.performAsCurrentDrawingAppearance {
            NSColor.white.setFill()
            dirtyRect.fill()
            CellRenderer(sheet: sheet, metrics: metrics, appearance: appearance)
                .draw(in: dirtyRect, context: context, gridLineColor: CellRenderer.gridLineColor(for: appearance))
        }
    }
}
