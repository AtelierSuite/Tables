import Foundation

/// How frozen rows and columns split a sheet into panes, as Excel does.
///
/// The sheet is one plane, cut at the freeze lines into up to four parts,
/// each shown by its own pane: the corner never scrolls, the frozen rows
/// scroll only sideways, the frozen columns only up and down, and the rest
/// both ways. Something floating over the sheet — a chart, a picture, a
/// selection — shows in every pane whose part it reaches, cut at the freeze
/// line, so the part in a frozen pane stays put while the rest scrolls.
///
/// All of it is in the grid's own coordinates, zoom applied.
public struct FrozenPanes: Equatable, Sendable {
    public enum Pane: Hashable, Sendable, CaseIterable {
        /// Past both freeze lines: scrolls both ways.
        case scrolling
        /// The frozen rows: scrolls sideways, never down.
        case rows
        /// The frozen columns: scrolls down, never sideways.
        case columns
        /// Where the frozen rows and columns meet: never scrolls.
        case corner
    }

    /// The part of something floating that one pane shows.
    public struct Piece: Equatable, Sendable {
        public var pane: Pane
        /// In the sheet's coordinates, inside the pane's part of the sheet.
        public var frame: CGRect
    }

    /// How far across the frozen columns reach.
    public var width: Double
    /// How far down the frozen rows reach.
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = max(0, width)
        self.height = max(0, height)
    }

    /// The panes a sheet's frozen rows and columns make at the metrics' zoom.
    public init(sheet: Worksheet, metrics: SheetMetrics) {
        self.init(
            width: sheet.frozenColumns > 0 ? metrics.x(ofColumn: sheet.frozenColumns) : 0,
            height: sheet.frozenRows > 0 ? metrics.y(ofRow: sheet.frozenRows) : 0)
    }

    /// Whether anything is frozen at all.
    public var isFrozen: Bool { width > 0 || height > 0 }

    /// The panes there are, from the bottom of the stack to the top.
    public var panes: [Pane] {
        var panes: [Pane] = [.scrolling]
        if height > 0 { panes.append(.rows) }
        if width > 0 { panes.append(.columns) }
        if width > 0, height > 0 { panes.append(.corner) }
        return panes
    }

    /// The pane showing a point of the sheet.
    public func pane(containing point: CGPoint) -> Pane {
        let inRows = Double(point.y) < height, inColumns = Double(point.x) < width
        switch (inRows, inColumns) {
        case (true, true): return .corner
        case (true, false): return .rows
        case (false, true): return .columns
        case (false, false): return .scrolling
        }
    }

    /// The pane an object belongs to: the one its top-left corner is in, as
    /// Excel anchors it.
    public func home(of frame: CGRect) -> Pane {
        pane(containing: frame.origin)
    }

    /// The parts of a frame each pane shows, cut at the freeze lines, from
    /// the bottom of the stack to the top. A frame within one pane is one
    /// piece; one across a freeze line is two, or four across both.
    public func pieces(of frame: CGRect) -> [Piece] {
        guard frame.width > 0, frame.height > 0 else { return [] }
        let across = Self.split(Double(frame.minX), Double(frame.maxX), at: width)
        let down = Self.split(Double(frame.minY), Double(frame.maxY), at: height)
        var pieces: [Piece] = []
        for pane in Pane.allCases {
            let frozenRows = pane == .rows || pane == .corner
            let frozenColumns = pane == .columns || pane == .corner
            guard let x = frozenColumns ? across.frozen : across.scrolling,
                  let y = frozenRows ? down.frozen : down.scrolling else { continue }
            pieces.append(Piece(
                pane: pane,
                frame: CGRect(x: x.lowerBound, y: y.lowerBound,
                              width: x.upperBound - x.lowerBound, height: y.upperBound - y.lowerBound)))
        }
        return pieces
    }

    /// Whether a pane shows any of a frame.
    public func shows(_ frame: CGRect, in pane: Pane) -> Bool {
        pieces(of: frame).contains { $0.pane == pane }
    }

    /// How far a pane's part of the sheet is moved back on screen, for the
    /// sheet scrolled by `scroll`: only along the axes the pane scrolls in.
    public func shift(of pane: Pane, scroll: CGPoint) -> CGPoint {
        switch pane {
        case .scrolling: return scroll
        case .rows: return CGPoint(x: scroll.x, y: 0)
        case .columns: return CGPoint(x: 0, y: scroll.y)
        case .corner: return .zero
        }
    }

    /// The pane under a point of the grid's window, measured from its
    /// top-left corner, and the point of the sheet it shows there, for the
    /// sheet scrolled by `scroll`.
    public func sheetPoint(atViewport point: CGPoint, scroll: CGPoint) -> (pane: Pane, point: CGPoint) {
        // The window's top-left shows the sheet's, and the frozen parts stay
        // there, so a point in the window is in the same pane as that point
        // of the sheet.
        let pane = pane(containing: point)
        let shift = shift(of: pane, scroll: scroll)
        return (pane, CGPoint(x: point.x + shift.x, y: point.y + shift.y))
    }

    /// The part of a span on each side of a freeze line, nil where it has none.
    private static func split(
        _ lower: Double, _ upper: Double, at line: Double
    ) -> (frozen: Range<Double>?, scrolling: Range<Double>?) {
        let frozen = lower < min(upper, line) ? lower..<min(upper, line) : nil
        let scrolling = max(lower, line) < upper ? max(lower, line)..<upper : nil
        return (frozen, scrolling)
    }
}
