import SwiftUI
import TablesEngine

/// How the sheet prints: orientation, paper, scale, margins, the print area,
/// the rows and columns repeated on every page, and the header and footer.
/// Changes are made to a copy and handed back on Done, so the whole edit is
/// one undo step.
struct PageSetupPanel: View {
    /// Called with the edited setup on Done, and with `nil` on Cancel.
    let finish: (PrintSetup?) -> Void
    /// The cells selected in the sheet, offered as the print area.
    let selection: CellRange
    private let original: PrintSetup
    @State private var page: PageSetup
    @State private var areaText: String
    @State private var titleRowsText: String
    @State private var titleColumnsText: String
    /// Which of the typed ranges cannot be read, shown on Done.
    @State private var invalid: Set<Field> = []

    private enum Field: Hashable {
        case area, titleRows, titleColumns
    }

    init(setup: PrintSetup, selection: CellRange, finish: @escaping (PrintSetup?) -> Void) {
        self.finish = finish
        self.selection = selection
        original = setup
        _page = State(initialValue: setup.page)
        _areaText = State(initialValue: PrintSetup.areasText(setup.areas))
        _titleRowsText = State(initialValue: setup.titles.rowsText)
        _titleColumnsText = State(initialValue: setup.titles.columnsText)
    }

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            form
            Divider()
            HStack {
                Spacer()
                Button("PageSetup.Cancel", role: .cancel) { finish(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("PageSetup.Done") { done() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("pageSetupDone")
            }
            .padding(12)
        }
        .frame(width: 480, height: 640)
        #else
        form
            .navigationTitle("PageSetup.Title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { finish(nil) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm) { done() }
                        .accessibilityIdentifier("pageSetupDone")
                }
            }
        #endif
    }

    /// Hands back the setup, unless a typed range cannot be read.
    private func done() {
        var setup = original
        setup.page = page
        var invalid: Set<Field> = []
        if let areas = PrintSetup.areas(fromText: areaText) { setup.areas = areas } else { invalid.insert(.area) }
        if let rows = PrintTitles.rows(fromText: titleRowsText) { setup.titles.rows = rows } else { invalid.insert(.titleRows) }
        if let columns = PrintTitles.columns(fromText: titleColumnsText) {
            setup.titles.columns = columns
        } else {
            invalid.insert(.titleColumns)
        }
        self.invalid = invalid
        if invalid.isEmpty { finish(setup) }
    }

    private var form: some View {
        Form {
            Section("PageSetup.Section.Page") {
                Picker("PageSetup.Orientation", selection: $page.orientation) {
                    Text("PageSetup.Orientation.Portrait").tag(PageSetup.Orientation.portrait)
                    Text("PageSetup.Orientation.Landscape").tag(PageSetup.Orientation.landscape)
                }
                .accessibilityIdentifier("pageSetup.orientation")
                Picker("PageSetup.PaperSize", selection: $page.paperSize) {
                    Text("PageSetup.PaperSize.Default").tag(Int?.none)
                    ForEach(PaperSize.known, id: \.code) { paper in
                        Text(verbatim: paper.name).tag(Int?.some(paper.code))
                    }
                    // A paper the file names that is not on the list stays choosable.
                    if let code = page.paperSize, PaperSize.known(code: code) == nil {
                        Text("PageSetup.PaperSize.Other").tag(Int?.some(code))
                    }
                }
                .accessibilityIdentifier("pageSetup.paperSize")
            }
            Section("PageSetup.Section.Scaling") {
                Picker("PageSetup.Scaling", selection: $page.fitsToPages) {
                    Text("PageSetup.Scaling.Percent").tag(false)
                    Text("PageSetup.Scaling.Fit").tag(true)
                }
                .accessibilityIdentifier("pageSetup.scaling")
                if page.fitsToPages {
                    Stepper(value: $page.fitWide, in: 0...99) {
                        LabeledContent("PageSetup.FitWide") { pages(page.fitWide) }
                    }
                    Stepper(value: $page.fitTall, in: 0...99) {
                        LabeledContent("PageSetup.FitTall") { pages(page.fitTall) }
                    }
                } else {
                    Stepper(value: $page.scale, in: PageSetup.scaleRange, step: 5) {
                        LabeledContent("PageSetup.Scale") {
                            Text(verbatim: "\(page.scale)%").monospacedDigit()
                        }
                    }
                    .accessibilityIdentifier("pageSetup.scale")
                }
            }
            Section {
                rangeField("PageSetup.PrintArea", text: $areaText, prompt: "A1:D20", field: .area)
                HStack {
                    Button("PageSetup.PrintArea.UseSelection") {
                        areaText = PrintSetup.areasText([selection])
                        invalid.remove(.area)
                    }
                    .accessibilityIdentifier("pageSetup.useSelection")
                    Spacer()
                    Button("PageSetup.PrintArea.Clear") {
                        areaText = ""
                        invalid.remove(.area)
                    }
                    .disabled(areaText.isEmpty)
                }
                .buttonStyle(.borderless)
            } header: {
                Text("PageSetup.Section.PrintArea")
            } footer: {
                Text("PageSetup.PrintArea.Footer")
            }
            Section {
                rangeField("PageSetup.TitleRows", text: $titleRowsText, prompt: "1:2", field: .titleRows)
                rangeField("PageSetup.TitleColumns", text: $titleColumnsText, prompt: "A:B", field: .titleColumns)
            } header: {
                Text("PageSetup.Section.Titles")
            } footer: {
                Text("PageSetup.Titles.Footer")
            }
            Section {
                textField("PageSetup.Left", text: $page.header.left, identifier: "header.left")
                textField("PageSetup.Center", text: $page.header.center, identifier: "header.center")
                textField("PageSetup.Right", text: $page.header.right, identifier: "header.right")
            } header: {
                Text("PageSetup.Section.Header")
            }
            Section {
                textField("PageSetup.Left", text: $page.footer.left, identifier: "footer.left")
                textField("PageSetup.Center", text: $page.footer.center, identifier: "footer.center")
                textField("PageSetup.Right", text: $page.footer.right, identifier: "footer.right")
            } header: {
                Text("PageSetup.Section.Footer")
            } footer: {
                Text("PageSetup.Codes.Footer")
            }
            Section(marginsTitle) {
                marginField("PageSetup.Margin.Top", value: $page.margins.top)
                marginField("PageSetup.Margin.Bottom", value: $page.margins.bottom)
                marginField("PageSetup.Margin.Left", value: $page.margins.left)
                marginField("PageSetup.Margin.Right", value: $page.margins.right)
                marginField("PageSetup.Margin.Header", value: $page.margins.header)
                marginField("PageSetup.Margin.Footer", value: $page.margins.footer)
            }
            Section("PageSetup.Section.Options") {
                Toggle("PageSetup.Gridlines", isOn: $page.printsGridlines)
                    .accessibilityIdentifier("pageSetup.gridlines")
                Toggle("PageSetup.CenterHorizontally", isOn: $page.centersHorizontally)
                Toggle("PageSetup.CenterVertically", isOn: $page.centersVertically)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func pages(_ count: Int) -> some View {
        if count == 0 {
            Text("PageSetup.Fit.Automatic")
        } else {
            Text(verbatim: "\(count)").monospacedDigit()
        }
    }

    // MARK: - Fields

    /// A labelled field for a range, marked when what was typed is not one.
    private func rangeField(_ label: LocalizedStringKey, text: Binding<String>, prompt: String, field: Field) -> some View {
        LabeledContent {
            TextField(label, text: text, prompt: Text(verbatim: prompt))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.characters)
                #endif
                .accessibilityIdentifier("pageSetup.\(field)")
        } label: {
            Text(label)
            if invalid.contains(field) {
                Text("PageSetup.InvalidRange").foregroundStyle(.red)
            }
        }
    }

    private func textField(_ label: LocalizedStringKey, text: Binding<String>, identifier: String) -> some View {
        LabeledContent(label) {
            TextField(label, text: text)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .accessibilityIdentifier("pageSetup.\(identifier)")
        }
    }

    // MARK: - Margins

    /// Margins are kept in inches, and shown in the unit the region measures in.
    private static let usesInches = Locale.current.measurementSystem == .us

    private var marginsTitle: LocalizedStringKey {
        Self.usesInches ? "PageSetup.Section.Margins.Inches" : "PageSetup.Section.Margins.Centimeters"
    }

    private func marginField(_ label: LocalizedStringKey, value: Binding<Double>) -> some View {
        let factor = Self.usesInches ? 1 : 2.54
        let shown = Binding<Double>(
            get: { (value.wrappedValue * factor * 100).rounded() / 100 },
            set: { value.wrappedValue = max(0, $0) / factor })
        return LabeledContent(label) {
            TextField(label, value: shown, format: .number.precision(.fractionLength(0...2)))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                #if os(iOS)
                .keyboardType(.decimalPad)
                #endif
        }
    }
}
