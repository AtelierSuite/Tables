import CoreGraphics
import TablesEngine

/// Where a table being dragged on a canvas comes to rest: never off the
/// top or left of the page, and in line with the tables around it when it
/// comes close to one, as Numbers lines objects up, with the guides that
/// show what it lined up with.
enum CanvasSnapping {
    /// A line drawn while a table is lined up with another.
    struct Guide: Equatable {
        enum Axis { case vertical, horizontal }
        var axis: Axis
        /// The line's x for a vertical guide, its y for a horizontal one.
        var position: CGFloat
        /// How far it runs, across both tables.
        var start: CGFloat
        var end: CGFloat
    }

    /// How close, in points on screen, an edge or middle has to come to
    /// another's to snap to it.
    static let threshold: CGFloat = 6

    /// The nearest a table's first cell may come to the page's top-left, on
    /// screen: room for its headers and its name, so its handle stays on
    /// the page.
    static func minimumOrigin(zoom: Double, rowCount: Int) -> CGPoint {
        CGPoint(x: CanvasChrome.rowHeaderWidth(rowCount: rowCount) + 4, y: CanvasChrome.nameReach(zoom: zoom) + 4)
    }

    /// Where `frame` lands among `others`, never nearer the page's top-left
    /// than `minimum`, and the guides showing what it lined up with. Every
    /// frame is in the same coordinates, the page's.
    static func snap(
        _ frame: CGRect, among others: [CGRect], minimum: CGPoint = .zero, threshold: CGFloat = threshold
    ) -> (origin: CGPoint, guides: [Guide]) {
        var frame = frame
        frame.origin.x = max(minimum.x, frame.origin.x)
        frame.origin.y = max(minimum.y, frame.origin.y)

        func lines(_ rect: CGRect, _ axis: Guide.Axis) -> [CGFloat] {
            axis == .vertical ? [rect.minX, rect.midX, rect.maxX] : [rect.minY, rect.midY, rect.maxY]
        }
        /// The smallest shift along an axis that lines one of the frame's
        /// lines up with one of another's, within the threshold.
        func shift(_ axis: Guide.Axis) -> CGFloat? {
            var best: CGFloat?
            for other in others {
                for line in lines(frame, axis) {
                    for target in lines(other, axis) {
                        let delta = target - line
                        if abs(delta) <= threshold, abs(delta) < abs(best ?? .infinity) { best = delta }
                    }
                }
            }
            return best
        }
        if let dx = shift(.vertical), frame.minX + dx >= minimum.x { frame.origin.x += dx }
        if let dy = shift(.horizontal), frame.minY + dy >= minimum.y { frame.origin.y += dy }

        var guides: [Guide] = []
        for axis in [Guide.Axis.vertical, .horizontal] {
            for line in lines(frame, axis) {
                let matches = others.filter { other in lines(other, axis).contains { abs($0 - line) < 0.5 } }
                guard !matches.isEmpty else { continue }
                let span = matches.reduce(frame) { $0.union($1) }
                guides.append(axis == .vertical
                    ? Guide(axis: .vertical, position: line, start: span.minY, end: span.maxY)
                    : Guide(axis: .horizontal, position: line, start: span.minX, end: span.maxX))
            }
        }
        return (frame.origin, guides)
    }
}

/// The headers a table on a canvas shows while it is the one worked on,
/// and the room kept for them whether or not they show, so a table taking
/// them on never moves, and neither does its name.
enum CanvasChrome {
    /// The bar of column letters above the table, on screen: taller on
    /// iPhone and iPad, for a finger.
    #if os(iOS)
    static let columnHeaderHeight: CGFloat = 24
    private static let minimumRowHeaderWidth: CGFloat = 32
    #else
    static let columnHeaderHeight: CGFloat = 20
    private static let minimumRowHeaderWidth: CGFloat = 26
    #endif

    /// The bar of row numbers to the table's left: wide enough for the
    /// last row's number.
    static func rowHeaderWidth(rowCount: Int) -> CGFloat {
        max(minimumRowHeaderWidth, 12 + 7 * CGFloat(String(max(1, rowCount)).count))
    }

    /// How far above a table's first cell the top of its name is: past the
    /// column bar, kept for it even while it isn't shown.
    static func nameReach(zoom: Double) -> CGFloat {
        columnHeaderHeight + SheetCanvas.nameHeight * zoom
    }

    /// How long headers take to fade in or out as tables are picked.
    static let fadeDuration = 0.18

    /// How opaque a table's headers are while it is being dragged, so what
    /// it passes over shows through them.
    static let draggingOpacity = 0.4
}
