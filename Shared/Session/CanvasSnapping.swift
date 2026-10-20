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

    /// How close a table may come to the page's left edge, on screen:
    /// enough to leave its grip on the page.
    static let leadingInset: CGFloat = 24

    /// The nearest a table's corner may come to the page's top-left, on
    /// screen, at a zoom: room for its grip, and for its name above it.
    static func minimumOrigin(zoom: Double) -> CGPoint {
        CGPoint(x: leadingInset, y: max(leadingInset, SheetCanvas.nameHeight * zoom))
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
