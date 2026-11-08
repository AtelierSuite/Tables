import SwiftUI
import TablesEngine

/// The inspector at the window's trailing edge, as Numbers has: how the
/// selected cells look and how their numbers read, or, with a chart picked
/// out, the chart's own settings. The cell panels are laid out for the Mac;
/// the chart's are the iPhone and iPad's.
struct WorkbookInspector: View {
    let model: HostedWorkbook
    @Bindable var state: EditorState

    private enum Tab: Hashable {
        case cell, numberFormat
    }

    @State private var tab = Tab.cell

    var body: some View {
        Group {
            if state.selectedChart(in: model.workbook) != nil {
                ChartPanel(workbook: model.binding, state: state)
                    .formStyle(.grouped)
                    // A grouped form in the inspector otherwise runs edge to edge.
                    .contentMargins(.horizontal, 14, for: .scrollContent)
            } else if state.formatting.isEmpty {
                ContentUnavailableView(
                    "Mac.Inspector.NoFormatting.Title", systemImage: "paintbrush",
                    description: Text("Mac.Inspector.NoFormatting.Message"))
            } else {
                cellPanels
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var cellPanels: some View {
        let tabs = availableTabs
        VStack(spacing: 0) {
            if tabs.count > 1 {
                Picker("Mac.Inspector.Title", selection: $tab) {
                    Text("Mac.Inspector.Cell").tag(Tab.cell)
                    Text("Panel.NumberFormat.Title").tag(Tab.numberFormat)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .frame(maxWidth: .infinity)
                .padding(.horizontal, InspectorMetrics.horizontalPadding)
                .padding(.top, 12)
                .padding(.bottom, 4)
            }
            switch tabs.contains(tab) ? tab : tabs[0] {
            case .cell: CellInspector(workbook: model.binding, state: state)
            case .numberFormat: NumberFormatInspector(workbook: model.binding, state: state)
            }
        }
    }

    /// Only the panels for formatting the document keeps.
    private var availableTabs: [Tab] {
        var tabs: [Tab] = []
        if state.formatting.contains(.styles) || state.formatting.contains(.borders) { tabs.append(.cell) }
        if state.formatting.contains(.numberFormats) { tabs.append(.numberFormat) }
        return tabs.isEmpty ? [.cell] : tabs
    }
}
