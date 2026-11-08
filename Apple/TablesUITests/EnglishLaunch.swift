import XCTest

extension XCUIApplication {
    /// Launches the app with its language pinned to English.
    ///
    /// These tests find controls by the words on them, and the app is
    /// translated — on a machine set to anything but English the labels they
    /// look for would not be the labels on screen. Pinning the language keeps
    /// the tests about behaviour rather than about the tester's settings.
    static func launchedInEnglish() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        return app
    }
}
