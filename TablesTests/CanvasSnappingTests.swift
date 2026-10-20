import CoreGraphics
import Testing
@testable import Tables

@Suite("Lining tables up on a canvas")
struct CanvasSnappingTests {
    private let other = CGRect(x: 100, y: 100, width: 200, height: 300)

    @Test("A table close to another's edge snaps to it, with a guide across both")
    func snapsToEdges() {
        let dragged = CGRect(x: 104, y: 450, width: 120, height: 80)
        let result = CanvasSnapping.snap(dragged, among: [other])
        #expect(result.origin == CGPoint(x: 100, y: 450))
        #expect(result.guides == [.init(axis: .vertical, position: 100, start: 100, end: 530)])
    }

    @Test("Middles line up as well as edges, and both axes at once")
    func snapsToMiddlesAndBothAxes() {
        // Its middle 3 points left of the other's, its top 5 below.
        let dragged = CGRect(x: 137, y: 105, width: 120, height: 80)
        let result = CanvasSnapping.snap(dragged, among: [other])
        #expect(result.origin == CGPoint(x: 140, y: 100))
        #expect(result.guides.contains { $0.axis == .vertical && $0.position == 200 })
        #expect(result.guides.contains { $0.axis == .horizontal && $0.position == 100 })
    }

    @Test("Nothing near enough leaves a table where it was put, with no guides")
    func farAwayStays() {
        let dragged = CGRect(x: 420, y: 520, width: 120, height: 80)
        let result = CanvasSnapping.snap(dragged, among: [other])
        #expect(result.origin == CGPoint(x: 420, y: 520))
        #expect(result.guides.isEmpty)
    }

    @Test("A table never leaves the page, however far it is dragged past the top or left")
    func staysOnThePage() {
        let dragged = CGRect(x: -900, y: -40, width: 120, height: 80)
        #expect(CanvasSnapping.snap(dragged, among: []).origin == .zero)
        // With room left for its grip and its name.
        let minimum = CanvasSnapping.minimumOrigin(zoom: 1)
        #expect(minimum == CGPoint(x: 24, y: 26))
        #expect(CanvasSnapping.snap(dragged, among: [], minimum: minimum).origin == minimum)
    }
}
