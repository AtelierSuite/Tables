import AppKit
import SwiftUI
import TablesEngine

/// A chart or picture floating over the sheet: picked out with a click,
/// moved by dragging, resized from its corner handle.
///
/// The frame is in grid coordinates at the grid's zoom; a finished move or
/// resize is handed back through `onCommit` for the document to keep.
@MainActor
final class FloatingObjectView: NSView {
    let content: NSView
    var onSelect: () -> Void = {}
    var onCommit: (CGRect) -> Void = { _ in }
    var onDoubleClick: () -> Void = {}

    private var isSelected = false
    private var isMovable = true
    private var isResizable = true
    private var keepsAspectRatio = false

    private enum Gesture {
        case moving(start: NSPoint, frame: CGRect)
        case resizing(start: NSPoint, frame: CGRect)
    }

    private var gesture: Gesture?
    private static let handleSize: CGFloat = 10
    private static let minimumSize = CGSize(width: 24, height: 24)

    /// The outline and handle, over the content rather than under it: a
    /// hosted chart draws in a layer of its own above anything drawn here.
    private let chrome = SelectionChrome()

    init(content: NSView) {
        self.content = content
        super.init(frame: .zero)
        addSubview(content)
        addSubview(chrome)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    func configure(frame: CGRect, isSelected: Bool, isMovable: Bool, isResizable: Bool, keepsAspectRatio: Bool) {
        // Mid-gesture, the view follows the pointer rather than the document.
        if gesture == nil, self.frame != frame { self.frame = frame }
        self.isMovable = isMovable
        self.isResizable = isResizable
        self.keepsAspectRatio = keepsAspectRatio
        if self.isSelected != isSelected {
            self.isSelected = isSelected
        }
        chrome.isSelected = isSelected
        chrome.isResizable = isResizable
        content.frame = bounds
        chrome.frame = bounds
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        content.frame = bounds
        chrome.frame = bounds
    }

    /// The content is shown, not used: clicks belong to the frame.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    private var handleRect: CGRect {
        CGRect(x: bounds.maxX - Self.handleSize, y: bounds.maxY - Self.handleSize,
               width: Self.handleSize, height: Self.handleSize)
    }

    override func resetCursorRects() {
        if isSelected, isResizable { addCursorRect(handleRect, cursor: .crosshair) }
    }

    override func mouseDown(with event: NSEvent) {
        onSelect()
        if event.clickCount == 2 {
            onDoubleClick()
            return
        }
        let point = superview?.convert(event.locationInWindow, from: nil) ?? .zero
        let local = convert(event.locationInWindow, from: nil)
        if isResizable, handleRect.insetBy(dx: -4, dy: -4).contains(local) {
            gesture = .resizing(start: point, frame: frame)
        } else if isMovable {
            gesture = .moving(start: point, frame: frame)
        }
        isSelected = true
        chrome.isSelected = true
        window?.invalidateCursorRects(for: self)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let gesture, let superview else { return }
        let point = superview.convert(event.locationInWindow, from: nil)
        switch gesture {
        case .moving(let start, let original):
            frame.origin = CGPoint(
                x: max(0, original.minX + point.x - start.x), y: max(0, original.minY + point.y - start.y)
            )
        case .resizing(let start, let original):
            var width = max(Self.minimumSize.width, original.width + point.x - start.x)
            var height = max(Self.minimumSize.height, original.height + point.y - start.y)
            if keepsAspectRatio, original.width > 0, original.height > 0 {
                let scale = max(width / original.width, height / original.height)
                width = original.width * scale
                height = original.height * scale
            }
            frame.size = CGSize(width: width, height: height)
        }
        superview.autoscroll(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard let gesture else { return }
        self.gesture = nil
        let original: CGRect
        switch gesture {
        case .moving(_, let frame), .resizing(_, let frame): original = frame
        }
        if frame != original { onCommit(frame) }
    }
}

/// The outline of a selected object, and the handle that resizes it.
@MainActor
private final class SelectionChrome: NSView {
    var isSelected = false { didSet { if isSelected != oldValue { needsDisplay = true } } }
    var isResizable = true { didSet { if isResizable != oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelected else { return }
        NSColor.controlAccentColor.setStroke()
        let outline = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        outline.lineWidth = 2
        outline.stroke()
        guard isResizable else { return }
        let size: CGFloat = 10
        let handle = NSBezierPath(ovalIn: CGRect(x: bounds.maxX - size, y: bounds.maxY - size, width: size, height: size))
        NSColor.controlAccentColor.setFill()
        handle.fill()
        NSColor.white.setStroke()
        handle.lineWidth = 1.5
        handle.stroke()
    }
}

/// A chart, drawn by the same Swift Charts view the iPhone and iPad use.
@MainActor
final class ChartContentView: NSView {
    private var hosting: NSHostingView<ChartView>?
    private var shown: ChartView?

    func show(_ chart: TablesEngine.Chart, data: ResolvedChart, zoom: Double) {
        let view = ChartView(chart: chart, data: data, zoom: zoom)
        guard view != shown else { return }
        shown = view
        if let hosting {
            hosting.rootView = view
        } else {
            let hosting = NSHostingView(rootView: view)
            hosting.frame = bounds
            hosting.autoresizingMask = [.width, .height]
            addSubview(hosting)
            self.hosting = hosting
        }
    }
}

/// A picture kept from the file, or a placeholder for an object Tables
/// keeps but cannot draw.
@MainActor
final class PictureContentView: NSView {
    private var image: CGImage?
    private var isChart = false

    override var isFlipped: Bool { true }

    func show(_ image: CGImage?, isChart: Bool) {
        guard image !== self.image || isChart != self.isChart else { return }
        self.image = image
        self.isChart = isChart
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if let image {
            NSImage(cgImage: image, size: bounds.size).draw(in: bounds)
            return
        }
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        NSColor.secondaryLabelColor.withAlphaComponent(0.08).setFill()
        shape.fill()
        NSColor.secondaryLabelColor.withAlphaComponent(0.35).setStroke()
        shape.setLineDash([4, 3], count: 2, phase: 0)
        shape.stroke()
        let label = String(localized: isChart ? "Chart.Preserved.Chart" : "Chart.Preserved.Object")
        let text = NSAttributedString(string: label, attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
        ])
        let size = text.boundingRect(with: CGSize(width: bounds.width - 16, height: bounds.height),
                                     options: [.usesLineFragmentOrigin]).size
        text.draw(with: CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                               width: size.width, height: size.height), options: [.usesLineFragmentOrigin])
    }
}
