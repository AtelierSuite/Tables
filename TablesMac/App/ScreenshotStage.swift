#if DEBUG
import AppKit
import TablesEngine
import TablesMacros

/// Sets the scene for an App Store screenshot, driven by
/// `Assets/App Store/capture-mac.sh`, which opens a sample workbook with
/// `-ScreenshotStage <name>` and captures the windows once it is ready.
///
/// Debug builds only: everything here changes the open document to show off
/// a feature, and is never meant to run for anyone else.
@MainActor
enum ScreenshotStage {
    static var requested: String? { UserDefaults.standard.string(forKey: "ScreenshotStage") }

    /// The window size a 2880 × 1800 capture needs on a Retina display.
    private static let windowSize = NSSize(width: 1440, height: 900)

    static func stage(_ name: String) {
        guard let document = NSApp.orderedDocuments.first as? WorkbookDocument,
              let windowController = document.windowControllers.first as? WorkbookWindowController,
              let window = windowController.window else {
            // The document is still opening.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { stage(name) }
            return
        }
        let controller = windowController.workbookViewController
        let isJapanese = Locale.preferredLanguages.first?.hasPrefix("ja") == true
        func text(_ english: String, _ japanese: String) -> String { isJapanese ? japanese : english }

        // On the Retina display, where the window is drawn at twice its size.
        let screen = NSScreen.screens.max { $0.backingScaleFactor < $1.backingScaleFactor } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            window.setFrame(NSRect(origin: NSPoint(x: visible.minX + 20, y: visible.maxY - windowSize.height - 20),
                                   size: windowSize), display: true)
        }
        let state = document.state
        let sheet = { document.activeSheet }
        NSApp.appearance = NSAppearance(named: name == "03-macros" ? .darkAqua : .aqua)
        // Where the sheet starts: showing a popover can scroll it.
        let clip = controller.scrollView.contentView
        let origin = clip.bounds.origin
        // Shown once the app is in front: bringing it there closes a popover.
        var panel: EditorPanel?

        switch name {
        case "01-budget":
            // A conversation on the year's income, open beside its total.
            let total = CellAddress(row: 7, column: 13)
            UserDefaults.standard.set("Ayane", forKey: EditorState.commentAuthorKey)
            document.edit { workbook in
                state.addComment(
                    text("Nonomi's card is carrying the year again. Can we lean on the bounties more?",
                         "今年もノノミのカード頼み…。賞金の方で何とかできないかな？"),
                    kind: .thread, at: total, in: &workbook
                )
                UserDefaults.standard.set("Serika", forKey: EditorState.commentAuthorKey)
                state.reply(text("On it. Three more listings this week.", "任せて！今週は3件追加するよ。"),
                            at: total, in: &workbook)
            }
            state.select(total, in: sheet())
            panel = .comment
        case "02-charts":
            // The spend of the first clubs over the first months, charted
            // beside the table, with the chart editor open.
            state.select(CellAddress(row: 0, column: 0), in: sheet())
            state.select(CellAddress(row: 6, column: 4), extending: true, in: sheet())
            document.edit { state.insertChart(.column, in: &$0) }
            if let id = sheet().charts.last?.id {
                // Without the first series, the school column, which holds
                // names rather than figures.
                document.edit { workbook in
                    state.selectChart(id)
                    state.updateSelectedChart(in: &workbook) { chart in
                        if chart.series.count > 1 { chart.series.removeFirst() }
                    }
                }
                let frame = CGRect(x: 120, y: 340, width: 620, height: 330)
                document.edit { state.moveChart(id, to: frame, in: &$0) }
                state.selectChart(id)
            }
            panel = .chart
        case "03-macros":
            // Dark, with a macro that has just tallied the plan.
            state.select(CellAddress(row: 8, column: 5), in: sheet())
            var workbook = document.workbook
            try? workbook.createMacroProject()
            if let data = workbook.macroProject, var project = try? VBAProject(data: data),
               let module = project.modules.first(where: { $0.kind == .standard }) {
                try? project.setSource(macro(text), ofModule: module.name)
                if let encoded = try? project.data() { workbook.setMacroProject(encoded) }
                let staged = workbook
                document.edit { $0 = staged }
                controller.showMacros(nil)
                if let macros = controller.macrosWindow?.window {
                    macros.setFrame(NSRect(x: window.frame.maxX - 700, y: window.frame.minY - 60,
                                           width: 860, height: 540), display: true)
                }
                controller.hasAllowedMacros = true
                controller.runMacro(MacroCatalog.Macro(module: module.name, procedure: "Tally"))
            }
        default:
            break
        }
        document.notify()
        clip.scroll(to: origin)
        controller.scrollView.reflectScrolledClipView(clip)
        // A screenshot of a sample isn't an edit anyone made.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            // In front, so the windows are drawn active.
            NSApp.activate()
            (name == "03-macros" ? controller.macrosWindow?.window : window)?.makeKeyAndOrderFront(nil)
            document.updateChangeCount(.changeCleared)
            if let panel {
                state.presentedPanel = panel
                document.notify()
                clip.scroll(to: origin)
                controller.scrollView.reflectScrolledClipView(clip)
            }
            controller.view.window?.makeFirstResponder(controller.grid)
        }
    }

    /// A short macro that counts the plan's tasks by how far along they are.
    private static func macro(_ text: (String, String) -> String) -> String {
        """
        ' \(text("Counts the festival's tasks by how far along they are.", "合同祭のタスクを進捗ごとに数えます。"))
        Sub Tally()
            Dim done As Long, started As Long, waiting As Long
            Dim row As Long
            For row = 4 To 30
                If Not IsEmpty(Cells(row, 6).Value) Then
                    Select Case Cells(row, 6).Value
                        Case 1: done = done + 1
                        Case 0: waiting = waiting + 1
                        Case Else: started = started + 1
                    End Select
                End If
            Next row
            Debug.Print "\(text("Done", "完了")): " & done
            Debug.Print "\(text("In progress", "進行中")): " & started
            Debug.Print "\(text("Not started", "未着手")): " & waiting
        End Sub

        """
    }
}
#endif
