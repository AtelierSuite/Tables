import AppKit
import TablesEngine
import TablesMacros
import UniformTypeIdentifiers

extension Notification.Name {
    /// Posted by a `WorkbookDocument` whenever its workbook or editing
    /// session changes, so its window can bring itself up to date.
    static let workbookDocumentDidChange = Notification.Name("WorkbookDocumentDidChange")
}

/// A workbook open on the Mac: the `WorkbookFile` it was read from, and the
/// editing session in its window.
///
/// Every change to the workbook goes through `edit(_:)`, which is where undo
/// steps are registered — the workbook as it was, rather than an inverse
/// operation, since the workbook is a value whose copies share whatever a
/// change left alone — and where a Numbers document takes back whatever part
/// of a change it couldn't save.
@MainActor
final class WorkbookDocument: NSDocument {
    private(set) var file = WorkbookFile()
    let state = EditorState()
    let macroRunner = MacroRunner()

    var workbook: Workbook { file.workbook }
    var activeSheet: Worksheet { state.activeSheet(in: file.workbook) }

    /// A run of changes this close together, of one kind, undoes as one step.
    private static let coalescingInterval: TimeInterval = 1
    private var lastScope: EditScope?
    private var lastChange = Date.distantPast

    override init() {
        super.init()
        hasUndoManager = true
        undoManager?.levelsOfUndo = 100
        prepareSession()
    }

    override class var autosavesInPlace: Bool { true }


    override func makeWindowControllers() {
        addWindowController(WorkbookWindowController())
    }

    // MARK: - Reading and writing

    // Documents are read and written on the main thread: neither
    // `canConcurrentlyReadDocuments` nor `canAsynchronouslyWrite` is on.

    override nonisolated func read(from fileWrapper: FileWrapper, ofType typeName: String) throws {
        guard let type = UTType(typeName) else { throw CocoaError(.fileReadUnsupportedScheme) }
        let file = try WorkbookFile(file: fileWrapper, contentType: type)
        MainActor.assumeIsolated {
            self.file = file
            prepareSession()
        }
    }

    override nonisolated func fileWrapper(ofType typeName: String) throws -> FileWrapper {
        // A file wrapper isn't Sendable, so it is handed out of the main
        // actor's closure by hand; it never leaves the main thread.
        nonisolated(unsafe) var wrapper: FileWrapper?
        try MainActor.assumeIsolated { wrapper = try write(ofType: typeName) }
        guard let wrapper else { throw CocoaError(.fileWriteUnknown) }
        return wrapper
    }

    private func write(ofType typeName: String) throws -> FileWrapper {
        guard let type = UTType(typeName) else { throw CocoaError(.fileWriteUnsupportedScheme) }
        // What is still being typed belongs in what is saved.
        if state.editingAddress != nil { edit { state.commitEditing(in: &$0, then: nil) } }
        // A Numbers document is patched rather than rewritten, from the
        // document as it is on disk.
        let existing = WorkbookFile.isNumbers(type) ? fileURL.flatMap { try? FileWrapper(url: $0) } : nil
        return try file.fileWrapper(
            contentType: type, existing: existing, exportSheetIndex: state.activeIndex(in: file.workbook)
        )
    }

    override nonisolated func writableTypes(for saveOperation: NSDocument.SaveOperationType) -> [String] {
        // Tables can patch a Numbers document but can't make one, so Numbers
        // is offered only for the document a Numbers file was opened as.
        let isNumbers = MainActor.assumeIsolated { file.isNumbers }
        return super.writableTypes(for: saveOperation).filter { identifier in
            guard let type = UTType(identifier), WorkbookFile.isNumbers(type) else { return true }
            return isNumbers && saveOperation != .saveAsOperation
        }
    }

    override nonisolated var fileType: String? {
        didSet { MainActor.assumeIsolated { fileTypeDidChange() } }
    }

    /// After Save As into another kind of file, the session keeps whatever
    /// that kind can: formatting once delimited text becomes a workbook,
    /// macros once a workbook becomes macro-enabled.
    private func fileTypeDidChange() {
        guard let fileType, let type = UTType(fileType), !file.isNumbers else { return }
        let isText = type.conforms(to: .commaSeparatedText) || type.conforms(to: .tabSeparatedText)
        file.isPlainText = isText
        file.isMacroEnabled = type.conforms(to: .macroEnabledWorkbook)
        refreshCapabilities()
        notify()
    }

    // MARK: - Exporting

    @objc func exportAsWorkbook(_ sender: Any?) { export(as: .openXMLWorkbook) }
    @objc func exportAsCSV(_ sender: Any?) { export(as: .commaSeparatedText) }
    @objc func exportAsTSV(_ sender: Any?) { export(as: .tabSeparatedText) }

    /// Writes a copy in another format, leaving the document as it is. A
    /// delimited copy holds the sheet in front.
    private func export(as type: UTType) {
        guard let window = windowControllers.first?.window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = (displayName as NSString).deletingPathExtension
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                let wrapper = try self.file.fileWrapper(
                    contentType: type, existing: nil, exportSheetIndex: self.state.activeIndex(in: self.workbook)
                )
                try wrapper.write(to: url, options: .atomic, originalContentsURL: nil)
            } catch {
                self.presentError(error, modalFor: window, delegate: nil, didPresent: nil, contextInfo: nil)
            }
        }
    }

    // MARK: - Printing

    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation {
        let view = SheetPrintView(sheet: activeSheet)
        let operation = NSPrintOperation(view: view, printInfo: printInfo)
        operation.jobTitle = displayName
        return operation
    }

    // MARK: - Editing

    /// Makes a change to the workbook as one undoable step.
    func edit(_ change: (inout Workbook) -> Void) {
        let old = file.workbook
        var new = old
        change(&new)
        guard new != old else { return notify() }
        if let source = file.numbersSource {
            let (allowed, violation) = NumbersEditPolicy.reconcile(new, from: old, source: source)
            if let violation { state.errorMessage = violation.localizedDescription }
            new = allowed
        }
        file.workbook = new
        record(from: old, to: new)
        notify()
    }

    /// A change to the editing session alone, such as moving the selection.
    func notify() {
        NotificationCenter.default.post(name: .workbookDocumentDidChange, object: self)
    }

    private func record(from old: Workbook, to new: Workbook) {
        guard old != new, let undoManager else { return }
        let scope = new.editScope(from: old)
        let now = Date()
        defer {
            lastScope = scope
            lastChange = now
        }
        // A run of the same kind of change is one step: the step already on
        // the stack holds the workbook from before the run began.
        if scope.coalesces, scope == lastScope, undoManager.canUndo,
           now.timeIntervalSince(lastChange) < Self.coalescingInterval {
            return
        }
        register(restoring: old, named: scope.actionName)
    }

    /// Registers putting `target` back. Run from inside an undo, the inverse
    /// it registers lands on the redo stack, and the other way round.
    private func register(restoring target: Workbook, named name: String) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { document in
            MainActor.assumeIsolated {
                let current = document.file.workbook
                document.register(restoring: current, named: name)
                // An edit straight after an undo starts a step of its own.
                document.lastScope = nil
                document.file.workbook = target
                document.state.showRestored(target, replacing: current)
                document.notify()
            }
        }
        undoManager.setActionName(name)
    }

    // MARK: - Session

    /// Points a fresh session at the workbook's first visible sheet.
    private func prepareSession() {
        let first = file.workbook.visibleSheets.first ?? file.workbook.sheets.first
        if let first { state.selectSheet(first.id, in: file.workbook) }
        state.allowsComments = !file.isPlainText && !file.isNumbers
        state.allowsFreezingPanes = !file.isPlainText && !file.isNumbers
        refreshCapabilities()
    }

    /// What the active sheet can keep, which changes from sheet to sheet in a
    /// Numbers document.
    func refreshCapabilities() {
        state.allowsComments = !file.isPlainText && !file.isNumbers
        state.allowsFreezingPanes = !file.isPlainText && !file.isNumbers
        state.allowsInsertingAndDeleting = file.allowsMovingCells(in: state.activeSheetID)
        state.formatting = file.formatting(in: state.activeSheetID)
    }

    func selectSheet(_ id: Worksheet.ID) {
        if state.editingAddress != nil { edit { state.commitEditing(in: &$0, then: nil) } }
        state.selectSheet(id, in: file.workbook)
        refreshCapabilities()
        notify()
    }

    var isPlainText: Bool { file.isPlainText }
    var isNumbers: Bool { file.isNumbers }
    var isMacroEnabled: Bool { file.isMacroEnabled }
    var numbersSource: NumbersSource? { file.numbersSource }
    var unsupportedFeatures: UnsupportedFeatureReport { file.unsupportedFeatures }
}
