import SwiftUI
import TablesEngine

/// While a formula is typed, the functions and defined names that finish the
/// word at its end, in a strip over the formula bar. Tapping one puts it in.
struct FormulaSuggestionsBar: View {
    let workbook: Workbook
    @Bindable var state: EditorState

    var body: some View {
        let suggestions = state.formulaSuggestions(in: workbook)
        if !suggestions.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(suggestions) { suggestion in
                        Button {
                            state.accept(suggestion)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: suggestion.kind == .name ? "character.textbox" : "function")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(suggestion.kind == .name ? Color.accentColor : .secondary)
                                Text(suggestion.text)
                                    .font(.callout.monospaced())
                                    .foregroundStyle(.primary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(.fill.tertiary, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(suggestion.text)
                        .accessibilityHint(suggestion.detail)
                        .accessibilityIdentifier("suggestion.\(suggestion.text)")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
    }
}
