import AppKit
import TablesEngine

/// The bar Find opens above the grid: text to look for in every sheet, by
/// what cells show or by their formulas, stepped through with Return or
/// Command-G as Find does in any Mac app.
@MainActor
final class FindBar: NSView, NSSearchFieldDelegate {
    weak var document: WorkbookDocument?
    /// Hides the bar again.
    var onClose: () -> Void = {}

    let searchField = NSSearchField()
    private let matchCase = NSButton()
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

        let row = NSStackView(views: [searchField, countLabel, stepper, matchCase, done])
        row.orientation = .horizontal
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
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

    /// Looks again, as cells may have changed since the last search.
    @objc private func queryChanged(_ sender: Any?) {
        guard let document else { return }
        matches = searchField.stringValue.isEmpty ? []
            : document.workbook.matches(for: searchField.stringValue, matchesCase: matchCase.state == .on)
        current = nil
        updateCount()
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
        let match = matches[next]
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
