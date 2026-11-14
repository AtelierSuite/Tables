import SwiftUI
import TablesEngine

/// The scrollable spreadsheet canvas.
///
/// The content is laid out absolutely inside one two-axis `ScrollView`, and only
/// the tiles intersecting the viewport are built. Headers live in an overlay
/// that counter-translates with the scroll offset, which keeps them pinned in
/// both axes without nesting scroll views.
///
/// The cells themselves are drawn rather than built: a tile is a single
/// `Canvas`, and everything that moves independently of them — the selection,
/// the in-cell editor, the menu anchor — is a sibling overlay, so none of it
/// reaches the drawing and none of it makes the grid redraw.
struct SheetGridView: View {
    @Binding var workbook: Workbook
    @Bindable var state: EditorState
    /// Runs the macro a form control was clicked for.
    var runMacro: (FormControl) -> Void = { _ in }
    /// The canvas the sheet is a table on, when it shares one: the grid then
    /// sits where the canvas puts it, among the other tables, with no
    /// headers pinned round it.
    var canvas: SheetCanvas?

    /// Room past the last row and column so the final cells can scroll clear of
    /// the floating controls.
    private let trailingPadding: Double = 120
    private let bottomPadding: Double = 160
    private let columnHeaderHeight: Double = 28
    private let selectionHandleDiameter: Double = 18

    @State private var scrollPosition = ScrollPosition()
    /// Where the pinch in progress began. Nil when no pinch is running.
    @State private var zoomAnchor: ZoomAnchor?
    /// The grid point the selection handle started from, in content coordinates.
    /// Non-nil only while the handle is being dragged.
    @State private var handleDragOrigin: CGPoint?
    /// While a fill handle is dragged, the range letting go would fill.
    @State private var fillTarget: CellRange?
    /// The last cell tapped and when, so a second tap on it can open the menu.
    @State private var lastTap: (address: CellAddress, time: Date)?
    /// Bumped to raise the cell menu from a double tap or a long press.
    @State private var cellMenuTrigger = 0
    /// Bumped to open the selected cell's validation list.
    @State private var listMenuTrigger = 0
    /// The cell the menu was last raised from, which a long press inside a
    /// larger selection leaves somewhere other than the selection's corner.
    @State private var cellMenuAddress: CellAddress?
    @State private var isCellEditorFocused = false
    /// The table whose name is being dragged across the canvas, and how far.
    @State private var tableDrag: (id: Worksheet.ID, offset: CGSize)?
    /// What the dragged table is lined up with, shown while it is.
    @State private var canvasGuides: [CanvasSnapping.Guide] = []
    /// The table being renamed from its menu, and the name typed so far.
    /// The table whose name is being typed in place, and what is typed.
    @State private var renamingTableID: Worksheet.ID?
    @State private var tableNameDraft = ""
    @FocusState private var isTableNameFocused: Bool
    /// What each tile draws, kept while the sheet and its size stay the same,
    /// so that a scroll frame only looks tiles up. A reference held across
    /// updates, which nothing observes: filling it never redraws the grid.
    @State private var tileCache = TileCache()
    /// A chart or picture being moved or resized, shared by the panes that
    /// show parts of it so they move together.
    @State private var objectDrags = FloatingObjectDrags()
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    #if os(macOS)
    /// Where the pointer last was, for the right-click menu to read.
    ///
    /// A reference rather than view state on purpose: the pointer moves
    /// continuously, and invalidating the grid on every mouse move to store a
    /// point nothing draws from would undo the work of not rebuilding it.
    @State private var pointer = PointerLocation()

    private final class PointerLocation {
        var location: CGPoint = .zero
    }
    #endif

    /// Matches the platform's own double-tap window closely enough that a
    /// deliberate double tap always lands and a slow retap never does.
    private static let doubleTapInterval: TimeInterval = 0.4

    private var activeSheet: Worksheet { state.activeSheet(in: workbook) }
    private var metrics: SheetMetrics { state.metrics }

    // MARK: - Canvas

    /// Where the grid's first cell sits in the scrolling content: past the
    /// headers, or at the table's place on its canvas.
    private var gridOrigin: CGPoint {
        guard let canvas, let table = canvas.table(for: activeSheet.id) else {
            return CGPoint(x: rowHeaderWidth, y: columnHeaderHeight)
        }
        let dragged = tableDrag?.id == activeSheet.id ? tableDrag?.offset ?? .zero : .zero
        let page = CanvasSnapping.pageInset(zoom: state.zoom)
        return pixelAligned(CGPoint(
            x: page.x + table.x * state.zoom + dragged.width, y: page.y + table.y * state.zoom + dragged.height
        ))
    }

    /// A table's place on the canvas rounded to whole pixels, so its cells'
    /// edges, snapped within it, stay on them.
    private func pixelAligned(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x * displayScale).rounded() / displayScale, y: (point.y * displayScale).rounded() / displayScale)
    }

    /// How much of the top and leading edges the pinned headers cover.
    private var headerInsets: CGSize {
        canvas == nil ? CGSize(width: rowHeaderWidth, height: columnHeaderHeight) : .zero
    }

    /// How large the scrolling content is: the sheet and some room past it,
    /// or every table on the canvas and a margin round them.
    private var contentExtent: CGSize {
        guard let canvas else {
            return CGSize(width: rowHeaderWidth + metrics.totalWidth + trailingPadding,
                          height: columnHeaderHeight + metrics.totalHeight + bottomPadding)
        }
        let zoom = state.zoom
        let page = CanvasSnapping.pageInset(zoom: zoom)
        var extent = CGSize(width: page.x, height: page.y)
        for sheet in workbook.sheets(on: canvas) {
            guard let table = canvas.table(for: sheet.id) else { continue }
            extent.width = max(extent.width, page.x + (table.x + sheet.totalWidth) * zoom)
            extent.height = max(extent.height, page.y + (table.y + sheet.totalHeight) * zoom)
        }
        return CGSize(width: extent.width + trailingPadding, height: extent.height + bottomPadding)
    }

    private var rowHeaderWidth: Double {
        // Widen the gutter as row numbers get longer.
        44 + Double(max(0, String(activeSheet.rowCount).count - 3)) * 9
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            GeometryReader { proxy in
                grid(in: proxy)
            }
            // Keep headers below the navigation bar, but extend them beneath
            // the floating toolbar just like the scroll view's cells.
            if canvas == nil {
                GeometryReader { proxy in
                    headerOverlay(in: proxy)
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                        .clipped()
                }
                .ignoresSafeArea(.container, edges: .bottom)
            }
        }
        .onChange(of: activeSheet.id) { _, _ in
            state.refreshMetrics(in: workbook)
            // On a canvas, a table just picked or added comes into view.
            if canvas != nil { revealActiveTable() }
        }
        .onChange(of: displayScale, initial: true) { _, scale in
            // Cell edges are snapped to this display's pixels.
            guard state.displayScale != scale else { return }
            state.displayScale = scale
            state.refreshMetrics(in: workbook)
        }
        .onChange(of: activeSheet.rowCount) { _, _ in state.refreshMetrics(in: workbook) }
        .onChange(of: activeSheet.columnCount) { _, _ in state.refreshMetrics(in: workbook) }
        .onChange(of: activeSheet.hiddenRows) { _, _ in state.refreshMetrics(in: workbook) }
        .onChange(of: activeSheet.hiddenColumns) { _, _ in state.refreshMetrics(in: workbook) }
        .onChange(of: activeSheet.columnWidths) { _, _ in state.refreshMetrics(in: workbook) }
        .onChange(of: activeSheet.rowHeights) { _, _ in state.refreshMetrics(in: workbook) }
        .onChange(of: state.scrollTarget) { _, target in
            guard let target else { return }
            scrollIntoView(target)
            state.scrollTarget = nil
        }
        .onChange(of: state.editingAddress) { _, address in
            isCellEditorFocused = address != nil && !state.isFormulaBarActive
        }
    }

    private func grid(in proxy: GeometryProxy) -> some View {
        ScrollView([.horizontal, .vertical]) {
            content
                // At least the viewport in both axes. A sheet small enough to
                // fit leaves the scroll view sizing its content to the grid,
                // and a content box smaller than the viewport gets centred —
                // which drags the headers off the top-left corner and floats
                // the whole sheet in the middle of the screen.
                .frame(
                    width: max(proxy.size.width, contentExtent.width),
                    height: max(proxy.size.height, contentExtent.height),
                    alignment: .topLeading
                )
        }
            .scrollPosition($scrollPosition)
            .scrollBounceBehavior(.basedOnSize)
            // The pinned headers are drawn over the scroll view, so keep the
            // indicators clear of them rather than sliding underneath.
            .contentMargins(.top, headerInsets.height, for: .scrollIndicators)
            .contentMargins(.leading, headerInsets.width, for: .scrollIndicators)
            // Canvas, not paper: the sheet paints its own extent, so anything
            // past the last row and column reads as the space around the sheet
            // rather than as grid that failed to draw.
            .background(canvas == nil ? Color.sheetCanvas : paper(of: activeSheet))
            // `contentOffset` is measured from the scroll view's origin, which
            // sits above the navigation bar's content inset — so it is already
            // negative at rest. Adding the insets back gives distance scrolled
            // from the top-left of the content, which is what the pinned headers
            // and the visible-window maths both want.
            .onScrollGeometryChange(for: ScrollAnchor.self) { geometry in
                ScrollAnchor(
                    offset: CGPoint(
                        x: geometry.contentOffset.x + geometry.contentInsets.leading,
                        y: geometry.contentOffset.y + geometry.contentInsets.top
                    ),
                    insets: CGSize(
                        width: geometry.contentInsets.leading,
                        height: geometry.contentInsets.top
                    )
                )
            } action: { _, anchor in
                state.scrollOffset = anchor.offset
                state.scrollInsets = anchor.insets
            }
            .simultaneousGesture(zoomGesture)
            .onAppear {
                state.viewportSize = proxy.size
                state.refreshMetrics(in: workbook)
            }
            .onChange(of: proxy.size) { _, size in state.viewportSize = size }
    }

    // MARK: - Zoom

    private var zoomGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .onChanged { value in
                let anchor = zoomAnchor ?? ZoomAnchor(
                    zoom: state.zoom,
                    scrollOffset: state.scrollOffset,
                    location: value.startLocation,
                    headers: headerInsets,
                    viewport: state.viewportSize
                )
                zoomAnchor = anchor
                let target = (anchor.zoom * value.magnification)
                    .clamped(to: EditorState.zoomRange)
                guard abs(target - state.zoom) > 0.001 else { return }
                state.zoom = target
                state.refreshMetrics(in: workbook)
                // The metrics have already grown, so the content box the new
                // offset is clamped against is the one being scrolled.
                let offset = anchor.scrollOffset(at: target, contentSize: contentExtent)
                // Back into the raw offsets `ScrollPosition` works in, and
                // without an animation: the pinch is already the animation.
                scrollPosition.scrollTo(point: CGPoint(
                    x: offset.x - state.scrollInsets.width,
                    y: offset.y - state.scrollInsets.height
                ))
            }
            .onEnded { _ in zoomAnchor = nil }
    }

    // MARK: - Visible window

    private var visibleRows: Range<Int> {
        let top = state.scrollOffset.y - gridOrigin.y + headerInsets.height - columnHeaderHeight
        let height = max(state.viewportSize.height, 200)
        return metrics.rows(in: max(0, top)...max(0, top + height))
    }

    /// The columns with a header showing: the frozen ones, then whatever
    /// has scrolled into view past them.
    private var headerColumns: [Int] {
        let frozen = activeSheet.frozenColumns
        return Array(0..<min(frozen, metrics.columnCount)) + visibleColumns.filter { $0 >= frozen }
    }

    /// What a sheet's cells without a fill of their own show through to.
    private func paper(of sheet: Worksheet) -> Color {
        sheet.backgroundColor(for: colorScheme) ?? .sheetBackground
    }

    private var visibleColumns: Range<Int> {
        let left = state.scrollOffset.x - gridOrigin.x + headerInsets.width - rowHeaderWidth
        let width = max(state.viewportSize.width, 200)
        return metrics.columns(in: max(0, left)...max(0, left + width))
    }

    // MARK: - Content

    private var content: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(paper(of: activeSheet))
                .frame(width: metrics.totalWidth, height: metrics.totalHeight)

            tiles
            if !state.isTableUnfocused { selectionOverlay() }
            validationOverlay
            floatingObjects(in: scrollingWindow, pane: nil)
            editorOverlay
            cellMenuAnchor
        }
        .padding(.leading, gridOrigin.x)
        .padding(.top, gridOrigin.y)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(alignment: .topLeading) {
            if let canvas { canvasTables(canvas) }
        }
        .overlay(alignment: .topLeading) {
            if let canvas { canvasHeaderLayer(canvas) }
        }
        .overlay(alignment: .topLeading) {
            if !canvasGuides.isEmpty { guideLines }
        }
        // The page between the tables, and past the sheet's last row and
        // column. The cells and names take their own taps first.
        .contentShape(.rect)
        .onTapGesture { tapOutsideCells() }
    }

    /// A tap where there is no cell puts away whatever is being typed: the
    /// cell being edited, which keeps what was typed, or a table's new name.
    /// On a canvas's page, or beside a Numbers sheet's one table, it also
    /// leaves no table worked on, as in Numbers.
    private func tapOutsideCells() {
        lastTap = nil
        endRenamingTable()
        if state.editingAddress != nil { state.commitEditing(in: &workbook, then: nil) }
        if canvas != nil || state.isNumbersDocument { state.unfocusTables() }
    }

    /// The drawn grid, plus the one tap and one long press that serve all of it.
    ///
    /// Both gestures live here rather than on the cells so that the sheet can be
    /// drawn instead of built. They read the cell out of the touch point, which
    /// the metrics already answer in constant time.
    private var tiles: some View {
        // The sheet and the window are resolved once and handed down. Both are
        // computed properties reaching through the workbook, and a tile asking
        // for them apiece is work repeated on every scroll frame.
        let sheet = activeSheet
        let plans = Self.tilePlans(rows: visibleRows, columns: visibleColumns, metrics: metrics)
        let drawing = tileCache.tiles(of: sheet, metrics: metrics)
        let scheme = drawing.scheme(for: colorScheme)

        return ZStack(alignment: .topLeading) {
            ForEach(plans) { plan in
                let frame = metrics.frame(for: plan.range)
                GridTileView(
                    rows: plan.rows,
                    columns: plan.columns,
                    origin: frame.origin,
                    size: frame.size,
                    hiddenRows: sheet.hiddenRows,
                    hiddenColumns: sheet.hiddenColumns,
                    contents: contents(of: plan, in: sheet, drawing: drawing, metrics: metrics),
                    metrics: metrics,
                    scheme: scheme
                )
                .equatable()
            }
        }
        .frame(width: metrics.totalWidth, height: metrics.totalHeight, alignment: .topLeading)
        .contentShape(.rect)
        .onTapGesture(coordinateSpace: .local) { point in
            // SwiftUI hands a tap to a view the finger only came near, and the
            // nearest cell is no answer for a tap on the page beside the grid.
            guard metrics.contains(point) else { return tapOutsideCells() }
            tap(address(at: point))
        }
        #if canImport(UIKit)
        // A long press raises the same menu the double tap does. It comes from
        // UIKit rather than from a SwiftUI gesture because only UIKit's
        // recognizer says *where* the press landed, which is the whole question
        // once the cells are drawn instead of built.
        .overlay { LongPressLocator { point in raiseCellMenu(at: point) } }
        // Hold the selection with one finger and pick further ranges with
        // another. Landing that second finger before the press above fires is
        // what tells the two apart, and doing so cancels it.
        .overlay {
            MultiRangeSelector(
                isHoldable: { point in canHoldSelection(at: point) },
                onBeginRange: { point in state.addRange(startingAt: address(at: point), in: activeSheet) },
                onExtendRange: { point in
                    state.select(address(at: point), extending: true, in: activeSheet)
                },
                onFinish: {}
            )
        }
        #endif
        #if os(macOS)
        .onContinuousHover(coordinateSpace: .local) { phase in
            if case .active(let point) = phase { pointer.location = point }
        }
        .contextMenu { HeaderActionMenu(actions: cellActions(for: address(at: pointer.location))) }
        #endif
    }

    // MARK: - Canvas tables

    /// The canvas's other tables, drawn where they sit, and every table's
    /// name above it, which a tap edits in place. A tap on another table
    /// makes it the one worked on.
    private func canvasTables(_ canvas: SheetCanvas) -> some View {
        let zoom = state.zoom
        let active = activeSheet.id
        let page = CanvasSnapping.pageInset(zoom: zoom)
        return ZStack(alignment: .topLeading) {
            ForEach(workbook.sheets(on: canvas)) { sheet in
                if let table = canvas.table(for: sheet.id) {
                    let dragged = tableDrag?.id == sheet.id ? tableDrag?.offset ?? .zero : .zero
                    let origin = pixelAligned(CGPoint(
                        x: page.x + table.x * zoom + dragged.width, y: page.y + table.y * zoom + dragged.height
                    ))
                    if sheet.id != active {
                        canvasTable(sheet, at: origin, zoom: zoom)
                    }
                    Rectangle()
                        .strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1)
                        .frame(width: sheet.totalWidth * zoom + 2, height: sheet.totalHeight * zoom + 2)
                        .offset(x: origin.x - 1, y: origin.y - 1)
                        .allowsHitTesting(false)
                    if table.showsName {
                        // Above the headers of the table worked on, and straight on top of any other.
                        let focused = sheet.id == active && !state.isTableUnfocused
                        tableName(of: sheet, isActive: sheet.id == active, isFocused: focused, zoom: zoom)
                            .offset(x: origin.x,
                                    y: origin.y - CanvasChrome.nameOffset(zoom: zoom, showsHeaders: focused))
                    }
                }
            }
        }
    }

    /// The headers round the table being worked on, in a layer of their own
    /// so only they fade as tables are picked. They go over the grid, as a
    /// sheet's own do, so the selection's grip on a cell beside them can't
    /// take a drag meant for the line between two of them.
    private func canvasHeaderLayer(_ canvas: SheetCanvas) -> some View {
        let active = activeSheet.id
        return ZStack(alignment: .topLeading) {
            ForEach(workbook.sheets(on: canvas)) { sheet in
                if sheet.id == active, !state.isTableUnfocused, canvas.table(for: sheet.id) != nil {
                    canvasHeaders(for: sheet)
                        .offset(x: gridOrigin.x, y: gridOrigin.y)
                        .transition(.opacity)
                }
            }
        }
        // What a dragged table passes over shows through its headers.
        .opacity(isMovingTable ? CanvasChrome.draggingOpacity : 1)
        .animation(.easeOut(duration: CanvasChrome.fadeDuration), value: active)
        .animation(.easeOut(duration: CanvasChrome.fadeDuration), value: state.isTableUnfocused)
        .animation(.easeOut(duration: CanvasChrome.fadeDuration), value: isMovingTable)
    }

    /// Resizes the nearest shown line before `index`, for the grip on the
    /// leading edge of its header; nil when there is none.
    private func resizer(
        forLineBefore index: Int, hidden: Set<Int>, resize: @escaping (Int, Double) -> Void
    ) -> ((Double) -> Void)? {
        var line = index - 1
        while line >= 0, hidden.contains(line) { line -= 1 }
        guard line >= 0 else { return nil }
        return { [line] delta in resize(line, delta) }
    }

    /// Whether a table is being dragged away from where it rests.
    private var isMovingTable: Bool {
        guard let tableDrag else { return false }
        return tableDrag.offset != .zero
    }

    /// The column letters and row numbers round the table being worked on,
    /// laid out from its first cell, in the room every table keeps for
    /// them. The corner where they meet is the handle the table is moved
    /// by, and a tap there selects all of it.
    private func canvasHeaders(for sheet: Worksheet) -> some View {
        let barHeight = Double(CanvasChrome.columnHeaderHeight)
        let barWidth = Double(CanvasChrome.rowHeaderWidth(rowCount: sheet.rowCount))
        let columns = visibleColumns.filter { $0 < metrics.columnCount && !sheet.hiddenColumns.contains($0) }
        let rows = visibleRows.filter { $0 < metrics.rowCount && !sheet.hiddenRows.contains($0) }
        return ZStack(alignment: .topLeading) {
            Color.headerBackground.background(.regularMaterial)
                .frame(width: metrics.totalWidth, height: barHeight)
                .offset(y: -barHeight)
            Color.headerBackground.background(.regularMaterial)
                .frame(width: barWidth, height: metrics.totalHeight)
                .offset(x: -barWidth)
            ForEach(columns, id: \.self) { column in
                ColumnHeaderCell(
                    title: CellAddress.columnName(column),
                    width: metrics.width(ofColumn: column), height: barHeight,
                    isSelected: !state.isTableUnfocused && state.selectedRanges.contains { $0.columnRange.contains(column) },
                    isHiddenNeighbor: sheet.hiddenColumns.contains(column + 1),
                    onSelect: { state.selectEntireColumns(column...column, in: activeSheet) },
                    onResize: { delta in
                        state.resizeColumn(column, to: (metrics.width(ofColumn: column) + delta) / metrics.zoom, in: &workbook)
                    },
                    onResizePrevious: resizer(forLineBefore: column, hidden: sheet.hiddenColumns) { line, delta in
                        state.resizeColumn(line, to: (metrics.width(ofColumn: line) + delta) / metrics.zoom, in: &workbook)
                    },
                    onFit: { state.fitColumn(column, in: &workbook) },
                    actions: {
                        HeaderMenuBuilder(axis: .column, index: column, workbook: $workbook, state: state).actions()
                    }
                )
                .offset(x: metrics.x(ofColumn: column), y: -barHeight)
            }
            ForEach(rows, id: \.self) { row in
                RowHeaderCell(
                    title: String(row + 1),
                    width: barWidth, height: metrics.height(ofRow: row),
                    isSelected: !state.isTableUnfocused && state.selectedRanges.contains { $0.rowRange.contains(row) },
                    isHiddenNeighbor: sheet.hiddenRows.contains(row + 1),
                    onSelect: { state.selectEntireRows(row...row, in: activeSheet) },
                    onResize: { delta in
                        state.resizeRow(row, to: (metrics.height(ofRow: row) + delta) / metrics.zoom, in: &workbook)
                    },
                    onResizePrevious: resizer(forLineBefore: row, hidden: sheet.hiddenRows) { line, delta in
                        state.resizeRow(line, to: (metrics.height(ofRow: line) + delta) / metrics.zoom, in: &workbook)
                    },
                    actions: {
                        HeaderMenuBuilder(axis: .row, index: row, workbook: $workbook, state: state).actions()
                    }
                )
                .offset(x: -barWidth, y: metrics.y(ofRow: row))
            }
            tableHandle(for: sheet, width: barWidth, height: barHeight)
                .offset(x: -barWidth, y: -barHeight)
        }
    }

    @ViewBuilder
    private func tableName(of sheet: Worksheet, isActive: Bool, isFocused: Bool, zoom: Double) -> some View {
        let font = Font.system(size: max(9, 14 * zoom), weight: .semibold)
        let height = (SheetCanvas.nameHeight - 4) * zoom
        if renamingTableID == sheet.id {
            TextField("SheetTabBar.RenameField.Placeholder", text: $tableNameDraft)
                .font(font)
                .textFieldStyle(.plain)
                .focused($isTableNameFocused)
                .submitLabel(.done)
                .onSubmit { endRenamingTable() }
                .onChange(of: isTableNameFocused) { _, focused in if !focused { endRenamingTable() } }
                .frame(width: max(sheet.totalWidth * zoom, 120), height: height, alignment: .bottomLeading)
        } else {
            Text(workbook.tableName(of: sheet.id))
                .font(font)
                .foregroundStyle(isFocused ? Color.primary : Color.secondary)
                .lineLimit(1)
                .frame(height: height, alignment: .bottomLeading)
                .contentShape(.rect)
                .onTapGesture {
                    if !isActive { pickTable(sheet, at: CellAddress(row: 0, column: 0)) }
                    state.refocusTables()
                    beginRenamingTable(sheet.id)
                }
                .contextMenu { HeaderActionMenu(actions: tableActions(for: sheet)) }
                // Light on a dark page, whatever the appearance.
                .environment(\.colorScheme, sheet.isBackgroundDark ? .dark : colorScheme)
        }
    }

    /// Puts a field where a table's name is, to type a new one in.
    private func beginRenamingTable(_ id: Worksheet.ID) {
        guard state.allowsLayingOutTables else { return }
        endRenamingTable()
        // A hidden name has nowhere to be typed, so it shows again.
        if workbook.canvas(containing: id)?.table(for: id)?.showsName == false {
            state.setTableNameShown(true, for: id, in: &workbook)
        }
        tableNameDraft = workbook.tableName(of: id)
        renamingTableID = id
        isTableNameFocused = true
    }

    /// Puts the name typed in place; an empty one leaves the old.
    private func endRenamingTable() {
        guard let id = renamingTableID else { return }
        renamingTableID = nil
        isTableNameFocused = false
        if tableNameDraft != workbook.tableName(of: id) { state.renameTable(id, to: tableNameDraft, in: &workbook) }
    }

    /// The corner where the active table's headers meet: dragged, it
    /// carries the table; tapped, it selects all of it. Its touch area
    /// reaches up and left, away from the cells.
    private func tableHandle(for sheet: Worksheet, width: Double, height: Double) -> some View {
        let movable = state.allowsLayingOutTables
        return ZStack {
            UnevenRoundedRectangle(topLeadingRadius: 5)
                .fill(movable ? Color.accentColor : Color.headerBackground)
            if movable {
                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: width, height: height)
        .padding([.top, .leading], 10)
        .contentShape(.rect)
        .onTapGesture { state.selectAll(in: activeSheet) }
        .gesture(tableDragGesture(for: sheet, zoom: state.zoom))
        .offset(x: -10, y: -10)
        .accessibilityLabel(Text("Canvas.MoveTable"))
        .accessibilityAction(named: Text("Grid.SelectAll")) { state.selectAll(in: activeSheet) }
    }

    /// Carries a table across the canvas, kept on the page and snapping
    /// into line with the others, and puts it down where it is let go.
    private func tableDragGesture(for sheet: Worksheet, zoom: Double) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard state.allowsLayingOutTables, let canvas = workbook.canvas(containing: sheet.id),
                      let table = canvas.table(for: sheet.id) else { return }
                // On screen, as the guides are drawn, and never past the page's corner.
                let page = CanvasSnapping.pageInset(zoom: zoom)
                let resting = CGRect(x: page.x + table.x * zoom, y: page.y + table.y * zoom,
                                     width: sheet.totalWidth * zoom, height: sheet.totalHeight * zoom)
                let others = workbook.sheets(on: canvas).compactMap { other -> CGRect? in
                    guard other.id != sheet.id, let placed = canvas.table(for: other.id) else { return nil }
                    return CGRect(x: page.x + placed.x * zoom, y: page.y + placed.y * zoom,
                                  width: other.totalWidth * zoom, height: other.totalHeight * zoom)
                }
                let snapped = CanvasSnapping.snap(
                    resting.offsetBy(dx: value.translation.width, dy: value.translation.height), among: others,
                    minimum: page)
                tableDrag = (sheet.id, CGSize(width: snapped.origin.x - resting.minX, height: snapped.origin.y - resting.minY))
                canvasGuides = snapped.guides
            }
            .onEnded { _ in
                defer {
                    tableDrag = nil
                    canvasGuides = []
                }
                guard state.allowsLayingOutTables, let offset = tableDrag?.offset,
                      let table = workbook.canvas(containing: sheet.id)?.table(for: sheet.id) else { return }
                state.moveTable(sheet.id, toX: (table.x + offset.width / zoom).rounded(),
                                y: (table.y + offset.height / zoom).rounded(), in: &workbook)
            }
    }

    /// The guides showing what a dragged table is lined up with, on the
    /// page and over everything, the active grid included.
    private var guideLines: some View {
        Path { path in
            for guide in canvasGuides {
                if guide.axis == .vertical {
                    path.addRect(CGRect(x: guide.position - 0.5, y: guide.start, width: 1, height: guide.end - guide.start))
                } else {
                    path.addRect(CGRect(x: guide.start, y: guide.position - 0.5, width: guide.end - guide.start, height: 1))
                }
            }
        }
        .fill(Color.yellow)
        .allowsHitTesting(false)
    }

    /// What a table's name offers when pressed: naming it, moving it to
    /// another sheet or one of its own, and adding another beside it.
    private func tableActions(for sheet: Worksheet) -> [HeaderMenuAction] {
        let showsName = workbook.canvas(containing: sheet.id)?.table(for: sheet.id)?.showsName ?? true
        let arranging = state.allowsArrangingCanvases
        let layingOut = state.allowsLayingOutTables
        let targets = state.canvasTargets(in: workbook).filter { $0.id != sheet.id }
        return [
            HeaderMenuAction(title: String(localized: "Canvas.RenameTable"), symbol: "pencil", isEnabled: layingOut) {
                beginRenamingTable(sheet.id)
            },
            HeaderMenuAction(
                title: String(localized: "Canvas.ShowTableName"), symbol: showsName ? "checkmark" : "",
                isEnabled: layingOut
            ) {
                state.setTableNameShown(!showsName, for: sheet.id, in: &workbook)
            },
            .separator,
            HeaderMenuAction(
                title: String(localized: "Canvas.MoveToSheet"), symbol: "rectangle.on.rectangle",
                isEnabled: arranging && !targets.isEmpty,
                children: targets.map { target in
                    HeaderMenuAction(title: workbook.canvas(containing: target.id)?.name ?? target.name, symbol: "") {
                        state.placeSheet(sheet.id, onCanvasWith: target.id, in: &workbook)
                    }
                }
            ),
            HeaderMenuAction(
                title: String(localized: "Canvas.MoveToOwnSheet"), symbol: "rectangle.portrait.and.arrow.right",
                isEnabled: arranging
            ) {
                state.removeFromCanvas(sheet.id, in: &workbook)
            },
            HeaderMenuAction(title: String(localized: "Canvas.NewTable"), symbol: "plus.rectangle", isEnabled: arranging) {
                state.selectSheet(sheet.id, in: workbook)
                state.addTable(in: &workbook)
            },
            .separator,
            HeaderMenuAction(
                title: String(localized: "SheetTabBar.Menu.Delete"), symbol: "trash", kind: .destructive,
                isEnabled: workbook.sheets.count > 1
            ) {
                state.deleteSheet(sheet.id, in: &workbook)
            },
        ]
    }

    /// Another table on the canvas, drawn only as far as it is in view.
    private func canvasTable(_ sheet: Worksheet, at origin: CGPoint, zoom: Double) -> some View {
        let metrics = tileCache.metrics(of: sheet, zoom: zoom, pixelScale: displayScale)
        let top = state.scrollOffset.y - origin.y
        let left = state.scrollOffset.x - origin.x
        let height = max(state.viewportSize.height, 200), width = max(state.viewportSize.width, 200)
        let rows = metrics.rows(in: max(0, top)...max(0, top + height))
        let columns = metrics.columns(in: max(0, left)...max(0, left + width))
        let plans = top + height < 0 || left + width < 0 ? [] : Self.tilePlans(rows: rows, columns: columns, metrics: metrics)
        let drawing = tileCache.tiles(of: sheet, metrics: metrics)
        let scheme = drawing.scheme(for: colorScheme)

        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(paper(of: sheet))
                .frame(width: metrics.totalWidth, height: metrics.totalHeight)
            ForEach(plans) { plan in
                let frame = metrics.frame(for: plan.range)
                GridTileView(
                    rows: plan.rows, columns: plan.columns,
                    origin: frame.origin, size: frame.size,
                    hiddenRows: sheet.hiddenRows, hiddenColumns: sheet.hiddenColumns,
                    contents: contents(of: plan, in: sheet, drawing: drawing, metrics: metrics),
                    metrics: metrics, scheme: scheme
                )
                .equatable()
            }
        }
        .frame(width: metrics.totalWidth, height: metrics.totalHeight, alignment: .topLeading)
        .clipped()
        .contentShape(.rect)
        .onTapGesture(coordinateSpace: .local) { point in
            // A tap on the page only near the table, which SwiftUI still hands
            // to it, leaves no table worked on rather than picking this one.
            guard metrics.contains(point) else { return tapOutsideCells() }
            pickTable(sheet, at: CellAddress(row: metrics.row(atY: point.y), column: metrics.column(atX: point.x)))
        }
        .offset(x: origin.x, y: origin.y)
    }

    /// Makes another table on the canvas the one worked on, with a cell of
    /// it selected, leaving the canvas scrolled where it is.
    private func pickTable(_ sheet: Worksheet, at address: CellAddress) {
        if state.editingAddress != nil { state.commitEditing(in: &workbook, then: nil) }
        let offset = state.scrollOffset
        state.selectSheet(sheet.id, in: workbook)
        state.scrollOffset = offset
        state.select(sheet.mergedRange(containing: address)?.normalized.start ?? address, in: sheet)
    }

    // MARK: - Tiles

    /// One tile's place in the grid.
    struct TilePlan: Identifiable {
        let id: Int
        let rows: Range<Int>
        let columns: Range<Int>

        var range: CellRange {
            CellRange(
                start: CellAddress(row: rows.lowerBound, column: columns.lowerBound),
                end: CellAddress(row: rows.upperBound - 1, column: columns.upperBound - 1)
            )
        }
    }

    /// Roughly how big a tile should be, before it is rounded to whole lines.
    /// Small enough that a tile scrolling into view is cheap to draw, large
    /// enough that a screenful is a dozen or so of them rather than a hundred.
    private static let tileExtent: Double = 400

    /// The tiles covering a window.
    ///
    /// Bands are cut from the sheet's own line numbering, never from the window:
    /// bands measured from the viewport would shift under every frame and no
    /// tile would ever be reused.
    static func tilePlans(rows: Range<Int>, columns: Range<Int>, metrics: SheetMetrics) -> [TilePlan] {
        guard !rows.isEmpty, !columns.isEmpty else { return [] }
        let rowSpan = tileSpan(extent: metrics.totalHeight, lines: metrics.rowCount)
        let columnSpan = tileSpan(extent: metrics.totalWidth, lines: metrics.columnCount)

        var plans: [TilePlan] = []
        for rowBand in (rows.lowerBound / rowSpan)...((rows.upperBound - 1) / rowSpan) {
            let bandRows = (rowBand * rowSpan)..<min(metrics.rowCount, (rowBand + 1) * rowSpan)
            guard !bandRows.isEmpty else { continue }
            for columnBand in (columns.lowerBound / columnSpan)...((columns.upperBound - 1) / columnSpan) {
                let bandColumns =
                    (columnBand * columnSpan)..<min(metrics.columnCount, (columnBand + 1) * columnSpan)
                guard !bandColumns.isEmpty else { continue }
                plans.append(TilePlan(
                    id: rowBand << 20 | columnBand, rows: bandRows, columns: bandColumns
                ))
            }
        }
        return plans
    }

    /// How many lines make up a band, from the average line size so that zoom
    /// and unusually tall rows both land on a sensible tile.
    private static func tileSpan(extent: Double, lines: Int) -> Int {
        guard lines > 0, extent > 0 else { return 16 }
        let average = extent / Double(lines)
        return max(2, min(64, Int((tileExtent / average).rounded())))
    }

    /// What a tile draws: kept from an earlier frame, or worked out now and
    /// kept for the next.
    private func contents(
        of plan: TilePlan, in sheet: Worksheet, drawing: TileCache.SheetTiles, metrics: SheetMetrics
    ) -> TileContents {
        drawing.contents(of: plan.range) {
            Self.contents(of: plan, in: sheet, lookup: drawing.lookup, metrics: metrics)
        }
    }

    /// Everything inside a tile that has something to draw.
    ///
    /// Blank cells are left out: they need only their separators, which the tile
    /// derives from its line ranges. On a sheet that is mostly empty — which is
    /// most sheets — that is the difference between a handful of entries per
    /// tile and a hundred.
    ///
    /// What a tile holds depends only on which tile it is, never on the tiles
    /// around it or the window they fill, so it can be kept as the sheet
    /// scrolls. `lookup` must be built from this version of `sheet`.
    static func contents(
        of plan: TilePlan, in sheet: Worksheet, lookup: SheetLookup, metrics: SheetMetrics
    ) -> TileContents {
        var painted = TileContents()

        // Merges get a pass of their own rather than being drawn by the cell at
        // their top-left corner: that corner is frequently outside the tile the
        // rest of the region falls in, and the region still has to draw.
        for box in lookup.merges.ranges(intersecting: plan.range) {
            painted.merges.append(PaintedMerge(
                range: box,
                frame: metrics.frame(for: box),
                cell: sheet.displayedCell(at: box.start),
                ownsElement: plan.rows.contains(box.start.row)
                    && plan.columns.contains(box.start.column)
            ))
            let firstRow = max(box.start.row, plan.rows.lowerBound)
            let lastRow = min(box.end.row, plan.rows.upperBound - 1)
            let firstColumn = max(box.start.column, plan.columns.lowerBound)
            let lastColumn = min(box.end.column, plan.columns.upperBound - 1)
            guard firstRow <= lastRow, firstColumn <= lastColumn else { continue }
            for row in firstRow...lastRow {
                for column in firstColumn...lastColumn {
                    painted.covered.insert(CellAddress(row: row, column: column))
                }
            }
        }

        for row in plan.rows where !sheet.hiddenRows.contains(row) {
            for column in plan.columns where !sheet.hiddenColumns.contains(column) {
                let address = CellAddress(row: row, column: column)
                guard !painted.covered.contains(address) else { continue }
                let cell = sheet.displayedCell(at: address)
                guard !cell.isEmptyEntirely else { continue }
                var entry = PaintedCell(address: address, frame: metrics.frame(for: address), cell: cell)
                (entry.overflow, entry.overflowSpan) = overflow(of: address, in: sheet, lookup: lookup, metrics: metrics)
                painted.cells.append(entry)
            }
            spillsFromOutside(row: row, of: plan, in: sheet, lookup: lookup, metrics: metrics, into: &painted)
        }
        borders(of: plan, in: sheet, lookup: lookup, metrics: metrics, into: &painted)
        // A comment on a merged cell marks the whole region's corner, so it
        // is drawn by the tile holding that corner, over the merge's fill.
        for (address, comment, range) in sheet.commentMarks(rows: plan.rows, columns: plan.columns, lookup: lookup) {
            painted.comments.append(CommentMark(
                address: address, frame: metrics.frame(for: range), kind: comment.kind, isResolved: comment.isResolved))
        }
        return painted
    }

    /// The borders of the cells and merges in and around a tile. Each is
    /// centred on a gridline, so half of one on the tile's edge falls inside
    /// the tile, and an edge two cells share is drawn by the one whose border
    /// wins.
    private static func borders(
        of plan: TilePlan, in sheet: Worksheet, lookup: SheetLookup, metrics: SheetMetrics,
        into painted: inout TileContents
    ) {
        let rows = metrics.rowsBordering(plan.rows)
        let columns = metrics.columnsBordering(plan.columns)
        let reach = CellRange(
            start: CellAddress(row: rows.lowerBound, column: columns.lowerBound),
            end: CellAddress(row: rows.upperBound - 1, column: columns.upperBound - 1)
        )
        let resolver = BorderResolver(sheet: sheet, metrics: metrics, near: reach)
        func add(_ region: CellRange) {
            let edges = resolver.drawnBorders(of: region)
            let diagonal = sheet[region.start].style.diagonalBorder
            guard !edges.isEmpty || diagonal?.isVisible == true else { return }
            painted.borders.append(PaintedBorders(frame: metrics.frame(for: region), edges: edges, diagonal: diagonal))
        }
        let nearby = lookup.merges.ranges(intersecting: reach).map(\.normalized)
        nearby.forEach(add)
        for row in rows where !sheet.hiddenRows.contains(row) {
            for column in columns where !sheet.hiddenColumns.contains(column) {
                let address = CellAddress(row: row, column: column)
                guard sheet.cells[address] != nil || sheet.inheritsStyle(at: address) else { continue }
                let style = sheet[address].style
                guard !style.borderSides.isEmpty || style.diagonalBorder != nil,
                      !nearby.contains(where: { $0.contains(address) }) else { continue }
                add(CellRange(address))
            }
        }
    }

    /// How far a cell's text may spill, as a frame and as the columns it
    /// spans. Which of their gridlines make way for it is left to the
    /// painter, which can measure the text.
    private static func overflow(
        of address: CellAddress, in sheet: Worksheet, lookup: SheetLookup, metrics: SheetMetrics
    ) -> (CGRect?, ClosedRange<Int>?) {
        guard let span = sheet.overflowSpan(of: address, lookup: lookup) else { return (nil, nil) }
        let frame = metrics.frame(for: CellRange(
            start: CellAddress(row: address.row, column: span.lowerBound),
            end: CellAddress(row: address.row, column: span.upperBound)
        ))
        return (frame, span)
    }

    /// Text that starts in a cell outside the tile and runs into it. The
    /// nearest filled cell on either side is the only one that can: anything
    /// further away is stopped by it.
    private static func spillsFromOutside(
        row: Int, of plan: TilePlan, in sheet: Worksheet, lookup: SheetLookup, metrics: SheetMetrics,
        into painted: inout TileContents
    ) {
        let reach = 24
        let before = stride(from: plan.columns.lowerBound - 1, through: max(0, plan.columns.lowerBound - reach), by: -1)
        let after = stride(from: plan.columns.upperBound, to: min(sheet.columnCount, plan.columns.upperBound + reach), by: 1)
        for columns in [AnySequence(before), AnySequence(after)] {
            for column in columns {
                let address = CellAddress(row: row, column: column)
                let cell = sheet.displayedCell(at: address)
                guard !cell.isBlank else { continue }
                if let span = sheet.overflowSpan(of: address, reach: reach, lookup: lookup),
                   span.overlaps(plan.columns.lowerBound...(plan.columns.upperBound - 1)) {
                    var entry = PaintedCell(address: address, frame: metrics.frame(for: address), cell: cell)
                    (entry.overflow, entry.overflowSpan) = overflow(of: address, in: sheet, lookup: lookup, metrics: metrics)
                    entry.textOnly = true
                    painted.cells.append(entry)
                }
                break
            }
        }
    }

    /// The cell under a point in the grid's own coordinates.
    private func address(at point: CGPoint) -> CellAddress {
        let address = CellAddress(
            row: metrics.row(atY: point.y), column: metrics.column(atX: point.x)
        )
        // A tap anywhere in a merge is a tap on the merge.
        return activeSheet.mergedRange(containing: address)?.normalized.start ?? address
    }

    /// A tap either points at a cell for the formula being typed, moves the
    /// selection there, or — when it is the second tap on the same cell —
    /// opens the cell menu, which is the same menu a long press raises.
    ///
    /// The double tap is timed here rather than handed to a second
    /// `onTapGesture(count: 2)`, because SwiftUI makes the two counts mutually
    /// exclusive: every single tap is then held for the whole double-tap window
    /// before it is delivered, which is a visible pause on every move between
    /// cells. One immediate gesture and a stopwatch gives the same two
    /// behaviours with the selection landing on touch-up.
    private func tap(_ address: CellAddress) {
        if state.isEnteringFormula {
            state.insertReference(CellRange(address), in: workbook)
            return
        }
        if let last = lastTap, last.address == address,
           Date.now.timeIntervalSince(last.time) < Self.doubleTapInterval {
            lastTap = nil
            cellMenuAddress = address
            cellMenuTrigger += 1
            return
        }
        lastTap = (address, .now)
        state.selectChart(nil)
        if state.editingAddress != nil { state.commitEditing(in: &workbook, then: nil) }
        // A tap on a checkbox ticks it or clears it, and selects its cell.
        if activeSheet[address].style.showsCheckbox { state.toggleCheckbox(at: address, in: &workbook) }
        #if os(macOS)
        state.select(address, extending: NSEvent.modifierFlags.contains(.shift), in: activeSheet)
        #else
        state.select(address, in: activeSheet)
        #endif
    }

    /// Whether a finger resting here is holding the selection, which is what
    /// starts a multi-range gesture. Typing owns its own pointing and dragging,
    /// so it is left alone.
    private func canHoldSelection(at point: CGPoint) -> Bool {
        guard state.editingAddress == nil, !state.isTableUnfocused else { return false }
        return state.isSelected(address(at: point))
    }

    // MARK: - Cell menu

    private func cellActions(for address: CellAddress) -> [HeaderMenuAction] {
        CellMenuBuilder(address: address, workbook: $workbook, state: state).actions()
    }

    /// Moves the selection onto the pressed cell, then raises its menu. A press
    /// inside the selection keeps it, so the menu can act on the whole range —
    /// merging it, for one.
    private func raiseCellMenu(at point: CGPoint) {
        let address = address(at: point)
        state.selectChart(nil)
        if state.editingAddress != nil { state.commitEditing(in: &workbook, then: nil) }
        if !state.selection.normalized.contains(address) || state.isTableUnfocused {
            state.select(address, in: activeSheet)
        }
        cellMenuAddress = address
        cellMenuTrigger += 1
    }

    /// The menu hangs from here.
    ///
    /// One anchor sitting over the selected cell rather than a presenter inside
    /// every cell: a platform view per cell would be paid for on every scroll
    /// frame. It sits over the cell the menu was raised from, which is inside
    /// the selection but not necessarily its first cell.
    private var cellMenuAnchor: some View {
        let address = cellMenuAddress.flatMap { state.selection.normalized.contains($0) ? $0 : nil }
            ?? state.selectedAddress
        let frame = metrics.frame(
            for: activeSheet.mergedRange(containing: address) ?? CellRange(address)
        )
        return NativeMenuPresenter(
            actions: { cellActions(for: address) }, trigger: cellMenuTrigger
        )
            .frame(width: frame.width, height: frame.height)
            .offset(x: frame.minX, y: frame.minY)
    }

    // MARK: - Data validation

    /// The arrow a list rule shows beside the selected cell, which opens the
    /// list, and the rule's input message under the cell.
    @ViewBuilder
    private var validationOverlay: some View {
        let frame = metrics.frame(for: activeSheet.expandedToMerges(CellRange(state.selectedAddress)))
        if state.dropDownRule(in: workbook) != nil {
            let side: Double = 28
            Button {
                listMenuTrigger += 1
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: side, height: side)
                    .background(.background, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("DataValidation.ChooseFromList"))
            .accessibilityIdentifier("dataValidationDropDown")
            // The list hangs from the button, and is built only when asked for.
            .background {
                NativeMenuPresenter(
                    actions: { CellMenuBuilder.listActions(workbook: $workbook, state: state) },
                    trigger: listMenuTrigger)
            }
            .offset(x: frame.maxX + 3, y: frame.midY - side / 2)
        }
        if state.editingAddress == nil, !state.isTableUnfocused, let message = state.inputMessage(in: workbook) {
            VStack(alignment: .leading, spacing: 2) {
                if !message.title.isEmpty { Text(message.title).fontWeight(.semibold) }
                if !message.message.isEmpty { Text(message.message) }
            }
            .font(.caption)
            .multilineTextAlignment(.leading)
            .padding(8)
            .frame(maxWidth: 240, alignment: .leading)
            .fixedSize(horizontal: true, vertical: true)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.gridLine, lineWidth: 1)
            }
            .allowsHitTesting(false)
            .accessibilityIdentifier("dataValidationInputMessage")
            .offset(x: frame.minX + 10, y: frame.maxY + 8)
        }
    }

    // MARK: - Selection

    /// Everything selected: the active range with its fill and drag handle, and
    /// behind it any further ranges picked up by the multi-range gesture.
    ///
    /// A frozen pane draws it too, over its own cells, without the grips:
    /// `interactive` is false there.
    @ViewBuilder
    private func selectionOverlay(interactive: Bool = true) -> some View {
        // A plain `ZStack` of siblings rather than one path over the lot: each
        // range is positioned by its own offset, which is what lets the active
        // one keep the grip and the anchor hole the others do not have.
        ZStack(alignment: .topLeading) {
            if state.isEnteringFormula {
                // The one being pointed at is drawn by the active overlay,
                // which carries the grip for growing it.
                let pending = state.pendingReferenceRange?.normalized
                ForEach(Array(formulaReferences.enumerated()), id: \.offset) { _, reference in
                    if reference.cells != pending {
                        rangeBox(reference.cells, color: FormulaReferenceColors.color(at: reference.colorIndex))
                    }
                }
            } else {
                ForEach(state.additionalSelections, id: \.self) { range in
                    rangeBox(range, color: .accentColor)
                }
            }
            activeSelectionOverlay(interactive: interactive)
        }
    }

    /// The references on this sheet in the formula being typed, each outlined
    /// in the colour it is written in, the way a spreadsheet shows them.
    private var formulaReferences: [FormulaReferenceScanner.Reference] {
        let name = activeSheet.name
        return FormulaReferenceScanner.references(in: state.editingText).filter { reference in
            reference.sheetName.map { $0.caseInsensitiveCompare(name) == .orderedSame } ?? true
        }
    }

    /// The colour of the reference being pointed at, or of the one the next
    /// tap will write, so the grip matches the outline it is growing.
    private var pointingTint: Color {
        let references = formulaReferences
        if let pending = state.pendingReferenceRange?.normalized,
           let reference = references.last(where: { $0.cells == pending }) {
            return FormulaReferenceColors.color(at: reference.colorIndex)
        }
        let nextIndex = (references.map(\.colorIndex).max() ?? -1) + 1
        return FormulaReferenceColors.color(at: nextIndex)
    }

    /// A range outlined beside the active one: one of the ranges held alongside
    /// it, or a reference in the formula being typed. The same wash, and a
    /// quieter border, since it is not what the next edit reads its style from.
    private func rangeBox(_ range: CellRange, color: Color) -> some View {
        let frame = metrics.frame(for: range)
        return RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(color.opacity(0.14))
            .overlay {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .strokeBorder(color.opacity(0.55), lineWidth: 1.5)
            }
            .frame(width: max(frame.width, 1), height: max(frame.height, 1))
            .allowsHitTesting(false)
            .offset(x: frame.minX, y: frame.minY)
    }

    private func activeSelectionOverlay(interactive: Bool) -> some View {
        let box = state.isEnteringFormula
            ? (state.pendingReferenceRange ?? state.selection).normalized
            : state.selection.normalized
        let frame = metrics.frame(for: box)
        let isEditing = state.editingAddress != nil && !state.isEnteringFormula
        let tint: Color = state.isEnteringFormula ? pointingTint : (state.isAutoFilling ? .yellow : .accentColor)

        return ZStack(alignment: .topLeading) {
            // Fill everything but the anchor cell, the way a spreadsheet does.
            Path { path in
                path.addRect(CGRect(origin: .zero, size: frame.size))
                // The anchor is a whole merged region when it lands in one, so
                // the unfilled hole matches what the user sees as one cell.
                let anchor = metrics.frame(
                    for: activeSheet.mergedRange(containing: state.selectedAddress)
                        ?? CellRange(state.selectedAddress)
                )
                if box.contains(state.selectedAddress), !state.isEnteringFormula {
                    path.addRect(anchor.offsetBy(dx: -frame.minX, dy: -frame.minY))
                }
            }
            .fill(tint.opacity(0.14), style: FillStyle(eoFill: true))

            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .strokeBorder(tint, lineWidth: isEditing ? 2.5 : 2)
        }
        .frame(width: max(frame.width, 1), height: max(frame.height, 1))
        // The fill and border are decoration drawn over the cells: they must
        // let taps through, or a tap inside a selected range would land on the
        // overlay and leave the range standing instead of collapsing it. Only
        // the grip takes touches.
        .allowsHitTesting(false)
        .overlay(alignment: .bottomTrailing) {
            if interactive, !isEditing, !state.isAutoFilling { selectionHandle(from: box, tint: tint) }
        }
        .overlay(alignment: .bottom) {
            if interactive, state.isAutoFilling, !isEditing { fillHandle(from: box, vertical: true) }
        }
        .overlay(alignment: .trailing) {
            if interactive, state.isAutoFilling, !isEditing { fillHandle(from: box, vertical: false) }
        }
        .overlay(alignment: .topLeading) {
            if state.isAutoFilling, let fillTarget {
                let preview = metrics.frame(for: fillTarget.normalized)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .strokeBorder(Color.yellow, style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                    .frame(width: preview.width, height: preview.height)
                    .offset(x: preview.minX - frame.minX, y: preview.minY - frame.minY)
                    .allowsHitTesting(false)
            }
        }
        .offset(x: frame.minX, y: frame.minY)
        // Settling into a new range looks good for keyboard and tap selection,
        // but an in-flight drag already tracks the finger — animating it there
        // just lags the grip.
        .animation(handleDragOrigin == nil ? .interactiveSpring(duration: 0.16) : nil, value: box)
    }

    /// Numbers-style corner grip: drag it to grow the selection — or, while a
    /// formula is being typed, to grow the reference being pointed at.
    private func selectionHandle(from box: CellRange, tint: Color) -> some View {
        Color.clear
            .frame(width: selectionHandleDiameter, height: selectionHandleDiameter)
            .glassEffect(.regular.tint(tint).interactive(), in: .circle)
            // A halo in the paper colour keeps the grip legible wherever it
            // lands on dense cell content, in either appearance.
            .background { Circle().fill(Color.sheetBackground).padding(-2) }
            .offset(x: selectionHandleDiameter / 2, y: selectionHandleDiameter / 2)
            .contentShape(.rect.inset(by: -16))
            .gesture(
                // Global space and a translation — never `value.location` in a
                // local space — because the grip rides the selection this
                // gesture is resizing. A moving reference frame would feed the
                // drag back into itself and make the range stutter.
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        let origin = handleDragOrigin ?? cornerPoint(of: box)
                        handleDragOrigin = origin
                        let point = CGPoint(
                            x: origin.x + value.translation.width,
                            y: origin.y + value.translation.height
                        )
                        let target = CellAddress(
                            row: metrics.row(atY: point.y), column: metrics.column(atX: point.x)
                        )
                        if state.isEnteringFormula {
                            let start = state.pendingReferenceRange?.normalized.start ?? target
                            state.insertReference(
                                CellRange(start: start, end: target), in: workbook
                            )
                        } else {
                            state.select(target, extending: true, in: activeSheet)
                        }
                    }
                    .onEnded { _ in handleDragOrigin = nil }
            )
            .accessibilityIdentifier("selectionGrip")
            .accessibilityLabel("Grid.ExtendSelection")
            .accessibilityAddTraits(.isButton)
    }

    /// One of the two fill handles autofill puts on the selection's bottom
    /// and trailing edges, as Numbers does. Dragging one away carries the
    /// selection's series on along that axis; dragging back in clears cells.
    private func fillHandle(from box: CellRange, vertical: Bool) -> some View {
        Image(systemName: vertical ? "chevron.compact.down" : "chevron.compact.right")
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.black)
            .frame(width: vertical ? 34 : 20, height: vertical ? 20 : 34)
            .glassEffect(.regular.tint(.yellow).interactive(), in: .capsule)
            .offset(x: vertical ? 0 : 10, y: vertical ? 10 : 0)
            .contentShape(.rect.inset(by: -14))
            .gesture(
                // Measured as a translation in global space, like the grip,
                // since the handle rides the range it is dragging.
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        let frame = metrics.frame(for: box)
                        let origin = handleDragOrigin ?? (vertical
                            ? CGPoint(x: frame.midX, y: frame.maxY - 1)
                            : CGPoint(x: frame.maxX - 1, y: frame.midY))
                        handleDragOrigin = origin
                        let point = CGPoint(
                            x: origin.x + value.translation.width, y: origin.y + value.translation.height)
                        let toward = vertical
                            ? CellAddress(row: metrics.row(atY: max(0, point.y)), column: box.end.column)
                            : CellAddress(row: box.end.row, column: metrics.column(atX: max(0, point.x)))
                        fillTarget = AutoFill.target(extending: box, toward: toward)
                    }
                    .onEnded { _ in
                        handleDragOrigin = nil
                        defer { fillTarget = nil }
                        guard let target = fillTarget, target.normalized != box else { return }
                        state.fillSelection(to: target, in: &workbook)
                        state.isAutoFilling = false
                    }
            )
            .accessibilityIdentifier(vertical ? "fillHandle.down" : "fillHandle.right")
            .accessibilityLabel(vertical ? "Grid.FillDown" : "Grid.FillRight")
            .accessibilityAddTraits(.isButton)
    }

    /// A point just inside the bottom-right cell of a range — where the grip
    /// sits, and so where a drag from it starts measuring.
    private func cornerPoint(of box: CellRange) -> CGPoint {
        let frame = metrics.frame(for: box)
        return CGPoint(x: frame.maxX - 1, y: frame.maxY - 1)
    }

    // MARK: - Charts

    /// The part of the sheet the scrolling grid has in view, and some way
    /// round it.
    private var scrollingWindow: CGRect {
        CGRect(
            x: state.scrollOffset.x - gridOrigin.x + headerInsets.width,
            y: state.scrollOffset.y - gridOrigin.y + headerInsets.height,
            width: state.viewportSize.width, height: state.viewportSize.height
        )
    }

    /// The charts and kept drawing objects floating over the sheet, above the
    /// cells and the selection — where Excel draws them — and below the
    /// in-cell editor, which must never be covered.
    ///
    /// The scrolling grid has them all (`pane` nil); a frozen pane has those
    /// reaching into its part of the sheet, and its clip cuts them at the
    /// freeze line, so a chart across it shows its frozen part fixed in the
    /// pane and the rest scrolling with the sheet. Each copy works the same:
    /// a tap on any part picks the object out, and a drag of any part moves
    /// all of them.
    ///
    /// Only the ones near `window` are built: a chart is a whole Swift
    /// Charts view, and a sheet can carry dozens.
    @ViewBuilder
    private func floatingObjects(in window: CGRect, pane: FrozenPanes.Pane?) -> some View {
        let sheet = activeSheet
        if !sheet.charts.isEmpty || !sheet.preservedDrawingAnchors.isEmpty || !sheet.formControls.isEmpty {
            let window = window.insetBy(dx: -200, dy: -200)
            let panes = frozenPanesLayout
            let panesShown = arePanesShown
            let isHome = { (frame: CGRect) in Self.isHome(frame, in: pane, of: panes, panesShown: panesShown) }
            let wanted = { (frame: CGRect) in Self.shows(frame, in: pane, of: panes, near: window) }

            // A form control's hidden DrawingML twin gives way to the control.
            let controlIDs = Set(sheet.formControls.map(\.id))

            ZStack(alignment: .topLeading) {
                ForEach(sheet.preservedDrawingAnchors) { anchor in
                    if let placement = anchor.placement, !(anchor.vmlShapeID.map(controlIDs.contains) ?? false) {
                        let frame = placement.frame(in: metrics)
                        if wanted(frame) {
                            keptDrawing(anchor, frame: frame)
                                .accessibilityHidden(!isHome(frame))
                        }
                    }
                }
                ForEach(sheet.charts) { chart in
                    let frame = chart.placement.frame(in: metrics)
                    if wanted(frame) {
                        embeddedChart(chart, frame: frame)
                            .accessibilityHidden(!isHome(frame))
                    }
                }
                ForEach(sheet.formControls) { control in
                    let frame = control.placement.frame(in: metrics)
                    if !control.isHidden, wanted(frame) {
                        formControl(control, frame: frame)
                            .accessibilityHidden(!isHome(frame))
                    }
                }
            }
        }
    }

    /// Whether a pane (nil for the scrolling grid) builds a floating object
    /// near its part of the sheet.
    private static func shows(
        _ frame: CGRect, in pane: FrozenPanes.Pane?, of panes: FrozenPanes, near window: CGRect
    ) -> Bool {
        guard frame.intersects(window), frame.width > 0, frame.height > 0 else { return false }
        guard let pane else { return true }
        return panes.shows(frame, in: pane)
    }

    /// Whether a pane's copy of a floating object is the one in the pane it
    /// belongs to, which alone is offered to accessibility.
    private static func isHome(
        _ frame: CGRect, in pane: FrozenPanes.Pane?, of panes: FrozenPanes, panesShown: Bool
    ) -> Bool {
        guard panesShown else { return pane == nil }
        return panes.home(of: frame) == (pane ?? .scrolling)
    }

    private func formControl(_ control: FormControl, frame: CGRect) -> some View {
        let sheet = activeSheet
        let checkState: FormControl.CheckState
        if control.kind == .optionButton, let index = sheet.formControls.firstIndex(where: { $0.id == control.id }) {
            checkState = sheet.isOptionChosen(index, in: workbook) ? .checked : .unchecked
        } else {
            checkState = control.checkState(in: workbook)
        }
        func finishEditing() {
            if state.editingAddress != nil { state.commitEditing(in: &workbook, then: nil) }
        }
        return FormControlView(
            control: control,
            checkState: checkState,
            selection: control.selection(in: workbook),
            items: control.kind == .dropDown ? control.items(in: workbook) : [],
            zoom: metrics.zoom,
            onPress: {
                finishEditing()
                switch control.kind {
                case .checkBox: workbook.toggleCheckBox(control.id, on: sheet.id)
                case .optionButton: workbook.chooseOptionButton(control.id, on: sheet.id)
                default: break
                }
                if control.macroTarget != nil { runMacro(control) }
            },
            onSelect: { item in
                finishEditing()
                workbook.selectDropDownItem(item, in: control.id, on: sheet.id)
                if control.macroTarget != nil { runMacro(control) }
            },
            onEditText: { text in workbook.setEditBoxText(text, in: control.id, on: sheet.id) }
        )
        .frame(width: frame.width, height: frame.height)
        .offset(x: frame.minX, y: frame.minY)
    }

    private func embeddedChart(_ chart: Chart, frame: CGRect) -> some View {
        EmbeddedChartView(
            chart: chart,
            data: chart.resolved(in: workbook),
            frame: frame,
            zoom: metrics.zoom,
            isSelected: state.selectedChartID == chart.id,
            onSelect: {
                if state.editingAddress != nil { state.commitEditing(in: &workbook, then: nil) }
                state.selectChart(chart.id)
            },
            onDeselect: { state.selectChart(nil) },
            onEdit: { state.presentedPanel = .chart },
            onCommit: { frame in
                let zoom = metrics.zoom
                state.moveChart(
                    chart.id,
                    to: CGRect(
                        x: frame.minX / zoom, y: frame.minY / zoom,
                        width: frame.width / zoom, height: frame.height / zoom
                    ),
                    in: &workbook
                )
            },
            onMoveToNewSheet: { state.moveSelectedChartToNewSheet(in: &workbook) },
            onDelete: { state.deleteSelectedChart(in: &workbook) },
            drags: objectDrags
        )
    }

    /// A picture, shape or unmodelled chart kept from the file: drawn as
    /// itself when it is a picture, as a placeholder when not, and moved
    /// either way.
    private func keptDrawing(_ anchor: PreservedDrawingAnchor, frame: CGRect) -> some View {
        let image = anchor.picture.flatMap { picture in
            workbook.preservedPackage.parts[picture.target].map { (picture, $0) }
        }
        return FloatingObjectView(
            frame: frame, isSelected: state.selectedDrawingID == anchor.id,
            minimumSize: CGSize(width: 12, height: 12),
            isMovable: !anchor.locks.noMove, isResizable: !anchor.locks.noResize,
            keepsAspectRatio: anchor.locks.noChangeAspect,
            gripIdentifier: "drawingResizeGrip", gripLabel: image != nil ? "Picture.Resize" : "Drawing.Resize",
            dragID: anchor.id, drags: objectDrags,
            onSelect: {
                if state.editingAddress != nil { state.commitEditing(in: &workbook, then: nil) }
                state.selectDrawing(anchor.id)
            },
            onDeselect: { state.selectDrawing(nil) },
            onCommit: { frame in
                let zoom = metrics.zoom
                state.moveDrawing(
                    anchor.id,
                    to: CGRect(
                        x: frame.minX / zoom, y: frame.minY / zoom,
                        width: frame.width / zoom, height: frame.height / zoom
                    ),
                    in: &workbook
                )
            }
        ) { size in
            Group {
                if let image {
                    PreservedPictureView(picture: image.0, data: image.1)
                        .accessibilityElement()
                        .accessibilityLabel("Picture.Label")
                        .accessibilityIdentifier("picture")
                } else {
                    PreservedDrawingPlaceholder(isChart: anchor.isChart, zoom: metrics.zoom)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("keptObject")
                }
            }
            .frame(width: size.width, height: size.height)
        } menu: {
            Button(image != nil ? "Picture.Menu.Delete" : "Drawing.Menu.Delete", systemImage: "trash", role: .destructive) {
                state.selectDrawing(anchor.id)
                state.deleteSelectedDrawing(in: &workbook)
            }
        }
    }

    // MARK: - In-cell editor

    @ViewBuilder
    private var editorOverlay: some View {
        // While the formula bar has the caret, it owns the edit — showing a
        // second field here would fight it for keyboard focus.
        if let address = state.editingAddress, !state.isFormulaBarActive {
            let frame = metrics.frame(
                for: activeSheet.mergedRange(containing: address) ?? CellRange(address)
            )
            // Single-line on purpose: a vertical-axis field treats Return as a
            // newline instead of committing the cell.
            FormulaTextField(
                text: $state.editingText,
                isFocused: $isCellEditorFocused,
                font: editorFont(for: activeSheet[address].style),
                accessibilityIdentifier: "cellEditor",
                returnKeyType: .done
            ) {
                state.commitEditing(in: &workbook, keepingEditor: true)
            }
                // Exactly the cell, padded exactly as the cell paints its text,
                // so opening the editor neither grows the box nor shifts the
                // glyphs. A field too narrow to hold what is being typed scrolls
                // its own contents, which is what a spreadsheet does anyway.
                .padding(.horizontal, 6 * metrics.zoom)
                .frame(width: frame.width, height: frame.height, alignment: .leading)
                .background(Color.sheetBackground)
                .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.accentColor, lineWidth: 2.5))
                .offset(x: frame.minX, y: frame.minY)
                .zIndex(2)
        }
    }

    /// Formulas in a monospaced face; anything else in the cell's own, so the
    /// glyphs do not jump when the editor opens over them.
    private func editorFont(for style: CellStyle) -> UIFont {
        let size = (state.editingText.hasPrefix("=") ? 14 : style.fontSize) * metrics.zoom
        if state.editingText.hasPrefix("=") {
            return .monospacedSystemFont(ofSize: size, weight: .regular)
        }
        // The cell's own family when it is installed, as the grid draws it.
        return style.platformFont(zoom: metrics.zoom)
    }

    // MARK: - Headers

    /// The header strips stop where the sheet does rather than running the full
    /// width and height of the screen: a sheet smaller than the viewport would
    /// otherwise be framed by headers labelling rows and columns that are not
    /// there.
    private func headerOverlay(in proxy: GeometryProxy) -> some View {
        let visibleGridWidth = max(
            0, min(proxy.size.width - rowHeaderWidth, metrics.totalWidth - state.scrollOffset.x)
        )
        let visibleGridHeight = max(
            0, min(proxy.size.height - columnHeaderHeight, metrics.totalHeight - state.scrollOffset.y)
        )

        return ZStack(alignment: .topLeading) {
            frozenPanes(width: visibleGridWidth, height: visibleGridHeight)
                .offset(x: rowHeaderWidth, y: columnHeaderHeight)

            columnHeaders
                .frame(width: visibleGridWidth, height: columnHeaderHeight)
                .offset(x: rowHeaderWidth)

            rowHeaders(viewportHeight: proxy.size.height)
                .frame(width: rowHeaderWidth, height: visibleGridHeight)
                .offset(y: columnHeaderHeight)

            cornerButton
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var columnHeaders: some View {
        ZStack(alignment: .topLeading) {
            Color.headerBackground.background(.regularMaterial)
            ForEach(headerColumns, id: \.self) { column in
                if !activeSheet.hiddenColumns.contains(column) {
                    ColumnHeaderCell(
                        title: CellAddress.columnName(column),
                        width: metrics.width(ofColumn: column),
                        height: columnHeaderHeight,
                        isSelected: !state.isTableUnfocused && state.selectedRanges.contains { $0.columnRange.contains(column) },
                        isHiddenNeighbor: activeSheet.hiddenColumns.contains(column + 1),
                        onSelect: { state.selectEntireColumns(column...column, in: activeSheet) },
                        onResize: { delta in
                            state.resizeColumn(
                                column,
                                to: (metrics.width(ofColumn: column) + delta) / metrics.zoom,
                                in: &workbook
                            )
                        },
                        onResizePrevious: resizer(forLineBefore: column, hidden: activeSheet.hiddenColumns) { line, delta in
                            state.resizeColumn(line, to: (metrics.width(ofColumn: line) + delta) / metrics.zoom, in: &workbook)
                        },
                        onFit: { state.fitColumn(column, in: &workbook) },
                        actions: {
                            HeaderMenuBuilder(
                                axis: .column, index: column, workbook: $workbook, state: state
                            ).actions()
                        }
                    )
                    .offset(x: metrics.x(ofColumn: column) - (column < activeSheet.frozenColumns ? 0 : state.scrollOffset.x))
                    // A frozen column's header stays put over the ones scrolling beneath it.
                    .zIndex(column < activeSheet.frozenColumns ? 1 : 0)
                    .background(alignment: .topLeading) {
                        if column < activeSheet.frozenColumns {
                            Color.headerBackground.background(.regularMaterial)
                                .frame(width: metrics.width(ofColumn: column), height: columnHeaderHeight)
                                .offset(x: metrics.x(ofColumn: column))
                        }
                    }
                }
            }
        }
        .clipped()
    }

    private func rowHeaders(viewportHeight: Double) -> some View {
        let top = state.scrollOffset.y - columnHeaderHeight
        let frozen = activeSheet.frozenRows
        let scrolled = metrics.rows(in: max(0, top)...(top + max(viewportHeight, 200))).filter { $0 >= frozen }
        let rows = Array(0..<min(frozen, metrics.rowCount)) + scrolled

        return ZStack(alignment: .topLeading) {
            Color.headerBackground.background(.regularMaterial)
            ForEach(rows, id: \.self) { row in
                if !activeSheet.hiddenRows.contains(row) {
                    RowHeaderCell(
                        title: String(row + 1),
                        width: rowHeaderWidth,
                        height: metrics.height(ofRow: row),
                        isSelected: !state.isTableUnfocused && state.selectedRanges.contains { $0.rowRange.contains(row) },
                        isHiddenNeighbor: activeSheet.hiddenRows.contains(row + 1),
                        onSelect: { state.selectEntireRows(row...row, in: activeSheet) },
                        onResize: { delta in
                            state.resizeRow(
                                row,
                                to: (metrics.height(ofRow: row) + delta) / metrics.zoom,
                                in: &workbook
                            )
                        },
                        onResizePrevious: resizer(forLineBefore: row, hidden: activeSheet.hiddenRows) { line, delta in
                            state.resizeRow(line, to: (metrics.height(ofRow: line) + delta) / metrics.zoom, in: &workbook)
                        },
                        actions: {
                            HeaderMenuBuilder(
                                axis: .row, index: row, workbook: $workbook, state: state
                            ).actions()
                        }
                    )
                    .offset(y: metrics.y(ofRow: row) - (row < activeSheet.frozenRows ? 0 : state.scrollOffset.y))
                    .zIndex(row < activeSheet.frozenRows ? 1 : 0)
                    .background(alignment: .topLeading) {
                        if row < activeSheet.frozenRows {
                            Color.headerBackground.background(.regularMaterial)
                                .frame(width: rowHeaderWidth, height: metrics.height(ofRow: row))
                                .offset(y: metrics.y(ofRow: row))
                        }
                    }
                }
            }
        }
        .clipped()
    }

    // MARK: - Frozen panes

    /// How far the frozen rows reach down, and the frozen columns across.
    private var frozenExtent: CGSize {
        let sheet = activeSheet
        guard canvas == nil else { return .zero }
        return CGSize(
            width: sheet.frozenColumns > 0 ? metrics.x(ofColumn: sheet.frozenColumns) : 0,
            height: sheet.frozenRows > 0 ? metrics.y(ofRow: sheet.frozenRows) : 0
        )
    }

    /// How the frozen rows and columns split the sheet into panes.
    private var frozenPanesLayout: FrozenPanes {
        FrozenPanes(width: frozenExtent.width, height: frozenExtent.height)
    }

    /// Whether the frozen panes are over the sheet now.
    private var arePanesShown: Bool {
        frozenPanesLayout.isFrozen && !isEditingFrozenCell
    }

    /// While a frozen cell is edited the panes step aside: the editor is one
    /// of the scrolling cells, and the sheet scrolls back to it.
    private var isEditingFrozenCell: Bool {
        guard let address = state.editingAddress, canvas == nil else { return false }
        return address.row < activeSheet.frozenRows || address.column < activeSheet.frozenColumns
    }

    /// The frozen rows along the top, the frozen columns down the side and
    /// the corner where they meet, drawn over the scrolling sheet where they
    /// stay. Each is the sheet's own tiles, shifted by the scroll along the
    /// axis it scrolls in.
    @ViewBuilder
    private func frozenPanes(width: Double, height: Double) -> some View {
        let sheet = activeSheet
        let frozen = frozenExtent
        if (frozen.width > 0 || frozen.height > 0), !isEditingFrozenCell {
            let rows = 0..<min(sheet.frozenRows, metrics.rowCount)
            let columns = 0..<min(sheet.frozenColumns, metrics.columnCount)
            ZStack(alignment: .topLeading) {
                if frozen.height > 0 {
                    let size = CGSize(width: width, height: min(height, frozen.height))
                    let shift = CGPoint(x: state.scrollOffset.x, y: 0)
                    pinned(frozenPane(.rows, rows: rows, columns: visibleColumns, shift: shift, size: size),
                           size: size, shift: shift)
                        .overlay(alignment: .bottom) { frozenEdge(horizontal: true) }
                }
                if frozen.width > 0 {
                    let size = CGSize(width: min(width, frozen.width), height: height)
                    let shift = CGPoint(x: 0, y: state.scrollOffset.y)
                    pinned(frozenPane(.columns, rows: visibleRows, columns: columns, shift: shift, size: size),
                           size: size, shift: shift)
                        .overlay(alignment: .trailing) { frozenEdge(horizontal: false) }
                }
                if frozen.width > 0, frozen.height > 0 {
                    let size = CGSize(width: min(width, frozen.width), height: min(height, frozen.height))
                    pinned(frozenPane(.corner, rows: rows, columns: columns, shift: .zero, size: size),
                           size: size, shift: .zero)
                }
            }
        }
    }

    /// One frozen pane: the tiles covering it, the selection, the formula's
    /// references and the floating objects over them, in the sheet's
    /// coordinates moved back by `shift`; `size` is how much of it shows.
    /// Taps on a cell land on the cell beneath, as they would on the sheet,
    /// and a chart or picture takes its own.
    private func frozenPane(
        _ pane: FrozenPanes.Pane, rows: Range<Int>, columns: Range<Int>, shift: CGPoint, size: CGSize
    ) -> some View {
        let sheet = activeSheet
        let plans = Self.tilePlans(rows: rows, columns: columns, metrics: metrics)
        let drawing = tileCache.tiles(of: sheet, metrics: metrics)
        let scheme = drawing.scheme(for: colorScheme)

        return ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(paper(of: sheet))
                    .frame(width: metrics.totalWidth, height: metrics.totalHeight)
                ForEach(plans) { plan in
                    let frame = metrics.frame(for: plan.range)
                    GridTileView(
                        rows: plan.rows,
                        columns: plan.columns,
                        origin: frame.origin,
                        size: frame.size,
                        hiddenRows: sheet.hiddenRows,
                        hiddenColumns: sheet.hiddenColumns,
                        contents: contents(of: plan, in: sheet, drawing: drawing, metrics: metrics),
                        metrics: metrics,
                        scheme: scheme
                    )
                    .equatable()
                }
                if !state.isTableUnfocused { selectionOverlay(interactive: false) }
            }
            // The cells and the selection take no touches of their own: the
            // pane hands taps on them to the cell beneath.
            .allowsHitTesting(false)
            floatingObjects(in: CGRect(origin: shift, size: size), pane: pane)
        }
        .frame(width: metrics.totalWidth, height: metrics.totalHeight, alignment: .topLeading)
        .offset(x: -shift.x, y: -shift.y)
    }

    /// Clips a frozen pane to its place and sends its taps to the cell under
    /// them, `shift` being how far the pane's drawing is scrolled. What the
    /// clip cuts off takes no touches either, so a chart running out of the
    /// pane leaves the cells beyond the freeze line to the sheet.
    private func pinned(_ pane: some View, size: CGSize, shift: CGPoint) -> some View {
        pane
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipped()
            .contentShape(.rect)
            .onTapGesture(coordinateSpace: .local) { point in
                tap(address(at: CGPoint(x: point.x + shift.x, y: point.y + shift.y)))
            }
    }

    /// The line Excel draws where the frozen part ends.
    private func frozenEdge(horizontal: Bool) -> some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.6))
            .frame(width: horizontal ? nil : 1, height: horizontal ? 1 : nil)
            .allowsHitTesting(false)
    }

    private var cornerButton: some View {
        Button {
            state.selectAll(in: activeSheet)
        } label: {
            ZStack {
                Color.headerBackground.background(.regularMaterial)
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: rowHeaderWidth, height: columnHeaderHeight)
            .overlay(alignment: .trailing) { Rectangle().fill(Color.gridLine).frame(width: 1) }
            .overlay(alignment: .bottom) { Rectangle().fill(Color.gridLine).frame(height: 1) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Grid.SelectAll")
    }

    // MARK: - Scrolling

    /// Brings the table just picked or added on a canvas into view: its top,
    /// name and all, near the top of the screen, unless it is there already,
    /// clear of the bars along the bottom.
    private func revealActiveTable() {
        let origin = gridOrigin
        let top = origin.y - CanvasChrome.nameReach(zoom: state.zoom)
        let offset = state.scrollOffset
        let comfortable = state.viewportSize.height * 0.5
        let inView = top >= offset.y && top <= offset.y + comfortable
            && origin.x >= offset.x && origin.x <= offset.x + state.viewportSize.width * 0.5
        guard !inView else { return }
        let destination = CGPoint(
            x: max(0, origin.x - CanvasChrome.rowHeaderWidth(rowCount: activeSheet.rowCount) - 16) - state.scrollInsets.width,
            y: max(0, top - 16) - state.scrollInsets.height
        )
        withAnimation(.easeOut(duration: 0.22)) {
            scrollPosition.scrollTo(point: destination)
        }
    }

    /// Nudges the scroll offset just enough to reveal a cell under the headers.
    private func scrollIntoView(_ address: CellAddress) {
        // In the content's coordinates, less the headers covering its edge.
        let shift = CGPoint(x: gridOrigin.x - headerInsets.width, y: gridOrigin.y - headerInsets.height)
        var frame = metrics.frame(for: address).offsetBy(dx: shift.x, dy: shift.y)
        // A table's first row brings its name along.
        if canvas != nil, address.row == 0 {
            let name = CanvasChrome.nameReach(zoom: state.zoom)
            frame = CGRect(x: frame.minX, y: frame.minY - name, width: frame.width, height: frame.height + name)
        }
        let visibleWidth = max(1, state.viewportSize.width - headerInsets.width)
        let visibleHeight = max(1, state.viewportSize.height - headerInsets.height)
        var offset = state.scrollOffset
        var sheet = activeSheet
        if canvas != nil {
            sheet.frozenRows = 0
            sheet.frozenColumns = 0
        }
        let frozen = frozenExtent
        // A frozen cell is in view already, unless it is being edited: the
        // editor lives with the scrolling cells, so the sheet goes back to it.
        let editingFrozen = isEditingFrozenCell
        let pinsRow = address.row < sheet.frozenRows && !editingFrozen
        let pinsColumn = address.column < sheet.frozenColumns && !editingFrozen
        // Anything else has to land clear of the frozen panes, not under them.
        let leading = address.column < sheet.frozenColumns ? 0 : frozen.width
        let top = address.row < sheet.frozenRows ? 0 : frozen.height

        if pinsColumn {
        } else if frame.minX < offset.x + leading {
            offset.x = frame.minX - leading
        } else if frame.maxX > offset.x + visibleWidth {
            offset.x = frame.maxX - visibleWidth
        }
        if pinsRow {
        } else if frame.minY < offset.y + top {
            offset.y = frame.minY - top
        } else if frame.maxY > offset.y + visibleHeight {
            offset.y = frame.maxY - visibleHeight
        }
        guard offset != state.scrollOffset else { return }
        // Convert back to the raw content offset the scroll view works in.
        let destination = CGPoint(
            x: max(0, offset.x) - state.scrollInsets.width,
            y: max(0, offset.y) - state.scrollInsets.height
        )
        withAnimation(.easeOut(duration: 0.18)) {
            scrollPosition.scrollTo(point: destination)
        }
    }
}

/// A pinch in progress, and the sums that keep the sheet under the fingers.
///
/// Everything here is captured once, when the gesture starts, rather than read
/// live: the gesture writes the scroll offset, so measuring each frame against
/// the current one would feed its own output back into its input and the sheet
/// would crawl away from the fingers over the course of a pinch.
struct ZoomAnchor: Equatable {
    let zoom: Double
    let scrollOffset: CGPoint
    /// The pinch's midpoint, in viewport coordinates.
    let location: CGPoint
    /// The pinned header strips: the row gutter's width and the column
    /// header's height. They do not scale, so they stay out of the sums.
    let headers: CGSize
    let viewport: CGSize

    /// Where to scroll so that whatever was under the fingers when the pinch
    /// began is still under them at `zoom`.
    ///
    /// The grid is measured in points that already have the zoom folded in, so
    /// the content only ever grows away from its top-left corner. Scaling the
    /// distance from that corner to the pinch's midpoint by the same ratio, and
    /// scrolling there, is what turns growth from the corner into growth from
    /// the fingers.
    func scrollOffset(at zoom: Double, contentSize: CGSize) -> CGPoint {
        let scale = zoom / self.zoom
        // The point under the fingers, relative to the grid's own corner.
        let grid = CGPoint(
            x: scrollOffset.x + location.x - headers.width,
            y: scrollOffset.y + location.y - headers.height
        )
        // A sheet smaller than the viewport still fills it, and cannot scroll.
        let scrollableWidth = max(0, max(viewport.width, contentSize.width) - viewport.width)
        let scrollableHeight = max(0, max(viewport.height, contentSize.height) - viewport.height)
        return CGPoint(
            x: (grid.x * scale + headers.width - location.x).clamped(to: 0...scrollableWidth),
            y: (grid.y * scale + headers.height - location.y).clamped(to: 0...scrollableHeight)
        )
    }
}

/// Scroll position plus the insets it was measured against, captured together
/// so they can never disagree.
private struct ScrollAnchor: Equatable {
    var offset: CGPoint
    var insets: CGSize
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
