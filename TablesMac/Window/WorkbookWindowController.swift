import AppKit
import TablesEngine

/// A workbook's window: the toolbar, and the sheet beneath it.
@MainActor
final class WorkbookWindowController: NSWindowController, NSWindowDelegate {
    let workbookViewController = WorkbookViewController()
    private var toolbarController: WorkbookToolbar?
    /// Typing in a cell or the formula bar is undone here, apart from the
    /// workbook's own steps: once the edit is written into the cell, the
    /// whole of it is one step on the document's stack.
    let textUndoManager = UndoManager()
    private var observer: NSObjectProtocol?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: true
        )
        window.minSize = NSSize(width: 520, height: 360)
        window.tabbingMode = .preferred
        window.toolbarStyle = .unified
        super.init(window: window)
        window.delegate = self
        window.contentViewController = workbookViewController
        window.setContentSize(NSSize(width: 1080, height: 720))
        window.center()
        windowFrameAutosaveName = "Workbook"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var document: AnyObject? {
        didSet {
            guard let document = document as? WorkbookDocument else { return }
            workbookViewController.document = document
            let toolbar = WorkbookToolbar(document: document)
            toolbarController = toolbar
            window?.toolbar = toolbar.toolbar
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = NotificationCenter.default.addObserver(
                forName: .workbookDocumentDidChange, object: document, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            refresh()
            window?.initialFirstResponder = workbookViewController.grid
            window?.makeFirstResponder(workbookViewController.grid)
        }
    }

    /// The sheet takes the keyboard whenever nothing else in the window has it.
    func windowDidBecomeKey(_ notification: Notification) {
        guard let window, window.firstResponder === window else { return }
        window.makeFirstResponder(workbookViewController.grid)
    }

    private func refresh() {
        workbookViewController.refresh()
        toolbarController?.refresh()
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        guard let document = document as? WorkbookDocument else { return nil }
        return document.state.editingAddress != nil ? textUndoManager : document.undoManager
    }
}
