import TablesEngine
#if canImport(UIKit)
import SwiftUI
import UIKit

/// Builds a selection out of several ranges: hold one finger on what is already
/// selected, and every tap or drag made with a second finger adds another range.
/// The hold can be kept up for as long as the user wants to keep adding.
///
/// There is no SwiftUI gesture for this. `DragGesture` reports one finger, and
/// composing two of them cannot express "this finger stays put while that one
/// works", so the whole thing is one UIKit recognizer that watches the touches
/// itself.
struct MultiRangeSelector: UIViewRepresentable {
    /// Whether a finger resting here counts as holding the selection. Only a
    /// press on the selection starts a multi-range gesture — anywhere else, the
    /// sheet keeps its ordinary tap, press and scroll behaviour.
    var isHoldable: (CGPoint) -> Bool
    /// A second finger has landed: start a range at this point.
    var onBeginRange: (CGPoint) -> Void
    /// That finger has moved: the range now reaches this point.
    var onExtendRange: (CGPoint) -> Void
    /// The holding finger has lifted and the gesture is over.
    var onFinish: () -> Void

    func makeUIView(context: Context) -> GridTouchFrame {
        context.coordinator.view
    }

    func updateUIView(_ view: GridTouchFrame, context: Context) {
        let recognizer = context.coordinator.recognizer
        recognizer.isHoldable = isHoldable
        recognizer.onBeginRange = onBeginRange
        recognizer.onExtendRange = onExtendRange
        recognizer.onFinish = onFinish
        // Also tried here because the scroll view is not always an ancestor yet
        // the first time the frame lands in a window.
        context.coordinator.attach()
    }

    static func dismantleUIView(_ view: GridTouchFrame, coordinator: Coordinator) {
        coordinator.detach()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        let view = GridTouchFrame()
        let recognizer: MultiRangeGestureRecognizer

        init() {
            recognizer = MultiRangeGestureRecognizer(frame: view)
            view.onEnterWindow = { [weak self] in self?.attach() }
        }

        func attach() {
            guard recognizer.view == nil, let host = view.enclosingScrollView else { return }
            host.addGestureRecognizer(recognizer)
        }

        func detach() {
            recognizer.view?.removeGestureRecognizer(recognizer)
        }
    }
}

/// One finger holds, the next one draws.
@MainActor
final class MultiRangeGestureRecognizer: UIGestureRecognizer {
    var isHoldable: (CGPoint) -> Bool = { _ in false }
    var onBeginRange: (CGPoint) -> Void = { _ in }
    var onExtendRange: (CGPoint) -> Void = { _ in }
    var onFinish: () -> Void = {}

    /// How long the first finger must rest before a second one means "add a
    /// range" rather than "two fingers landed at once".
    private static let minimumHold: TimeInterval = 0.12
    /// How far the holding finger may drift and still count as holding.
    private static let holdSlop: Double = 12

    private weak var frame: GridTouchFrame?
    private var hold: UITouch?
    private var holdOrigin: CGPoint = .zero
    private var holdBegan: TimeInterval = 0
    /// Set when the holding finger wandered, so it can no longer start a range.
    private var holdMoved = false
    /// Whether a range has been started, which is what lets the next finger
    /// add one without asking about the hold again.
    private var isActive = false
    private var draw: UITouch?
    /// The scroll view's own setting, restored when the gesture is over.
    private var wasScrollEnabled: Bool?

    init(frame: GridTouchFrame) {
        self.frame = frame
        super.init(target: nil, action: nil)
        // Once this begins it owns the touches: the tap that would have moved
        // the selection, and the long press that would have raised the cell
        // menu, both need to let go.
        cancelsTouchesInView = true
        delaysTouchesBegan = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let frame else { return }
        for touch in touches.sorted(by: { $0.timestamp < $1.timestamp }) {
            if hold == nil {
                hold = touch
                holdOrigin = touch.location(in: frame)
                holdBegan = touch.timestamp
                holdMoved = false
            } else if draw == nil, canStartRange(at: touch.timestamp) {
                draw = touch
                if isActive {
                    state = .changed
                } else {
                    isActive = true
                    takeOverTouches()
                    state = .began
                }
                onBeginRange(touch.location(in: frame))
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let frame else { return }
        if let hold, touches.contains(hold), !holdMoved {
            let point = hold.location(in: frame)
            if hypot(point.x - holdOrigin.x, point.y - holdOrigin.y) > Self.holdSlop {
                // A first finger that is really scrolling or dragging is not
                // holding anything, and must not start ranges later on.
                holdMoved = true
            }
        }
        guard isActive, let draw, touches.contains(draw) else { return }
        state = .changed
        onExtendRange(draw.location(in: frame))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        finish(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        finish(touches)
    }

    override func reset() {
        super.reset()
        hold = nil
        draw = nil
        holdMoved = false
        isActive = false
        restoreScrolling()
    }

    /// A finger lifting either ends the range it was drawing — leaving the hold
    /// free to start another — or ends the whole gesture.
    private func finish(_ touches: Set<UITouch>) {
        if let draw, touches.contains(draw) {
            self.draw = nil
            // Deliberately still `.changed`: the hold is down, so the next
            // finger continues this same gesture with another range.
        }
        guard let hold, touches.contains(hold) else { return }
        self.hold = nil
        guard isActive else {
            state = .failed
            return
        }
        onFinish()
        state = .ended
    }

    private func canStartRange(at timestamp: TimeInterval) -> Bool {
        guard !holdMoved, timestamp - holdBegan >= Self.minimumHold else { return false }
        return isActive || isHoldable(holdOrigin)
    }

    /// Cancels everything else competing for these touches.
    ///
    /// `cancelsTouchesInView` only stops touches reaching views; the scroll
    /// view's pan, the sheet's pinch and the grid's own tap are all recognizers,
    /// and a recognizer toggled off drops the touches it was tracking. They come
    /// straight back on, but a recognizer re-enabled mid-touch is not handed
    /// fingers that are already down — so they stay out of the way until the
    /// user lifts off.
    private func takeOverTouches() {
        guard let frame else { return }
        for other in frame.competingRecognizers() where other !== self {
            other.isEnabled = false
            other.isEnabled = true
        }
        if let scrollView = frame.enclosingScrollView, wasScrollEnabled == nil {
            wasScrollEnabled = scrollView.isScrollEnabled
            scrollView.isScrollEnabled = false
        }
    }

    private func restoreScrolling() {
        guard let wasScrollEnabled else { return }
        frame?.enclosingScrollView?.isScrollEnabled = wasScrollEnabled
        self.wasScrollEnabled = nil
    }
}
#endif
