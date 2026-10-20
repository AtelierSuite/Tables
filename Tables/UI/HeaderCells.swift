import SwiftUI
import TablesEngine

/// A column letter button with a drag-to-resize grip on its trailing edge.
/// Long-press (or right-click) opens the structure menu; so does a double tap.
struct ColumnHeaderCell: View {
    let title: String
    let width: Double
    let height: Double
    let isSelected: Bool
    /// Marks the seam where a hidden column was collapsed away.
    let isHiddenNeighbor: Bool
    let onSelect: () -> Void
    let onResize: (Double) -> Void
    let onFit: () -> Void
    /// Built on demand rather than handed over ready-made: the grid rebuilds
    /// every visible header on each scroll frame, and a menu's worth of
    /// localized titles and closures per header is a cost paid for something
    /// the user sees only when they open it.
    let actions: () -> [HeaderMenuAction]

    @State private var menuTrigger = 0

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: isSelected ? .bold : .medium))
            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            .frame(width: width, height: height)
            .background(isSelected ? Color.accentColor.opacity(0.16) : .clear)
            .contentShape(.rect)
            .onTapGesture(count: 2) { menuTrigger += 1 }
            .onTapGesture(perform: onSelect)
            .contextMenu { HeaderActionMenu(actions: actions()) }
            .background { NativeMenuPresenter(actions: actions, trigger: menuTrigger) }
            .overlay(alignment: .bottom) { Rectangle().fill(Color.gridLine).frame(height: 1) }
            .overlay(alignment: .trailing) { HiddenSeam(isVertical: true, isVisible: isHiddenNeighbor) }
            .overlay(alignment: .trailing) {
                ResizeGrip(isVertical: true, extent: width, onResize: onResize, onDoubleTap: onFit)
            }
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isButton)
    }
}

/// A row number button with a drag-to-resize grip on its bottom edge.
struct RowHeaderCell: View {
    let title: String
    let width: Double
    let height: Double
    let isSelected: Bool
    let isHiddenNeighbor: Bool
    let onSelect: () -> Void
    let onResize: (Double) -> Void
    /// Built on demand, for the reason `ColumnHeaderCell.actions` gives.
    let actions: () -> [HeaderMenuAction]

    @State private var menuTrigger = 0

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: isSelected ? .bold : .medium))
            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            .frame(width: width, height: height)
            .background(isSelected ? Color.accentColor.opacity(0.16) : .clear)
            .contentShape(.rect)
            .onTapGesture(count: 2) { menuTrigger += 1 }
            .onTapGesture(perform: onSelect)
            .contextMenu { HeaderActionMenu(actions: actions()) }
            .background { NativeMenuPresenter(actions: actions, trigger: menuTrigger) }
            .overlay(alignment: .trailing) { Rectangle().fill(Color.gridLine).frame(width: 1) }
            .overlay(alignment: .bottom) { HiddenSeam(isVertical: false, isVisible: isHiddenNeighbor) }
            .overlay(alignment: .bottom) {
                ResizeGrip(isVertical: false, extent: height, onResize: onResize)
            }
            .accessibilityLabel(String(format: Self.labelFormat, title))
            .accessibilityAddTraits(.isButton)
    }

    /// Looked up once: every visible row header asks for it on every frame.
    private static let labelFormat = String(localized: "Grid.RowHeader.Accessibility")
}

/// A doubled hairline marking where hidden rows or columns were collapsed.
private struct HiddenSeam: View {
    let isVertical: Bool
    let isVisible: Bool

    var body: some View {
        Group {
            if isVertical {
                HStack(spacing: 1) {
                    Rectangle().frame(width: 1.5)
                    Rectangle().frame(width: 1.5)
                }
            } else {
                VStack(spacing: 1) {
                    Rectangle().frame(height: 1.5)
                    Rectangle().frame(height: 1.5)
                }
            }
        }
        .foregroundStyle(Color.accentColor.opacity(0.75))
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(false)
    }
}

/// Attaches a double-tap handler only when there is one, so the view below
/// keeps receiving the gesture otherwise.
private struct DoubleTapAction: ViewModifier {
    let perform: (() -> Void)?

    func body(content: Content) -> some View {
        if let perform {
            content.onTapGesture(count: 2, perform: perform)
        } else {
            content
        }
    }
}

/// The thin hit area between headers that resizes the neighbouring line.
private struct ResizeGrip: View {
    let isVertical: Bool
    /// The header's size along the axis being resized. The grip is a fraction of
    /// it rather than a fixed width: on a short row a fixed grip would cover
    /// most of the header and swallow taps meant for the header itself.
    let extent: Double
    let onResize: (Double) -> Void
    /// Omitted when the grip has nothing to do on a double tap, so the header
    /// underneath keeps receiving it and can open its menu.
    var onDoubleTap: (() -> Void)?

    @State private var lastTranslation: Double = 0

    /// Never more than a third of the header, so most of it stays tappable,
    /// and never so thin it cannot be grabbed.
    private var thickness: Double { min(10, max(4, extent / 3)) }

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: isVertical ? thickness : nil, height: isVertical ? nil : thickness)
            .contentShape(.rect)
            .gesture(
                // Global space: the grip itself moves as the line resizes, so a
                // local-space translation would jump by the amount the view just
                // moved and the delta feedback loop would oscillate.
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let total = isVertical ? value.translation.width : value.translation.height
                        onResize(total - lastTranslation)
                        lastTranslation = total
                    }
                    .onEnded { _ in lastTranslation = 0 }
            )
            .modifier(DoubleTapAction(perform: onDoubleTap))
            #if os(macOS)
            .onHover { inside in
                if inside {
                    (isVertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                } else {
                    NSCursor.pop()
                }
            }
            #endif
    }
}
