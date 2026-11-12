import AppKit
import TablesEngine

/// A sheet laid out for printing: every row and column out to the last cell
/// with anything in it, drawn as the grid draws it, without the selection.
///
/// Pages break between rows and between columns, never through one, as
/// `PrintPagination` cuts them.
@MainActor
final class SheetPrintView: NSView {
    private let sheet: Worksheet
    private let metrics: SheetMetrics
    private let range: CellRange
    private var pagination: PrintPagination?

    init(sheet: Worksheet) {
        self.sheet = sheet
        let metrics = SheetMetrics(sheet: sheet)
        self.metrics = metrics
        range = PrintPagination.printedRange(of: sheet, objectFrames: [], metrics: metrics)
            ?? CellRange(CellAddress(row: 0, column: 0))
        let frame = metrics.frame(for: range)
        super.init(frame: CGRect(x: 0, y: 0, width: frame.maxX, height: frame.maxY))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    // MARK: - Pages

    /// The pages, cut for the paper, margins and scale chosen in the print
    /// panel, which change while it is open.
    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        let info = NSPrintOperation.current?.printInfo ?? NSPrintInfo.shared
        let pagination = PrintPagination(range: self.range, metrics: metrics, pageSize: Self.printableSize(of: info))
        self.pagination = pagination
        range.pointee = NSRange(location: 1, length: max(1, pagination.pages.count))
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect {
        guard let pages = pagination?.pages, pages.indices.contains(page - 1) else { return bounds }
        return pages[page - 1].frame
    }

    /// What one page holds, in the sheet's points: the paper inside its
    /// margins, grown or shrunk by the print panel's scale.
    static func printableSize(of info: NSPrintInfo) -> CGSize {
        let scale = info.scalingFactor > 0 ? info.scalingFactor : 1
        return CGSize(
            width: max(1, (info.paperSize.width - info.leftMargin - info.rightMargin) / scale),
            height: max(1, (info.paperSize.height - info.topMargin - info.bottomMargin) / scale))
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let page = NSPrintOperation.current.flatMap { rectForPage($0.currentPage) } ?? bounds
        // Paper is white, whatever the screen's appearance.
        let appearance = NSAppearance(named: .aqua) ?? effectiveAppearance
        appearance.performAsCurrentDrawingAppearance {
            NSColor.white.setFill()
            dirtyRect.fill()
            var renderer = CellRenderer(sheet: sheet, metrics: metrics, appearance: appearance)
            // Borders on a page's edges stay on that page.
            renderer.shownArea = page
            renderer.draw(in: dirtyRect, context: context, gridLineColor: CellRenderer.gridLineColor(for: appearance))
        }
    }
}
