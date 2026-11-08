import XCTest

/// Stages and captures the App Store screenshots.
///
/// Driven by `Assets/App Store/capture.sh`, which seeds the documents these
/// open and says where to write through `SCREENSHOT_DIR` and which language to
/// use through `SCREENSHOT_LANGUAGE`. Without them the tests skip, so they stay
/// out of the way of an ordinary test run.
///
final class AppStoreScreenshots: XCTestCase {
    private enum Panel {
        case format, numberFormat, functions

        /// The toolbar button's accessibility label, which is translated.
        func label(_ language: String) -> String {
            switch self {
            case .format: language == "ja" ? "書式" : "Format"
            case .numberFormat: language == "ja" ? "数値の書式" : "Number format"
            case .functions: language == "ja" ? "関数" : "Functions"
            }
        }
    }

    private struct Shot {
        let name: String
        /// The file name without its extension, keyed by language.
        let document: [String: String]
        let cell: String
        var panel: Panel?
        var isDark = false
    }

    private static let budget = ["en": "Abydos Budget", "ja": "アビドス予算"]
    private static let plan = ["en": "Festival Plan", "ja": "合同祭計画"]
    private static let makeUpClub = ["en": "Make-up Work Club", "ja": "補習授業部"]
    private static let clubs = ["en": "Club Budgets", "ja": "部活予算"]
    private static let lessons = ["en": "Supplementary Lessons", "ja": "補習授業"]

    private static let iPhoneShots = [
        Shot(name: "01-budget", document: budget, cell: "C20"),
        Shot(name: "02-functions", document: makeUpClub, cell: "F4", panel: .functions),
        Shot(name: "03-format", document: plan, cell: "F10", panel: .format),
        Shot(name: "04-number-format", document: budget, cell: "D6", panel: .numberFormat),
        Shot(name: "05-dark", document: plan, cell: "F9", isDark: true),
    ]

    private static let iPadShots = [
        Shot(name: "01-budget", document: budget, cell: "N27"),
        Shot(name: "02-clubs", document: clubs, cell: "L5"),
        Shot(name: "03-functions", document: clubs, cell: "L5", panel: .functions),
        Shot(name: "04-format", document: plan, cell: "G26", panel: .format),
        Shot(name: "05-number-format", document: lessons, cell: "L3", panel: .numberFormat),
        Shot(name: "06-dark", document: clubs, cell: "L5", isDark: true),
    ]

    private var directory: URL!
    private var language = "en"
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["SCREENSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("run through Assets/App Store/capture.sh")
        }
        directory = URL(fileURLWithPath: path)
        language = environment["SCREENSHOT_LANGUAGE"] ?? "en"
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func testScreens() throws {
        defer { XCUIDevice.shared.appearance = .light }
        try capture(shots)
    }

    private var shots: [Shot] {
        UIDevice.current.userInterfaceIdiom == .pad ? Self.iPadShots : Self.iPhoneShots
    }

    private func capture(_ shots: [Shot]) throws {
        for shot in shots {
            XCUIDevice.shared.appearance = shot.isDark ? .dark : .light
            launch()
            open(try XCTUnwrap(shot.document[language]))
            select(shot.cell)
            if let panel = shot.panel {
                let button = app.buttons[panel.label(language)].firstMatch
                XCTAssertTrue(button.waitForExistence(timeout: 5), "missing \(panel) button")
                button.tap()
            }
            // Let the selection handle and any panel finish animating in.
            Thread.sleep(forTimeInterval: 2)
            let file = directory.appendingPathComponent("\(shot.name).png")
            try XCUIScreen.main.screenshot().pngRepresentation.write(to: file)
        }
    }

    // MARK: - Steps

    private func launch() {
        app = XCUIApplication()
        let locale = language == "ja" ? "ja_JP" : "en_US"
        app.launchArguments += ["-AppleLanguages", "(\(language))", "-AppleLocale", locale]
        app.launch()
    }

    /// Opens a document from the app's folder in the document browser.
    private func open(_ name: String) {
        let browse = app.buttons[language == "ja" ? "ブラウズ" : "Browse"].firstMatch
        if browse.waitForExistence(timeout: 15), !browse.isSelected {
            browse.tap()
        }

        // The cell, not its name: a tap on the name label does not open the file.
        let file = app.collectionViews.cells.containing(.staticText, identifier: name).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 10), "\(name) is not in the browser")
        // On iPhone the browser starts as a sheet that only shows its first row.
        if !file.isHittable {
            app.collectionViews.firstMatch.swipeUp()
        }
        file.tap()

        XCTAssertTrue(
            app.textFields["formulaField"].waitForExistence(timeout: 20), "\(name) never opened"
        )
        settle()
    }

    /// Selects a cell and waits for the formula bar to show it.
    private func select(_ reference: String) {
        let cell = gridCell(reference, in: app)
        XCTAssertTrue(cell.waitForExistence(timeout: 5), "missing cell \(reference)")
        let address = app.staticTexts["addressBox"]
        // A tap that lands while a freshly opened sheet is still settling is lost.
        for _ in 0..<4 where address.label != reference {
            cell.tap()
            let deadline = Date().addingTimeInterval(2)
            while address.label != reference, Date() < deadline {
                usleep(50_000)
            }
        }
        XCTAssertEqual(address.label, reference, "the selection never reached \(reference)")
    }
}
