import AppKit
import SwiftUI
import TablesEngine

/// The strip of sheet tabs under the grid.
///
/// A click shows a sheet, a double-click renames it, dragging reorders, and
/// a right-click offers the rest. Hidden sheets come back from the menu beside
/// the add button. Sheets laid out together on a canvas take one tab, named
/// for the canvas; its tables are picked on the canvas itself.
@MainActor
final class SheetTabBar: NSVisualEffectView, NSTextFieldDelegate {
    weak var document: WorkbookDocument?
    /// Builds the menu for a right-click on a tab.
    var tabMenu: ((Worksheet.ID) -> NSMenu?)?

    private let addButton = NSButton()
    private let hiddenButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private var hiddenGlass = NSView()
    private let tabStack = NSStackView()
    private let scrollView = NSScrollView()
    private var renameField: NSTextField?
    private var renamingID: Worksheet.ID?

    override init(frame: NSRect) {
        super.init(frame: frame)
        // A bar of material the sheet scrolls under, as a window's title bar is.
        material = .titlebar
        blendingMode = .withinWindow
        state = .followsWindowActiveState
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)
        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: String(localized: "SheetTabBar.AddSheet"))
        addButton.isBordered = false
        addButton.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        addButton.target = self
        addButton.action = #selector(addSheet(_:))
        addButton.toolTip = String(localized: "SheetTabBar.AddSheet")

        hiddenButton.isBordered = false
        hiddenButton.toolTip = String(localized: "SheetTabBar.ShowHiddenSheet")
        (hiddenButton.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow

        tabStack.orientation = .horizontal
        tabStack.spacing = 6
        tabStack.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        let clip = FlippedClipView()
        scrollView.contentView = clip
        scrollView.documentView = tabStack
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.horizontalScrollElasticity = .allowed
        tabStack.translatesAutoresizingMaskIntoConstraints = false

        let addGlass = GlassCircle(content: addButton)
        hiddenGlass = GlassCircle(content: hiddenButton)
        let row = NSStackView(views: [addGlass, hiddenGlass, scrollView])
        row.orientation = .horizontal
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            tabStack.topAnchor.constraint(equalTo: clip.topAnchor),
            tabStack.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
            tabStack.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            scrollView.heightAnchor.constraint(equalTo: row.heightAnchor),
        ])
        scrollView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        scrollView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }


    // MARK: - Sheets

    /// The sheets on the canvas a sheet shares, in order; empty when it has
    /// the page to itself.
    private func tables(sharingTabWith sheet: Worksheet, in document: WorkbookDocument) -> [Worksheet] {
        guard let canvas = document.workbook.canvas(containing: sheet.id) else { return [] }
        let sheets = document.workbook.sheets(on: canvas)
        return sheets.count > 1 ? sheets : []
    }

    /// Every visible sheet, but only the first of a canvas's tables.
    private func tabSheets(in document: WorkbookDocument) -> [Worksheet] {
        document.workbook.visibleSheets.filter { sheet in
            tables(sharingTabWith: sheet, in: document).first.map { $0.id == sheet.id } ?? true
        }
    }

    private func tabName(for sheet: Worksheet, in document: WorkbookDocument) -> String {
        guard !tables(sharingTabWith: sheet, in: document).isEmpty,
              let name = document.workbook.canvas(containing: sheet.id)?.name, !name.isEmpty else { return sheet.name }
        return name
    }

    func refresh() {
        guard let document, renamingID == nil else { return }
        let workbook = document.workbook
        let active = document.activeSheet
        let activeTables = tables(sharingTabWith: active, in: document)
        let activeTab = activeTables.first?.id ?? active.id

        let sheets = tabSheets(in: document)
        var tabs = tabStack.arrangedSubviews.compactMap { $0 as? SheetTab }
        while tabs.count > sheets.count { tabs.removeLast().removeFromSuperview() }
        while tabs.count < sheets.count {
            let tab = SheetTab()
            tab.bar = self
            tabStack.addArrangedSubview(tab)
            tabs.append(tab)
        }
        for (tab, sheet) in zip(tabs, sheets) {
            tab.configure(id: sheet.id, title: tabName(for: sheet, in: document), isActive: sheet.id == activeTab,
                          colorHex: sheet.tabColorHex)
        }
        tabStack.layoutSubtreeIfNeeded()
        if let current = tabs.first(where: { $0.sheetID == activeTab }) {
            current.scrollToVisible(current.bounds)
        }

        let hidden = workbook.sheets.filter(\.isHidden)
        hiddenGlass.isHidden = hidden.isEmpty
        hiddenButton.removeAllItems()
        hiddenButton.addItem(withTitle: "")
        hiddenButton.item(at: 0)?.image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: String(
            format: String(localized: "SheetTabBar.HiddenSheets.Accessibility"), hidden.count))
        for sheet in hidden {
            let item = NSMenuItem(title: sheet.name, action: #selector(showHiddenSheet(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = sheet.id
            hiddenButton.menu?.addItem(item)
        }
    }

    // MARK: - Actions

    @objc private func addSheet(_ sender: Any?) {
        guard let document else { return }
        let state = document.state
        document.edit { state.addSheet(in: &$0) }
        document.refreshCapabilities()
        document.notify()
    }

    @objc private func showHiddenSheet(_ sender: NSMenuItem) {
        guard let document, let id = sender.representedObject as? Worksheet.ID else { return }
        let state = document.state
        document.edit { state.setSheet(id, hidden: false, in: &$0) }
        document.refreshCapabilities()
        document.notify()
    }

    /// A tab already showing one of its canvas's tables stays on that table.
    fileprivate func select(_ id: Worksheet.ID) {
        guard let document, let sheet = document.workbook[id] else { return }
        if tables(sharingTabWith: sheet, in: document).contains(where: { $0.id == document.activeSheet.id }) { return }
        document.selectSheet(id)
    }

    fileprivate func menu(for id: Worksheet.ID) -> NSMenu? {
        select(id)
        return tabMenu?(id)
    }

    /// Moves a dragged tab to wherever it was let go.
    fileprivate func drop(_ id: Worksheet.ID, atX x: CGFloat) {
        guard let document else { return }
        let tabs = tabStack.arrangedSubviews.compactMap { $0 as? SheetTab }
        let point = tabStack.convert(CGPoint(x: x, y: 0), from: nil)
        guard let target = tabs.first(where: { point.x < $0.frame.maxX }) ?? tabs.last,
              target.sheetID != id, let destination = document.workbook.index(of: target.sheetID) else { return }
        document.edit { $0.moveSheet(id, to: destination) }
    }

    // MARK: - Renaming

    /// Swaps a tab's name for a field to type its new one in.
    func beginRenaming(_ id: Worksheet.ID) {
        guard let document, let tab = tabStack.arrangedSubviews.compactMap({ $0 as? SheetTab })
            .first(where: { $0.sheetID == id }), let sheet = document.workbook[id] else { return }
        // A canvas's tab is the canvas's name, which only a file that keeps
        // canvases can change.
        let isCanvas = !tables(sharingTabWith: sheet, in: document).isEmpty
        if isCanvas, !document.state.allowsLayingOutTables { return }
        let field = NSTextField(string: tabName(for: sheet, in: document))
        field.delegate = self
        field.font = .systemFont(ofSize: 12)
        field.focusRingType = .none
        field.frame = tab.convert(tab.bounds, to: self).insetBy(dx: 2, dy: 3)
        addSubview(field)
        renameField = field
        renamingID = id
        window?.makeFirstResponder(field)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = renameField, let id = renamingID else { return }
        let name = field.stringValue
        renameField = nil
        renamingID = nil
        field.removeFromSuperview()
        if (notification.userInfo?["NSTextMovement"] as? Int) != NSTextMovement.cancel.rawValue, let document {
            if let sheet = document.workbook[id], !tables(sharingTabWith: sheet, in: document).isEmpty {
                let state = document.state
                document.edit { state.renameCanvas(containing: id, to: name, in: &$0) }
            } else {
                document.edit { $0.renameSheet(id, to: name) }
            }
        }
        refresh()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(cancelOperation(_:)), let field = renameField else { return false }
        renameField = nil
        renamingID = nil
        field.removeFromSuperview()
        refresh()
        return true
    }
}

/// One sheet's tab: a capsule of glass, tinted when it is the sheet in
/// front, as the tabs are on the iPhone and iPad.
@MainActor
private final class SheetTab: NSView {
    weak var bar: SheetTabBar?
    private(set) var sheetID = UUID()
    private var title = ""
    private var isActive = false
    private var colorHex: String?
    private var dragStart: CGFloat?
    private var isDragging = false

    private let glass = NSGlassEffectView()
    private let label = NSTextField(labelWithString: "")
    private let colorBar = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        let content = NSView()
        for view in [label, colorBar] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        colorBar.wantsLayer = true
        colorBar.layer?.cornerRadius = 1
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            colorBar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            colorBar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            colorBar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -3),
            colorBar.heightAnchor.constraint(equalToConstant: 2),
        ])
        glass.contentView = content
        glass.cornerRadius = 15
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.centerYAnchor.constraint(equalTo: centerYAnchor),
            glass.heightAnchor.constraint(equalToConstant: 30),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(label.intrinsicContentSize.width) + 28, height: 30)
    }

    func configure(id: Worksheet.ID, title: String, isActive: Bool, colorHex: String?) {
        guard id != sheetID || title != self.title || isActive != self.isActive || colorHex != self.colorHex else { return }
        sheetID = id
        self.title = title
        self.isActive = isActive
        self.colorHex = colorHex
        label.stringValue = title
        label.font = .systemFont(ofSize: 13, weight: isActive ? .semibold : .regular)
        label.textColor = isActive ? .controlAccentColor : .labelColor
        glass.tintColor = isActive ? NSColor.controlAccentColor.withAlphaComponent(0.22) : nil
        let tint = Color(argbHex: colorHex).map(NSColor.init)
        colorBar.isHidden = tint == nil
        colorBar.layer?.backgroundColor = tint?.cgColor
        setAccessibilityLabel(title)
        setAccessibilityValue(isActive)
        invalidateIntrinsicContentSize()
    }

    /// The glass is shown, not used: clicks belong to the tab.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            bar?.beginRenaming(sheetID)
            return
        }
        bar?.select(sheetID)
        dragStart = event.locationInWindow.x
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }
        if abs(event.locationInWindow.x - dragStart) > 6 { isDragging = true }
        if isDragging { NSCursor.closedHand.set() }
    }

    override func mouseUp(with event: NSEvent) {
        if isDragging { bar?.drop(sheetID, atX: event.locationInWindow.x) }
        NSCursor.arrow.set()
        dragStart = nil
        isDragging = false
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        bar?.menu(for: sheetID)
    }
}

/// A round piece of glass around a small control, as the add and hidden
/// sheets buttons sit on the iPhone and iPad.
@MainActor
private final class GlassCircle: NSView {
    init(content: NSView) {
        super.init(frame: .zero)
        let glass = NSGlassEffectView()
        glass.cornerRadius = 15
        content.translatesAutoresizingMaskIntoConstraints = false
        let holder = NSView()
        holder.addSubview(content)
        glass.contentView = holder
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 30),
            glass.widthAnchor.constraint(equalToConstant: 30),
            glass.heightAnchor.constraint(equalToConstant: 30),
            glass.centerXAnchor.constraint(equalTo: centerXAnchor),
            glass.centerYAnchor.constraint(equalTo: centerYAnchor),
            content.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
            content.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
            content.widthAnchor.constraint(equalToConstant: 30),
            content.heightAnchor.constraint(equalToConstant: 30),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// A clip view that lays its document out from the top, as the rest of the
/// window does.
final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}
