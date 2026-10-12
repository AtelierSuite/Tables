import SwiftUI

/// The document's root view: the grid, the formula bar beneath it, sheet tabs,
/// and whichever platform chrome belongs on top.
struct WorkbookView: View {
    @Binding var document: TablesDocument
    /// Where the file lives, which is what converting it moves.
    var fileURL: URL?
    @State private var state = EditorState()
    @State private var history = WorkbookHistory()
    @State private var macroRunner = MacroRunner()
    @State private var isShowingMacros = false
    /// The macro waiting on the user's say-so before the first run.
    @State private var pendingMacro: MacroCatalog.Macro?
    /// Asked once per window: after that, running a macro just runs it.
    @State private var hasAllowedMacros = false
    @State private var macroInput = ""
    /// A conversion waiting on the user's say-so because it would drop macros.
    @State private var pendingConversion: DocumentConversion.Target?
    /// A change to a Numbers document with what it couldn't keep taken out,
    /// written back in place of the change as made.
    @State private var pendingReconciliation: Workbook?
    @Environment(\.undoManager) private var undoManager
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @Namespace private var panelTransition

    private var workbook: Binding<Workbook> { $document.workbook }
    /// The file's name, which macros see as `ThisWorkbook.Name`.
    private var fileName: String? { fileURL?.lastPathComponent }

    var body: some View {
        VStack(spacing: 0) {
            sheetContent
                // Keyboard navigation belongs to the grid, and only while no
                // text field is up — otherwise it holds focus away from them.
                .focusable(state.editingAddress == nil && !state.isFormulaBarActive)
                .focusEffectDisabled()
                .onKeyPress(action: handleKeyPress)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    #if os(iOS)
                    FloatingActionBar(
                        workbook: workbook, state: state, namespace: panelTransition,
                        // Any workbook can be given macros; delimited text and
                        // Numbers documents have nowhere to keep them.
                        showMacros: document.isPlainText || document.isNumbers ? nil : { isShowingMacros = true },
                        isMacroRunning: macroRunner.isRunning
                    )
                        .padding(.bottom, 8)
                    #endif
                }

            Divider()
            // A chart sheet has no cells to show a formula for.
            if !activeSheet.isChartSheet {
                FormulaBarView(workbook: workbook, state: state)
                Divider()
            }
            SheetTabBarView(workbook: workbook, state: state)
                .background(.bar)
        }
        .background(Color.sheetBackground)
        .overlay { if macroRunner.isRunning { runningMacroOverlay } }
        // The Macros sheet asks its own questions while it is up.
        .modifier(MacroPrompts(runner: macroRunner, input: $macroInput, isEnabled: !isShowingMacros))
        .sheet(isPresented: $isShowingMacros) {
            macrosSheet.presentationContentInteraction(.scrolls)
        }
        .confirmationDialog(
            "Macros.Confirm.Title",
            isPresented: Binding(get: { pendingMacro != nil }, set: { if !$0 { pendingMacro = nil } }),
            titleVisibility: .visible,
            presenting: pendingMacro
        ) { macro in
            Button("Macros.Confirm.Run") {
                hasAllowedMacros = true
                runMacro(macro)
            }
        } message: { _ in
            Text("Macros.Confirm.Message")
        }
        .toolbarTitleMenu { titleMenu }
        .confirmationDialog(
            "Convert.DropMacros.Title",
            isPresented: Binding(get: { pendingConversion != nil }, set: { if !$0 { pendingConversion = nil } }),
            titleVisibility: .visible,
            presenting: pendingConversion
        ) { target in
            Button("Convert.DropMacros.Confirm", role: .destructive) { convert(to: target) }
        } message: { _ in
            Text("Convert.DropMacros.Message")
        }
        .onAppear {
            state.allowsFormatting = !document.isPlainText && !document.isNumbers
            if state.activeSheetID == nil {
                state.activeSheetID = document.workbook.sheets.first?.id
                state.refreshMetrics(in: document.workbook)
            }
            state.allowsInsertingAndDeleting = document.allowsMovingCells(in: state.activeSheetID)
            attachHistory()
        }
        .onChange(of: undoManager) { _, _ in attachHistory() }
        .onChange(of: document.workbook) { old, new in record(from: old, to: new) }
        .onChange(of: state.activeSheetID) { _, _ in
            // CSV holds one sheet; export whichever one the user is looking at.
            document.csvExport.sheetIndex = state.activeIndex(in: document.workbook)
            state.allowsInsertingAndDeleting = document.allowsMovingCells(in: state.activeSheetID)
        }
        #if os(iOS)
        .toolbar { editorToolbar }
        .sheet(isPresented: $state.isShowingUnsupportedFeatureNotice) {
            UnsupportedFeatureNotice(report: document.unsupportedFeatures)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationContentInteraction(.scrolls)
        }
        #endif
        #if os(macOS)
        .toolbar { sharingToolbar }
        .toolbar { macToolbar }
        .popover(item: $state.presentedPanel) { panel in
            panelContent(panel)
                .frame(width: 360, height: 480)
        }
        #else
        .sheet(item: $state.presentedPanel) { panel in
            NavigationStack {
                panelContent(panel)
                    .navigationTitle(panel.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .navigationBarBackButtonHidden()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            // `.confirm` is the SDK's label-less Done button.
                            Button(role: .confirm) { state.presentedPanel = nil }
                        }
                    }
            }
            .navigationTransition(.zoom(sourceID: panel, in: panelTransition))
            .presentationDetents(panelDetents(panel))
            .presentationDragIndicator(.visible)
            .presentationContentInteraction(.scrolls)
            .presentationBackground(.regularMaterial)
        }
        #endif
        .alert(
            "Alert.Error.Title",
            isPresented: Binding(
                get: { state.errorMessage != nil },
                set: { if !$0 { state.errorMessage = nil } }
            )
        ) {
            Button("Common.OK", role: .cancel) { state.errorMessage = nil }
        } message: {
            Text(state.errorMessage ?? "")
        }
    }

    private var activeSheet: Worksheet { state.activeSheet(in: document.workbook) }

    @ViewBuilder
    private var sheetContent: some View {
        if activeSheet.isChartSheet {
            ChartSheetView(workbook: workbook, state: state, sheet: activeSheet)
        } else {
            SheetGridView(workbook: workbook, state: state, runMacro: runControlMacro)
        }
    }

    // MARK: - Panels

    @ViewBuilder
    private func panelContent(_ panel: EditorPanel) -> some View {
        switch panel {
        case .format: FormatPanel(workbook: workbook, state: state)
        case .numberFormat: NumberFormatPanel(workbook: workbook, state: state)
        case .rowsAndColumns: RowsColumnsPanel(workbook: workbook, state: state)
        case .functions: FunctionsPanel(workbook: workbook, state: state)
        case .chart: ChartPanel(workbook: workbook, state: state)
        case .comment: CommentPanel(workbook: workbook, state: state)
        case .find: FindPanel(workbook: workbook, state: state)
        }
    }

    #if os(iOS)
    /// Formatting panels stay at half height so the cells they change stay in view.
    private func panelDetents(_ panel: EditorPanel) -> Set<PresentationDetent> {
        switch panel {
        case .format, .numberFormat, .rowsAndColumns: return [.medium]
        case .functions, .chart, .comment, .find: return [.medium, .large]
        }
    }
    #endif

    // MARK: - Title menu

    /// The menu under the file's name: renaming it, and turning it into
    /// another kind of workbook — which is how a CSV gains formatting.
    @ViewBuilder
    private var titleMenu: some View {
        RenameButton()
        if let fileURL, document.isNumbers {
            Section {
                Button("TitleMenu.SaveAsXLSX", systemImage: "square.and.arrow.down.on.square") {
                    saveCopy(besideFileAt: fileURL)
                }
            }
        } else if let fileURL {
            Section {
                ForEach(DocumentConversion.targets(for: fileURL)) { target in
                    Button(conversionTitle(for: target), systemImage: "arrow.triangle.2.circlepath") {
                        // An `.xlsx` has nowhere to keep macros; say so first.
                        if target == .workbook, document.workbook.hasMacros {
                            pendingConversion = target
                        } else {
                            convert(to: target)
                        }
                    }
                }
            }
        }
    }

    private func conversionTitle(for target: DocumentConversion.Target) -> LocalizedStringKey {
        switch target {
        case .workbook: return "TitleMenu.ConvertToXLSX"
        case .macroEnabledWorkbook: return "TitleMenu.ConvertToXLSM"
        }
    }

    private func convert(to target: DocumentConversion.Target) {
        guard let fileURL else { return }
        state.commitEditing(in: &document.workbook, then: nil)
        let workbook = document.workbook
        Task {
            do {
                _ = try await DocumentConversion.convert(fileAt: fileURL, workbook: workbook, to: target)
            } catch {
                state.errorMessage = error.localizedDescription
                return
            }
            document.isPlainText = false
            document.isMacroEnabled = target == .macroEnabledWorkbook
            state.allowsFormatting = true
        }
    }

    /// Saves a Numbers document's workbook as an `.xlsx` beside it, leaving
    /// the document itself as it is.
    private func saveCopy(besideFileAt fileURL: URL) {
        state.commitEditing(in: &document.workbook, then: nil)
        let workbook = document.workbook
        Task {
            do {
                _ = try await DocumentConversion.saveCopy(of: workbook, besideFileAt: fileURL)
            } catch {
                state.errorMessage = error.localizedDescription
            }
        }
    }

    /// Every change to the workbook passes through here on its way to the
    /// undo stack. A Numbers document first has whatever part of the change
    /// it couldn't save taken back out, and says why.
    private func record(from old: Workbook, to new: Workbook) {
        if let reconciled = pendingReconciliation {
            pendingReconciliation = nil
            if reconciled == new { return }
        }
        guard let source = document.numbersSource else { return history.record(from: old, to: new) }
        let (allowed, violation) = NumbersEditPolicy.reconcile(new, from: old, source: source)
        if let violation { state.errorMessage = violation.localizedDescription }
        if allowed != new {
            // Putting it back is itself a change, reported in a moment; the
            // step it completes is the one recorded here.
            pendingReconciliation = allowed
            document.workbook = allowed
        }
        history.record(from: old, to: allowed)
    }

    // MARK: - Toolbars

    private var export: WorkbookExport {
        WorkbookExport(
            workbook: document.workbook,
            name: state.activeSheet(in: document.workbook).name,
            sheetIndex: state.activeIndex(in: document.workbook)
        )
    }

    private func attachHistory() {
        let document = $document
        let state = state
        history.attach(
            to: undoManager,
            read: { document.wrappedValue.workbook },
            write: { document.wrappedValue.workbook = $0 },
            restored: { now, before in state.showRestored(now, replacing: before) }
        )
    }

    #if os(iOS)
    /// Clipboard, history, Find, then Share sharing a group with "…". An
    /// iPhone's bar has room for history and "…" only, so there the clipboard,
    /// Find and Share move into the menu.
    @ToolbarContentBuilder
    private var editorToolbar: some ToolbarContent {
        if horizontalSizeClass != .compact {
            ToolbarItemGroup(placement: .topBarTrailing) { clipboardButtons }
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
        }
        undoToolbar
        ToolbarSpacer(.fixed, placement: .topBarTrailing)
        if horizontalSizeClass != .compact {
            ToolbarItem(placement: .topBarTrailing) { findButton }
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if horizontalSizeClass != .compact {
                shareButton
            }
            moreMenu
        }
    }

    /// macOS has Undo and Redo in its Edit menu; iOS has nowhere to put them
    /// but here, and a hardware keyboard reaches them through these too.
    @ToolbarContentBuilder
    private var undoToolbar: some ToolbarContent {
        // Pinned to the trailing edge: as primary actions the bar would fold
        // Redo into its own overflow menu once it ran short of room.
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button("Toolbar.Undo", systemImage: "arrow.uturn.backward") { history.undo() }
                .disabled(!history.canUndo)
                .keyboardShortcut("z", modifiers: .command)
                .accessibilityIdentifier("undo")
            Button("Toolbar.Redo", systemImage: "arrow.uturn.forward") { history.redo() }
                .disabled(!history.canRedo)
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .accessibilityIdentifier("redo")
        }
    }

    @ViewBuilder
    private var clipboardButtons: some View {
        Button("CellMenu.Cut", systemImage: "scissors") {
            state.cutSelection(in: &document.workbook)
        }
        .accessibilityIdentifier("cut")
        Button("CellMenu.Copy", systemImage: "doc.on.doc") {
            state.copySelection(in: document.workbook)
        }
        .accessibilityIdentifier("copy")
        Button("CellMenu.Paste", systemImage: "doc.on.clipboard") {
            state.paste(in: &document.workbook)
        }
        .accessibilityIdentifier("paste")
    }

    private var shareButton: some View {
        ShareLink(item: export, preview: SharePreview(export.name, image: Image(systemName: "tablecells"))) {
            Label("Toolbar.Share.Label", systemImage: "square.and.arrow.up")
        }
        .accessibilityIdentifier("share")
    }

    private var findButton: some View {
        Button("Toolbar.Find", systemImage: "magnifyingglass") {
            state.presentedPanel = .find
        }
        .keyboardShortcut("f", modifiers: .command)
        .accessibilityIdentifier("find")
    }

    /// The "…" menu. A menu of its own rather than secondary actions, which an
    /// iPad's document bar lays out across the middle instead of folding away.
    private var moreMenu: some View {
        Menu("Toolbar.More", systemImage: "ellipsis") {
            if horizontalSizeClass == .compact {
                Section { clipboardButtons }
                Section { findButton }
                Section { shareButton }
            }
            Section {
                if !document.unsupportedFeatures.isEmpty {
                    Button("Toolbar.UnsupportedFeatures.Label", systemImage: "exclamationmark.triangle") {
                        state.isShowingUnsupportedFeatureNotice = true
                    }
                    .accessibilityIdentifier("unsupportedFeatures")
                }
                Link(destination: URL(string: "https://github.com/katagaki/Tables")!) {
                    Label("Toolbar.SourceCode", systemImage: "chevron.left.forwardslash.chevron.right")
                }
            }
        }
        .accessibilityIdentifier("more")
    }
    #endif

    @ToolbarContentBuilder
    private var sharingToolbar: some ToolbarContent {
        #if os(macOS)
        // On iOS this lives in the floating action bar instead.
        if !document.isPlainText && !document.isNumbers {
            ToolbarItem(placement: .primaryAction) {
                Button("Toolbar.Macros", systemImage: "curlybraces") { isShowingMacros = true }
                    .disabled(macroRunner.isRunning)
                    .help(String(localized: "Toolbar.Macros"))
                    .accessibilityIdentifier("macros")
            }
        }
        #endif
        // Declared before the share button so it sits beside it on the inside.
        if !document.unsupportedFeatures.isEmpty {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    state.isShowingUnsupportedFeatureNotice = true
                } label: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .accessibilityIdentifier("unsupportedFeatures")
                .accessibilityLabel("Toolbar.UnsupportedFeatures.Label")
                .popover(isPresented: $state.isShowingUnsupportedFeatureNotice) {
                    UnsupportedFeatureNotice(report: document.unsupportedFeatures)
                }
            }
        }
        ToolbarItem(placement: .primaryAction) {
            ShareLink(item: export, preview: SharePreview(export.name, image: Image(systemName: "tablecells")))
                .accessibilityLabel("Toolbar.Share.Label")
        }
    }

    #if os(macOS)
    /// macOS gets one horizontal toolbar holding everything.
    @ToolbarContentBuilder
    private var macToolbar: some ToolbarContent {
        // Delimited text keeps no styling, so there is nothing to format.
        if state.allowsFormatting {
            formattingToolbar
        }

        ToolbarItemGroup {
            toolbarToggle("sum", label: String(localized: "Toolbar.Sum"), isOn: false) {
                state.insertAggregate("SUM", in: &document.workbook)
            }
            toolbarToggle(
                "function", label: String(localized: "Toolbar.InsertFunction"),
                isOn: state.presentedPanel == .functions
            ) {
                state.presentedPanel = .functions
            }
            toolbarToggle("tablecells", label: String(localized: "Toolbar.RowsAndColumns"),
                          isOn: state.presentedPanel == .rowsAndColumns) {
                state.presentedPanel = .rowsAndColumns
            }
        }

        ToolbarItemGroup {
            Menu {
                InsertChartMenuItems(workbook: $document.workbook, state: state)
            } label: {
                Image(systemName: "chart.bar.xaxis")
            }
            .menuIndicator(.hidden)
            .disabled(activeSheet.isChartSheet)
            .help(String(localized: "Toolbar.InsertChart"))
            .accessibilityLabel(String(localized: "Toolbar.InsertChart"))

            if state.selectedChartID != nil {
                toolbarToggle(
                    "slider.horizontal.3", label: String(localized: "Toolbar.EditChart"),
                    isOn: state.presentedPanel == .chart
                ) {
                    state.presentedPanel = .chart
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var formattingToolbar: some ToolbarContent {
        ToolbarItemGroup {
            toolbarToggle("bold", label: String(localized: "Toolbar.Bold"), isOn: currentStyle.isBold) {
                state.toggleBold(in: &document.workbook)
            }
            toolbarToggle("italic", label: String(localized: "Toolbar.Italic"), isOn: currentStyle.isItalic) {
                state.toggleItalic(in: &document.workbook)
            }
            toolbarToggle(
                "underline", label: String(localized: "Toolbar.Underline"),
                isOn: currentStyle.isUnderlined
            ) {
                state.toggleUnderline(in: &document.workbook)
            }
        }

        ToolbarItemGroup {
            ForEach(HorizontalTextAlignment.allCases.filter { $0 != .automatic }, id: \.self) { option in
                toolbarToggle(
                    option.symbolName, label: option.label,
                    isOn: currentStyle.horizontalAlignment == option
                ) {
                    state.applyStyle(in: &document.workbook) { $0.horizontalAlignment = option }
                }
            }
        }

        ToolbarItemGroup {
            toolbarToggle(
                "number", label: String(localized: "Toolbar.NumberFormat"),
                isOn: state.presentedPanel == .numberFormat
            ) {
                state.presentedPanel = .numberFormat
            }
            toolbarToggle(
                "paintpalette", label: String(localized: "Toolbar.CellFormat"),
                isOn: state.presentedPanel == .format
            ) {
                state.presentedPanel = .format
            }
        }
    }

    private var currentStyle: CellStyle { state.representativeStyle(in: document.workbook) }

    /// Active toolbar controls take a round highlight, matching the floating bar.
    private func toolbarToggle(
        _ symbol: String, label: String, isOn: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 26, height: 26)
                .background(isOn ? Color.accentColor.opacity(0.22) : .clear, in: .circle)
                .foregroundStyle(isOn ? Color.accentColor : .primary)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
    #endif

    // MARK: - Macros

    private var macrosSheet: some View {
        let loaded = Result { try document.workbook.macroProject.map(VBAProject.init(data:)) }
        return MacrosView(
            project: (try? loaded.get()) ?? nil,
            loadError: loaded.failureDescription,
            isMacroEnabledFile: document.isMacroEnabled,
            workingFolder: MacroFiles.folder(forWorkbookNamed: fileName),
            runner: macroRunner,
            run: { module, procedure in
                let macro = MacroCatalog.Macro(module: module, procedure: procedure)
                isShowingMacros = false
                if hasAllowedMacros {
                    runMacro(macro)
                } else {
                    pendingMacro = macro
                }
            },
            // From the code editor, where the code is the user's own and the
            // sheet stays up to show how the run went.
            testRun: { module, procedure in
                await performMacro(MacroCatalog.Macro(module: module, procedure: procedure), reportingFailure: false)
            },
            edit: { change in
                guard let data = document.workbook.macroProject else { return }
                var project = try VBAProject(data: data)
                try change(&project)
                document.workbook.setMacroProject(try project.data())
            },
            createProject: { try document.workbook.createMacroProject() }
        )
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }

    /// Runs a macro on a copy of the workbook and puts back what it made
    /// of it in one change, so a single undo takes the whole run back.
    private func runMacro(_ macro: MacroCatalog.Macro) {
        Task { await performMacro(macro, reportingFailure: true) }
    }

    /// Runs a macro and applies what it did, returning why it stopped early
    /// when it did.
    @discardableResult
    private func performMacro(_ macro: MacroCatalog.Macro, reportingFailure: Bool) async -> String? {
        guard let data = document.workbook.macroProject, let project = try? VBAProject(data: data) else { return nil }
        state.commitEditing(in: &document.workbook, then: nil)
        let before = document.workbook
        let outcome = await macroRunner.run(
            macro.procedure, in: macro.module, project: project, workbook: before,
            workbookName: fileName ?? String(localized: "Macros.DefaultWorkbookName"),
            activeSheet: state.activeSheetID, selection: state.selection,
            workingFolder: MacroFiles.folder(forWorkbookNamed: fileName)
        )
        if outcome.workbook != before { document.workbook = outcome.workbook }
        if outcome.activeSheetID != state.activeSheetID, outcome.workbook.index(of: outcome.activeSheetID) != nil {
            state.selectSheet(outcome.activeSheetID, in: outcome.workbook)
        }
        state.selection = outcome.selection
        state.anchor = outcome.selection.start
        state.additionalSelections = []
        state.clampSelection(to: state.activeSheet(in: document.workbook))
        state.refreshMetrics(in: document.workbook)
        if let failure = outcome.failure, reportingFailure {
            state.errorMessage = String(format: String(localized: "Macros.Failed"), failure)
        }
        return outcome.failure
    }

    /// Runs the macro a form control names, asking first as the macro list
    /// does. Excel lets the name leave out the module.
    private func runControlMacro(_ control: FormControl) {
        guard let target = control.macroTarget else { return }
        let catalog = document.workbook.macroProject
            .flatMap { try? VBAProject(data: $0) }
            .map { MacroCatalog(project: $0) } ?? MacroCatalog()
        func same(_ lhs: String, _ rhs: String) -> Bool { lhs.caseInsensitiveCompare(rhs) == .orderedSame }
        guard let macro = catalog.macros.first(where: { macro in
            same(macro.procedure, target.procedure) && (target.module.map { same($0, macro.module) } ?? true)
        }) else {
            state.errorMessage = String(format: String(localized: "FormControl.MacroNotFound"), control.macro ?? "")
            return
        }
        if hasAllowedMacros {
            runMacro(macro)
        } else {
            pendingMacro = macro
        }
    }

    /// While a macro runs the sheet is the macro's: a veil keeps edits off
    /// it, and says how to stop a macro that does not finish.
    private var runningMacroOverlay: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.08)
                .ignoresSafeArea()
                .contentShape(.rect)
                .onTapGesture { /* Swallow taps meant for the sheet. */ }
            HStack(spacing: 12) {
                ProgressView()
                Text(String(format: String(localized: "Macros.Running"), macroRunner.runningMacro ?? ""))
                    .lineLimit(1)
                Button("Macros.Stop", role: .destructive) { macroRunner.stop() }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("stopMacro")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: .capsule)
            .padding(.bottom, 24)
        }
    }

    // MARK: - Keyboard

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        let sheet = state.activeSheet(in: document.workbook)
        let isEditing = state.editingAddress != nil
        let extending = press.modifiers.contains(.shift)

        // With a chart picked out, the keyboard is about the chart.
        if state.selectedChartID != nil, !isEditing {
            switch press.key {
            case .delete, .deleteForward:
                state.deleteSelectedChart(in: &document.workbook)
                return .handled
            case .escape where !sheet.isChartSheet:
                state.selectChart(nil)
                return .handled
            case .return:
                state.presentedPanel = .chart
                return .handled
            default:
                if !sheet.isChartSheet { state.selectChart(nil) }
            }
        }
        // Likewise a picture.
        if state.selectedDrawingID != nil, !isEditing {
            switch press.key {
            case .delete, .deleteForward:
                state.deleteSelectedDrawing(in: &document.workbook)
                return .handled
            case .escape:
                state.selectDrawing(nil)
                return .handled
            default:
                state.selectDrawing(nil)
            }
        }
        // There are no cells on a chart sheet to move between or type into.
        guard !sheet.isChartSheet else { return .ignored }

        switch press.key {
        case .upArrow where !isEditing:
            state.move(.up, extending: extending, in: sheet)
            return .handled
        case .downArrow where !isEditing:
            state.move(.down, extending: extending, in: sheet)
            return .handled
        case .leftArrow where !isEditing:
            state.move(.left, extending: extending, in: sheet)
            return .handled
        case .rightArrow where !isEditing:
            state.move(.right, extending: extending, in: sheet)
            return .handled
        case .tab where !isEditing:
            state.move(extending ? .left : .right, in: sheet)
            return .handled
        // Traversing while typing keeps you typing in the next cell.
        case .tab where isEditing:
            state.commitEditing(
                in: &document.workbook, then: extending ? .left : .right, keepingEditor: true
            )
            return .handled
        case .return where isEditing:
            state.commitEditing(
                in: &document.workbook, then: extending ? .up : .down, keepingEditor: true
            )
            return .handled
        case .return where !isEditing:
            state.beginEditing(state.selectedAddress, in: document.workbook)
            return .handled
        case .escape where isEditing:
            state.cancelEditing()
            return .handled
        case .delete where !isEditing, .deleteForward where !isEditing:
            state.clearContents(in: &document.workbook)
            return .handled
        default:
            break
        }

        guard !isEditing, !press.characters.isEmpty else { return .ignored }

        if press.modifiers.contains(.command) {
            switch press.characters.lowercased() {
            case "b" where state.allowsFormatting: state.toggleBold(in: &document.workbook); return .handled
            case "i" where state.allowsFormatting: state.toggleItalic(in: &document.workbook); return .handled
            case "u" where state.allowsFormatting: state.toggleUnderline(in: &document.workbook); return .handled
            case "c": state.copySelection(in: document.workbook); return .handled
            case "x": state.cutSelection(in: &document.workbook); return .handled
            case "v": state.paste(in: &document.workbook); return .handled
            case "a": state.selectAll(in: sheet); return .handled
            default: return .ignored
            }
        }

        // Any other printable key starts an edit with that character.
        guard let first = press.characters.first, !first.isNewline, first.isLetter || first.isNumber
                || first.isPunctuation || first.isSymbol || first == " " else {
            return .ignored
        }
        state.beginEditing(state.selectedAddress, in: document.workbook, replacingWith: press.characters)
        return .handled
    }
}

/// What the toolbar's warning button says: which parts of the file Tables can
/// only carry, and which it will drop.
///
/// A popover rather than an alert: nothing here needs deciding, so it has no
/// business stopping the user before they have seen their spreadsheet.
private struct UnsupportedFeatureNotice: View {
    var report: UnsupportedFeatureReport

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Notice.UnsupportedFeatures.Title", systemImage: "exclamationmark.triangle")
                .font(.headline)
                .labelStyle(.titleAndIcon)
            Text(report.noticeMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                // A popover sizes itself to its content, and without this the
                // message is laid out on one unbroken line.
                .fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(.leading)
        .padding(20)
        .frame(idealWidth: 300, maxWidth: 340, alignment: .leading)
        // iPhone turns a popover into a sheet unless it is told not to.
        .presentationCompactAdaptation(.popover)
    }
}
