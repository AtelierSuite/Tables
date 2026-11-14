import AppKit
import TablesEngine

/// Data validation on the grid: the arrow a list rule shows beside its cell,
/// the list it opens, and the input message under the selected cell.
extension GridView {
    /// Where the selected cell's list arrow is drawn: just past the cell's
    /// right edge as in Excel, or inside it where the sheet ends there.
    func dropDownRect(in document: WorkbookDocument) -> NSRect? {
        let state = document.state
        guard state.dropDownRule(in: document.workbook) != nil else { return nil }
        let cell = state.metrics.frame(for: document.activeSheet.expandedToMerges(CellRange(state.selectedAddress)))
        let side = min(18, max(12, cell.height))
        var rect = NSRect(x: cell.maxX + 1, y: cell.maxY - side, width: side, height: side)
        if rect.maxX > bounds.maxX { rect.origin.x = cell.maxX - side - 1 }
        return rect
    }

    /// Draws the list arrow and the input message of the selected cell.
    func drawValidation(in document: WorkbookDocument, context: CGContext) {
        let state = document.state
        if let rect = dropDownRect(in: document) {
            context.saveGState()
            let box = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
            NSColor.controlBackgroundColor.setFill()
            box.fill()
            NSColor.controlAccentColor.setStroke()
            box.lineWidth = 1
            box.stroke()
            let arrow = NSBezierPath()
            let width = rect.width * 0.4, height = rect.height * 0.22
            arrow.move(to: NSPoint(x: rect.midX - width / 2, y: rect.midY - height / 2))
            arrow.line(to: NSPoint(x: rect.midX, y: rect.midY + height / 2))
            arrow.line(to: NSPoint(x: rect.midX + width / 2, y: rect.midY - height / 2))
            arrow.lineWidth = 1.5
            arrow.lineCapStyle = .round
            arrow.lineJoinStyle = .round
            NSColor.controlAccentColor.setStroke()
            arrow.stroke()
            context.restoreGState()
        }

        guard state.editingAddress == nil, !state.isTableUnfocused,
              let message = state.inputMessage(in: document.workbook) else { return }
        let text = NSMutableAttributedString()
        let size = NSFont.smallSystemFontSize
        if !message.title.isEmpty {
            text.append(NSAttributedString(
                string: message.message.isEmpty ? message.title : message.title + "\n",
                attributes: [.font: NSFont.boldSystemFont(ofSize: size), .foregroundColor: NSColor.labelColor]))
        }
        text.append(NSAttributedString(
            string: message.message,
            attributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.labelColor]))
        let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        let fitted = text.boundingRect(with: NSSize(width: 220, height: 400), options: options).size
        let cell = state.metrics.frame(for: document.activeSheet.expandedToMerges(CellRange(state.selectedAddress)))
        let padding: CGFloat = 6
        var box = NSRect(
            x: cell.minX + 10, y: cell.maxY + 6,
            width: ceil(fitted.width) + padding * 2, height: ceil(fitted.height) + padding * 2)
        box.origin.x = max(0, min(box.origin.x, bounds.maxX - box.width - 2))
        context.saveGState()
        let path = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
        Self.inputMessageFill.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
        text.draw(with: box.insetBy(dx: padding, dy: padding), options: options)
        context.restoreGState()
    }

    /// The pale yellow of a note, or its dark counterpart.
    private static let inputMessageFill = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.27, green: 0.25, blue: 0.14, alpha: 1)
            : NSColor(srgbRed: 1, green: 0.98, blue: 0.84, alpha: 1)
    }

    /// Opens the selected cell's list under the cell. False when it has none.
    @discardableResult
    func showDropDown() -> Bool {
        guard let document, let rect = dropDownRect(in: document),
              let items = document.state.dropDownItems(in: document.workbook) else { return false }
        let state = document.state
        let current = CellFormatter.displayText(for: document.activeSheet[state.selectedAddress])
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in items {
            let item = NSMenuItem(title: entry, action: #selector(pickListEntry(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry
            item.state = entry == current ? .on : .off
            menu.addItem(item)
        }
        guard !items.isEmpty else { return true }
        let cell = state.metrics.frame(for: document.activeSheet.expandedToMerges(CellRange(state.selectedAddress)))
        menu.minimumWidth = cell.width
        menu.popUp(positioning: nil, at: NSPoint(x: cell.minX, y: rect.maxY + 2), in: self)
        return true
    }

    @objc func pickListEntry(_ sender: NSMenuItem) {
        guard let document, let entry = sender.representedObject as? String else { return }
        let state = document.state
        document.edit { state.enter(entry, in: &$0) }
    }
}
