import SwiftUI
import TablesEngine

/// One chart floating over the grid.
struct EmbeddedChartView: View {
    let chart: Chart
    let data: ResolvedChart
    /// Where the chart sits, in the grid's own zoomed coordinates.
    let frame: CGRect
    let zoom: Double
    let isSelected: Bool
    var onSelect: () -> Void
    var onDeselect: () -> Void
    var onEdit: () -> Void
    /// The new frame, in the grid's zoomed coordinates.
    var onCommit: (CGRect) -> Void
    var onMoveToNewSheet: () -> Void
    var onDelete: () -> Void

    var body: some View {
        FloatingObjectView(
            frame: frame, isSelected: isSelected, minimumSize: CGSize(width: 48, height: 36),
            gripIdentifier: "chartResizeGrip", gripLabel: "Chart.Resize",
            onSelect: onSelect, onDeselect: onDeselect, onCommit: onCommit
        ) { size in
            ChartView(chart: chart, data: data, zoom: zoom)
                .equatable()
                .frame(width: size.width, height: size.height)
                // Here rather than on the whole view, so the grip keeps its own.
                .accessibilityIdentifier("chart.\(chart.name)")
        } menu: {
            Button("Chart.Menu.Edit", systemImage: "slider.horizontal.3") {
                onSelect()
                onEdit()
            }
            Button("Chart.Menu.MoveToNewSheet", systemImage: "rectangle.portrait.on.rectangle.portrait") {
                onSelect()
                onMoveToNewSheet()
            }
            Divider()
            Button("Chart.Menu.Delete", systemImage: "trash", role: .destructive) {
                onSelect()
                onDelete()
            }
        }
        .accessibilityAction(named: Text("Chart.Menu.Edit")) {
            onSelect()
            onEdit()
        }
    }
}

/// Something floating over the grid that can be picked out, moved and
/// resized: a chart, or a picture kept from the file.
///
/// A tap picks it out; once picked out, dragging it moves it and the corner
/// grip resizes it, and a further tap lets it go again. While it is not
/// selected a drag over it scrolls the sheet like anywhere else — an object
/// that swallowed every pan would make a sheet full of them impossible to
/// move around in, and one that filled the screen could only be scrolled past
/// by letting it go.
struct FloatingObjectView<Content: View, MenuItems: View>: View {
    /// Where the object sits, in the grid's own zoomed coordinates.
    let frame: CGRect
    let isSelected: Bool
    let minimumSize: CGSize
    var isMovable = true
    var isResizable = true
    /// Whether the grip scales the object rather than stretching it.
    var keepsAspectRatio = false
    let gripIdentifier: String
    let gripLabel: LocalizedStringKey
    var onSelect: () -> Void
    var onDeselect: () -> Void
    /// The new frame, in the grid's zoomed coordinates.
    var onCommit: (CGRect) -> Void
    /// The object itself, at the size it is being shown.
    @ViewBuilder var content: (CGSize) -> Content
    @ViewBuilder var menu: () -> MenuItems

    @State private var translation: CGSize = .zero
    @State private var growth: CGSize = .zero

    private let gripDiameter: Double = 18

    var body: some View {
        let size = resized(by: growth)

        content(size)
            .shadow(color: .black.opacity(isSelected ? 0.18 : 0.08), radius: isSelected ? 8 : 3, y: 1)
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .padding(-1)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(.rect)
            .gesture(interaction)
            .overlay(alignment: .bottomTrailing) {
                if isSelected, isResizable { resizeGrip }
            }
            .contextMenu { menu() }
            .offset(x: frame.minX + translation.width, y: frame.minY + translation.height)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// The frame's size grown by a drag of the grip, kept to its proportions
    /// when it must be — by whichever side the drag stretched further — and
    /// never smaller than the minimum.
    private func resized(by drag: CGSize) -> CGSize {
        guard keepsAspectRatio, frame.width > 0, frame.height > 0 else {
            return CGSize(
                width: max(minimumSize.width, frame.width + drag.width),
                height: max(minimumSize.height, frame.height + drag.height)
            )
        }
        let scale = max(
            (frame.width + drag.width) / frame.width,
            (frame.height + drag.height) / frame.height,
            minimumSize.width / frame.width,
            minimumSize.height / frame.height
        )
        return CGSize(width: frame.width * scale, height: frame.height * scale)
    }

    /// Unselected, a plain tap: anything more is the scroll view's. Selected,
    /// a drag from a standing start, so the object follows the finger from its
    /// first point — and a drag that never went anywhere was a tap, which
    /// lets the object go.
    private var interaction: AnyGesture<Void> {
        if isSelected {
            return AnyGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { if isMovable { translation = $0.translation } }
                    .onEnded { value in
                        let distance = hypot(value.translation.width, value.translation.height)
                        if distance <= 4 {
                            onDeselect()
                        } else if isMovable {
                            onCommit(frame.offsetBy(dx: value.translation.width, dy: value.translation.height))
                        }
                        translation = .zero
                    }
                    .map { _ in () }
            )
        }
        return AnyGesture(TapGesture().onEnded { onSelect() })
    }

    private var resizeGrip: some View {
        Color.clear
            .frame(width: gripDiameter, height: gripDiameter)
            .glassEffect(.regular.tint(.accentColor).interactive(), in: .circle)
            .background { Circle().fill(Color.sheetBackground).padding(-2) }
            .offset(x: gripDiameter / 2, y: gripDiameter / 2)
            .contentShape(.rect.inset(by: -16))
            .gesture(
                // Global space, for the same reason as the selection grip: the
                // grip rides the edge it is dragging.
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { growth = $0.translation }
                    .onEnded { value in
                        onCommit(CGRect(origin: frame.origin, size: resized(by: value.translation)))
                        growth = .zero
                    }
            )
            .accessibilityIdentifier(gripIdentifier)
            .accessibilityLabel(gripLabel)
    }
}

/// A chart sheet: the chart, filling the space the grid would.
struct ChartSheetView: View {
    @Binding var workbook: Workbook
    @Bindable var state: EditorState
    let sheet: Worksheet

    var body: some View {
        Group {
            if let chart = sheet.charts.first {
                ChartView(chart: chart, data: chart.resolved(in: workbook))
                    .equatable()
                    .shadow(color: .black.opacity(0.1), radius: 6, y: 2)
                    .contentShape(.rect)
                    .onTapGesture {
                        state.selectChart(chart.id)
                        state.presentedPanel = .chart
                    }
                    .contextMenu {
                        Button("Chart.Menu.Edit", systemImage: "slider.horizontal.3") {
                            state.selectChart(chart.id)
                            state.presentedPanel = .chart
                        }
                        Divider()
                        Button("Chart.Menu.Delete", systemImage: "trash", role: .destructive) {
                            state.deleteSelectedChart(in: &workbook)
                        }
                    }
                    .accessibilityIdentifier("chartSheet.chart")
            } else if let anchor = sheet.preservedDrawingAnchors.first {
                PreservedDrawingPlaceholder(isChart: anchor.isChart, zoom: 1.5)
            } else {
                ContentUnavailableView("Chart.Empty", systemImage: "chart.bar.xaxis")
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.sheetCanvas)
    }
}
