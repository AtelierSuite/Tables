import AppKit
import SwiftUI
import TablesEngine

/// A sheet laid out for printing, as its page setup asks: the print area,
/// or else every row and column out to the last cell with anything in it,
/// with the charts and pictures floating over them, drawn as the grid draws
/// them, without the selection or comment marks.
///
/// The view is a stack of whole sheets of paper. Each holds one page of
/// cells, cut by `PrintPagination` between rows and between columns, inside
/// the sheet's margins and at its scale, with the title rows and columns
/// again beside them, and the header and footer in the margins. Gridlines
/// print when the sheet or the print panel asks for them.
@MainActor
final class SheetPrintView: NSView {
    private let sheet: Worksheet
    private let workbook: Workbook
    private let metrics: SheetMetrics
    private let objects: [PrintedObject]
    private let areas: [CellRange]
    private let setup: PrintSetup
    private let fileName: String
    private var layout: Layout?

    /// A chart or picture, where it sits on the sheet.
    private struct PrintedObject {
        enum Content {
            case chart(TablesEngine.Chart, ResolvedChart)
            case picture(CGImage)
            case shape(DrawingShape)
        }

        let frame: CGRect
        let content: Content
    }

    /// The pages for one paper size, and how they sit on it.
    private struct Layout {
        var paper: CGSize
        /// The paper inside the sheet's margins.
        var content: CGRect
        /// Sheet points to paper points.
        var scale: CGFloat
        var pages: [PrintPagination.Page]
    }

    init(sheet: Worksheet, in workbook: Workbook, fileName: String = "") {
        self.sheet = sheet
        self.workbook = workbook
        self.fileName = fileName
        // Whether gridlines print is the print settings' say, not the
        // sheet's view of them on screen.
        var printed = sheet
        printed.showsGridLines = true
        let metrics = SheetMetrics(sheet: printed)
        self.metrics = metrics
        let objects = Self.objects(on: sheet, in: workbook, metrics: metrics)
        self.objects = objects
        let setup = workbook.printSetup(of: sheet.id)
        self.setup = setup
        if setup.areas.isEmpty {
            areas = [PrintPagination.printedRange(of: sheet, objectFrames: objects.map(\.frame), metrics: metrics)
                ?? CellRange(CellAddress(row: 0, column: 0))]
        } else {
            areas = setup.areas
        }
        super.init(frame: CGRect(x: 0, y: 0, width: 612, height: 792))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    /// Puts the sheet's paper, orientation and gridlines into the print
    /// info, and takes the margins out of it: the view draws whole sheets of
    /// paper and keeps the sheet's own margins itself, so that the header
    /// and footer can go in them.
    static func apply(_ setup: PageSetup, to info: NSPrintInfo) {
        if let paper = setup.paperSize.flatMap(PaperSize.known(code:)) {
            info.orientation = .portrait
            info.paperSize = CGSize(width: paper.width, height: paper.height)
        }
        info.orientation = setup.orientation == .landscape ? .landscape : .portrait
        info.leftMargin = 0
        info.rightMargin = 0
        info.topMargin = 0
        info.bottomMargin = 0
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        SheetPrintSettings.setPrintsGridlines(setup.printsGridlines, in: info)
    }

    // MARK: - Pages

    /// The pages, cut for the paper and scale chosen in the print panel,
    /// which change while it is open.
    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        let info = NSPrintOperation.current?.printInfo ?? NSPrintInfo.shared
        let layout = makeLayout(for: info)
        self.layout = layout
        let count = max(1, layout.pages.count)
        setFrameSize(CGSize(width: layout.paper.width, height: layout.paper.height * CGFloat(count)))
        range.pointee = NSRange(location: 1, length: count)
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect {
        guard let layout else { return bounds }
        return CGRect(x: 0, y: layout.paper.height * CGFloat(page - 1), width: layout.paper.width, height: layout.paper.height)
    }

    private func makeLayout(for info: NSPrintInfo) -> Layout {
        // The print panel's own scale grows or shrinks the whole sheet of paper.
        let panelScale = info.scalingFactor > 0 ? info.scalingFactor : 1
        let paper = CGSize(width: info.paperSize.width / panelScale, height: info.paperSize.height / panelScale)
        let margins = setup.page.margins
        var content = CGRect(
            x: margins.left * 72, y: margins.top * 72,
            width: paper.width - (margins.left + margins.right) * 72,
            height: paper.height - (margins.top + margins.bottom) * 72)
        // Margins wider than the paper leave the whole of it.
        if content.width < 36 || content.height < 36 { content = CGRect(origin: .zero, size: paper) }

        let scale: CGFloat
        if setup.page.fitsToPages {
            scale = PrintPagination.fittedScale(
                areas: areas, metrics: metrics, pageSize: content.size, titles: setup.titles,
                wide: setup.page.fitWide, tall: setup.page.fitTall)
        } else {
            scale = CGFloat(setup.page.scale) / 100
        }
        // Excel leaves manual breaks out when fitting to pages.
        let breaks = setup.page.fitsToPages ? (rows: Set<Int>(), columns: Set<Int>()) : sheet.manualPageBreaks
        let pagination = PrintPagination(
            areas: areas, metrics: metrics,
            pageSize: CGSize(width: content.width / scale, height: content.height / scale),
            titles: setup.titles, rowBreaks: breaks.rows, columnBreaks: breaks.columns)
        return Layout(paper: paper, content: content, scale: scale, pages: pagination.pages)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let layout = self.layout ?? makeLayout(for: NSPrintOperation.current?.printInfo ?? NSPrintInfo.shared)
        let info = NSPrintOperation.current?.printInfo
        // Paper is white, whatever the screen's appearance.
        let appearance = NSAppearance(named: .aqua) ?? effectiveAppearance
        appearance.performAsCurrentDrawingAppearance {
            NSColor.white.setFill()
            dirtyRect.fill()
            var renderer = CellRenderer(
                sheet: sheet, metrics: metrics, appearance: appearance,
                drawsGridlines: info.map(SheetPrintSettings.printsGridlines) ?? setup.page.printsGridlines)
            renderer.drawsCommentMarks = false
            for (index, page) in layout.pages.enumerated() {
                let paper = CGRect(
                    x: 0, y: layout.paper.height * CGFloat(index), width: layout.paper.width, height: layout.paper.height)
                guard paper.intersects(dirtyRect) else { continue }
                context.saveGState()
                context.translateBy(x: paper.minX, y: paper.minY)
                draw(page, in: layout, renderer: renderer, context: context)
                drawHeaderAndFooter(page: index + 1, of: layout.pages.count, in: layout)
                context.restoreGState()
            }
        }
    }

    /// One page's cells on its sheet of paper, whose top left is the origin:
    /// the title rows and columns, when it has them, then its own cells
    /// below and to the right of those.
    private func draw(_ page: PrintPagination.Page, in layout: Layout, renderer: CellRenderer, context: CGContext) {
        func frame(rows: Range<Int>, columns: Range<Int>) -> CGRect {
            metrics.frame(for: CellRange(
                start: CellAddress(row: rows.lowerBound, column: columns.lowerBound),
                end: CellAddress(row: rows.upperBound - 1, column: columns.upperBound - 1)))
        }
        let titleHeight = page.titleRows.map { frame(rows: $0, columns: page.columns).height } ?? 0
        let titleWidth = page.titleColumns.map { frame(rows: page.rows, columns: $0).width } ?? 0
        let used = CGSize(
            width: (titleWidth + page.frame.width) * layout.scale, height: (titleHeight + page.frame.height) * layout.scale)
        var origin = layout.content.origin
        if setup.page.centersHorizontally { origin.x += max(0, (layout.content.width - used.width) / 2) }
        if setup.page.centersVertically { origin.y += max(0, (layout.content.height - used.height) / 2) }

        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y)
        context.scaleBy(x: layout.scale, y: layout.scale)
        var parts: [(cells: CGRect, at: CGPoint)] = [(page.frame, CGPoint(x: titleWidth, y: titleHeight))]
        if let rows = page.titleRows {
            parts.append((frame(rows: rows, columns: page.columns), CGPoint(x: titleWidth, y: 0)))
        }
        if let columns = page.titleColumns {
            parts.append((frame(rows: page.rows, columns: columns), CGPoint(x: 0, y: titleHeight)))
        }
        if let rows = page.titleRows, let columns = page.titleColumns {
            parts.append((frame(rows: rows, columns: columns), .zero))
        }
        for part in parts {
            context.saveGState()
            context.clip(to: CGRect(origin: part.at, size: part.cells.size))
            context.translateBy(x: part.at.x - part.cells.minX, y: part.at.y - part.cells.minY)
            var renderer = renderer
            // Borders on a page's edges stay on that page.
            renderer.shownArea = part.cells
            renderer.draw(in: part.cells, context: context, gridLineColor: CellRenderer.gridLineColor(for: .init(named: .aqua)!))
            for object in objects where object.frame.intersects(part.cells) {
                draw(object, in: context)
            }
            context.restoreGState()
        }
        context.restoreGState()
    }

    /// The header and footer, in the margins: each a left, middle and right
    /// part, between the sheet's side margins.
    private func drawHeaderAndFooter(page: Int, of count: Int, in layout: Layout) {
        let header = setup.page.header, footer = setup.page.footer
        guard !header.isEmpty || !footer.isEmpty else { return }
        let now = Date()
        let fields = HeaderFooterText.Fields(
            page: page, pageCount: count,
            date: now.formatted(date: .numeric, time: .omitted), time: now.formatted(date: .omitted, time: .shortened),
            fileName: fileName, sheetName: sheet.name)
        let margins = setup.page.margins
        let band = CGRect(
            x: layout.content.minX, y: 0, width: layout.content.width, height: layout.paper.height)

        func draw(_ code: String, alignment: NSTextAlignment, isHeader: Bool) {
            let text = HeaderFooterText.printed(code, fields: fields)
            guard !text.isEmpty else { return }
            let style = NSMutableParagraphStyle()
            style.alignment = alignment
            let string = NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.black, .paragraphStyle: style,
            ])
            let height = ceil(string.boundingRect(
                with: CGSize(width: band.width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin]).height)
            let y = isHeader ? margins.header * 72 : layout.paper.height - margins.footer * 72 - height
            string.draw(with: CGRect(x: band.minX, y: y, width: band.width, height: height), options: [.usesLineFragmentOrigin])
        }
        for (text, isHeader) in [(header, true), (footer, false)] {
            draw(text.left, alignment: .left, isHeader: isHeader)
            draw(text.center, alignment: .center, isHeader: isHeader)
            draw(text.right, alignment: .right, isHeader: isHeader)
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
            render(ChartView(chart: chart, data: data), in: frame, context: context)
        case .shape(let shape):
            render(DrawingShapeView(shape: shape), in: frame, context: context)
        }
    }

    private func render(_ view: some View, in frame: CGRect, context: CGContext) {
        let renderer = ImageRenderer(content: view
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

    /// The charts, pictures and shapes on the sheet, in the order the grid
    /// stacks them. Objects Tables keeps but cannot draw print nothing, rather than
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
            guard let placement = anchor.placement, !(anchor.vmlShapeID.map(controlIDs.contains) ?? false) else { continue }
            let frame = placement.frame(in: metrics)
            guard frame.width > 0, frame.height > 0 else { continue }
            if let picture = anchor.picture, let data = workbook.preservedPackage.parts[picture.target],
               let image = PictureCache.shared.image(for: picture, data: data) {
                objects.append(PrintedObject(frame: frame, content: .picture(image)))
            } else if let shape = anchor.shape {
                objects.append(PrintedObject(frame: frame, content: .shape(shape)))
            }
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
