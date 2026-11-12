import AppKit
import TablesEngine

/// The bar Find opens above the grid: text to look for in every sheet, by
/// what cells show or by their formulas, stepped through with Return or
/// Command-G as Find does in any Mac app, and replaced in the match in
/// front or in every one.
@MainActor
final class FindBar: NSView, NSSearchFieldDelegate {
    weak var document: WorkbookDocument?
    /// Hides the bar again.
    var onClose: () -> Void = {}

    let searchField = NSSearchField()
    let replaceField = NSTextField()
    private let matchCase = NSButton()
    private let matchWholeCell = NSButton()
    private let lookIn = NSPopUpButton()
    private let replaceLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let stepper = NSSegmentedControl()
    private var matches: [FindMatch] = []
    private var current: Int?

    override init(frame: NSRect) {
        super.init(frame: frame)
        searchField.placeholderString = String(localized: "Find.Placeholder")
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(queryChanged(_:))
        searchField.setAccessibilityIdentifier("findText")

        matchCase.setButtonType(.switch)
        matchCase.title = String(localized: "Find.MatchCase")
        matchCase.target = self
        matchCase.action = #selector(queryChanged(_:))

        matchWholeCell.setButtonType(.switch)
        matchWholeCell.title = String(localized: "Find.MatchWholeCell")
        matchWholeCell.target = self
        matchWholeCell.action = #selector(queryChanged(_:))

        for option in FindOptions.LookIn.allCases {
            lookIn.addItem(withTitle: option.title)
            lookIn.lastItem?.representedObject = option.rawValue
        }
        lookIn.controlSize = .small
        lookIn.toolTip = String(localized: "Find.LookIn")
        lookIn.target = self
        lookIn.action = #selector(queryChanged(_:))

        replaceField.placeholderString = String(localized: "Find.ReplacePlaceholder")
        replaceField.setAccessibilityIdentifier("replaceText")
        replaceField.delegate = self
        let replace = NSButton(title: String(localized: "Find.Replace"), target: self, action: #selector(replaceOne(_:)))
        let replaceAll = NSButton(title: String(localized: "Find.ReplaceAll"), target: self, action: #selector(replaceAll(_:)))
        for button in [replace, replaceAll] {
            button.bezelStyle = .push
            button.controlSize = .small
        }
        replaceLabel.textColor = .secondaryLabelColor
        replaceLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        replaceLabel.lineBreakMode = .byTruncatingTail
        // The result takes what room the row has left, and no more.
        replaceLabel.setContentCompressionResistancePriority(.fittingSizeCompression, for: .horizontal)
        replaceLabel.setContentHuggingPriority(.fittingSizeCompression, for: .horizontal)

        countLabel.textColor = .secondaryLabelColor
        countLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        stepper.segmentCount = 2
        stepper.trackingMode = .momentary
        stepper.setImage(NSImage(systemSymbolName: "chevron.left", accessibilityDescription: String(localized: "Mac.Menu.FindPrevious")), forSegment: 0)
        stepper.setImage(NSImage(systemSymbolName: "chevron.right", accessibilityDescription: String(localized: "Mac.Menu.FindNext")), forSegment: 1)
        stepper.target = self
        stepper.action = #selector(step(_:))

        let done = NSButton(title: String(localized: "Mac.Find.Done"), target: self, action: #selector(close(_:)))
        done.bezelStyle = .push
        done.controlSize = .small

        let row = NSStackView(views: [searchField, countLabel, stepper, matchCase, matchWholeCell, done])
        row.orientation = .horizontal
        row.spacing = 10
        let replaceRow = NSStackView(views: [replaceField, replace, replaceAll, lookIn, replaceLabel])
        replaceRow.orientation = .horizontal
        replaceRow.spacing = 10
        let rows = NSStackView(views: [row, replaceRow])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 6
        rows.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        rows.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rows)
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: trailingAnchor),
            rows.centerYAnchor.constraint(equalTo: centerYAnchor),
            row.trailingAnchor.constraint(equalTo: rows.trailingAnchor, constant: -10),
            replaceRow.trailingAnchor.constraint(equalTo: rows.trailingAnchor, constant: -10),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
            replaceField.widthAnchor.constraint(equalTo: searchField.widthAnchor),
        ])
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        CGRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    var query: String {
        get { searchField.stringValue }
        set {
            searchField.stringValue = newValue
            queryChanged(nil)
        }
    }

    private var options: FindOptions {
        FindOptions(
            matchesCase: matchCase.state == .on,
            matchesWholeCell: matchWholeCell.state == .on,
            lookIn: (lookIn.selectedItem?.representedObject as? String).flatMap(FindOptions.LookIn.init) ?? .formulasAndValues
        )
    }

    /// Looks again, as cells may have changed since the bar was last up.
    func refresh() { queryChanged(nil) }

    /// Looks again, as cells may have changed since the last search.
    @objc private func queryChanged(_ sender: Any?) {
        guard let document else { return }
        matches = searchField.stringValue.isEmpty ? []
            : document.workbook.matches(for: searchField.stringValue, options: options)
        current = nil
        replaceLabel.stringValue = ""
        replaceLabel.toolTip = nil
        updateCount()
    }

    /// Replaces the selected match, or the next one, then goes to the match
    /// after it.
    @objc private func replaceOne(_ sender: Any?) {
        guard let document else { return }
        queryChanged(nil)
        let state = document.state
        guard let sheetID = state.activeSheetID,
              let target = FindReplace.target(
                  in: matches, sheetID: sheetID, address: state.selectedAddress, workbook: document.workbook
              ) else { return NSSound.beep() }
        var result = ReplaceResult()
        document.edit { result = $0.replace([target], query: searchField.stringValue, with: replaceField.stringValue, options: options) }
        queryChanged(nil)
        showSummary(of: result)
        if let next = FindReplace.next(after: target.sheetID, target.address, in: matches, workbook: document.workbook) {
            current = matches.firstIndex(of: next)
            show(next, in: document)
        }
    }

    /// What the last Replace did, on one line; the whole of it in the tooltip
    /// when the bar is too narrow for it.
    private func showSummary(of result: ReplaceResult) {
        replaceLabel.stringValue = FindReplace.summary(of: result).replacingOccurrences(of: "\n", with: " · ")
        replaceLabel.toolTip = FindReplace.summary(of: result)
    }

    /// Replaces every match in the workbook, as one step to undo.
    @objc private func replaceAll(_ sender: Any?) {
        guard let document, !searchField.stringValue.isEmpty else { return }
        var result = ReplaceResult()
        document.edit { result = $0.replaceAll(searchField.stringValue, with: replaceField.stringValue, options: options) }
        queryChanged(nil)
        showSummary(of: result)
    }

    private func updateCount() {
        countLabel.stringValue = searchField.stringValue.isEmpty ? ""
            : String.localizedStringWithFormat(String(localized: "Find.Count"), matches.count)
        stepper.isEnabled = !matches.isEmpty
    }

    @objc private func step(_ sender: NSSegmentedControl) {
        sender.selectedSegment == 0 ? findPrevious() : findNext()
    }

    func findNext() { show(offset: 1) }
    func findPrevious() { show(offset: -1) }

    /// Goes to the next or previous match: brings its sheet up and selects it.
    private func show(offset: Int) {
        guard let document else { return }
        if matches.isEmpty { queryChanged(nil) }
        guard !matches.isEmpty else { return NSSound.beep() }
        let next = current.map { ($0 + offset + matches.count) % matches.count } ?? (offset > 0 ? 0 : matches.count - 1)
        current = next
        show(matches[next], in: document)
    }

    /// Brings the match's sheet up and selects it.
    private func show(_ match: FindMatch, in document: WorkbookDocument) {
        let state = document.state
        if state.activeSheetID != match.sheetID { document.selectSheet(match.sheetID) }
        guard let sheet = document.workbook[match.sheetID] else { return }
        state.select(match.address, in: sheet)
        state.scrollTarget = match.address
        document.notify()
    }

    @objc private func close(_ sender: Any?) { onClose() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(insertTab(_:)) where control === searchField,
             #selector(insertBacktab(_:)) where control === searchField:
            window?.makeFirstResponder(replaceField)
        case #selector(insertTab(_:)) where control === replaceField,
             #selector(insertBacktab(_:)) where control === replaceField:
            window?.makeFirstResponder(searchField)
        case #selector(insertNewline(_:)) where control === replaceField:
            replaceOne(nil)
        case #selector(insertNewline(_:)):
            NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? findPrevious() : findNext()
        case #selector(cancelOperation(_:)):
            onClose()
        default:
            return false
        }
        return true
    }
}
