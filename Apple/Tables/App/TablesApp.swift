import SwiftUI
import TablesEngine

@main
struct TablesApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: TablesDocument()) { configuration in
            WorkbookView(document: configuration.$document, fileURL: configuration.fileURL)
        }
        #if os(macOS)
        .defaultSize(width: 1080, height: 720)
        #endif

        // An empty title, so the feature wall carries the header on its own.
        // With no title at all, the scene falls back to the app's name.
        DocumentGroupLaunchScene(Text(verbatim: "")) {
            NewDocumentButton("Launch.NewWorkbook", contentType: .openXMLWorkbook)
        } background: {
            DocumentLaunchBackground()
        } backgroundAccessoryView: { geometry in
            DocumentLaunchFeatureWall(geometry: geometry)
        }
    }
}
