import XCTest

extension XCTestCase {
    /// A grid cell. They are combined accessibility elements, so they have to be
    /// queried by identifier across every element type rather than as buttons.
    func gridCell(_ reference: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "cell.\(reference)").firstMatch
    }

    /// Gives a freshly opened document the beat it needs before being driven.
    ///
    /// Its elements exist — the formula bar, the cells — a noticeable moment
    /// before the scene is actually taking input, and there is nothing to query
    /// that says so. Text typed into that window is simply lost, which shows up
    /// later as a cell nobody filled in rather than as anything to do with
    /// opening a document.
    func settle() {
        Thread.sleep(forTimeInterval: 1.5)
    }

    /// Types one cell's contents and commits with Return.
    ///
    /// The typing is checked rather than assumed: a field can be up a moment
    /// before it is taking input, for the same reason `settle()` exists.
    /// Watching the grid for the value turns that into a retry instead of a
    /// puzzling failure three assertions downstream.
    ///
    /// Assumes the cell starts empty, which is how these tests build a workbook:
    /// each cell is written once.
    func enterText(
        _ text: String, into reference: String, in app: XCUIApplication,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let target = gridCell(reference, in: app)
        let empty = "\(reference), empty"

        for _ in 0..<3 {
            openCellEditor(on: reference, in: app, file: file, line: line).typeText(text + "\n")

            let deadline = Date().addingTimeInterval(3)
            while target.label == empty, Date() < deadline { usleep(50_000) }
            if target.label != empty { return }
        }
        XCTFail("\(reference) never took the text \(text)", file: file, line: line)
    }

    /// Return leaves the editor open on the next cell, and with a software
    /// keyboard up the lower rows sit under it. Discarding that empty edit
    /// brings them back before a test reaches for one.
    func uncover(in app: XCUIApplication) {
        // A cell under the keyboard still reports itself hittable, so the
        // keyboard is the thing to look for.
        guard app.keyboards.element.exists else { return }
        let discard = app.buttons["Discard edit"]
        if discard.exists { discard.tap() }
        _ = app.keyboards.element.waitForNonExistence(timeout: 3)
    }

    /// Opens a cell's in-place editor, and hands back the field ready to type
    /// into.
    ///
    /// The way in is the cell menu's Edit entry. The menu is raised here by
    /// long press rather than by double tap, even though both work, because the
    /// double tap is timed against the app's own window and a synthesized pair
    /// does not reliably land inside it once the grid has content to redraw.
    /// `testDoubleTapRaisesCellMenu` covers the double tap on its own.
    @discardableResult
    func openCellEditor(
        on reference: String, in app: XCUIApplication,
        file: StaticString = #filePath, line: UInt = #line
    ) -> XCUIElement {
        let target = gridCell(reference, in: app)
        XCTAssertTrue(
            target.waitForExistence(timeout: 5), "missing cell \(reference)", file: file, line: line
        )

        uncover(in: app)

        // Land the selection with a plain tap first. It commits whatever the
        // last Return left open and scrolls the cell into view, so the press
        // that follows is not competing with an animation the scroll view would
        // rather read as a drag — which is a press that quietly does nothing.
        target.tap()

        // Repeated because UIKit drops a request to present a menu while the
        // app is still settling, and says nothing about having done so.
        let edit = app.buttons["Edit"]
        for _ in 0..<4 {
            if edit.exists { break }
            target.press(forDuration: 1)
            if edit.waitForExistence(timeout: 3) { break }
        }
        XCTAssertTrue(
            edit.exists, "the cell menu never opened on \(reference)", file: file, line: line
        )
        edit.tap()

        let editor = app.textFields["cellEditor"]
        XCTAssertTrue(
            editor.waitForExistence(timeout: 5),
            "the in-cell editor never opened on \(reference)", file: file, line: line
        )
        XCTAssertTrue(
            app.keyboards.element.waitForExistence(timeout: 5),
            "the keyboard never came up for \(reference)", file: file, line: line
        )
        return editor
    }
}
