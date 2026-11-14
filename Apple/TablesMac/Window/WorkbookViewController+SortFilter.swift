import AppKit
import SwiftUI
import TablesEngine

/// The sort and filter panels, shown in a popover on the cell they are
/// about: the selection for a sort, the column's header cell for a filter.
extension WorkbookViewController {
    /// Shows the popover while the session asks for one of the panels, and
    /// keeps the workbook it shows up to date.
    func syncSortFilterPopover(in document: WorkbookDocument) {
        let state = document.state
        guard let panel = state.presentedPanel, panel == .sort || panel == .filter,
              !document.activeSheet.isChartSheet else {
            if let popover = sortFilterPopover, popover.isShown { popover.close() }
            return
        }
        sortFilterModel?.refresh()
        if let popover = sortFilterPopover, popover.isShown {
            if sortFilterPanel == panel { return }
            // The other panel was asked for: this one makes way for it.
            sortFilterPopover = nil
            popover.close()
        }

        let sheet = document.activeSheet
        var address = state.selectedAddress
        if panel == .filter, let filter = sheet.autoFilter {
            address = CellAddress(row: filter.range.start.row, column: state.filterColumn ?? address.column)
        }
        let rect = state.metrics.frame(for: sheet.mergedRange(containing: address) ?? CellRange(address))
        let model = HostedWorkbook(document: document)
        let content: AnyView
        switch panel {
        case .sort: content = AnyView(SortPanel(workbook: model.binding, state: state))
        default: content = AnyView(FilterPanel(workbook: model.binding, state: state))
        }
        let host = NSHostingController(rootView: content.frame(width: 320, height: panel == .sort ? 380 : 480))
        let popover = NSPopover()
        popover.contentViewController = host
        popover.behavior = .transient
        popover.delegate = self
        grid.reveal(address)
        popover.show(relativeTo: rect, of: grid.host(for: address), preferredEdge: .maxY)
        sortFilterPopover = popover
        sortFilterModel = model
        sortFilterPanel = panel
    }

    func sortFilterPopoverDidClose() {
        sortFilterPopover = nil
        sortFilterModel = nil
        guard let document else { return }
        if document.state.presentedPanel == sortFilterPanel {
            document.state.presentedPanel = nil
            document.notify()
        }
        sortFilterPanel = nil
        view.window?.makeFirstResponder(grid)
    }
}
