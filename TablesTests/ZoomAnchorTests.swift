import Testing
import CoreGraphics
@testable import Tables
@testable import TablesEngine

/// Pinch-to-zoom scales the sheet about the fingers rather than about the
/// top-left corner. That is entirely a matter of where the scroll view is left
/// pointing afterwards, so these check the offset the gesture asks for.
@Suite("Pinch anchoring")
struct ZoomAnchorTests {
    private let headers = CGSize(width: 44, height: 28)
    private let viewport = CGSize(width: 400, height: 800)
    /// Big enough that nothing in these cases runs into the scroll limits.
    private let content = CGSize(width: 20_000, height: 40_000)

    private func anchor(
        zoom: Double = 1, scrolledTo offset: CGPoint = .zero, fingersAt location: CGPoint
    ) -> ZoomAnchor {
        ZoomAnchor(
            zoom: zoom, scrollOffset: offset, location: location,
            headers: headers, viewport: viewport
        )
    }

    /// The whole point: the grid point under the fingers before the pinch is
    /// under them after it.
    private func gridPoint(
        under anchor: ZoomAnchor, at zoom: Double, offset: CGPoint
    ) -> CGPoint {
        // What the finger is over, in the zoomed grid, divided back out to the
        // sheet's own unzoomed coordinates so the two zooms are comparable.
        CGPoint(
            x: (offset.x + anchor.location.x - headers.width) / zoom,
            y: (offset.y + anchor.location.y - headers.height) / zoom
        )
    }

    /// The start offsets here all leave room in both directions. Pinned against
    /// an edge the anchor cannot hold — there is nowhere left to scroll — which
    /// `staysInsideTheContent` covers instead.
    @Test("The sheet under the fingers stays under them, wherever they are")
    func anchorHolds() {
        for location in [
            CGPoint(x: 60, y: 40), CGPoint(x: 200, y: 400), CGPoint(x: 390, y: 780)
        ] {
            for start in [CGPoint(x: 500, y: 1_200), CGPoint(x: 3_000, y: 9_000)] {
                for target in [0.6, 1.5, 3.0] {
                    let anchor = anchor(scrolledTo: start, fingersAt: location)
                    let before = gridPoint(under: anchor, at: 1, offset: start)
                    let after = gridPoint(
                        under: anchor, at: target,
                        offset: anchor.scrollOffset(at: target, contentSize: content)
                    )
                    #expect(abs(after.x - before.x) < 0.001, "x drifted at \(location), \(target)")
                    #expect(abs(after.y - before.y) < 0.001, "y drifted at \(location), \(target)")
                }
            }
        }
    }

    @Test("Zooming about the top-left corner still scrolls to the top-left corner")
    func cornerPinchStaysPut() {
        let anchor = anchor(fingersAt: CGPoint(x: headers.width, y: headers.height))
        let offset = anchor.scrollOffset(at: 2, contentSize: content)
        #expect(offset == .zero)
    }

    @Test("Zoom that does not change asks for the offset it already has")
    func identityIsANoOp() {
        let start = CGPoint(x: 320, y: 90)
        let anchor = anchor(scrolledTo: start, fingersAt: CGPoint(x: 210, y: 505))
        let offset = anchor.scrollOffset(at: 1, contentSize: content)
        #expect(abs(offset.x - start.x) < 0.001)
        #expect(abs(offset.y - start.y) < 0.001)
    }

    @Test("The offset never leaves the scrollable range")
    func staysInsideTheContent() {
        // Zooming out from deep in a big sheet overshoots the top-left corner.
        let anchor = anchor(
            zoom: 3, scrolledTo: CGPoint(x: 40, y: 60), fingersAt: CGPoint(x: 380, y: 760)
        )
        let out = anchor.scrollOffset(at: 0.5, contentSize: content)
        #expect(out.x >= 0)
        #expect(out.y >= 0)

        // And a sheet smaller than the viewport cannot scroll at all.
        let small = anchor.scrollOffset(at: 1, contentSize: CGSize(width: 120, height: 200))
        #expect(small == .zero)
    }

    @Test("Zooming out at the top-left corner keeps the corner, having nowhere else to go")
    func zoomingOutAtTheCornerStays() {
        let anchor = anchor(fingersAt: CGPoint(x: 300, y: 600))
        #expect(anchor.scrollOffset(at: 0.5, contentSize: content) == .zero)
    }
}
