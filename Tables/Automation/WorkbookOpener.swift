import Foundation
import TablesEngine
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Opens a workbook file in the app's own editor, for the Open in Tables action.
@MainActor
enum WorkbookOpener {
    enum Failure: Error, LocalizedError {
        case unavailable

        var errorDescription: String? { String(localized: "Automation.Error.CannotOpen") }
    }

    static func open(_ url: URL) async throws {
        #if canImport(UIKit)
        // A document group opens whatever its browser reports picked, which is
        // how a file chosen in the browser reaches the editor; handing it the
        // file takes the same route, replacing any document already open.
        let documentController = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .compactMap { ($0.rootViewController as? UINavigationController)?.viewControllers.first }
            .compactMap { $0 as? UIDocumentViewController }
            .first
        guard let browser = documentController?.launchOptions.browserViewController,
              let delegate = browser.delegate else { throw Failure.unavailable }
        delegate.documentBrowser?(browser, didPickDocumentsAt: [url])
        #else
        _ = try await NSDocumentController.shared.openDocument(withContentsOf: url, display: true)
        #endif
    }
}
