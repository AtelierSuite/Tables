import AppIntents
import TablesEngine

/// The actions Siri and Spotlight offer by phrase, without a shortcut being built first.
struct TablesShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: EvaluateFormulaIntent(),
            phrases: ["Calculate a formula with \(.applicationName)", "Work out a formula in \(.applicationName)"],
            shortTitle: "Intent.Evaluate.Title",
            systemImageName: "function"
        )
        AppShortcut(
            intent: CreateWorkbookIntent(),
            phrases: ["Create a workbook in \(.applicationName)", "New \(.applicationName) workbook"],
            shortTitle: "Intent.Create.Title",
            systemImageName: "tablecells.badge.ellipsis"
        )
        AppShortcut(
            intent: GetWorkbookIntent(),
            phrases: ["Get a workbook in \(.applicationName)"],
            shortTitle: "Intent.Open.Title",
            systemImageName: "doc.text.magnifyingglass"
        )
    }
}
