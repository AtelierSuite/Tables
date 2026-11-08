import XCTest

/// The two gestures the tab strip carries beyond selection: a double tap raises
/// the sheet's menu, and a long press picks a tab up to be dragged elsewhere.
final class SheetTabBarUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication.launchedInEnglish()
        openDocument()
    }

    /// Gets to an open workbook, whether the app restored one or the document
    /// browser is waiting for us to make a new one.
    private func openDocument() {
        let formulaField = app.textFields["formulaField"]
        if formulaField.waitForExistence(timeout: 5) { return }

        let create = app.buttons["Create Document"]
        XCTAssertTrue(create.waitForExistence(timeout: 30), "the document browser never appeared")
        create.tap()

        if !formulaField.waitForExistence(timeout: 20) {
            // The simulator's document browser refuses to import a new file after
            // a few creations in one session. Any workbook will do here.
            let alertButton = app.alerts.buttons.firstMatch
            if alertButton.exists { alertButton.tap() }
            let existing = app.collectionViews.cells.firstMatch
            if existing.waitForExistence(timeout: 5) {
                existing.doubleTap()
            } else if create.exists {
                create.tap()
            }
        }
        XCTAssertTrue(formulaField.waitForExistence(timeout: 30), "the editor never appeared")
    }

    /// The tab labels, left to right as they appear in the strip.
    private func tabOrder() -> [String] {
        app.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH 'Sheet'"))
            .allElementsBoundByIndex
            .sorted { $0.frame.minX < $1.frame.minX }
            .map { $0.label }
    }

    private func addSheets(_ count: Int) {
        let add = app.buttons["Add a sheet"]
        XCTAssertTrue(add.waitForExistence(timeout: 10), "the add-sheet button is missing")
        for _ in 0..<count { add.tap() }
    }

    func testDoubleTapRaisesTheSheetMenu() throws {
        let tab = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Sheet'")).firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "no sheet tab")
        tab.doubleTap()

        XCTAssertTrue(
            app.buttons["Rename…"].waitForExistence(timeout: 5),
            "the double tap did not raise the sheet menu"
        )
        for item in ["Duplicate", "Hide", "Delete"] {
            XCTAssertTrue(app.buttons[item].exists, "the menu is missing \(item)")
        }
    }

    /// Long press picks the tab up; dragging then carries it past its neighbour.
    func testLongPressDragReordersTabs() throws {
        addSheets(2)

        let before = tabOrder()
        XCTAssertEqual(before.count, 3, "expected three tabs, got \(before)")

        app.staticTexts[before[0]].press(forDuration: 0.9, thenDragTo: app.staticTexts[before[2]])

        let after = tabOrder()
        XCTAssertNotEqual(after, before, "the drag did not reorder the tabs (still \(after))")
        XCTAssertEqual(Set(after), Set(before), "a tab went missing: \(after)")
        XCTAssertGreaterThan(
            after.firstIndex(of: before[0])!, 0,
            "the dragged tab did not move rightwards: \(after)"
        )
    }
}
