import AppKit
import SwiftUI
import TablesEngine

/// The building blocks of the Mac inspector, laid out the way the Mac's
/// document apps lay theirs out: flat sections under a small grey heading,
/// separated by hairlines, with a label on the left of each row and a compact
/// control on the right.
enum InspectorMetrics {
    static let horizontalPadding: CGFloat = 16
    static let rowSpacing: CGFloat = 10
    /// The width popup menus and colour wells settle at, so the controls in a
    /// section line up down their right-hand edge.
    static let controlWidth: CGFloat = 150
}

/// A run of sections, hairlines between them, that scrolls as one.
struct InspectorScroll<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(.bottom, 12)
        }
        .scrollIndicators(.automatic)
    }
}

/// One section: a small grey heading over its rows, closed off by a hairline.
struct InspectorSection<Content: View>: View {
    let title: LocalizedStringKey?
    var showsDivider = true
    @ViewBuilder let content: Content

    init(_ title: LocalizedStringKey? = nil, showsDivider: Bool = true, @ViewBuilder content: () -> Content) {
        self.title = title
        self.showsDivider = showsDivider
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
                if let title {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                content
            }
            .padding(.horizontal, InspectorMetrics.horizontalPadding)
            .padding(.vertical, 12)
            if showsDivider {
                Divider().padding(.horizontal, InspectorMetrics.horizontalPadding)
            }
        }
    }
}

/// A label on the left and its control pushed to the right.
struct InspectorRow<Control: View>: View {
    let label: LocalizedStringKey
    @ViewBuilder let control: Control

    init(_ label: LocalizedStringKey, @ViewBuilder control: () -> Control) {
        self.label = label
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 8)
            control
        }
        .frame(minHeight: 22)
    }
}

/// A popup menu sized to sit in an `InspectorRow`.
struct InspectorPopup<Selection: Hashable, Content: View>: View {
    @Binding var selection: Selection
    @ViewBuilder let content: Content

    var body: some View {
        Picker("", selection: $selection) { content }
            .pickerStyle(.menu)
            .labelsHidden()
            // Every popup the same width, rather than each hugging its title.
            .buttonSizing(.flexible)
            .frame(width: InspectorMetrics.controlWidth)
    }
}

// MARK: - Segmented control

/// A native segmented control whose segments can each be on or off on their
/// own (bold, italic…), one of a set (alignment), or plain buttons (indent).
///
/// SwiftUI's segmented picker only offers the one-of-a-set behaviour, and the
/// style buttons need to read as the same control as the alignment ones.
struct InspectorSegments: NSViewRepresentable {
    struct Segment {
        enum Content {
            case symbol(String)
            case text(String)
        }

        let content: Content
        let label: String
        var isOn = false
        let action: () -> Void

        init(symbol: String, label: String, isOn: Bool = false, action: @escaping () -> Void) {
            self.content = .symbol(symbol)
            self.label = label
            self.isOn = isOn
            self.action = action
        }

        init(text: String, isOn: Bool = false, action: @escaping () -> Void) {
            self.content = .text(text)
            self.label = text
            self.isOn = isOn
            self.action = action
        }
    }

    enum Mode {
        case selectAny, selectOne, momentary

        var trackingMode: NSSegmentedControl.SwitchTracking {
            switch self {
            case .selectAny: return .selectAny
            case .selectOne: return .selectOne
            case .momentary: return .momentary
            }
        }
    }

    let mode: Mode
    let segments: [Segment]
    /// Stretch across the row rather than hug the segments' content.
    var fillsWidth = true

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.trackingMode = mode.trackingMode
        control.segmentDistribution = fillsWidth ? .fillEqually : .fit
        control.target = context.coordinator
        control.action = #selector(Coordinator.changed(_:))
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.segments = segments
        context.coordinator.mode = mode
        control.trackingMode = mode.trackingMode
        if control.segmentCount != segments.count { control.segmentCount = segments.count }
        for (index, segment) in segments.enumerated() {
            switch segment.content {
            case .symbol(let name):
                control.setImage(
                    NSImage(systemSymbolName: name, accessibilityDescription: segment.label), forSegment: index
                )
                control.setLabel("", forSegment: index)
            case .text(let text):
                control.setImage(nil, forSegment: index)
                control.setLabel(text, forSegment: index)
            }
            control.setToolTip(segment.label, forSegment: index)
            if mode != .momentary {
                control.setSelected(segment.isOn, forSegment: index)
            }
        }
        if mode == .selectOne, !segments.contains(where: \.isOn) {
            control.selectedSegment = -1
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        let natural = nsView.intrinsicContentSize
        guard fillsWidth, let width = proposal.width, width.isFinite else { return natural }
        return CGSize(width: max(width, natural.width), height: natural.height)
    }

    final class Coordinator: NSObject {
        var segments: [Segment] = []
        var mode = Mode.selectOne

        @MainActor @objc func changed(_ sender: NSSegmentedControl) {
            switch mode {
            case .momentary, .selectOne:
                let index = sender.selectedSegment
                guard segments.indices.contains(index) else { return }
                segments[index].action()
            case .selectAny:
                // The clicked segment is whichever no longer matches the model.
                for (index, segment) in segments.enumerated()
                where sender.isSelected(forSegment: index) != segment.isOn {
                    segment.action()
                }
            }
        }
    }
}

// MARK: - Colour well

/// A colour well that opens onto the system palette, with "none" and the
/// full colour panel alongside, as the Mac's document apps offer colour.
struct InspectorColorWell: View {
    /// The colour applied, as OOXML "AARRGGBB", or nil for none.
    let selectedHex: String?
    /// Shown, and offered to the colour panel, when nothing is applied.
    var automaticColor: Color = .primary
    /// Whether "no colour" means the automatic colour rather than nothing,
    /// as it does for text.
    var noneShowsAutomatic = false
    let noneLabel: LocalizedStringKey
    let onChange: (String?) -> Void

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            well
        }
        .buttonStyle(.plain)
        .accessibilityLabel(noneLabel)
        .popover(isPresented: $isPresented, arrowEdge: .leading) {
            palette
        }
    }

    private var well: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return Group {
            if let color = Color(argbHex: selectedHex) {
                shape.fill(color)
            } else if noneShowsAutomatic {
                shape.fill(automaticColor)
            } else {
                shape.fill(Color(nsColor: .controlBackgroundColor)).overlay(NoColorSlash().padding(3))
            }
        }
        .frame(width: 52, height: 20)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.2), lineWidth: 1))
        .contentShape(shape)
    }

    private var palette: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                choose(nil)
            } label: {
                HStack(spacing: 8) {
                    swatchShape(isSelected: selectedHex == nil) {
                        Circle().fill(Color(nsColor: .controlBackgroundColor))
                            .overlay(NoColorSlash().padding(2))
                    }
                    Text("Mac.Inspector.Color.None")
                    Spacer()
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(noneLabel)

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(22), spacing: 8), count: 6), spacing: 8) {
                ForEach(SystemColorPalette.accents) { swatch in swatchButton(swatch) }
            }

            HStack(spacing: 0) {
                ForEach(SystemColorPalette.neutrals) { swatch in
                    let isSelected = matches(swatch)
                    Button {
                        choose(swatch.argbHex)
                    } label: {
                        Rectangle().fill(swatch.color)
                            .frame(height: 18)
                            .overlay {
                                if isSelected {
                                    Rectangle().strokeBorder(Color.accentColor, lineWidth: 2)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(swatch.label)
                }
            }
            .clipShape(.rect(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))

            Divider()

            ColorPicker("ColorSwatches.MoreColours", selection: Binding(
                get: { Color(argbHex: selectedHex) ?? automaticColor },
                set: { color in onChange(color.argbHex) }
            ), supportsOpacity: false)
        }
        .padding(12)
        .frame(width: 22 * 6 + 8 * 5 + 24)
    }

    private func swatchButton(_ swatch: SystemColorPalette.Swatch) -> some View {
        Button {
            choose(swatch.argbHex)
        } label: {
            swatchShape(isSelected: matches(swatch)) {
                Circle().fill(swatch.color)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(swatch.label)
    }

    private func swatchShape<Fill: View>(isSelected: Bool, @ViewBuilder fill: () -> Fill) -> some View {
        fill()
            .frame(width: 18, height: 18)
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
            .overlay {
                if isSelected {
                    Circle().strokeBorder(Color.accentColor, lineWidth: 2).padding(-3)
                }
            }
            .frame(width: 22, height: 22)
    }

    private func matches(_ swatch: SystemColorPalette.Swatch) -> Bool {
        selectedHex?.caseInsensitiveCompare(swatch.argbHex) == .orderedSame
    }

    private func choose(_ hex: String?) {
        onChange(hex)
        isPresented = false
    }
}

/// The red rule through an empty well that means "no colour".
private struct NoColorSlash: View {
    var body: some View {
        GeometryReader { proxy in
            Path { path in
                path.move(to: CGPoint(x: 0, y: proxy.size.height))
                path.addLine(to: CGPoint(x: proxy.size.width, y: 0))
            }
            .stroke(Color.red.opacity(0.85), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }
    }
}
