import SwiftUI
import TablesEngine

/// A Form Control drawn over the sheet, working as it does in Excel: a button
/// runs its macro, a check box or option button flips and writes its linked
/// cell, a drop-down lists its range, an edit box takes text.
struct FormControlView: View {
    let control: FormControl
    /// Whether the control shows as ticked or chosen.
    var checkState: FormControl.CheckState
    var selection: Int
    var items: [String]
    var zoom: Double
    var onPress: () -> Void
    var onSelect: (Int) -> Void
    var onEditText: (String) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        content
            .font(.system(size: control.font.size * zoom, weight: control.font.isBold ? .bold : .regular))
            .foregroundStyle(textColor)
            .lineLimit(nil)
    }

    @ViewBuilder
    private var content: some View {
        switch control.kind {
        case .button:
            Button(action: onPress) { caption.padding(.horizontal, 2 * zoom) }
                .buttonStyle(FormButtonStyle(zoom: zoom))
                .accessibilityIdentifier("formButton")
        case .checkBox:
            Button(action: onPress) {
                labelled { CheckBoxMark(state: checkState, zoom: zoom) }
            }
            .buttonStyle(.plain)
            .accessibilityValue(Text(checkState == .checked ? "FormControl.On" : "FormControl.Off"))
            .accessibilityIdentifier("formCheckBox")
        case .optionButton:
            Button(action: onPress) {
                labelled { OptionButtonMark(isOn: checkState == .checked, zoom: zoom) }
            }
            .buttonStyle(.plain)
            .accessibilityValue(Text(checkState == .checked ? "FormControl.On" : "FormControl.Off"))
            .accessibilityIdentifier("formOptionButton")
        case .dropDown:
            dropDown
        case .editBox:
            EditBoxField(text: control.text, zoom: zoom, onCommit: onEditText)
        case .groupBox:
            groupBox.allowsHitTesting(false)
        case .label:
            caption.allowsHitTesting(false)
        case .unsupported:
            PreservedDrawingPlaceholder(isChart: false, zoom: zoom)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("keptObject")
        }
    }

    private var textColor: Color {
        AdaptiveColor.resolveText(hex: control.font.colorHex, on: nil, for: colorScheme) ?? .primary
    }

    private var frameAlignment: Alignment {
        let horizontal: HorizontalAlignment = switch control.horizontalAlignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
        let vertical: VerticalAlignment = switch control.verticalAlignment {
        case .top: .top
        case .center: .center
        case .bottom: .bottom
        }
        return Alignment(horizontal: horizontal, vertical: vertical)
    }

    private var textAlignment: TextAlignment {
        switch control.horizontalAlignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private var caption: some View {
        Text(control.text)
            .multilineTextAlignment(textAlignment)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: frameAlignment)
    }

    /// A mark beside the caption, the whole width tappable as in Excel.
    private func labelled(@ViewBuilder mark: () -> some View) -> some View {
        HStack(spacing: 4 * zoom) {
            mark()
            caption
        }
        .padding(.leading, 2 * zoom)
        .contentShape(.rect)
    }

    private var dropDown: some View {
        Menu {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                Button {
                    onSelect(index + 1)
                } label: {
                    if index + 1 == selection {
                        Label(item, systemImage: "checkmark")
                    } else {
                        Text(item)
                    }
                }
            }
        } label: {
            HStack(spacing: 0) {
                Text(items.indices.contains(selection - 1) ? items[selection - 1] : "")
                    .lineLimit(1)
                    .padding(.horizontal, 3 * zoom)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8 * zoom, weight: .semibold))
                    .frame(width: 14 * zoom)
                    .frame(maxHeight: .infinity)
                    .background(Color.primary.opacity(0.06))
            }
            .background(Color.sheetBackground)
            .overlay { Rectangle().strokeBorder(Color.primary.opacity(0.35), lineWidth: 1) }
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityIdentifier("formDropDown")
    }

    private var groupBox: some View {
        let inset = control.font.size * zoom / 2
        return Rectangle()
            .strokeBorder(Color.primary.opacity(0.3), lineWidth: 1)
            .padding(.top, inset)
            .overlay(alignment: .topLeading) {
                if !control.text.isEmpty {
                    Text(control.text)
                        .lineLimit(1)
                        .padding(.horizontal, 2 * zoom)
                        .background(Color.sheetBackground)
                        .padding(.leading, 6 * zoom)
                }
            }
    }
}

/// Excel's push button: a raised face that sinks while held.
private struct FormButtonStyle: ButtonStyle {
    var zoom: Double

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 3 * zoom, style: .continuous)
                    .fill(Color.sheetBackground)
                    .overlay {
                        RoundedRectangle(cornerRadius: 3 * zoom, style: .continuous)
                            .fill(Color.primary.opacity(configuration.isPressed ? 0.16 : 0.07))
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 3 * zoom, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.35), lineWidth: 1)
            }
            .contentShape(.rect)
    }
}

private struct CheckBoxMark: View {
    var state: FormControl.CheckState
    var zoom: Double

    var body: some View {
        let side = 10 * zoom
        RoundedRectangle(cornerRadius: 1.5 * zoom)
            .fill(state == .mixed ? Color.primary.opacity(0.12) : Color.sheetBackground)
            .overlay { RoundedRectangle(cornerRadius: 1.5 * zoom).strokeBorder(Color.primary.opacity(0.55), lineWidth: 1) }
            .overlay {
                if state != .unchecked {
                    Image(systemName: "checkmark")
                        .font(.system(size: side * 0.7, weight: .bold))
                        .foregroundStyle(state == .mixed ? Color.secondary : Color.primary)
                }
            }
            .frame(width: side, height: side)
    }
}

private struct OptionButtonMark: View {
    var isOn: Bool
    var zoom: Double

    var body: some View {
        let side = 10 * zoom
        Circle()
            .fill(Color.sheetBackground)
            .overlay { Circle().strokeBorder(Color.primary.opacity(0.55), lineWidth: 1) }
            .overlay {
                if isOn { Circle().fill(Color.primary).padding(side * 0.28) }
            }
            .frame(width: side, height: side)
    }
}

/// An edit box's field, handing its text over once typing is done rather
/// than on every keystroke, so a word typed is one change to undo.
private struct EditBoxField: View {
    var text: String
    var zoom: Double
    var onCommit: (String) -> Void
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("", text: $draft)
            .textFieldStyle(.plain)
            .padding(.horizontal, 3 * zoom)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(Color.sheetBackground)
            .overlay { Rectangle().strokeBorder(Color.primary.opacity(0.35), lineWidth: 1) }
            .focused($isFocused)
            .onAppear { draft = text }
            .onChange(of: text) { _, newValue in if !isFocused { draft = newValue } }
            .onChange(of: isFocused) { _, focused in if !focused, draft != text { onCommit(draft) } }
            .onSubmit { if draft != text { onCommit(draft) } }
            .accessibilityIdentifier("formEditBox")
    }
}
