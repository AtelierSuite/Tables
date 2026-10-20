import AppKit
import Observation
import TablesEngine
import TablesMacros

/// Running a workbook's macros from its window: asking first, running on a
/// copy of the workbook and putting back what came of it as one change, and
/// carrying a running macro's questions to the user as alerts.
extension WorkbookViewController {
    @objc func showMacros(_ sender: Any?) {
        guard let document else { return }
        let controller = macrosWindow ?? MacrosWindowController(document: document)
        controller.run = { [weak self] macro in self?.runMacro(macro) }
        macrosWindow = controller
        controller.reload()
        controller.showWindow(sender)
        observeMacroRunner()
    }

    /// Runs a macro, asking first the first time macros from this workbook
    /// are run: a macro can change anything in it.
    func runMacro(_ macro: MacroCatalog.Macro) {
        guard let document else { return }
        guard !hasAllowedMacros else { return start(macro) }
        let alert = NSAlert()
        alert.messageText = String(localized: "Macros.Confirm.Title")
        alert.informativeText = String(localized: "Macros.Confirm.Message")
        alert.addButton(withTitle: String(localized: "Macros.Confirm.Run"))
        alert.addButton(withTitle: String(localized: "Macros.Button.Cancel"))
        let window = macrosWindow?.window?.isVisible == true ? macrosWindow?.window : view.window
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.hasAllowedMacros = true
            self.start(macro)
        }
        _ = document
    }

    private func start(_ macro: MacroCatalog.Macro) {
        observeMacroRunner()
        Task { await performMacro(macro) }
    }

    /// Runs a macro on a copy of the workbook and applies what it did, so a
    /// single undo takes the whole run back.
    private func performMacro(_ macro: MacroCatalog.Macro) async {
        guard let document, let data = document.workbook.macroProject,
              let project = try? VBAProject(data: data) else { return }
        let state = document.state
        if state.editingAddress != nil { grid.commitEditing(then: nil) }
        let before = document.workbook
        let fileName = document.fileURL?.lastPathComponent
        let outcome = await document.macroRunner.run(
            macro.procedure, in: macro.module, project: project, workbook: before,
            workbookName: fileName ?? String(localized: "Macros.DefaultWorkbookName"),
            activeSheet: state.activeSheetID, selection: state.selection,
            workingFolder: MacroFiles.folder(forWorkbookNamed: fileName)
        )
        if outcome.workbook != before { document.edit { $0 = outcome.workbook } }
        if outcome.activeSheetID != state.activeSheetID, outcome.workbook.index(of: outcome.activeSheetID) != nil {
            state.selectSheet(outcome.activeSheetID, in: outcome.workbook)
        }
        state.selection = outcome.selection
        state.anchor = outcome.selection.start
        state.additionalSelections = []
        state.clampSelection(to: state.activeSheet(in: document.workbook))
        state.refreshMetrics(in: document.workbook)
        document.refreshCapabilities()
        if let failure = outcome.failure {
            state.errorMessage = String(format: String(localized: "Macros.Failed"), failure)
        }
        document.notify()
        macrosWindow?.reload()
    }

    // MARK: - While a macro runs

    /// Follows the runner: its questions, whether it is running, and what it
    /// prints.
    func observeMacroRunner() {
        guard let runner = document?.macroRunner, !isObservingRunner else { return }
        isObservingRunner = true
        track(runner)
    }

    private func track(_ runner: MacroRunner) {
        withObservationTracking {
            _ = runner.prompt
            _ = runner.runningMacro
            _ = runner.output
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.runnerDidChange(runner)
                self.track(runner)
            }
        }
        runnerDidChange(runner)
    }

    private func runnerDidChange(_ runner: MacroRunner) {
        runningOverlay.show(runner.runningMacro)
        macrosWindow?.refreshOutput()
        if let prompt = runner.prompt, prompt.id != presentedPromptID { present(prompt, from: runner) }
    }

    /// A `MsgBox`, `InputBox`, link or `SendKeys` question, as an alert on
    /// whichever window the macro was run from.
    private func present(_ prompt: MacroRunner.Prompt, from runner: MacroRunner) {
        let window = macrosWindow?.window?.isKeyWindow == true ? macrosWindow?.window : view.window
        guard let window else { return }
        presentedPromptID = prompt.id
        let alert = NSAlert()
        var codes: [Int] = []
        var field: NSTextField?
        switch prompt.kind {
        case .message(let buttons):
            alert.messageText = prompt.title ?? String(localized: "Macros.Prompt.DefaultTitle")
            alert.informativeText = prompt.text
            for button in Self.buttons(for: buttons) {
                alert.addButton(withTitle: button.title)
                codes.append(button.code)
            }
        case .input(let defaultText):
            alert.messageText = prompt.title ?? String(localized: "Macros.Prompt.DefaultTitle")
            alert.informativeText = prompt.text
            let input = NSTextField(string: defaultText)
            input.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
            alert.accessoryView = input
            alert.window.initialFirstResponder = input
            field = input
            alert.addButton(withTitle: String(localized: "Common.OK"))
            alert.addButton(withTitle: String(localized: "Macros.Button.Cancel"))
        case .openLink(let url):
            alert.messageText = String(localized: "Macros.OpenLink.Title")
            alert.informativeText = String(format: String(localized: "Macros.OpenLink.Message"), url.absoluteString)
            alert.addButton(withTitle: String(localized: "Macros.OpenLink.Open"))
            alert.addButton(withTitle: String(localized: "Macros.Button.Cancel"))
        case .sendKeys(let keys):
            alert.messageText = String(localized: "Macros.SendKeys.Title")
            alert.informativeText = String(localized: "Macros.SendKeys.Message")
            let shown = NSTextField(string: keys)
            shown.isEditable = false
            shown.isSelectable = true
            shown.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
            alert.accessoryView = shown
            alert.addButton(withTitle: String(localized: "Common.OK"))
        }
        alert.beginSheetModal(for: window) { response in
            let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            switch prompt.kind {
            case .message:
                runner.answer(button: codes.indices.contains(index) ? codes[index] : 2)
            case .input:
                runner.answer(text: index == 0 ? field?.stringValue ?? "" : nil)
            case .openLink(let url):
                if index == 0 { NSWorkspace.shared.open(url) }
                runner.answer(button: index == 0 ? 1 : 2)
            case .sendKeys:
                runner.answer(button: 1)
            }
        }
    }

    /// The buttons of a `MsgBox` button set, answering with VBA's codes:
    /// vbOK 1, vbCancel 2, vbAbort 3, vbRetry 4, vbIgnore 5, vbYes 6, vbNo 7.
    private static func buttons(for style: Int) -> [(title: String, code: Int)] {
        let ok = (String(localized: "Common.OK"), 1)
        let cancel = (String(localized: "Macros.Button.Cancel"), 2)
        let yes = (String(localized: "Macros.Button.Yes"), 6)
        let no = (String(localized: "Macros.Button.No"), 7)
        let retry = (String(localized: "Macros.Button.Retry"), 4)
        switch style & 0xF {
        case 1: return [ok, cancel]
        case 2: return [(String(localized: "Macros.Button.Abort"), 3), retry, (String(localized: "Macros.Button.Ignore"), 5)]
        case 3: return [yes, no, cancel]
        case 4: return [yes, no]
        case 5: return [retry, cancel]
        default: return [ok]
        }
    }
}

/// While a macro runs the sheet is the macro's: this covers it, swallowing
/// clicks, and says how to stop a macro that does not finish.
@MainActor
final class RunningMacroOverlay: NSView {
    var onStop: () -> Void = {}
    private let label = NSTextField(labelWithString: "")
    private let glass = NSGlassEffectView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.08).cgColor
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let stop = NSButton(title: String(localized: "Macros.Stop"), target: self, action: #selector(stop(_:)))
        stop.hasDestructiveAction = true
        stop.setAccessibilityIdentifier("stopMacro")
        label.lineBreakMode = .byTruncatingTail
        let row = NSStackView(views: [spinner, label, stop])
        row.orientation = .horizontal
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        glass.contentView = row
        glass.cornerRadius = 22
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        NSLayoutConstraint.activate([
            glass.centerXAnchor.constraint(equalTo: centerXAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -70),
            glass.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ macro: String?) {
        isHidden = macro == nil
        label.stringValue = String(format: String(localized: "Macros.Running"), macro ?? "")
    }

    @objc private func stop(_ sender: Any?) { onStop() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        return super.hitTest(point) ?? self
    }

    override func mouseDown(with event: NSEvent) { /* Swallow clicks meant for the sheet. */ }
}
