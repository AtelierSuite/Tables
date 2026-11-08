import AppKit
import SwiftUI
import TablesEngine

/// A workbook's window: the toolbar, the sheet beneath it, and the
/// inspector beside it.
@MainActor
final class WorkbookWindowController: NSWindowController, NSWindowDelegate {
    let workbookViewController = WorkbookViewController()
    private let splitViewController = NSSplitViewController()
    private var inspectorItem: NSSplitViewItem?
    private var inspectorObservation: NSKeyValueObservation?
    /// Whether windows open with the inspector showing: as it was last left.
    nonisolated private static let showsInspectorKey = "ShowsInspector"
    /// The workbook as the inspector's SwiftUI panels see it.
    private var hostedWorkbook: HostedWorkbook?
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
        splitViewController.addSplitViewItem(NSSplitViewItem(viewController: workbookViewController))
        splitViewController.splitView.autosaveName = "WorkbookInspector"
        window.contentViewController = splitViewController
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
            installInspector(for: document)
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
        hostedWorkbook?.refresh()
        // Editing a chart opens the inspector, where its settings live.
        if let document = document as? WorkbookDocument, document.state.presentedPanel == .chart {
            document.state.presentedPanel = nil
            if inspectorItem?.isCollapsed == true { inspectorItem?.animator().isCollapsed = false }
        }
    }

    /// The inspector, open or closed as it was last left.
    private func installInspector(for document: WorkbookDocument) {
        if let inspectorItem { splitViewController.removeSplitViewItem(inspectorItem) }
        let model = HostedWorkbook(document: document)
        hostedWorkbook = model
        let host = NSHostingController(rootView: WorkbookInspector(model: model, state: document.state))
        // The split view decides the width; the panels fit themselves to it.
        host.sizingOptions = []
        let item = NSSplitViewItem(inspectorWithViewController: host)
        item.minimumThickness = 280
        item.maximumThickness = 420
        item.isCollapsed = !UserDefaults.standard.bool(forKey: Self.showsInspectorKey)
        splitViewController.addSplitViewItem(item)
        inspectorItem = item
        inspectorObservation = item.observe(\.isCollapsed, options: [.new]) { _, change in
            guard let collapsed = change.newValue else { return }
            UserDefaults.standard.set(!collapsed, forKey: Self.showsInspectorKey)
        }
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        guard let document = document as? WorkbookDocument else { return nil }
        return document.state.editingAddress != nil ? textUndoManager : document.undoManager
    }
}
