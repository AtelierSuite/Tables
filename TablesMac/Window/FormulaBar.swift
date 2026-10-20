import AppKit
import TablesEngine

/// The strip above the grid: the selected cell's name, which can be typed
/// over to go somewhere else, and its contents, which can be edited there
/// instead of in the cell.
@MainActor
final class FormulaBar: NSView, NSTextFieldDelegate {
    weak var document: WorkbookDocument?
    /// The grid, for finishing an edit and pointing at references.
    weak var grid: GridView?

    let nameField = NSTextField()
    let formulaField = NSTextField()
    private let functionLabel = NSTextField(labelWithString: "ƒx")

    override init(frame: NSRect) {
        super.init(frame: frame)

        nameField.placeholderString = "A1"
        nameField.alignment = .center
        nameField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        nameField.delegate = self
        nameField.setAccessibilityLabel(String(localized: "Mac.FormulaBar.CellName"))
        nameField.setAccessibilityIdentifier("cellName")

        functionLabel.textColor = .secondaryLabelColor
        functionLabel.font = .systemFont(ofSize: 13, weight: .medium)

        formulaField.placeholderString = String(localized: "FormulaBar.Field.Placeholder")
        formulaField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        formulaField.delegate = self
        formulaField.cell?.isScrollable = true
        formulaField.cell?.wraps = false
        formulaField.lineBreakMode = .byClipping
        formulaField.setAccessibilityIdentifier("formulaBar")

        let stack = NSStackView(views: [nameField, functionLabel, formulaField])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            nameField.widthAnchor.constraint(equalToConstant: 88),
        ])
        formulaField.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        CGRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    /// Shows the selected cell, or what is being typed into it.
    func refresh() {
        guard let document else { return }
        let state = document.state
        let sheet = document.activeSheet
        let isEditingName = window?.firstResponder === nameField.currentEditor()
        if !isEditingName {
            let box = state.selection.normalized
            nameField.stringValue = box.isSingleCell || sheet.mergedRange(containing: box.start) == box
                ? box.start.a1 : box.a1
        }
        let isEditingHere = window?.firstResponder === formulaField.currentEditor()
        let text = state.editingAddress != nil ? state.editingText : sheet[state.selectedAddress].editableText
        if !isEditingHere || formulaField.stringValue != text {
            if !isEditingHere { formulaField.stringValue = text }
        }
        formulaField.isEditable = !sheet.isChartSheet
    }

    // MARK: - Editing

    func controlTextDidBeginEditing(_ notification: Notification) {
        guard let document, (notification.object as? NSTextField) === formulaField else { return }
        let state = document.state
        if state.editingAddress == nil {
            state.beginEditing(state.selectedAddress, in: document.workbook)
        }
        state.isFormulaBarActive = true
        document.notify()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let document, (notification.object as? NSTextField) === formulaField else { return }
        let state = document.state
        if state.editingAddress == nil {
            state.beginEditing(state.selectedAddress, in: document.workbook)
            state.isFormulaBarActive = true
        }
        state.editingText = formulaField.stringValue
        document.notify()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if control === nameField {
            switch selector {
            case #selector(insertNewline(_:)):
                go(to: nameField.stringValue)
                return true
            case #selector(cancelOperation(_:)):
                window?.makeFirstResponder(grid)
                refresh()
                return true
            default:
                return false
            }
        }
        switch selector {
        case #selector(insertNewline(_:)):
            grid?.commitEditing(then: .down)
        case #selector(insertTab(_:)):
            grid?.commitEditing(then: .right)
        case #selector(cancelOperation(_:)):
            grid?.cancelEditing()
        default:
            return false
        }
        refresh()
        return true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let document, (notification.object as? NSTextField) === formulaField,
              document.state.editingAddress != nil, document.state.isFormulaBarActive else { return }
        // Clicking away keeps what was typed.
        grid?.commitEditing(then: nil)
    }

    /// Selects the cell or range typed into the name box: `B7`, `A1:C4`.
    private func go(to reference: String) {
        guard let document else { return }
        let text = reference.trimmingCharacters(in: .whitespaces).uppercased()
        let parts = text.split(separator: ":").map(String.init)
        let sheet = document.activeSheet
        let state = document.state
        guard let first = parts.first.flatMap(CellAddress.init(a1:)), sheet.contains(first) else {
            NSSound.beep()
            return
        }
        state.select(first, in: sheet)
        if parts.count == 2, let last = CellAddress(a1: parts[1]), sheet.contains(last) {
            state.select(last, extending: true, in: sheet)
        }
        state.scrollTarget = first
        window?.makeFirstResponder(grid)
        document.notify()
    }
}
