import SwiftUI
import TablesEngine

/// One entry in a row or column header menu, described independently of how it
/// gets presented. SwiftUI renders these for `contextMenu`; the platform bridge
/// turns the same list into a real `UIMenu` or `NSMenu`, so the long-press and
/// double-tap paths can never drift apart.
struct HeaderMenuAction: Identifiable {
    enum Kind {
        case normal
        case destructive
        case separator
    }

    let id = UUID()
    var title = ""
    var symbol = ""
    var kind: Kind = .normal
    var isEnabled = true
    /// A submenu's entries, which make this one open them instead of acting.
    var children: [HeaderMenuAction] = []
    var perform: () -> Void = {}

    static var separator: HeaderMenuAction {
        HeaderMenuAction(kind: .separator)
    }
}

/// Builds the action list for one axis of the sheet.
@MainActor
struct HeaderMenuBuilder {
    enum Axis { case row, column }

    let axis: Axis
    /// The header the menu was opened from, so it can act on that line even when
    /// the selection is somewhere else.
    let index: Int
    let workbook: Binding<Workbook>
    let state: EditorState

    private var activeSheet: Worksheet { state.activeSheet(in: workbook.wrappedValue) }

    private var isHidden: Bool {
        axis == .row ? activeSheet.hiddenRows.contains(index) : activeSheet.hiddenColumns.contains(index)
    }

    private var hiddenCount: Int {
        activeSheet.hiddenRows.count + activeSheet.hiddenColumns.count
    }

    private var canDelete: Bool {
        axis == .row ? activeSheet.rowCount > 1 : activeSheet.columnCount > 1
    }

    func actions() -> [HeaderMenuAction] {
        var actions = axis == .row ? rowActions() : columnActions()

        if hiddenCount > 0 {
            actions.append(.separator)
            let title = String(
                format: String(localized: "RowsColumns.ShowAllHidden"), hiddenCount
            )
            actions.append(HeaderMenuAction(title: title, symbol: "eye") {
                state.unhideEverything(in: &workbook.wrappedValue)
            })
        }
        if state.allowsFreezingPanes {
            actions.append(.separator)
            actions += freezeActions()
        }
        actions.append(.separator)
        actions.append(HeaderMenuAction(
            title: String(localized: "HeaderMenu.RowsAndColumns"), symbol: "tablecells"
        ) {
            state.presentedPanel = .rowsAndColumns
        })
        return actions
    }

    /// Freezing the lines up to this one, so they stay in view while the rest
    /// scrolls, and letting go of what is frozen along this axis.
    private func freezeActions() -> [HeaderMenuAction] {
        let sheet = activeSheet
        let frozen = axis == .row ? sheet.frozenRows : sheet.frozenColumns
        var actions: [HeaderMenuAction] = []
        if frozen != index + 1 {
            actions.append(HeaderMenuAction(
                title: String(localized: axis == .row ? "HeaderMenu.FreezeThroughRow" : "HeaderMenu.FreezeThroughColumn"),
                symbol: axis == .row ? "rectangle.topthird.inset.filled" : "rectangle.leadingthird.inset.filled"
            ) {
                if axis == .row {
                    state.freezePanes(rows: index + 1, columns: sheet.frozenColumns, in: &workbook.wrappedValue)
                } else {
                    state.freezePanes(rows: sheet.frozenRows, columns: index + 1, in: &workbook.wrappedValue)
                }
            })
        }
        if frozen > 0 {
            actions.append(HeaderMenuAction(
                title: String(localized: axis == .row ? "HeaderMenu.UnfreezeRows" : "HeaderMenu.UnfreezeColumns"),
                symbol: "rectangle"
            ) {
                if axis == .row {
                    state.freezePanes(rows: 0, columns: sheet.frozenColumns, in: &workbook.wrappedValue)
                } else {
                    state.freezePanes(rows: sheet.frozenRows, columns: 0, in: &workbook.wrappedValue)
                }
            })
        }
        return actions
    }

    private func rowActions() -> [HeaderMenuAction] {
        var actions: [HeaderMenuAction] = [
            HeaderMenuAction(
                title: String(localized: "HeaderMenu.Row.InsertAbove"), symbol: "arrow.up.to.line"
            ) {
                target()
                state.insertRows(above: true, in: &workbook.wrappedValue)
            },
            HeaderMenuAction(
                title: String(localized: "HeaderMenu.Row.InsertBelow"), symbol: "arrow.down.to.line"
            ) {
                target()
                state.insertRows(above: false, in: &workbook.wrappedValue)
            },
            HeaderMenuAction(
                title: String(localized: "HeaderMenu.Row.AddAtEnd"), symbol: "plus.rectangle"
            ) {
                state.addRows(in: &workbook.wrappedValue)
            },
            .separator,
            HeaderMenuAction(title: String(localized: "HeaderMenu.Row.Hide"), symbol: "eye.slash") {
                target()
                state.setSelectedRows(hidden: true, in: &workbook.wrappedValue)
            },
        ]
        if isHidden {
            actions.append(HeaderMenuAction(title: String(localized: "HeaderMenu.Row.Show"), symbol: "eye") {
                target()
                state.setSelectedRows(hidden: false, in: &workbook.wrappedValue)
            })
        }
        actions.append(.separator)
        actions.append(HeaderMenuAction(
            title: String(localized: "HeaderMenu.Row.Delete"), symbol: "trash", kind: .destructive,
            isEnabled: canDelete
        ) {
            target()
            state.deleteSelectedRows(in: &workbook.wrappedValue)
        })
        return actions
    }

    private func columnActions() -> [HeaderMenuAction] {
        var actions: [HeaderMenuAction] = [
            HeaderMenuAction(
                title: String(localized: "HeaderMenu.Column.InsertBefore"), symbol: "arrow.left.to.line"
            ) {
                target()
                state.insertColumns(before: true, in: &workbook.wrappedValue)
            },
            HeaderMenuAction(
                title: String(localized: "HeaderMenu.Column.InsertAfter"), symbol: "arrow.right.to.line"
            ) {
                target()
                state.insertColumns(before: false, in: &workbook.wrappedValue)
            },
            HeaderMenuAction(
                title: String(localized: "HeaderMenu.Column.AddAtEnd"), symbol: "plus.rectangle.portrait"
            ) {
                state.addColumns(in: &workbook.wrappedValue)
            },
            .separator,
            HeaderMenuAction(title: String(localized: "HeaderMenu.Column.Hide"), symbol: "eye.slash") {
                target()
                state.setSelectedColumns(hidden: true, in: &workbook.wrappedValue)
            },
        ]
        if isHidden {
            actions.append(HeaderMenuAction(title: String(localized: "HeaderMenu.Column.Show"), symbol: "eye") {
                target()
                state.setSelectedColumns(hidden: false, in: &workbook.wrappedValue)
            })
        }
        actions.append(contentsOf: [
            .separator,
            HeaderMenuAction(
                title: String(localized: "HeaderMenu.Column.FitToContents"), symbol: "arrow.left.and.right"
            ) {
                state.fitColumn(index, in: &workbook.wrappedValue)
            },
            .separator,
            HeaderMenuAction(
                title: String(localized: "HeaderMenu.Column.Delete"), symbol: "trash",
                kind: .destructive, isEnabled: canDelete
            ) {
                target()
                state.deleteSelectedColumns(in: &workbook.wrappedValue)
            },
        ])
        return actions
    }

    /// Points the selection at the header this menu belongs to, unless that
    /// header is already part of a larger selection the user made.
    private func target() {
        switch axis {
        case .row:
            guard !(state.selectionSpansEntireRows(in: activeSheet)
                    && state.selection.normalized.rowRange.contains(index)) else { return }
            state.selectEntireRows(index...index, in: activeSheet)
        case .column:
            guard !(state.selectionSpansEntireColumns(in: activeSheet)
                    && state.selection.normalized.columnRange.contains(index)) else { return }
            state.selectEntireColumns(index...index, in: activeSheet)
        }
    }
}

/// Renders the action list as SwiftUI buttons, for use as `contextMenu` content.
struct HeaderActionMenu: View {
    let actions: [HeaderMenuAction]

    var body: some View {
        ForEach(actions) { action in
            switch action.kind {
            case .separator:
                Divider()
            case .normal, .destructive:
                if !action.children.isEmpty {
                    Menu(action.title, systemImage: action.symbol) {
                        HeaderActionMenu(actions: action.children)
                    }
                    .disabled(!action.isEnabled)
                } else {
                    Button(
                        action.title, systemImage: action.symbol,
                        role: action.kind == .destructive ? .destructive : nil,
                        action: action.perform
                    )
                    .disabled(!action.isEnabled)
                }
            }
        }
    }
}
