import XCTest

/// Drives a real document end to end and captures screenshots of each stage.
final class WorkbookUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Grid cells are combined accessibility elements, so query them by identifier
    /// across every element type.
    private func cell(_ reference: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "cell.\(reference)").firstMatch
    }

    /// Gets to an open workbook, whether the app restored one or the document
    /// browser is waiting for us to make a new one.
    @discardableResult
    private func openEditor(_ app: XCUIApplication) -> XCUIElement {
        let formulaField = app.textFields["formulaField"]
        if formulaField.waitForExistence(timeout: 5) {
            settle()
            return formulaField
        }

        let create = app.buttons["Create Document"]
        XCTAssertTrue(create.waitForExistence(timeout: 30), "the document browser never appeared")
        create.tap()

        if !formulaField.waitForExistence(timeout: 20) {
            capture(app, "diagnostic-after-create-tap")
            // The simulator's document browser refuses to import a new file after
            // a few creations in one session. Fall back to a document we already
            // made — this test only needs *a* workbook, not a pristine one.
            let alertButton = app.alerts.buttons.firstMatch
            if alertButton.exists { alertButton.tap() }

            let existing = app.collectionViews.cells.firstMatch
            if existing.waitForExistence(timeout: 5) {
                existing.doubleTap()
            } else if create.exists {
                create.tap()  // the browser can also swallow the first tap
            }
        }
        XCTAssertTrue(formulaField.waitForExistence(timeout: 30), "the editor never appeared")
        settle()
        return formulaField
    }

    private func type(_ text: String, into reference: String, app: XCUIApplication) {
        enterText(text, into: reference, in: app)
    }

    /// Enters a small table and checks the SUM formula evaluates in the grid.
    func testEntersDataAndEvaluatesFormula() throws {
        let app = XCUIApplication.launchedInEnglish()
        openEditor(app)
        capture(app, "01-empty-grid")

        let entries = [
            ("A1", "Region"), ("B1", "Revenue"),
            ("A2", "North"), ("B2", "1200.5"),
            ("A3", "South"), ("B3", "980"),
            ("A4", "Total"), ("B4", "=SUM(B2:B3)"),
        ]
        for (reference, text) in entries {
            type(text, into: reference, app: app)
        }
        capture(app, "02-filled-grid")

        XCTAssertEqual(cell("A1", in: app).label, "A1, Region", "typed text is missing")
        XCTAssertEqual(cell("B4", in: app).label, "B4, 2180.5", "the SUM formula did not evaluate")
    }

    /// Adds a row and a column, then confirms the sheet's extent really grew.
    func testAddsRowsAndColumns() throws {
        let app = XCUIApplication.launchedInEnglish()
        openEditor(app)

        // Structure lives in the header menus, opened by double-tapping a header.
        let columnHeader = app.buttons["A"].firstMatch
        XCTAssertTrue(columnHeader.waitForExistence(timeout: 5), "the column headers are missing")
        columnHeader.doubleTap()
        let addColumn = app.buttons["Add Column at End"].firstMatch
        XCTAssertTrue(addColumn.waitForExistence(timeout: 5), "the column header menu never opened")
        addColumn.tap()

        // Let the menu finish dismissing; UIKit ignores a request to present
        // another one while the last is still on its way out.
        let closed = Date().addingTimeInterval(5)
        while addColumn.exists, Date() < closed { usleep(50_000) }

        let rowHeader = app.buttons["Row 1"].firstMatch
        XCTAssertTrue(rowHeader.waitForExistence(timeout: 5), "the row headers are missing")
        rowHeader.doubleTap()
        let addRow = app.buttons["Add Row at End"].firstMatch
        XCTAssertTrue(addRow.waitForExistence(timeout: 5), "the row header menu never opened")
        addRow.tap()
        capture(app, "03-after-adding")

        // "Select all cells" reports the sheet's full extent in the address box.
        app.buttons["Select all cells"].tap()
        let addressBox = app.staticTexts["addressBox"]
        XCTAssertTrue(addressBox.waitForExistence(timeout: 5))
        XCTAssertEqual(
            addressBox.label, "A1:F21",
            "a new sheet plus one row and one column should span A1:F21"
        )
    }

    /// A double tap on a cell raises the cell menu — the same one a long press
    /// gives — rather than opening the editor directly.
    func testDoubleTapRaisesCellMenu() throws {
        let app = XCUIApplication.launchedInEnglish()
        openEditor(app)

        let target = cell("B2", in: app)
        XCTAssertTrue(target.waitForExistence(timeout: 5), "missing cell B2")
        target.doubleTap()

        XCTAssertTrue(
            app.buttons["Edit"].waitForExistence(timeout: 5),
            "the double tap did not raise the cell menu"
        )
        for item in ["Copy", "Cut", "Reset Formatting"] {
            XCTAssertTrue(app.buttons[item].exists, "the menu is missing \(item)")
        }
    }

    /// Formatting the selection updates the grid without disturbing values.
    func testAppliesBoldFormatting() throws {
        let app = XCUIApplication.launchedInEnglish()
        openEditor(app)

        type("Heading", into: "A1", app: app)
        cell("A1", in: app).tap()

        let bold = app.buttons["Bold"]
        XCTAssertTrue(bold.waitForExistence(timeout: 10), "the Bold control is missing")
        bold.tap()
        capture(app, "04-bold-applied")

        XCTAssertEqual(cell("A1", in: app).label, "A1, Heading", "formatting dropped the cell's text")
    }
}
