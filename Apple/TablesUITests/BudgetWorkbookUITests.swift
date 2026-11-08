import XCTest

/// Builds a real budgeting workbook through the interface, the way a person
/// would: create the document, lay out and format each sheet's template, then
/// type the numbers in.
///
/// This is deliberately one long test rather than several. Each test method
/// relaunches the app into a fresh document, so a workbook assembled across
/// several methods would never exist as one artefact — and the point here is
/// that the parts work *together*: cross-sheet formulas reading totals that
/// another sheet's SUM produced, formatting surviving later edits, and the
/// numbers arriving last against a template that was already styled.
final class BudgetWorkbookUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication.launchedInEnglish()
    }

    // MARK: - Building blocks

    private func cell(_ reference: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "cell.\(reference)").firstMatch
    }

    private var addressBox: XCUIElement { app.staticTexts["addressBox"] }

    /// Waits for the selection to actually reach a cell. The editor travels with
    /// the selection, so typing before it lands puts the text in the wrong cell.
    private func waitForSelection(_ reference: String, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while addressBox.label != reference, Date() < deadline {
            usleep(50_000)
        }
        XCTAssertEqual(addressBox.label, reference, "the selection never reached \(reference)")
    }

    /// `expecting` differs from `reference` where the tap lands in a merged
    /// region, because selecting one of its cells selects the whole thing.
    private func select(_ reference: String, expecting: String? = nil) {
        let target = cell(reference)
        XCTAssertTrue(target.waitForExistence(timeout: 5), "missing cell \(reference)")
        uncover(in: app)
        target.tap()
        waitForSelection(expecting ?? reference)
    }

    private func enter(_ text: String, into reference: String) {
        enterText(text, into: reference, in: app)
    }

    /// Fills a row left to right from a starting column.
    private func enterRow(_ values: [String], startingAt reference: String) {
        guard let start = reference.first.map(String.init),
              let column = start.unicodeScalars.first?.value,
              let row = Int(reference.dropFirst()) else {
            XCTFail("malformed reference \(reference)")
            return
        }
        for (offset, value) in values.enumerated() where !value.isEmpty {
            let letter = String(UnicodeScalar(column + UInt32(offset))!)
            enter(value, into: "\(letter)\(row)")
        }
    }

    private func openPanel(_ control: String, titled title: String) {
        let button = app.buttons[control]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "the \(control) control is missing")
        button.tap()
        XCTAssertTrue(
            app.navigationBars[title].waitForExistence(timeout: 5), "the \(title) panel never opened"
        )
    }

    private func openFormatPanel() { openPanel("Format", titled: "Format") }
    private func openNumberFormatPanel() { openPanel("Number format", titled: "Number Format") }

    /// Panels close with the label-less Done button in their own navigation bar.
    private func dismissPanel(_ title: String) {
        let done = app.navigationBars[title].buttons.firstMatch
        if done.waitForExistence(timeout: 5) { done.tap() }
        XCTAssertTrue(addressBox.waitForExistence(timeout: 5), "the grid never came back")
    }

    /// Taps a control that may have scrolled out of the panel's visible area.
    ///
    /// Scrolls the form itself rather than the screen, so the swipe cannot be
    /// mistaken for a drag on the sheet's grabber and dismiss the panel — and
    /// only ever downward, since swiping down at the top of a sheet dismisses
    /// it. Callers must therefore visit a panel's controls in layout order.
    private func tapInPanel(_ element: XCUIElement, name: String) {
        for _ in 0..<4 {
            if element.exists, element.isHittable { break }
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(element.waitForExistence(timeout: 5), "\(name) is missing from the panel")
        element.tap()
    }

    // MARK: - Formatting vocabulary

    /// Applies a fill and text colour from the HIG system palette.
    private func applyColours(fill: String?, text: String?) {
        openFormatPanel()
        if let text { tapSwatch(text, role: "textColor") }
        if let fill { tapSwatch(fill, role: "fillColor") }
        dismissPanel("Format")
    }

    /// Taps a swatch in a colour carousel, scrolling the panel down to the
    /// carousel and then the carousel itself sideways until the swatch lands.
    private func tapSwatch(_ id: String, role: String) {
        let carousel = app.scrollViews[role + ".swatches"]
        for _ in 0..<4 {
            if carousel.exists, carousel.isHittable { break }
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(carousel.waitForExistence(timeout: 5), "the \(role) carousel is missing")

        let swatch = app.buttons["\(role).\(id)"]
        for _ in 0..<6 {
            if swatch.exists, swatch.isHittable { break }
            carousel.swipeLeft()
        }
        XCTAssertTrue(swatch.waitForExistence(timeout: 5), "\(role) \(id) is missing from the carousel")
        swatch.tap()
    }

    private func applyNumberFormat(_ preset: String) {
        openNumberFormatPanel()
        tapInPanel(app.staticTexts[preset], name: "number format \(preset)")
        dismissPanel("Number Format")
    }

    private func toggleBold() {
        let bold = app.buttons["Bold"]
        XCTAssertTrue(bold.waitForExistence(timeout: 10), "the Bold control is missing")
        bold.tap()
    }

    private func centre() {
        // The alignment control cycles left → centre → right → automatic.
        let alignment = app.buttons["Alignment"]
        XCTAssertTrue(alignment.waitForExistence(timeout: 10), "the Alignment control is missing")
        alignment.tap()
        alignment.tap()
    }

    /// Drags the selection grip so a range, not a single cell, is formatted.
    private func extendSelection(from origin: String, to destination: String) {
        select(origin)
        let grip = app.descendants(matching: .any).matching(identifier: "selectionGrip").firstMatch
        let target = cell(destination)
        XCTAssertTrue(grip.waitForExistence(timeout: 5), "the selection grip is missing")
        XCTAssertTrue(target.waitForExistence(timeout: 5), "missing cell \(destination)")
        grip.press(forDuration: 0.1, thenDragTo: target)
        waitForSelection("\(origin):\(destination)")
    }

    // MARK: - Sheets

    private func addSheet(named name: String) {
        let add = app.buttons["Add a sheet"]
        XCTAssertTrue(add.waitForExistence(timeout: 10), "the add-sheet control is missing")
        add.tap()
        renameCurrentSheet(to: name)
    }

    /// Double-tapping a tab raises its menu; rename is the first entry.
    private func renameCurrentSheet(to name: String) {
        let tab = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Sheet'")).firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 5), "no active sheet tab to rename")
        tab.doubleTap()

        let rename = app.buttons["Rename…"]
        XCTAssertTrue(rename.waitForExistence(timeout: 5), "the sheet menu never appeared")
        rename.tap()

        let field = app.textFields["Sheet name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the rename field never appeared")
        field.tap()
        // Replace rather than append: the field is pre-filled with the old name.
        // Deleting it character by character works whether or not the
        // simulator has a hardware keyboard to take a select-all shortcut.
        let existing = (field.value as? String) ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count + 2))
        field.typeText(name + "\n")
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 5), "the sheet was not renamed to \(name)")
    }

    private func switchToSheet(named name: String) {
        let tab = app.staticTexts[name]
        XCTAssertTrue(tab.waitForExistence(timeout: 5), "no tab named \(name)")
        tab.tap()
        XCTAssertTrue(cell("A1").waitForExistence(timeout: 5), "\(name) never came up")
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - The workbook

    func testBuildsBudgetWorkbook() throws {
        openNewDocument()
        capture("00-new-document")

        buildIncomeSheet()
        buildExpensesSheet()
        buildSummarySheet()

        verifyTotalsAndCrossSheetFormulas()
        capture("04-finished-workbook")
    }

    private func openNewDocument() {
        let formulaField = app.textFields["formulaField"]
        if formulaField.waitForExistence(timeout: 5) {
            settle()
            return
        }

        let create = app.buttons["Create Document"]
        XCTAssertTrue(create.waitForExistence(timeout: 30), "the document browser never appeared")
        create.tap()

        if !formulaField.waitForExistence(timeout: 20) {
            // The simulator's browser refuses new files after a few per session;
            // an existing workbook is fine for this test.
            let alert = app.alerts.buttons.firstMatch
            if alert.exists { alert.tap() }
            let existing = app.collectionViews.cells.firstMatch
            if existing.waitForExistence(timeout: 5) { existing.doubleTap() } else if create.exists { create.tap() }
        }
        XCTAssertTrue(formulaField.waitForExistence(timeout: 30), "the editor never appeared")
        settle()
    }

    /// Income: a titled, coloured header band, three sources, and a SUM total.
    private func buildIncomeSheet() {
        renameCurrentSheet(to: "Income")

        enter("Income 2026", into: "A1")
        select("A1")
        toggleBold()
        applyColours(fill: "green", text: "white")

        enterRow(["Source", "Planned", "Actual"], startingAt: "A3")
        extendSelection(from: "A3", to: "C3")
        toggleBold()
        centre()
        applyColours(fill: "gray6", text: nil)

        enterRow(["Salary", "5200", "5200"], startingAt: "A4")
        enterRow(["Freelance", "800", "1150"], startingAt: "A5")
        enterRow(["Interest", "45", "52"], startingAt: "A6")

        enter("Total", into: "A8")
        enter("=SUM(B4:B6)", into: "B8")
        enter("=SUM(C4:C6)", into: "C8")

        select("A8")
        toggleBold()

        extendSelection(from: "B4", to: "C8")
        applyNumberFormat("Currency")

        XCTAssertEqual(cell("B8").label, "B8, $6,045.00", "income planned total is wrong")
        XCTAssertEqual(cell("C8").label, "C8, $6,402.00", "income actual total is wrong")
        capture("01-income-sheet")
    }

    /// Expenses: five categories, a SUM total, and an IF flagging overspend.
    private func buildExpensesSheet() {
        addSheet(named: "Expenses")

        enter("Expenses 2026", into: "A1")
        select("A1")
        toggleBold()
        applyColours(fill: "red", text: "white")

        // The template is four columns wide; a new sheet starts at five, so the
        // extra column is left for notes rather than deleted.
        enterRow(["Category", "Planned", "Actual", "Status"], startingAt: "A3")
        extendSelection(from: "A3", to: "D3")
        toggleBold()
        centre()
        applyColours(fill: "gray6", text: nil)

        let categories = [
            ["Rent", "1800", "1800"],
            ["Groceries", "650", "712"],
            ["Transport", "220", "198"],
            ["Utilities", "180", "205"],
            ["Subscriptions", "60", "60"],
        ]
        for (offset, row) in categories.enumerated() {
            let line = offset + 4
            enterRow(row, startingAt: "A\(line)")
            enter("=IF(C\(line)>B\(line),\"Over\",\"OK\")", into: "D\(line)")
        }

        enter("Total", into: "A10")
        enter("=SUM(B4:B8)", into: "B10")
        enter("=SUM(C4:C8)", into: "C10")

        select("A10")
        toggleBold()

        extendSelection(from: "B4", to: "C10")
        applyNumberFormat("Currency")

        XCTAssertEqual(cell("B10").label, "B10, $2,910.00", "expenses planned total is wrong")
        XCTAssertEqual(cell("C10").label, "C10, $2,975.00", "expenses actual total is wrong")
        XCTAssertEqual(cell("D5").label, "D5, Over", "groceries overspend was not flagged")
        XCTAssertEqual(cell("D6").label, "D6, OK", "transport was under budget and should read OK")
        capture("02-expenses-sheet")
    }

    /// Summary: a merged title and cross-sheet formulas reading the other totals.
    private func buildSummarySheet() {
        addSheet(named: "Summary")

        enter("Monthly Budget", into: "A1")
        extendSelection(from: "A1", to: "D1")
        // Colours first, then merge: the panel only ever scrolls downward, and
        // Merge sits below the colour sections.
        applyColours(fill: "blue", text: "white")
        // The range is still selected — re-tapping A1 here would collapse it
        // before there is a merge to expand it again.
        openFormatPanel()
        tapInPanel(app.buttons["Merge Cells"], name: "Merge Cells")
        dismissPanel("Format")
        select("A1", expecting: "A1:D1")
        toggleBold()
        centre()

        enterRow(["Category", "Planned", "Actual", "Variance"], startingAt: "A3")
        extendSelection(from: "A3", to: "D3")
        toggleBold()
        centre()
        applyColours(fill: "gray5", text: nil)

        enter("Income", into: "A4")
        enter("=Income!B8", into: "B4")
        enter("=Income!C8", into: "C4")
        enter("=C4-B4", into: "D4")

        enter("Expenses", into: "A5")
        enter("=Expenses!B10", into: "B5")
        enter("=Expenses!C10", into: "C5")
        enter("=C5-B5", into: "D5")

        enter("Net", into: "A6")
        enter("=B4-B5", into: "B6")
        enter("=C4-C5", into: "C6")
        enter("=C6-B6", into: "D6")

        select("A6")
        toggleBold()

        extendSelection(from: "B4", to: "D6")
        applyNumberFormat("Currency")

        enter("Savings rate", into: "A8")
        enter("=C6/C4", into: "B8")
        select("B8")
        applyNumberFormat("Percentage")
        applyColours(fill: nil, text: "indigo")

        capture("03-summary-sheet")
    }

    /// The whole point of the workbook: the summary is derived, not typed.
    private func verifyTotalsAndCrossSheetFormulas() {
        switchToSheet(named: "Summary")

        XCTAssertEqual(cell("B4").label, "B4, $6,045.00", "income planned did not cross sheets")
        XCTAssertEqual(cell("C4").label, "C4, $6,402.00", "income actual did not cross sheets")
        XCTAssertEqual(cell("B5").label, "B5, $2,910.00", "expenses planned did not cross sheets")
        XCTAssertEqual(cell("C5").label, "C5, $2,975.00", "expenses actual did not cross sheets")

        // Net = income − expenses, on both the planned and actual columns.
        XCTAssertEqual(cell("B6").label, "B6, $3,135.00", "planned net is wrong")
        XCTAssertEqual(cell("C6").label, "C6, $3,427.00", "actual net is wrong")
        // Variance = actual − planned, so beating the plan reads positive.
        XCTAssertEqual(cell("D6").label, "D6, $292.00", "net variance is wrong")

        // 3427 / 6402 = 53.53%, rendered by the percentage format.
        XCTAssertEqual(cell("B8").label, "B8, 54%", "savings rate is wrong")

        // Formatting applied before the numbers arrived must still be in force.
        XCTAssertTrue(cell("A1").label.contains("Monthly Budget"), "the merged title lost its text")
    }
}
