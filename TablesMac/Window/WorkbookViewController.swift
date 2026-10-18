import AppKit
import SwiftUI
import TablesEngine

/// The inside of a workbook window: the formula bar, the grid with its
/// headers, and the sheet tabs. Answers the menu bar for whatever is in
/// front — see `WorkbookViewController+Actions`.
@MainActor
final class WorkbookViewController: NSViewController {
    weak var document: WorkbookDocument? {
        didSet { connect() }
    }

    let formulaBar = FormulaBar()
    let grid = GridView()
    let scrollView = NSScrollView()
    let tabBar = SheetTabBar()
    let findBar = FindBar()
    private var findBarHeight: NSLayoutConstraint?
    /// A chart sheet shows its one chart in the grid's place.
    private let chartSheet = ChartContentView()
    private var columnHeader: HeaderRulerView?
    private var rowHeader: HeaderRulerView?
    /// The last error shown, so one is not raised twice.
    private var presentedError: String?
    /// What the shared colour panel is picking a colour for.
    var colorTarget = ColorTarget.fill
    /// The popover the comment on the selected cell is shown in.
    var commentPopover: NSPopover?
    /// The popover the selected chart is edited in.
    var chartPopover: NSPopover?
    var hostedWorkbook: HostedWorkbook?

    private static let tabBarHeight: CGFloat = 46

    override func loadView() {
        let root = NSView()
        root.setFrameSize(NSSize(width: 1080, height: 720))

        scrollView.documentView = grid
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .underPageBackgroundColor
        scrollView.borderType = .noBorder
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: Self.tabBarHeight, right: 0)
        scrollView.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: Self.tabBarHeight, right: 0)

        let columns = HeaderRulerView(scrollView: scrollView, orientation: .horizontalRuler)
        let rows = HeaderRulerView(scrollView: scrollView, orientation: .verticalRuler)
        scrollView.horizontalRulerView = columns
        scrollView.verticalRulerView = rows
        scrollView.hasHorizontalRuler = true
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        columns.clientView = grid
        rows.clientView = grid
        columnHeader = columns
        rowHeader = rows

        chartSheet.isHidden = true
        formulaBar.grid = grid
        grid.formulaBarField = { [weak self] in self?.formulaBar.formulaField }

        findBar.isHidden = true
        findBar.onClose = { [weak self] in self?.setFindBarShown(false) }
        for view in [formulaBar, findBar, scrollView, chartSheet, tabBar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            formulaBar.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            formulaBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            formulaBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            formulaBar.heightAnchor.constraint(equalToConstant: 36),
            findBar.topAnchor.constraint(equalTo: formulaBar.bottomAnchor),
            findBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            findBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: findBar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            // Under the tab bar, which is translucent; insets keep the last row
            // clear of it.
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            chartSheet.topAnchor.constraint(equalTo: formulaBar.bottomAnchor, constant: 16),
            chartSheet.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            chartSheet.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            chartSheet.bottomAnchor.constraint(equalTo: tabBar.topAnchor, constant: -16),
            tabBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: Self.tabBarHeight),
        ])
        let height = findBar.heightAnchor.constraint(equalToConstant: 0)
        height.isActive = true
        findBarHeight = height
        view = root

        NotificationCenter.default.addObserver(
            self, selector: #selector(gridDidScroll(_:)),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView
        )
    }

    private func connect() {
        guard let document else { return }
        grid.document = document
        formulaBar.document = document
        findBar.document = document
        tabBar.document = document
        columnHeader?.document = document
        rowHeader?.document = document
        grid.cellMenu = { [weak self] address in self?.cellMenu(for: address) }
        columnHeader?.lineMenu = { [weak self] isColumn, _ in self?.headerMenu(forColumns: isColumn) }
        rowHeader?.lineMenu = { [weak self] isColumn, _ in self?.headerMenu(forColumns: isColumn) }
        tabBar.tabMenu = { [weak self] _ in self?.sheetMenu() }
        refresh()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(grid)
    }

    /// Brings every part of the window up to date with the document.
    func refresh() {
        guard let document, isViewLoaded else { return }
        let sheet = document.activeSheet
        let isChartSheet = sheet.isChartSheet
        scrollView.isHidden = isChartSheet
        chartSheet.isHidden = !isChartSheet
        if isChartSheet, let chart = sheet.charts.first {
            chartSheet.show(chart, data: chart.resolved(in: document.workbook), zoom: 1)
        }
        grid.refresh()
        columnHeader?.refresh()
        rowHeader?.refresh()
        formulaBar.refresh()
        tabBar.refresh()
        view.window?.invalidateCursorRects(for: columnHeader ?? view)
        view.window?.invalidateCursorRects(for: rowHeader ?? view)
        updateTitleSubtitle(for: sheet)
        syncCommentPopover(in: document)
        syncChartPopover(in: document)
        showErrorIfNeeded(in: document)
    }

    private func updateTitleSubtitle(for sheet: Worksheet) {
        view.window?.subtitle = sheet.name
    }

    @objc private func gridDidScroll(_ notification: Notification) {
        columnHeader?.needsDisplay = true
        rowHeader?.needsDisplay = true
    }

    /// Says why an edit could not be made, once.
    private func showErrorIfNeeded(in document: WorkbookDocument) {
        guard let message = document.state.errorMessage, message != presentedError, let window = view.window else {
            return
        }
        presentedError = message
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: String(localized: "Common.OK"))
        alert.beginSheetModal(for: window) { [weak self, weak document] _ in
            document?.state.errorMessage = nil
            self?.presentedError = nil
        }
    }

    // MARK: - Find

    func setFindBarShown(_ shown: Bool) {
        findBar.isHidden = !shown
        findBarHeight?.constant = shown ? 36 : 0
        view.window?.makeFirstResponder(shown ? findBar.searchField : grid)
    }

    // MARK: - Comments

    /// Shows the comment popover while the session asks for it, pointing at
    /// the selected cell, and keeps what it shows up to date.
    private func syncCommentPopover(in document: WorkbookDocument) {
        let state = document.state
        guard state.presentedPanel == .comment, !document.activeSheet.isChartSheet else {
            if let popover = commentPopover, popover.isShown { popover.close() }
            return
        }
        let sheet = document.activeSheet
        let address = state.selectedAddress
        let rect = state.metrics.frame(for: sheet.mergedRange(containing: address) ?? CellRange(address))
        if let popover = commentPopover, popover.isShown {
            (popover.contentViewController as? CommentViewController)?.refresh()
            popover.positioningRect = rect
            return
        }
        let controller = CommentViewController()
        controller.document = document
        _ = controller.view
        controller.refresh(force: true)
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.delegate = self
        grid.scrollToVisible(rect)
        popover.show(relativeTo: rect, of: grid, preferredEdge: .maxX)
        commentPopover = popover
    }

    // MARK: - Charts

    /// Shows the chart editor while the session asks for it, beside the
    /// selected chart, or filling in for a chart sheet's.
    private func syncChartPopover(in document: WorkbookDocument) {
        let state = document.state
        hostedWorkbook?.refresh()
        guard state.presentedPanel == .chart, let chart = state.selectedChart(in: document.workbook) else {
            if let popover = chartPopover, popover.isShown { popover.close() }
            return
        }
        guard chartPopover?.isShown != true else { return }
        let model = hostedWorkbook ?? HostedWorkbook(document: document)
        hostedWorkbook = model
        let popover = NSPopover()
        popover.contentViewController = NSHostingController(rootView: ChartEditor(model: model, state: state))
        popover.behavior = .semitransient
        popover.delegate = self
        if document.activeSheet.isChartSheet {
            popover.show(relativeTo: chartSheet.bounds, of: chartSheet, preferredEdge: .maxX)
        } else {
            let frame = chart.placement.frame(in: state.metrics)
            grid.scrollToVisible(frame)
            popover.show(relativeTo: frame, of: grid, preferredEdge: .maxX)
        }
        chartPopover = popover
    }

    // MARK: - Zoom

    /// Zooms the grid about a point in it, which stays put on screen: the
    /// pointer when it is over the sheet, the selected cell otherwise.
    func setZoom(_ zoom: Double, around anchor: CGPoint? = nil) {
        guard let document else { return }
        let state = document.state
        let clamped = min(max(zoom, EditorState.zoomRange.lowerBound), EditorState.zoomRange.upperBound)
        guard clamped != state.zoom else { return }
        let old = state.metrics
        let point = anchor ?? zoomAnchor(in: document)

        // The anchor as a line and a fraction of it, so it lands on the same
        // spot of the same cell however lines grow.
        let column = old.column(atX: Double(point.x)), row = old.row(atY: Double(point.y))
        let columnFraction = old.width(ofColumn: column) > 0
            ? (Double(point.x) - old.x(ofColumn: column)) / old.width(ofColumn: column) : 0
        let rowFraction = old.height(ofRow: row) > 0
            ? (Double(point.y) - old.y(ofRow: row)) / old.height(ofRow: row) : 0

        state.zoom = clamped
        state.refreshMetrics(in: document.workbook)
        document.notify()
        let new = state.metrics
        let moved = CGPoint(
            x: new.x(ofColumn: column) + columnFraction * new.width(ofColumn: column),
            y: new.y(ofRow: row) + rowFraction * new.height(ofRow: row)
        )
        // Shifting the clip view by as much as the anchor moved keeps it under
        // the pointer, whatever the rulers overlapping the clip view add.
        let clip = scrollView.contentView
        var bounds = clip.bounds
        bounds.origin.x += moved.x - point.x
        bounds.origin.y += moved.y - point.y
        clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
        scrollView.reflectScrolledClipView(clip)
    }

    private func zoomAnchor(in document: WorkbookDocument) -> CGPoint {
        if let window = view.window {
            let pointer = grid.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if grid.visibleRect.contains(pointer) { return pointer }
        }
        let state = document.state
        let cell = state.metrics.frame(for: state.selection.normalized)
        let visible = grid.visibleRect
        return visible.intersects(cell) ? CGPoint(x: cell.midX, y: cell.midY) : CGPoint(x: visible.midX, y: visible.midY)
    }
}

extension WorkbookViewController: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        if (notification.object as? NSPopover) === chartPopover, let document {
            chartPopover = nil
            if document.state.presentedPanel == .chart {
                document.state.presentedPanel = nil
                document.notify()
            }
            return
        }
        guard (notification.object as? NSPopover) === commentPopover, let document else { return }
        commentPopover = nil
        if document.state.presentedPanel == .comment {
            document.state.presentedPanel = nil
            document.notify()
        }
        view.window?.makeFirstResponder(grid)
    }
}
