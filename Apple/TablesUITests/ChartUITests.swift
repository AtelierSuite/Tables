import XCTest

/// Inserts a chart from a selection through the interface, then edits it in
/// the chart panel — the path a person takes, end to end.
final class ChartUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication.launchedInEnglish()
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Gets to an open workbook, whether one was restored or the document
    /// browser is waiting for a new one.
    private func openEditor() {
        let formulaField = app.textFields["formulaField"]
        if formulaField.waitForExistence(timeout: 5) {
            settle()
            return
        }
        let create = app.buttons["Create Document"]
        XCTAssertTrue(create.waitForExistence(timeout: 30), "the document browser never appeared")
        create.tap()
        if !formulaField.waitForExistence(timeout: 20) {
            // The simulator's browser stops importing new files after a few
            // creations in a session; any workbook will do, as WorkbookUITests
            // also finds.
            let alertButton = app.alerts.buttons.firstMatch
            if alertButton.exists { alertButton.tap() }
            let existing = app.collectionViews.cells.firstMatch
            if existing.waitForExistence(timeout: 5) { existing.doubleTap() }
        }
        XCTAssertTrue(formulaField.waitForExistence(timeout: 30), "the editor never appeared")
        settle()
    }

    /// Enters a value unless a document reopened from an earlier run already
    /// holds it.
    private func fill(_ text: String, into reference: String) {
        let target = gridCell(reference, in: app)
        XCTAssertTrue(target.waitForExistence(timeout: 5), "missing cell \(reference)")
        if target.label.hasSuffix(", \(text)") { return }
        enterText(text, into: reference, in: app)
    }

    private var charts: XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'chart.Chart'"))
    }

    /// The action bar scrolls sideways on a phone; bring a control into reach.
    private func reveal(_ element: XCUIElement) {
        for _ in 0..<4 where !element.isHittable {
            element.firstMatch.swipeLeft()
        }
    }

    func testInsertChartFromSelectionAndEditIt() throws {
        openEditor()
        let rows = [("Quarter", "Sales"), ("Q1", "10"), ("Q2", "14"), ("Q3", "9"), ("Q4", "17")]
        for (index, row) in rows.enumerated() {
            fill(row.0, into: "A\(index + 1)")
            fill(row.1, into: "B\(index + 1)")
        }

        // One cell inside the block is enough: the chart takes the block.
        gridCell("B3", in: app).tap()
        let existingCharts = Set(charts.allElementsBoundByIndex.map { $0.identifier })

        let insert = app.buttons["insertChart"]
        XCTAssertTrue(insert.waitForExistence(timeout: 5), "the Insert Chart control is missing")
        reveal(insert)
        insert.tap()
        let column = app.buttons["Column"]
        XCTAssertTrue(column.waitForExistence(timeout: 5), "the chart type menu never opened")
        column.tap()

        let deadline = Date().addingTimeInterval(5)
        var identifier: String?
        while identifier == nil, Date() < deadline {
            identifier = charts.allElementsBoundByIndex.map { $0.identifier }.first { !existingCharts.contains($0) }
            if identifier == nil { usleep(100_000) }
        }
        let added = try XCTUnwrap(identifier, "no chart appeared on the sheet")
        // The chart and its resize grip share the identifier; the chart comes first.
        let chart = app.descendants(matching: .any).matching(identifier: added).firstMatch
        capture("chart-inserted")

        // The new chart is already selected, and the bar brings its actions
        // into view.
        app.buttons["editChart"].tap()
        XCTAssertTrue(app.navigationBars["Chart"].waitForExistence(timeout: 5), "the chart panel never opened")
        // The title sits below the type and data sections; scroll the form,
        // not the screen, so the swipe cannot dismiss the panel.
        let title = app.textFields["chartTitle"]
        for _ in 0..<5 where !(title.exists && title.isHittable) {
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(title.waitForExistence(timeout: 5), "the chart title field never appeared")
        title.tap()
        title.typeText("Quarterly Sales\n")
        capture("chart-panel")

        app.navigationBars["Chart"].buttons.firstMatch.tap()
        XCTAssertTrue(chart.waitForExistence(timeout: 5))
        XCTAssertTrue(chart.label.contains("Quarterly Sales"), "the title did not reach the chart: \(chart.label)")
        capture("chart-titled")
    }

    func testUndoAndRedoAChartInsertion() throws {
        openEditor()
        let rows = [("Quarter", "Sales"), ("Q1", "10"), ("Q2", "14"), ("Q3", "9"), ("Q4", "17")]
        for (index, row) in rows.enumerated() {
            fill(row.0, into: "A\(index + 1)")
            fill(row.1, into: "B\(index + 1)")
        }
        gridCell("B3", in: app).tap()
        let before = charts.count

        let insert = app.buttons["insertChart"]
        XCTAssertTrue(insert.waitForExistence(timeout: 5))
        reveal(insert)
        insert.tap()
        let column = app.buttons["Column"]
        XCTAssertTrue(column.waitForExistence(timeout: 5))
        column.tap()
        XCTAssertTrue(waitFor { self.charts.count == before + 1 }, "no chart appeared")

        let undo = app.buttons["undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "the Undo button is missing")
        undo.tap()
        XCTAssertTrue(waitFor { self.charts.count == before }, "undo left the chart on the sheet")
        capture("chart-undone")

        let redo = app.buttons["redo"]
        XCTAssertTrue(redo.waitForExistence(timeout: 5), "the Redo button is missing")
        XCTAssertTrue(redo.isEnabled)
        redo.tap()
        XCTAssertTrue(waitFor { self.charts.count == before + 1 }, "redo did not bring the chart back")
        capture("chart-redone")
    }

    private func waitFor(_ condition: @escaping () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(100_000)
        }
        return condition()
    }
}
