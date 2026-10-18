import AppKit
import SwiftUI

/// The macro help book — what Tables can run and what it can't — in a window
/// of its own, shared by every workbook.
@MainActor
final class MacroHelpWindowController: NSWindowController {
    static let shared = MacroHelpWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: true
        )
        window.title = String(localized: "Help.Title")
        window.contentViewController = NSHostingController(rootView: NavigationStack { MacroHelpView() })
        window.setContentSize(NSSize(width: 620, height: 680))
        window.center()
        super.init(window: window)
        windowFrameAutosaveName = "MacroHelp"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
