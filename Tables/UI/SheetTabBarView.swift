import SwiftUI

/// The bottom strip of worksheet tabs, Numbers-style.
struct SheetTabBarView: View {
    @Binding var workbook: Workbook
    @Bindable var state: EditorState
    /// The Numbers document the workbook was read from, whose sheets holding
    /// several tables take one tab between them.
    var numbersSource: NumbersSource?

    @State private var renamingSheetID: Worksheet.ID?
    @State private var draftName = ""
    @FocusState private var isRenaming: Bool

    /// Bumped per tab to raise that tab's menu; see `NativeMenuPresenter`.
    @State private var menuTriggers: [Worksheet.ID: Int] = [:]

    // Long-press reordering.
    @State private var draggingSheetID: Worksheet.ID?
    /// How far the finger has travelled since the drag began.
    @State private var dragTranslation: Double = 0
    /// How far the dragged tab has been carried by the reorders it has already
    /// caused. Subtracting it from the translation keeps the tab under the
    /// finger instead of jumping a slot each time the strip rearranges.
    @State private var layoutShift: Double = 0
    @State private var tabWidths: [Worksheet.ID: Double] = [:]

    private let tabSpacing: Double = 6

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    state.addSheet(in: &workbook)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .help("SheetTabBar.AddSheet")
                // `help` is a tooltip, and tooltips do not exist on iOS — without
                // this the control is an unlabelled glyph to VoiceOver.
                .accessibilityLabel("SheetTabBar.AddSheet")

                // Beside the add button rather than after the tabs: at the
                // trailing end, a long tab name ran on underneath it.
                if !hiddenSheets.isEmpty { hiddenSheetsMenu }

                ScrollView(.horizontal) {
                    // A container of its own so the tabs never melt together:
                    // the outer one's spacing is wider than the gap between
                    // tabs, which bridged neighbours into one blob of glass.
                    GlassEffectContainer(spacing: 0) {
                        HStack(spacing: tabSpacing) {
                            ForEach(tabSheets) { sheet in
                                tab(for: sheet)
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                    .animation(.snappy(duration: 0.22), value: tabSheets.map(\.id))
                }
                .scrollIndicators(.hidden)
                // A tab being carried has to ride over its neighbours, and a
                // scroll view clips to its bounds by default.
                .scrollClipDisabled(draggingSheetID != nil)

            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var hiddenSheets: [Worksheet] { workbook.sheets.filter(\.isHidden) }

    /// The sheets that get a tab: every visible one, but only the first of
    /// the tables a Numbers sheet holds — the rest are reached from the
    /// strip of tables above the grid.
    private var tabSheets: [Worksheet] {
        workbook.visibleSheets.filter { sheet in
            tables(sharingTabWith: sheet).first.map { $0.id == sheet.id } ?? true
        }
    }

    /// The tables a tab stands for when its Numbers sheet holds several.
    private func tables(sharingTabWith sheet: Worksheet) -> [Worksheet] {
        numbersSource?.worksheets(sharingSheetWith: sheet.id, in: workbook) ?? []
    }

    /// What a tab is called: a Numbers sheet's own name when it holds
    /// several tables, as each of its worksheets is named after both.
    private func tabName(for sheet: Worksheet) -> String {
        guard !tables(sharingTabWith: sheet).isEmpty, let name = numbersSource?.tables[sheet.id]?.sheetName,
              !name.isEmpty else { return sheet.name }
        return name
    }

    /// The only way back to a hidden sheet, so hiding one is never a one-way door.
    private var hiddenSheetsMenu: some View {
        Menu {
            ForEach(hiddenSheets) { sheet in
                Button(sheet.name) { state.setSheet(sheet.id, hidden: false, in: &workbook) }
            }
        } label: {
            Image(systemName: "eye.slash")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 30, height: 30)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 30, height: 30)
        .glassEffect(.regular.interactive(), in: .circle)
        .help("SheetTabBar.ShowHiddenSheet")
        .accessibilityLabel(
            String(
                format: String(localized: "SheetTabBar.HiddenSheets.Accessibility"),
                hiddenSheets.count
            )
        )
    }

    @ViewBuilder
    private func tab(for sheet: Worksheet) -> some View {
        let activeID = state.activeSheet(in: workbook).id
        let grouped = tables(sharingTabWith: sheet)
        let isActive = sheet.id == activeID || grouped.contains { $0.id == activeID }

        Group {
            if renamingSheetID == sheet.id {
                TextField("SheetTabBar.RenameField.Placeholder", text: $draftName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($isRenaming)
                    .frame(minWidth: 80)
                    .onSubmit { commitRename(for: sheet) }
            } else if sheet.isChartSheet {
                Label(sheet.name, systemImage: "chart.bar.xaxis")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 13))
                    .lineLimit(1)
            } else {
                Text(tabName(for: sheet))
                    .font(.system(size: 13))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(isActive ? Color.accentColor : .primary)
        .padding(.horizontal, 14)
        .frame(height: 30)
        .glassEffect(
            isActive ? .regular.tint(Color.accentColor.opacity(0.22)).interactive() : .regular.interactive(),
            in: .capsule
        )
        .contentShape(.capsule)
        // Measured before the drag offset, so the width a reorder is judged
        // against is the tab's resting width rather than its carried one.
        .onGeometryChange(for: Double.self) { $0.size.width } action: { tabWidths[sheet.id] = $0 }
        .scaleEffect(draggingSheetID == sheet.id ? 1.08 : 1)
        .shadow(
            color: .black.opacity(draggingSheetID == sheet.id ? 0.22 : 0),
            radius: 8, y: 3
        )
        .offset(x: draggingSheetID == sheet.id ? dragTranslation - layoutShift : 0)
        .zIndex(draggingSheetID == sheet.id ? 1 : 0)
        .animation(.snappy(duration: 0.2), value: draggingSheetID)
        .onTapGesture(count: 2) { menuTriggers[sheet.id, default: 0] += 1 }
        // A tab already showing one of its tables stays on that table.
        .onTapGesture { if grouped.isEmpty || !isActive { state.selectSheet(sheet.id, in: workbook) } }
        .gesture(reorderGesture(for: sheet))
        .background {
            NativeMenuPresenter(
                actions: { menuActions(for: sheet) }, trigger: menuTriggers[sheet.id] ?? 0
            )
        }
    }

    // MARK: - Menu

    private func menuActions(for sheet: Worksheet) -> [HeaderMenuAction] {
        // A tab standing for several tables has no one name to rename.
        let rename = tables(sharingTabWith: sheet).isEmpty ? [
            HeaderMenuAction(title: String(localized: "SheetTabBar.Menu.Rename"), symbol: "pencil") {
                beginRename(sheet)
            },
        ] : []
        return rename + [
            HeaderMenuAction(
                title: String(localized: "SheetTabBar.Menu.Duplicate"), symbol: "plus.square.on.square"
            ) {
                state.selectSheet(sheet.id, in: workbook)
                state.duplicateActiveSheet(in: &workbook)
            },
            HeaderMenuAction(
                title: String(localized: "SheetTabBar.Menu.Hide"), symbol: "eye.slash",
                isEnabled: workbook.visibleSheets.count > 1
            ) {
                state.setSheet(sheet.id, hidden: true, in: &workbook)
            },
            .separator,
            HeaderMenuAction(
                title: String(localized: "SheetTabBar.Menu.Delete"), symbol: "trash", kind: .destructive,
                isEnabled: workbook.sheets.count > 1
            ) {
                state.deleteSheet(sheet.id, in: &workbook)
            },
        ]
    }

    // MARK: - Reordering

    /// Press and hold to pick a tab up, then drag it along the strip.
    ///
    /// The long press has to come first: a bare drag on a tab is how the strip
    /// itself is scrolled, and claiming it here would make a crowded workbook
    /// impossible to move around in. A UIKit recognizer rather than SwiftUI's
    /// long press sequenced into a drag, which held the touch from the scroll
    /// view even when the press never completed.
    private func reorderGesture(for sheet: Worksheet) -> TabHoldGesture {
        TabHoldGesture(
            began: { beginDragging(sheet) },
            moved: { translation in
                dragTranslation = translation
                reorder(sheet, by: dragTranslation - layoutShift)
            },
            ended: endDragging
        )
    }

    private func beginDragging(_ sheet: Worksheet) {
        guard draggingSheetID != sheet.id else { return }
        draggingSheetID = sheet.id
        dragTranslation = 0
        layoutShift = 0
        // Picking a tab up also makes it the one being worked on, which is what
        // dropping it somewhere implies anyway.
        let activeID = state.activeSheet(in: workbook).id
        if sheet.id != activeID, !tables(sharingTabWith: sheet).contains(where: { $0.id == activeID }) {
            state.selectSheet(sheet.id, in: workbook)
        }
    }

    private func endDragging() {
        draggingSheetID = nil
        dragTranslation = 0
        layoutShift = 0
    }

    /// Swaps the dragged tab past a neighbour once it has been carried over
    /// half of that neighbour, and books the distance the swap moved it.
    private func reorder(_ sheet: Worksheet, by displacement: Double) {
        let visible = tabSheets
        guard let position = visible.firstIndex(where: { $0.id == sheet.id }) else { return }

        let neighborIndex = displacement > 0 ? position + 1 : position - 1
        guard visible.indices.contains(neighborIndex) else { return }
        let neighbor = visible[neighborIndex]
        // The neighbour's own width is how far the swap will carry this tab —
        // measured, because tabs are as wide as their names.
        let step = (tabWidths[neighbor.id] ?? 0) + tabSpacing
        guard step > 0, abs(displacement) > step / 2 else { return }

        // Destination is the neighbour's index in the full sheet list, so a
        // hidden sheet sitting between the two is stepped over rather than
        // landed on.
        guard let destination = workbook.index(of: neighbor.id) else { return }
        workbook.moveSheet(sheet.id, to: destination)
        layoutShift += displacement > 0 ? step : -step
    }

    private func beginRename(_ sheet: Worksheet) {
        draftName = sheet.name
        renamingSheetID = sheet.id
        isRenaming = true
    }

    private func commitRename(for sheet: Worksheet) {
        workbook.renameSheet(sheet.id, to: draftName)
        renamingSheetID = nil
        isRenaming = false
    }
}

/// A press held in place, then tracked sideways until the finger lifts.
///
/// UIKit's long press gives up as soon as the finger wanders before the hold
/// completes, which leaves that touch to the scroll view around it.
private struct TabHoldGesture: UIGestureRecognizerRepresentable {
    var began: () -> Void
    /// How far the finger has moved sideways since the hold completed.
    var moved: (Double) -> Void
    var ended: () -> Void

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer()
        recognizer.minimumPressDuration = 0.35
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        // Measured in the window: the tab itself moves under the finger.
        let x = recognizer.location(in: nil).x
        switch recognizer.state {
        case .began:
            context.coordinator.startX = x
            began()
        case .changed:
            moved(x - context.coordinator.startX)
        case .ended, .cancelled, .failed:
            ended()
        default:
            break
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    final class Coordinator {
        var startX: CGFloat = 0
    }
}
