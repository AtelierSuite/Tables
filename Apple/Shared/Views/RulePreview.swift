import SwiftUI
import TablesEngine

/// The workbook as the cell rules editor's draft would leave it, worked out
/// away from the main thread, and the previewed cells a validation rule refuses.
struct RulePreviewSnapshot {
    var workbook: Workbook
    var sheetIndex: Int
    var failing: Set<CellAddress>

    static let rowLimit = 8
    static let columnLimit = 6

    /// The part of `range` a preview shows: its top-left corner, as far as fits.
    static func shown(_ range: CellRange, in sheet: Worksheet) -> CellRange {
        let box = range.normalized
        let lastRow = min(box.end.row, box.start.row + rowLimit - 1, max(sheet.rowCount - 1, box.start.row))
        let lastColumn = min(box.end.column, box.start.column + columnLimit - 1, max(sheet.columnCount - 1, box.start.column))
        return CellRange(start: box.start, end: CellAddress(row: lastRow, column: lastColumn))
    }

    static func make(draft: CellRulesDraft, workbook: Workbook, sheetIndex: Int) -> RulePreviewSnapshot {
        let trial = draft.trial(of: workbook, sheetIndex: sheetIndex)
        var failing = Set<CellAddress>()
        if draft.validation != nil, trial.sheets.indices.contains(sheetIndex), let range = draft.selection.last {
            let sheet = trial.sheets[sheetIndex]
            shown(range, in: sheet).forEachAddress { address in
                let cell = sheet[address]
                if case .empty = cell.value { return }
                if trial.dataValidationFailure(entering: cell, at: address, sheetIndex: sheetIndex) != nil {
                    failing.insert(address)
                }
            }
        }
        return RulePreviewSnapshot(workbook: trial, sheetIndex: sheetIndex, failing: failing)
    }

    var sheet: Worksheet? { workbook.sheets.indices.contains(sheetIndex) ? workbook.sheets[sheetIndex] : nil }
}

/// A few of a range's cells drawn as the sheet would draw them with the
/// draft's rules: fills, text, data bars and icons, with any value a
/// validation rule refuses circled in red.
struct RulePreviewGrid: View {
    let snapshot: RulePreviewSnapshot?
    let range: CellRange
    var showsFailures = true

    private let cellSize = CGSize(width: 64, height: 26)
    private let headerWidth: CGFloat = 28

    var body: some View {
        if let snapshot, let sheet = snapshot.sheet {
            let shown = RulePreviewSnapshot.shown(range, in: sheet)
            VStack(alignment: .leading, spacing: 6) {
                ScrollView(.horizontal) {
                    grid(sheet: sheet, shown: shown, failing: showsFailures ? snapshot.failing : [])
                        .padding(.vertical, 4)
                }
                .scrollIndicators(.hidden)
                if shown != range.normalized {
                    Text(String(format: String(localized: "CellRules.Preview.Partial"), shown.a1, range.normalized.a1))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("CellRules.Preview"))
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: cellSize.height * 3)
        }
    }

    private func grid(sheet: Worksheet, shown: CellRange, failing: Set<CellAddress>) -> some View {
        Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                Color.clear.frame(width: headerWidth, height: 18)
                ForEach(Array(shown.columnRange), id: \.self) { column in
                    Text(CellAddress.columnName(column))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(width: cellSize.width, height: 18)
                }
            }
            ForEach(Array(shown.rowRange), id: \.self) { row in
                GridRow {
                    Text("\(row + 1)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(width: headerWidth, height: cellSize.height)
                    ForEach(Array(shown.columnRange), id: \.self) { column in
                        let address = CellAddress(row: row, column: column)
                        PreviewCell(
                            cell: sheet.displayedCell(at: address),
                            conditional: sheet.conditionalStyles[address],
                            isFailing: failing.contains(address))
                            .frame(width: cellSize.width, height: cellSize.height)
                    }
                }
            }
        }
        .overlay(alignment: .topLeading) {
            Rectangle()
                .strokeBorder(Color.secondary.opacity(0.35), lineWidth: 0.5)
                .padding(.leading, headerWidth)
                .padding(.top, 18)
        }
    }
}

private struct PreviewCell: View {
    let cell: Cell
    let conditional: ConditionalStyle?
    let isFailing: Bool

    var body: some View {
        let style = cell.style
        let text = CellFormatter.displayText(for: cell)
        let isNumber: Bool = { if case .number = cell.value { return true } else { return false } }()
        ZStack {
            (Color(argbHex: style.fillColorHex) ?? Color.white)
            if let conditional, conditional.hasMarks {
                Canvas { context, size in
                    for mark in conditional.marks(in: CGRect(origin: .zero, size: size), zoom: 1) {
                        context.fill(mark.path, with: .color(Color(argbHex: mark.colorHex) ?? .gray))
                    }
                }
            }
            Text(text)
                .font(.system(size: 12, weight: style.isBold ? .bold : .regular))
                .italic(style.isItalic)
                .underline(style.isUnderlined)
                .strikethrough(style.isStruckThrough)
                .foregroundStyle(Color(argbHex: style.textColorHex) ?? Color.black)
                .lineLimit(1)
                .padding(.horizontal, 4)
                .padding(.leading, conditional?.icon != nil ? 14 : 0)
                .frame(maxWidth: .infinity, alignment: isNumber ? .trailing : .leading)
            if isFailing {
                Ellipse()
                    .strokeBorder(Color.red, lineWidth: 1.5)
                    .padding(1)
            }
        }
        .overlay(Rectangle().strokeBorder(Color.gray.opacity(0.25), lineWidth: 0.5))
        .environment(\.colorScheme, .light)
    }
}

// MARK: - Stepping through cells

/// Picks one cell of a rule's ranges to try the rule on.
struct PreviewCellStepper: View {
    let addresses: [CellAddress]
    @Binding var index: Int

    var body: some View {
        LabeledContent("CellRules.Test.Cell") {
            HStack(spacing: 12) {
                Button { index = max(index - 1, 0) } label: { Image(systemName: "chevron.left") }
                    .disabled(index <= 0)
                    .accessibilityLabel(Text("CellRules.Test.Previous"))
                Text(addresses.indices.contains(index) ? addresses[index].a1 : "—")
                    .font(.body.monospaced())
                    .frame(minWidth: 44)
                Button { index = min(index + 1, addresses.count - 1) } label: { Image(systemName: "chevron.right") }
                    .disabled(index >= addresses.count - 1)
                    .accessibilityLabel(Text("CellRules.Test.Next"))
            }
            .buttonStyle(.borderless)
        }
    }

    /// Up to `limit` cells of `ranges`, row by row within each.
    static func addresses(in ranges: [CellRange], sheet: Worksheet?, limit: Int = 500) -> [CellAddress] {
        var result: [CellAddress] = []
        var seen = Set<CellAddress>()
        for range in ranges {
            let box = range.normalized
            let lastRow = min(box.end.row, max((sheet?.rowCount ?? box.end.row + 1) - 1, box.start.row))
            let lastColumn = min(box.end.column, max((sheet?.columnCount ?? box.end.column + 1) - 1, box.start.column))
            for row in box.start.row...lastRow {
                for column in box.start.column...lastColumn {
                    let address = CellAddress(row: row, column: column)
                    if seen.insert(address).inserted { result.append(address) }
                    if result.count >= limit { return result }
                }
            }
        }
        return result
    }
}

/// A rule's result shown as a badge: passes, fails, or could not be worked out.
struct RuleOutcomeBadge: View {
    enum Outcome { case passes, fails, error(String) }

    let outcome: Outcome
    let passText: LocalizedStringKey
    let failText: LocalizedStringKey

    var body: some View {
        switch outcome {
        case .passes:
            Label(passText, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .fails:
            Label(failText, systemImage: "xmark.circle.fill").foregroundStyle(.secondary)
        case .error(let text):
            Label(text, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    /// How a formula's result reads as a test: as a conditional format reads it.
    static func outcome(of value: CellValue) -> Outcome {
        switch value {
        case .boolean(let flag): return flag ? .passes : .fails
        case .number(let number): return number != 0 ? .passes : .fails
        case .error: return .error(CellFormatter.displayText(for: value, format: NumberFormatPreset.general.code))
        case .empty, .text: return .fails
        }
    }
}

/// "Result" with its badge at the trailing edge.
private struct RuleResultRow: View {
    let badge: RuleOutcomeBadge

    var body: some View {
        HStack(spacing: 8) {
            Text("CellRules.Test.Result")
            Spacer(minLength: 8)
            badge.multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Testing a formula

/// Works a conditional format's test out for one of its cells: the cell's
/// value, the test as it reads there, and whether it passes.
struct ConditionalFormulaTester: View {
    let rule: ConditionalRule
    let snapshot: RulePreviewSnapshot?
    @State private var index = 0

    var body: some View {
        let addresses = PreviewCellStepper.addresses(in: rule.ranges, sheet: snapshot?.sheet)
        PreviewCellStepper(addresses: addresses, index: $index)
        if addresses.indices.contains(index), let snapshot, let sheet = snapshot.sheet {
            let address = addresses[index]
            LabeledContent("CellRules.Test.Value") {
                Text(CellFormatter.displayText(for: sheet[address]))
                    .foregroundStyle(.secondary)
            }
            if let test = rule.testFormula(at: address) {
                LabeledContent("CellRules.Test.Formula") {
                    Text("=" + test)
                        .font(.callout.monospaced())
                        .multilineTextAlignment(.trailing)
                }
                let value = CalculationEngine.preview(
                    formula: test, in: snapshot.workbook, sheetIndex: snapshot.sheetIndex, at: address)
                RuleResultRow(badge: RuleOutcomeBadge(
                    outcome: RuleOutcomeBadge.outcome(of: value),
                    passText: "CellRules.Test.Applies", failText: "CellRules.Test.DoesNotApply"))
                .accessibilityIdentifier("cellRules.formulaResult")
            } else {
                Text("CellRules.Test.Incomplete").foregroundStyle(.secondary)
            }
        }
    }
}

/// Tries an entry against a validation rule in one of its cells, as typing
/// it there would.
struct ValidationEntryTester: View {
    let rule: DataValidation
    let ranges: [CellRange]
    let snapshot: RulePreviewSnapshot?
    @State private var entry = ""
    @State private var index = 0

    var body: some View {
        let addresses = PreviewCellStepper.addresses(in: ranges, sheet: snapshot?.sheet)
        PreviewCellStepper(addresses: addresses, index: $index)
        TextField("CellRules.Test.Entry", text: $entry)
            .autocorrectionDisabled()
            #if !os(macOS)
            .textInputAutocapitalization(.never)
            #endif
            .accessibilityIdentifier("cellRules.testEntry")
        if !entry.isEmpty, addresses.indices.contains(index), let snapshot {
            let address = addresses[index]
            if !rule.showsErrorMessage || rule.kind == .any {
                Label("CellRules.Test.NotChecked", systemImage: "info.circle").foregroundStyle(.secondary)
            } else {
                let cell = CellInputParser.cell(from: entry, inheriting: snapshot.sheet?[address].style ?? .default)
                let refused = snapshot.workbook.dataValidationFailure(
                    entering: cell, at: address, sheetIndex: snapshot.sheetIndex) != nil
                RuleResultRow(badge: RuleOutcomeBadge(
                    outcome: refused ? .fails : .passes,
                    passText: "CellRules.Test.Accepted", failText: refused ? refusal : "CellRules.Test.Refused"))
                .accessibilityIdentifier("cellRules.entryResult")
                if refused {
                    let title = rule.errorTitle ?? ""
                    let message = rule.errorMessage ?? ""
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title.isEmpty ? String(localized: "DataValidation.Alert.DefaultTitle") : title).bold()
                        Text(message.isEmpty ? String(localized: "DataValidation.Alert.DefaultMessage") : message)
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
        }
    }

    private var refusal: LocalizedStringKey {
        switch rule.alertStyle {
        case .stop: return "CellRules.Test.Refused"
        case .warning: return "CellRules.Test.Warned"
        case .information: return "CellRules.Test.Informed"
        }
    }
}
