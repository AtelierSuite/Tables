import AppKit
import TablesEngine
import UniformTypeIdentifiers

/// The Mac app: an AppKit document app, one window per workbook.
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The application holds its delegate weakly.
    private static let shared = AppDelegate()

    static func main() {
        let application = NSApplication.shared
        application.delegate = shared
        application.mainMenu = MainMenu.make()
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ahead of the first window: the document controller has to exist
        // before anything asks for `NSDocumentController.shared`.
        _ = DocumentController.shared
        // A plain launch should begin with the standard document picker.
        // Defer until AppKit has finished restoring or opening launch items.
        DispatchQueue.main.async { [weak self] in
            guard let self, NSApp.orderedDocuments.isEmpty else { return }
            DocumentController.shared.openDocument(self)
        }
        #if DEBUG
        if let stage = ScreenshotStage.requested {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { ScreenshotStage.stage(stage) }
        }
        #endif
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    @objc func showFunctionReference(_ sender: Any?) {
        FunctionReferenceWindowController.shared.showWindow(sender)
    }

    @objc func showMacroHelp(_ sender: Any?) {
        MacroHelpWindowController.shared.showWindow(sender)
    }
}

/// The app's document controller, made first so it is the shared one.
final class DocumentController: NSDocumentController {
    /// The type a new workbook is saved as unless the user picks another.
    override var defaultType: String? { UTType.openXMLWorkbook.identifier }
}
