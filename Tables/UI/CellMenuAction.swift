import SwiftUI
import TablesEngine

/// Builds the action list for a cell, in the same shape the header menus use so
/// the long-press and double-tap paths can share one description of the menu.
@MainActor
struct CellMenuBuilder {
    /// The cell the menu was opened from, so it can act on that cell even when
    /// the selection is somewhere else.
    let address: CellAddress
    let workbook: Binding<Workbook>
    let state: EditorState

    private var activeSheet: Worksheet { state.activeSheet(in: workbook.wrappedValue) }

    /// Whether there is anything to paste — the app's own clipboard if the copy
    /// happened here, otherwise text sitting on the system pasteboard.
    private var canPaste: Bool {
        if let clipboard = state.clipboard, !clipboard.isEmpty { return true }
        #if canImport(UIKit)
        return UIPasteboard.general.hasStrings
        #else
        return NSPasteboard.general.canReadObject(forClasses: [NSString.self])
        #endif
    }

    func actions() -> [HeaderMenuAction] {
        var actions = [
            // The way into the in-cell editor by touch, since the double tap
            // raises this menu.
            HeaderMenuAction(title: String(localized: "CellMenu.Edit"), symbol: "pencil") {
                target()
                state.beginEditing(address, in: workbook.wrappedValue)
            },
            .separator,
            HeaderMenuAction(title: String(localized: "CellMenu.Copy"), symbol: "doc.on.doc") {
                target()
                state.copySelection(in: workbook.wrappedValue)
            },
            HeaderMenuAction(title: String(localized: "CellMenu.Cut"), symbol: "scissors") {
                target()
                state.cutSelection(in: &workbook.wrappedValue)
            },
            HeaderMenuAction(
                title: String(localized: "CellMenu.Paste"), symbol: "doc.on.clipboard",
                isEnabled: canPaste
            ) {
                target()
                state.paste(in: &workbook.wrappedValue)
            },
        ]
        if state.allowsComments {
            actions.append(.separator)
            if activeSheet.comments[address] != nil {
                actions += [
                    HeaderMenuAction(title: String(localized: "CellMenu.ShowComment"), symbol: "text.bubble") {
                        state.showComment(at: address, kind: .thread, in: workbook.wrappedValue)
                    },
                    HeaderMenuAction(
                        title: String(localized: "CellMenu.DeleteComment"), symbol: "trash", kind: .destructive
                    ) {
                        state.deleteComment(at: address, in: &workbook.wrappedValue)
                    },
                ]
            } else {
                actions += [
                    HeaderMenuAction(title: String(localized: "CellMenu.NewComment"), symbol: "plus.bubble") {
                        state.showComment(at: address, kind: .thread, in: workbook.wrappedValue)
                    },
                    HeaderMenuAction(title: String(localized: "CellMenu.NewNote"), symbol: "note.text.badge.plus") {
                        state.showComment(at: address, kind: .note, in: workbook.wrappedValue)
                    },
                ]
            }
        }
        if state.formatting.contains(.merging) {
            actions += mergeActions()
        }
        if !state.formatting.isEmpty {
            actions += [
                .separator,
                HeaderMenuAction(
                    title: String(localized: "CellMenu.ResetFormatting"), symbol: "paintbrush"
                ) {
                    target()
                    state.clearFormatting(in: &workbook.wrappedValue)
                },
            ]
        }
        return actions
    }

    /// Merging or splitting whichever is possible for the selection the menu
    /// was raised in. Opened from outside the selection, there is only the
    /// one cell to act on, which can be split but never merged.
    private func mergeActions() -> [HeaderMenuAction] {
        let workbook = workbook.wrappedValue
        let isInSelection = state.selection.normalized.contains(address)
        var actions: [HeaderMenuAction] = []
        if isInSelection, state.canMergeSelection(in: workbook) {
            actions.append(
                HeaderMenuAction(
                    title: String(localized: "Format.Merge.Merge"),
                    symbol: "arrow.right.and.line.vertical.and.arrow.left"
                ) {
                    state.mergeSelection(in: &self.workbook.wrappedValue)
                }
            )
        }
        let canUnmerge = isInSelection
            ? state.canUnmergeSelection(in: workbook)
            : activeSheet.mergedRange(containing: address) != nil
        if canUnmerge {
            actions.append(
                HeaderMenuAction(
                    title: String(localized: "Format.Merge.Unmerge"),
                    symbol: "arrow.left.and.line.vertical.and.arrow.right"
                ) {
                    target()
                    state.unmergeSelection(in: &self.workbook.wrappedValue)
                }
            )
        }
        return actions.isEmpty ? [] : [.separator] + actions
    }

    /// Points the selection at the cell this menu belongs to, unless it is
    /// already part of a larger selection the user made.
    private func target() {
        guard !state.selection.normalized.contains(address) else { return }
        state.select(address, in: activeSheet)
    }
}
