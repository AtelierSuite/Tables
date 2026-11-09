import AppKit

/// The scroll view's clip view, which hands on a click on the page showing
/// past the sheet's last row or column: there is no view there to take it.
final class SheetClipView: NSClipView {
    /// Called for a click that lands beside the document rather than on it.
    var onClickOutsideDocument: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        // Anything on the document is hit-tested to it, and never gets here.
        guard let onClickOutsideDocument else { return super.mouseDown(with: event) }
        onClickOutsideDocument()
    }
}
