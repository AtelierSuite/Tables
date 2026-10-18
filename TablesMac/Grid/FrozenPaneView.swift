import AppKit
import TablesEngine

/// One of the parts of the sheet frozen panes keep in view, laid over the
/// scrolling grid: the frozen rows along the top, the frozen columns down
/// the side, or the corner where they meet.
///
/// Its bounds are the sheet's own coordinates for what it shows, so it draws
/// through the grid's drawing and hands clicks to the grid unchanged; the
/// grid works out from the pointer which pane, if any, it was over.
@MainActor
final class FrozenPaneView: NSView {
    enum Part {
        /// The frozen rows: scrolls sideways with the sheet, never down.
        case rows
        /// The frozen columns: scrolls down with the sheet, never sideways.
        case columns
        /// Both at once: never scrolls.
        case corner
    }

    let part: Part
    weak var grid: GridView?
    private var pointerArea: NSTrackingArea?

    init(part: Part) {
        self.part = part
        super.init(frame: .zero)
        isHidden = true
        // Views no longer clip by default, and the sheet is drawn from
        // whatever area AppKit asks for: kept to the pane's own.
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    /// Places the pane over the visible part of the grid and points its
    /// bounds at the sheet area it shows. The pane lives in a container
    /// lying exactly over the clip view; `headers` is how far the column and
    /// row headers reach over the clip view, and `trailing` how much of its
    /// edge the scrollers take.
    func layout(in clip: NSClipView, frozen: CGSize, headers: CGSize, trailing: CGSize) {
        let shown = (part == .rows && frozen.height > 0) || (part == .columns && frozen.width > 0)
            || (part == .corner && frozen.width > 0 && frozen.height > 0)
        isHidden = !shown
        guard shown else { return }
        // The first point of the sheet not under a header.
        var visible = clip.bounds
        visible.size.width -= trailing.width
        visible.size.height -= trailing.height
        let left = visible.minX + headers.width, top = visible.minY + headers.height
        let placed: CGRect
        let origin: CGPoint
        switch part {
        case .rows:
            placed = CGRect(x: left, y: top, width: max(0, visible.maxX - left), height: frozen.height)
            origin = CGPoint(x: left, y: 0)
        case .columns:
            placed = CGRect(x: left, y: top, width: frozen.width, height: max(0, visible.maxY - top))
            origin = CGPoint(x: 0, y: top)
        case .corner:
            placed = CGRect(x: left, y: top, width: frozen.width, height: frozen.height)
            origin = .zero
        }
        // From the clip view's coordinates, the sheet's, to the container's.
        let framed = placed.offsetBy(dx: -clip.bounds.minX, dy: -clip.bounds.minY)
        if frame != framed { frame = framed }
        if bounds.origin != origin { setBoundsOrigin(origin) }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let grid, let context = NSGraphicsContext.current?.cgContext else { return }
        let area = dirtyRect.intersection(bounds)
        guard !area.isEmpty else { return }
        context.saveGState()
        context.clip(to: area)
        grid.drawSheet(area, in: context)
        context.restoreGState()
        // The line Excel draws where the frozen part ends.
        NSColor.separatorColor.withAlphaComponent(0.9).setFill()
        switch part {
        case .rows:
            NSRect(x: bounds.minX, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
        case .columns:
            NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()
        case .corner:
            NSRect(x: bounds.minX, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
            NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()
        }
    }

    // MARK: - Events, handed to the grid

    override func mouseDown(with event: NSEvent) { grid?.mouseDown(with: event) }
    override func mouseDragged(with event: NSEvent) { grid?.mouseDragged(with: event) }
    override func mouseUp(with event: NSEvent) { grid?.mouseUp(with: event) }
    override func menu(for event: NSEvent) -> NSMenu? { grid?.menu(for: event) }
    override func magnify(with event: NSEvent) { grid?.magnify(with: event) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerArea { removeTrackingArea(pointerArea) }
        let area = NSTrackingArea(
            rect: .zero, options: [.cursorUpdate, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        pointerArea = area
    }

    override func cursorUpdate(with event: NSEvent) { grid?.cursorUpdate(with: event) }
    override func mouseMoved(with event: NSEvent) { grid?.mouseMoved(with: event) }
}

/// Holds the frozen panes over the scroll view's clip view, taking only the
/// clicks that land on one of them.
@MainActor
final class FrozenPaneContainer: NSView {
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}
