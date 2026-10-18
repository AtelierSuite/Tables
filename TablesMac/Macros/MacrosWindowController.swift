import AppKit
import TablesEngine
import TablesMacros

/// A workbook's macros, in a window of their own beside it: the modules down
/// the side, the selected one's code, and what the last run printed.
///
/// Code is written back into the workbook — one undoable step — when Save
/// is chosen, another module is picked, a macro is run or the window closes.
@MainActor
final class MacrosWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate,
                                    NSTableViewDataSource, NSTableViewDelegate {
    private weak var workbookDocument: WorkbookDocument?
    /// Runs a macro the way the workbook window does, asking first.
    var run: (MacroCatalog.Macro) -> Void = { _ in }

    private let table = NSTableView()
    private let (codeScroll, code) = CodeTextView.makeScrollable()
    private let output = NSTextView()
    private let banner = NSTextField(wrappingLabelWithString: "")
    private let bannerGlass = NSGlassEffectView()
    private let emptyState = NSStackView()
    private let notice = NSTextField(wrappingLabelWithString: "")
    private var runItem: NSMenuToolbarItem?

    private var project: VBAProject?
    private var loadError: String?
    /// Modules whose code doesn't parse, as of the last save.
    private var problems: [String: String] = [:]
    private var selectedModule: String?
    /// The code as last saved, to tell whether there is anything to save.
    private var savedCode = ""
    private var checkTask: Task<Void, Never>?

    init(document: WorkbookDocument) {
        self.workbookDocument = document
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: true
        )
        window.minSize = NSSize(width: 560, height: 360)
        window.toolbarStyle = .unified
        super.init(window: window)
        window.delegate = self
        window.title = String(localized: "Macros.Title")
        window.subtitle = document.displayName
        window.contentViewController = makeContent()
        let toolbar = NSToolbar(identifier: "Macros")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        windowFrameAutosaveName = "Macros"
        reload()
    }

    /// The split views size the window to their smallest on first layout,
    /// so the first showing sets a roomier size unless one was saved.
    private var hasSized = false

    override func showWindow(_ sender: Any?) {
        if !hasSized, let window {
            hasSized = true
            if !window.setFrameUsingName("Macros") {
                window.setContentSize(NSSize(width: 900, height: 600))
                window.center()
            }
        }
        super.showWindow(sender)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: - Layout

    private func makeContent() -> NSViewController {
        let split = NSSplitViewController()

        // The modules.
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("module"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .sourceList
        table.dataSource = self
        table.delegate = self
        table.menu = moduleMenu()
        table.setAccessibilityIdentifier("modules")
        let tableScroll = NSScrollView()
        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true
        tableScroll.drawsBackground = false

        notice.textColor = .secondaryLabelColor
        notice.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        let create = NSButton(title: String(localized: "Macros.Create"), target: self, action: #selector(createProject(_:)))
        create.bezelColor = .controlAccentColor
        create.setAccessibilityIdentifier("createMacros")
        let createMessage = NSTextField(wrappingLabelWithString: String(localized: "Macros.Create.Message"))
        createMessage.textColor = .secondaryLabelColor
        emptyState.orientation = .vertical
        emptyState.alignment = .leading
        emptyState.spacing = 10
        emptyState.addArrangedSubview(createMessage)
        emptyState.addArrangedSubview(create)

        let sidebar = NSStackView(views: [tableScroll, emptyState, notice])
        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 10, right: 10)
        tableScroll.widthAnchor.constraint(equalTo: sidebar.widthAnchor, constant: -20).isActive = true
        createMessage.preferredMaxLayoutWidth = 200
        notice.preferredMaxLayoutWidth = 200
        let sidebarController = NSViewController()
        sidebarController.view = sidebar
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 320
        split.addSplitViewItem(sidebarItem)

        // The code, with problems floating over it on glass.
        code.onChange = { [weak self] in self?.codeDidChange() }
        let codeArea = NSView()
        codeScroll.translatesAutoresizingMaskIntoConstraints = false
        codeArea.addSubview(codeScroll)
        banner.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        banner.textColor = .labelColor
        let bannerContent = NSView()
        banner.translatesAutoresizingMaskIntoConstraints = false
        bannerContent.addSubview(banner)
        bannerGlass.contentView = bannerContent
        bannerGlass.cornerRadius = 12
        bannerGlass.tintColor = NSColor.systemOrange.withAlphaComponent(0.25)
        bannerGlass.isHidden = true
        bannerGlass.translatesAutoresizingMaskIntoConstraints = false
        codeArea.addSubview(bannerGlass)
        NSLayoutConstraint.activate([
            codeScroll.leadingAnchor.constraint(equalTo: codeArea.leadingAnchor),
            codeScroll.trailingAnchor.constraint(equalTo: codeArea.trailingAnchor),
            codeScroll.topAnchor.constraint(equalTo: codeArea.topAnchor),
            codeScroll.bottomAnchor.constraint(equalTo: codeArea.bottomAnchor),
            bannerGlass.leadingAnchor.constraint(equalTo: codeArea.leadingAnchor, constant: 16),
            bannerGlass.trailingAnchor.constraint(equalTo: codeArea.trailingAnchor, constant: -16),
            bannerGlass.bottomAnchor.constraint(equalTo: codeArea.bottomAnchor, constant: -16),
            banner.leadingAnchor.constraint(equalTo: bannerContent.leadingAnchor, constant: 12),
            banner.trailingAnchor.constraint(equalTo: bannerContent.trailingAnchor, constant: -12),
            banner.topAnchor.constraint(equalTo: bannerContent.topAnchor, constant: 8),
            banner.bottomAnchor.constraint(equalTo: bannerContent.bottomAnchor, constant: -8),
        ])

        // What the last run printed.
        let outputScroll = NSTextView.scrollableTextView()
        let outputView = outputScroll.documentView as! NSTextView
        outputView.isEditable = false
        outputView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        outputView.textContainerInset = NSSize(width: 6, height: 6)
        outputView.setAccessibilityIdentifier("macroOutput")
        outputTextView = outputView
        let outputLabel = NSTextField(labelWithString: String(localized: "Macros.Section.Output"))
        outputLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        outputLabel.textColor = .secondaryLabelColor
        let outputStack = NSStackView(views: [outputLabel, outputScroll])
        outputStack.orientation = .vertical
        outputStack.alignment = .leading
        outputStack.spacing = 4
        outputStack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 0, right: 0)
        outputScroll.widthAnchor.constraint(equalTo: outputStack.widthAnchor, constant: -8).isActive = true

        let detail = NSSplitViewController()
        detail.splitView.isVertical = false
        let codeController = NSViewController()
        codeController.view = codeArea
        let outputController = NSViewController()
        outputController.view = outputStack
        let codeItem = NSSplitViewItem(viewController: codeController)
        let outputItem = NSSplitViewItem(viewController: outputController)
        outputItem.minimumThickness = 60
        outputItem.holdingPriority = .defaultLow + 10
        detail.addSplitViewItem(codeItem)
        detail.addSplitViewItem(outputItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: detail))
        return split
    }

    private var outputTextView: NSTextView?

    // MARK: - Loading

    /// Reads the project out of the workbook again, as it may have changed
    /// by undo or by a macro run.
    func reload() {
        guard let document = workbookDocument else { return }
        let loaded = Result { try document.workbook.macroProject.map(VBAProject.init(data:)) }
        let previous = project
        project = (try? loaded.get()) ?? nil
        loadError = loaded.failureDescription
        problems = project.map { MacroCatalog(project: $0).problems } ?? [:]
        if let project, !project.modules.contains(where: { $0.name == selectedModule }) {
            selectedModule = project.modules.first(where: { $0.kind == .standard })?.name ?? project.modules.first?.name
        }
        table.reloadData()
        if let selectedModule, let index = project?.modules.firstIndex(where: { $0.name == selectedModule }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        // Keep what is being typed unless the project changed underneath it.
        if previous != project || code.string == savedCode { showSelectedModule() }

        emptyState.isHidden = project != nil || loadError != nil
        var notes: [String] = []
        if let loadError { notes.append(String(format: String(localized: "Macros.LoadFailed"), loadError)) }
        if !document.isMacroEnabled { notes.append(String(localized: "Macros.XLSXNotice")) }
        notes.append(String(localized: "Macros.Footer"))
        notice.stringValue = notes.joined(separator: "\n\n")
        refreshOutput()
        rebuildRunMenu()
    }

    private func showSelectedModule() {
        let module = project?.modules.first { $0.name == selectedModule }
        code.setCode(module?.source ?? "")
        savedCode = code.string
        code.isEditable = module != nil
        check()
    }

    func refreshOutput() {
        guard let document = workbookDocument else { return }
        outputTextView?.string = document.macroRunner.output.joined(separator: "\n")
        outputTextView?.scrollToEndOfDocument(nil)
        runItem?.isEnabled = !document.macroRunner.isRunning
    }

    // MARK: - Saving

    /// Writes the code being edited into the workbook, if it changed.
    @discardableResult
    func saveCode() -> Bool {
        guard let selectedModule, code.string != savedCode else { return true }
        let source = code.string
        let saved = edit { try $0.setSource(source, ofModule: selectedModule) }
        if saved { savedCode = source }
        return saved
    }

    /// Changes the workbook's project and writes it back, saying why when
    /// it can't be.
    @discardableResult
    private func edit(_ change: (inout VBAProject) throws -> Void) -> Bool {
        guard let document = workbookDocument, let data = document.workbook.macroProject else { return false }
        do {
            var project = try VBAProject(data: data)
            try change(&project)
            let encoded = try project.data()
            document.edit { $0.setMacroProject(encoded) }
            self.project = project
            return true
        } catch {
            showError(error.localizedDescription)
            return false
        }
    }

    private func showError(_ message: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Macros.Save.Failed")
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "Common.OK"))
        alert.beginSheetModal(for: window)
    }

    @objc func saveMacros(_ sender: Any?) { saveCode() }

    func windowWillClose(_ notification: Notification) { saveCode() }
    func windowDidResignKey(_ notification: Notification) { saveCode() }

    // MARK: - Checking

    private func codeDidChange() {
        checkTask?.cancel()
        // Problems trail the typing by a moment, so a half-typed line is not
        // flagged before it is finished.
        checkTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.check()
        }
    }

    private func check() {
        guard let selectedModule else {
            bannerGlass.isHidden = true
            return
        }
        do {
            _ = try VBAParser.parse(module: selectedModule, source: code.string)
            bannerGlass.isHidden = true
        } catch {
            banner.stringValue = error.localizedDescription
            bannerGlass.isHidden = false
        }
    }

    // MARK: - Modules

    func numberOfRows(in tableView: NSTableView) -> Int { project?.modules.count ?? 0 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let module = project?.modules[row] else { return nil }
        let cell = NSTableCellView()
        let name = NSTextField(labelWithString: module.name)
        let kind = NSTextField(labelWithString: module.kind.label)
        kind.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        kind.textColor = .secondaryLabelColor
        let icon = NSImageView(image: NSImage(
            systemSymbolName: module.kind == .classModule ? "cube" : "doc.text", accessibilityDescription: nil
        ) ?? NSImage())
        let labels = NSStackView(views: [name, kind])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 0
        let row = NSStackView(views: [icon, labels])
        row.orientation = .horizontal
        row.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(row)
        cell.textField = name
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            row.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        if problems[module.name] != nil {
            let warning = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil) ?? NSImage())
            warning.contentTintColor = .systemOrange
            row.addArrangedSubview(warning)
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 36 }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let project, table.selectedRow >= 0, table.selectedRow < project.modules.count else { return }
        let name = project.modules[table.selectedRow].name
        guard name != selectedModule else { return }
        saveCode()
        selectedModule = name
        showSelectedModule()
        rebuildRunMenu()
    }

    private func moduleMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Macros.RenameModule"), action: #selector(renameModule(_:)), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Macros.RemoveModule.Confirm"), action: #selector(removeModule(_:)), keyEquivalent: "")
        menu.items.forEach { $0.target = self }
        return menu
    }

    /// The module a context-menu action is for: the one clicked, or else
    /// the selected one. Only code modules can be renamed or removed.
    private var actedModule: VBAProject.Module? {
        guard let project else { return nil }
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard row >= 0, row < project.modules.count else { return nil }
        let module = project.modules[row]
        return module.kind == .standard || module.kind == .classModule ? module : nil
    }

    @objc private func addStandardModule(_ sender: Any?) { addModule(kind: .standard) }
    @objc private func addClassModule(_ sender: Any?) { addModule(kind: .classModule) }

    private func addModule(kind: VBAProject.Module.Kind) {
        guard let project else { return }
        saveCode()
        let suggested = project.nextModuleName(kind == .classModule ? "Class" : "Module")
        askName(
            title: String(localized: kind == .classModule ? "Macros.AddClassModule" : "Macros.AddModule"),
            message: String(localized: kind == .classModule ? "Macros.AddClassModule.Message" : "Macros.AddModule.Message"),
            confirm: String(localized: "Macros.AddModule.Confirm"), initial: suggested,
            problem: { project.problem(withModuleName: $0) }
        ) { [weak self] name in
            guard let self, self.edit({ try $0.addModule(named: name, kind: kind) }) else { return }
            self.selectedModule = name
            self.reload()
        }
    }

    @objc private func renameModule(_ sender: Any?) {
        guard let project, let module = actedModule else { return }
        saveCode()
        askName(
            title: String(localized: "Macros.RenameModule.Title"), message: nil,
            confirm: String(localized: "Macros.RenameModule"), initial: module.name,
            problem: { name in
                name.caseInsensitiveCompare(module.name) == .orderedSame ? nil : project.problem(withModuleName: name)
            }
        ) { [weak self] name in
            guard let self, self.edit({ try $0.renameModule(module.name, to: name) }) else { return }
            if self.selectedModule == module.name { self.selectedModule = name }
            self.reload()
        }
    }

    @objc private func removeModule(_ sender: Any?) {
        guard let module = actedModule, let window else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Macros.RemoveModule.Title")
        alert.informativeText = String(format: String(localized: "Macros.RemoveModule.Message"), module.name)
        alert.addButton(withTitle: String(localized: "Macros.RemoveModule.Confirm")).hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "Macros.Button.Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            if self.edit({ $0.removeModule(named: module.name) }) { self.reload() }
        }
    }

    /// Asks for a module name, saying what is wrong with it as it is typed.
    private func askName(
        title: String, message: String?, confirm: String, initial: String,
        problem: @escaping (String) -> String?, then: @escaping (String) -> Void
    ) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message ?? ""
        let field = NSTextField(string: initial)
        field.placeholderString = String(localized: "Macros.AddModule.Placeholder")
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: String(localized: "Macros.Button.Cancel"))
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            if let issue = problem(name) {
                self?.showError(issue)
            } else {
                then(name)
            }
        }
    }

    @objc private func createProject(_ sender: Any?) {
        guard let document = workbookDocument else { return }
        do {
            var workbook = document.workbook
            try workbook.createMacroProject()
            let created = workbook
            document.edit { $0 = created }
            reload()
        } catch {
            showError(error.localizedDescription)
        }
    }

    // MARK: - Running

    private func rebuildRunMenu() {
        guard let runItem else { return }
        let catalog = project.map(MacroCatalog.init(project:)) ?? MacroCatalog()
        let menu = NSMenu()
        if catalog.macros.isEmpty {
            let empty = NSMenuItem(title: String(localized: "Macros.Empty"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        // The selected module's macros first, as those are the ones being written.
        let ordered = catalog.macros.filter { $0.module == selectedModule } + catalog.macros.filter { $0.module != selectedModule }
        for macro in ordered {
            let item = NSMenuItem(title: "\(macro.module).\(macro.procedure)", action: #selector(runMacro(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = macro.id
            item.setAccessibilityIdentifier("macro.\(macro.module).\(macro.procedure)")
            menu.addItem(item)
        }
        runItem.menu = menu
    }

    @objc private func runMacro(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let macro = (project.map(MacroCatalog.init(project:)) ?? MacroCatalog()).macros.first(where: { $0.id == id })
        else { return }
        guard saveCode() else { return }
        run(macro)
    }

    @objc private func stopMacro(_ sender: Any?) { workbookDocument?.macroRunner.stop() }

    @objc private func showFiles(_ sender: Any?) {
        guard let document = workbookDocument else { return }
        let folder = MacroFiles.folder(forWorkbookNamed: document.fileURL?.lastPathComponent)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    @objc private func showHelp(_ sender: Any?) {
        MacroHelpWindowController.shared.showWindow(sender)
    }

    // MARK: - Toolbar

    private enum Item {
        static let run = NSToolbarItem.Identifier("run")
        static let stop = NSToolbarItem.Identifier("stop")
        static let add = NSToolbarItem.Identifier("add")
        static let save = NSToolbarItem.Identifier("save")
        static let files = NSToolbarItem.Identifier("files")
        static let help = NSToolbarItem.Identifier("help")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, Item.add, .sidebarTrackingSeparator, Item.run, Item.stop, Item.save, .flexibleSpace,
         Item.files, Item.help]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        func button(_ symbol: String, _ label: String, _ action: Selector) -> NSToolbarItem {
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            item.label = label
            item.toolTip = label
            item.target = self
            item.action = action
            item.isBordered = true
            return item
        }
        switch identifier {
        case Item.run:
            let item = NSMenuToolbarItem(itemIdentifier: identifier)
            item.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: String(localized: "Macros.Run"))
            item.label = String(localized: "Macros.Run")
            item.toolTip = String(localized: "Macros.Run")
            item.showsIndicator = true
            runItem = item
            rebuildRunMenu()
            return item
        case Item.stop: return button("stop.fill", String(localized: "Macros.Stop"), #selector(stopMacro(_:)))
        case Item.save: return button("square.and.arrow.down", String(localized: "Macros.Save"), #selector(saveMacros(_:)))
        case Item.files: return button("folder", String(localized: "Macros.Files.Title"), #selector(showFiles(_:)))
        case Item.help: return button("questionmark.circle", String(localized: "Help.Title"), #selector(showHelp(_:)))
        case Item.add:
            let item = NSMenuToolbarItem(itemIdentifier: identifier)
            item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: String(localized: "Macros.AddModule"))
            item.label = String(localized: "Macros.AddModule")
            let menu = NSMenu()
            menu.addItem(withTitle: String(localized: "Macros.AddModule"), action: #selector(addStandardModule(_:)), keyEquivalent: "")
            menu.addItem(withTitle: String(localized: "Macros.AddClassModule"), action: #selector(addClassModule(_:)), keyEquivalent: "")
            menu.items.forEach { $0.target = self }
            item.menu = menu
            return item
        default:
            return nil
        }
    }
}

extension MacrosWindowController: NSToolbarItemValidation, NSMenuItemValidation {
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        let isRunning = workbookDocument?.macroRunner.isRunning ?? false
        switch item.itemIdentifier {
        case Item.stop: return isRunning
        case Item.save: return project != nil && code.string != savedCode
        case Item.add: return project != nil
        default: return true
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(renameModule(_:)), #selector(removeModule(_:)): return actedModule != nil
        case #selector(saveMacros(_:)): return project != nil
        default: return true
        }
    }
}
