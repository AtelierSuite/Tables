import AppKit
import SwiftUI
import TablesEngine

/// A sheet laid out for printing: every row and column out to the last cell
/// with anything in it, and the charts and pictures floating over them,
/// drawn as the grid draws them, without the selection or comment marks.
///
/// Pages break between rows and between columns, never through one, as
/// `PrintPagination` cuts them. Gridlines print only when asked for in the
/// print panel, as in Excel.
@MainActor
final class SheetPrintView: NSView {
    private let sheet: Worksheet
    private let workbook: Workbook
    private let metrics: SheetMetrics
    private let objects: [PrintedObject]
    private let range: CellRange
    private var pagination: PrintPagination?

    /// A chart or picture, where it sits on the sheet.
    private struct PrintedObject {
        enum Content {
            case chart(TablesEngine.Chart, ResolvedChart)
            case picture(CGImage)
        }

        let frame: CGRect
        let content: Content
    }

    init(sheet: Worksheet, in workbook: Workbook) {
        self.sheet = sheet
        self.workbook = workbook
        let metrics = SheetMetrics(sheet: sheet)
        self.metrics = metrics
        let objects = Self.objects(on: sheet, in: workbook, metrics: metrics)
        self.objects = objects
        range = PrintPagination.printedRange(of: sheet, objectFrames: objects.map(\.frame), metrics: metrics)
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
        let info = NSPrintOperation.current?.printInfo
        let page = NSPrintOperation.current.flatMap { rectForPage($0.currentPage) } ?? bounds
        // Paper is white, whatever the screen's appearance.
        let appearance = NSAppearance(named: .aqua) ?? effectiveAppearance
        appearance.performAsCurrentDrawingAppearance {
            NSColor.white.setFill()
            dirtyRect.fill()
            var renderer = CellRenderer(
                sheet: sheet, metrics: metrics, appearance: appearance,
                drawsGridlines: info.map(SheetPrintSettings.printsGridlines) ?? false)
            renderer.drawsCommentMarks = false
            // Borders on a page's edges stay on that page.
            renderer.shownArea = page
            renderer.draw(in: dirtyRect, context: context, gridLineColor: CellRenderer.gridLineColor(for: appearance))
            for object in objects where object.frame.intersects(dirtyRect) {
                draw(object, in: context)
            }
        }
    }

    /// An object across a page break prints on each page it reaches, cut at
    /// the page's edge.
    private func draw(_ object: PrintedObject, in context: CGContext) {
        let frame = object.frame
        switch object.content {
        case .picture(let image):
            NSImage(cgImage: image, size: frame.size).draw(
                in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        case .chart(let chart, let data):
            let renderer = ImageRenderer(content: ChartView(chart: chart, data: data)
                .frame(width: frame.width, height: frame.height)
                .environment(\.colorScheme, .light))
            renderer.proposedSize = ProposedViewSize(frame.size)
            renderer.render { _, render in
                // Drawn the right way up for an unflipped context, as paper is.
                context.saveGState()
                context.translateBy(x: frame.minX, y: frame.maxY)
                context.scaleBy(x: 1, y: -1)
                render(context)
                context.restoreGState()
            }
        }
    }

    /// The charts and pictures on the sheet, in the order the grid stacks
    /// them. Objects Tables keeps but cannot draw print nothing, rather than
    /// the placeholder the grid shows for them.
    private static func objects(on sheet: Worksheet, in workbook: Workbook, metrics: SheetMetrics) -> [PrintedObject] {
        var objects: [PrintedObject] = []
        if !sheet.isChartSheet {
            for chart in sheet.charts {
                let frame = chart.placement.frame(in: metrics)
                guard frame.width > 0, frame.height > 0 else { continue }
                objects.append(PrintedObject(frame: frame, content: .chart(chart, chart.resolved(in: workbook))))
            }
        }
        let controlIDs = Set(sheet.formControls.map(\.id))
        for anchor in sheet.preservedDrawingAnchors {
            guard let placement = anchor.placement, !(anchor.vmlShapeID.map(controlIDs.contains) ?? false),
                  let picture = anchor.picture,
                  let data = workbook.preservedPackage.parts[picture.target],
                  let image = PictureCache.shared.image(for: picture, data: data) else { continue }
            let frame = placement.frame(in: metrics)
            guard frame.width > 0, frame.height > 0 else { continue }
            objects.append(PrintedObject(frame: frame, content: .picture(image)))
        }
        return objects
    }
}

/// The sheet's own print settings, kept in the print info with the paper
/// and margins.
enum SheetPrintSettings {
    static let gridlinesKey = NSPrintInfo.AttributeKey("TablesPrintsGridlines")

    static func printsGridlines(_ info: NSPrintInfo) -> Bool {
        (info.dictionary()[gridlinesKey] as? NSNumber)?.boolValue ?? false
    }

    static func setPrintsGridlines(_ isOn: Bool, in info: NSPrintInfo) {
        info.dictionary()[gridlinesKey] = NSNumber(value: isOn)
    }
}

/// The print panel's own section for a sheet: whether to print gridlines.
@MainActor
final class SheetPrintAccessory: NSViewController, NSPrintPanelAccessorizing {
    private let checkbox = NSButton(checkboxWithTitle: String(localized: "Mac.Print.Gridlines"), target: nil, action: nil)

    private var info: NSPrintInfo? { representedObject as? NSPrintInfo }

    @objc dynamic var printsGridlines = false {
        didSet {
            if let info { SheetPrintSettings.setPrintsGridlines(printsGridlines, in: info) }
            checkbox.state = printsGridlines ? .on : .off
        }
    }

    override var representedObject: Any? {
        didSet {
            if let info, SheetPrintSettings.printsGridlines(info) != printsGridlines {
                printsGridlines = SheetPrintSettings.printsGridlines(info)
            }
        }
    }

    override func loadView() {
        title = String(localized: "Mac.Print.Title")
        checkbox.target = self
        checkbox.action = #selector(toggleGridlines(_:))
        checkbox.state = printsGridlines ? .on : .off
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        view.addSubview(checkbox)
        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            checkbox.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
            checkbox.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            checkbox.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
        ])
        self.view = view
    }

    @objc private func toggleGridlines(_ sender: NSButton) {
        printsGridlines = sender.state == .on
    }

    nonisolated func localizedSummaryItems() -> [[NSPrintPanel.AccessorySummaryKey: String]] {
        MainActor.assumeIsolated {
            [[
                .itemName: String(localized: "Mac.Print.GridlinesSummary"),
                .itemDescription: printsGridlines ? String(localized: "Mac.Print.On") : String(localized: "Mac.Print.Off"),
            ]]
        }
    }

    nonisolated func keyPathsForValuesAffectingPreview() -> Set<String> {
        ["printsGridlines"]
    }
}
