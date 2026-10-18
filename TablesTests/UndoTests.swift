import Foundation
import Testing
@testable import Tables
@testable import TablesEngine
@testable import TablesMacros

/// Undo and redo over whole-workbook snapshots, and which changes run
/// together into one step.
@Suite("Undo")
@MainActor
struct UndoTests {

    private func workbookWithChart() throws -> Workbook {
        var workbook = Workbook()
        let sheet = workbook.sheets[0].id
        workbook.sheets[0][CellAddress(row: 0, column: 1)] = Cell(value: .text("Sales"))
        for row in 1...3 {
            workbook.sheets[0][CellAddress(row: row, column: 0)] = Cell(value: .text("Q\(row)"))
            workbook.sheets[0][CellAddress(row: row, column: 1)] = Cell(value: .number(Double(row * 10)))
        }
        let range = try #require(CellRange(a1Range: "A1:B4"))
        let chart = try #require(ChartBuilder.chart(.column, from: range, in: workbook.sheets[0], named: "Chart 1"))
        workbook[sheet]?.charts = [chart]
        return workbook
    }

    // MARK: - Scopes

    @Test("Each kind of change is told apart")
    func scopes() throws {
        let base = try workbookWithChart()
        let sheet = base.sheets[0].id
        let chart = base.sheets[0].charts[0].id

        var titled = base
        titled.sheets[0].charts[0].title = ChartTitle(text: "Q")
        #expect(titled.editScope(from: base) == .chart(sheet, chart))

        var widened = base
        widened.sheets[0].columnWidths[1] = 120
        #expect(widened.editScope(from: base) == .sheetLayout(sheet))

        var reordered = base
        _ = reordered.addSheet()
        var moved = reordered
        moved.moveSheet(moved.sheets[1].id, to: 0)
        #expect(moved.editScope(from: reordered) == .sheetOrder)
        #expect(reordered.editScope(from: base) == .other)

        var typed = base
        typed.sheets[0][CellAddress(row: 5, column: 5)] = Cell(value: .number(1))
        #expect(typed.editScope(from: base) == .other)

        // A chart edited along with a cell is not a chart edit.
        var both = titled
        both.sheets[0][CellAddress(row: 5, column: 5)] = Cell(value: .number(1))
        #expect(both.editScope(from: base) == .other)
    }

    // MARK: - History

    /// A document standing in for SwiftUI's: writes land in `value`, and
    /// `change` plays the part of `onChange`, reporting old and new.
    private final class Document {
        var value: Workbook
        init(_ value: Workbook) { self.value = value }
    }

    private func makeHistory(_ document: Document) -> (WorkbookHistory, UndoManager) {
        // As the app's: a group opens with the first registration in an event
        // and closes when the run loop comes round, so a change that
        // registers nothing leaves nothing behind.
        let undoManager = UndoManager()
        let history = WorkbookHistory()
        history.attach(
            to: undoManager,
            read: { document.value },
            write: { document.value = $0 },
            restored: { _, _ in /* These tests do not follow where changes land. */ }
        )
        return (history, undoManager)
    }

    /// An edit as the editor makes one: through the document, then reported.
    private func edit(
        _ document: Document, _ history: WorkbookHistory,
        _ change: (inout Workbook) -> Void
    ) {
        let old = document.value
        change(&document.value)
        history.record(from: old, to: document.value)
        endEvent()
    }

    /// Lets the run loop come round, which closes the event's undo group.
    private func endEvent() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }

    /// An undo or redo, followed by the change report SwiftUI sends after it.
    private func step(_ document: Document, _ history: WorkbookHistory, undo: Bool) {
        let old = document.value
        if undo { history.undo() } else { history.redo() }
        history.record(from: old, to: document.value)
        endEvent()
    }

    @Test("Undo puts back what was there, and redo what was done")
    func undoAndRedo() throws {
        let document = Document(try workbookWithChart())
        let (history, undoManager) = makeHistory(document)
        let original = document.value

        edit(document, history) { $0.sheets[0][CellAddress(row: 9, column: 0)] = Cell(value: .number(1)) }
        let afterFirst = document.value
        edit(document, history) { $0.sheets[0].charts.removeAll() }
        let afterSecond = document.value
        #expect(history.canUndo)

        step(document, history, undo: true)
        #expect(document.value == afterFirst)
        #expect(history.canRedo)
        step(document, history, undo: true)
        #expect(document.value == original)
        #expect(!history.canUndo)

        step(document, history, undo: false)
        #expect(document.value == afterFirst)
        step(document, history, undo: false)
        #expect(document.value == afterSecond)
        #expect(!history.canRedo)
    }

    @Test("Typing a chart's title is one step, and a new edit after an undo is another")
    func chartEditsCoalesce() throws {
        let document = Document(try workbookWithChart())
        let (history, undoManager) = makeHistory(document)
        let original = document.value

        for length in 1...6 {
            edit(document, history) {
                $0.sheets[0].charts[0].title = ChartTitle(text: String("Totals".prefix(length)))
            }
        }
        #expect(document.value.sheets[0].charts[0].title?.text == "Totals")
        step(document, history, undo: true)
        #expect(document.value == original)
        #expect(!history.canUndo)

        // Straight after the undo, the same kind of edit must not fold itself
        // into whatever step is now on top.
        edit(document, history) { $0.sheets[0][CellAddress(row: 9, column: 0)] = Cell(value: .number(1)) }
        let typed = document.value
        edit(document, history) { $0.sheets[0].charts[0].legend = .top }
        edit(document, history) { $0.sheets[0].charts[0].legend = .left }
        step(document, history, undo: true)
        #expect(document.value == typed)
    }

    @Test("An edit to a different chart starts a new step")
    func coalescingBoundaries() throws {
        var workbook = try workbookWithChart()
        var second = workbook.sheets[0].charts[0]
        second.id = UUID()
        workbook.sheets[0].charts.append(second)
        let document = Document(workbook)
        let (history, undoManager) = makeHistory(document)

        edit(document, history) { $0.sheets[0].charts[0].legend = .top }
        let afterFirstChart = document.value
        edit(document, history) { $0.sheets[0].charts[1].legend = .top }
        step(document, history, undo: true)
        #expect(document.value == afterFirstChart)
    }

    @Test("After an undo the editor shows the sheet that changed and lets go of a vanished chart")
    func editorFollowsTheUndo() throws {
        var before = try workbookWithChart()
        let first = before.sheets[0].id
        let second = before.addSheet()
        var after = before
        after[first]?.charts.removeAll()

        let state = EditorState()
        state.selectSheet(second, in: after)
        // Redoing the deletion while its chart is selected on the first sheet.
        state.selectedChartID = before.sheets[0].charts[0].id
        state.presentedPanel = .chart
        state.showRestored(after, replacing: before)
        #expect(state.activeSheetID == first)
        #expect(state.selectedChartID == nil)
        #expect(state.presentedPanel == nil)

        // Undoing the creation of the sheet being looked at.
        state.selectSheet(second, in: before)
        let withoutSecond = { var copy = before; _ = copy.removeSheet(second); return copy }()
        state.showRestored(withoutSecond, replacing: before)
        #expect(state.activeSheetID == first)
    }
}
