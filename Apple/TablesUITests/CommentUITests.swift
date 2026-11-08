import XCTest

/// Adds a comment through the cell menu and checks it lands on the cell.
final class CommentUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func openEditor(_ app: XCUIApplication) {
        let formulaField = app.textFields["formulaField"]
        if formulaField.waitForExistence(timeout: 5) {
            settle()
            return
        }
        let create = app.buttons["Create Document"]
        XCTAssertTrue(create.waitForExistence(timeout: 30), "the document browser never appeared")
        create.tap()
        if !formulaField.waitForExistence(timeout: 20) {
            capture(app, "diagnostic-after-create-tap")
            // The simulator's document browser sometimes asks first, or swallows
            // the first tap; an existing document will do as well as a new one.
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
        settle()
    }

    func testAddsAndAnswersAComment() throws {
        let app = XCUIApplication.launchedInEnglish()
        openEditor(app)
        let target = gridCell("C3", in: app)
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        target.tap()

        let newComment = app.buttons["New Comment"]
        for _ in 0..<4 {
            if newComment.exists { break }
            target.press(forDuration: 1)
            if newComment.waitForExistence(timeout: 3) { break }
        }
        capture(app, "01-cell-menu")
        XCTAssertTrue(newComment.exists, "the cell menu has no New Comment")
        newComment.tap()

        let draft = app.textFields["Start a conversation"]
        XCTAssertTrue(draft.waitForExistence(timeout: 5), "the comment panel never opened")
        draft.tap()
        draft.typeText("Is this figure final?")
        app.buttons["comment.post"].tap()

        let reply = app.textFields["Reply"]
        XCTAssertTrue(reply.waitForExistence(timeout: 5), "the conversation never appeared")
        reply.tap()
        reply.typeText("Not yet.")
        capture(app, "02a-reply-typed")
        let send = app.buttons["comment.reply"]
        send.tap()
        let posted = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Not yet.")).firstMatch
        if !posted.waitForExistence(timeout: 3), send.isEnabled {
            // The first tap can only put the keyboard away.
            send.tap()
        }
        capture(app, "02b-reply-tapped")
        XCTAssertTrue(posted.waitForExistence(timeout: 5), "the reply never appeared")
        capture(app, "02-conversation")

        app.buttons["Done"].firstMatch.tap()
        let label = target.label
        XCTAssertTrue(label.contains("has comment"), "the cell does not report its comment: \(label)")
        capture(app, "03-marked-cell")
    }
}
