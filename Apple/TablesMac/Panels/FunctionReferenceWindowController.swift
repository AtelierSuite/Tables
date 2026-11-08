import AppKit
import SwiftUI

/// The function reference in a window of its own, shared by every workbook.
/// Inserting a function starts it in the frontmost workbook's selected cell.
@MainActor
final class FunctionReferenceWindowController: NSWindowController {
    static let shared = FunctionReferenceWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: true
        )
        window.title = String(localized: "FunctionReference.Title")
        window.contentViewController = NSHostingController(rootView: FunctionReferenceView { entry in
            Self.insert(entry)
        })
        window.setContentSize(NSSize(width: 920, height: 600))
        window.center()
        super.init(window: window)
        windowFrameAutosaveName = "FunctionReference"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Hands the function to the frontmost workbook. Not through the
    /// responder chain: this window becomes main as well as key, so the
    /// chain would never reach a workbook.
    private static func insert(_ entry: FunctionReference) {
        let workbook = NSApp.orderedWindows.lazy
            .compactMap { $0.windowController as? WorkbookWindowController }
            .first
        guard let workbook else {
            NSSound.beep()
            return
        }
        let sender = NSMenuItem()
        sender.representedObject = entry.name
        workbook.workbookViewController.startFunction(sender)
    }
}
