import TablesEngine
#if canImport(UIKit)
import UIKit

/// A coordinate frame for gestures that hang off the grid's scroll view.
///
/// The recognizers that read the grid have to be attached to the enclosing
/// scroll view — a view large enough to catch every touch would also swallow
/// the taps the grid below it needs, and one that lets them through cannot be
/// pressed. So they attach upwards and measure downwards: this view never takes
/// a touch, it only says where one landed in the grid's own coordinates.
final class GridTouchFrame: UIView {
    var onEnterWindow: (() -> Void)?

    /// Never takes a touch: everything under it stays reachable.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { false }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { onEnterWindow?() }
    }

    var enclosingScrollView: UIScrollView? {
        var candidate = superview
        while let view = candidate {
            if let scrollView = view as? UIScrollView { return scrollView }
            candidate = view.superview
        }
        return nil
    }

    /// Every recognizer between this frame and the scroll view it hangs from,
    /// which together are all the ones competing for the grid's touches.
    func competingRecognizers() -> [UIGestureRecognizer] {
        var found: [UIGestureRecognizer] = []
        var candidate: UIView? = self
        while let view = candidate {
            found.append(contentsOf: view.gestureRecognizers ?? [])
            if view is UIScrollView { break }
            candidate = view.superview
        }
        return found
    }
}
#endif
