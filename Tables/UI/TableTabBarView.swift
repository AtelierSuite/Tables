import SwiftUI

/// The strip of tables along the top of a Numbers sheet that holds several,
/// as Numbers shows them: the sheet itself takes one tab at the bottom, and
/// its tables are picked from here.
struct TableTabBarView: View {
    @Binding var workbook: Workbook
    @Bindable var state: EditorState
    /// The worksheets the sheet's tables became, in order.
    var tables: [Worksheet]
    var numbersSource: NumbersSource

    var body: some View {
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 0) {
                HStack(spacing: 6) {
                    ForEach(tables) { table in
                        tab(for: table)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
    }

    /// A table goes by its own name; one without falls back on its
    /// worksheet's, which is named after its sheet.
    private func name(of table: Worksheet) -> String {
        let name = numbersSource.tables[table.id]?.tableName ?? ""
        return name.isEmpty ? table.name : name
    }

    private func tab(for table: Worksheet) -> some View {
        let isActive = table.id == state.activeSheet(in: workbook).id

        return Label(name(of: table), systemImage: "tablecells")
            .labelStyle(.titleAndIcon)
            .font(.system(size: 13))
            .lineLimit(1)
            .foregroundStyle(isActive ? Color.accentColor : .primary)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .glassEffect(
                isActive ? .regular.tint(Color.accentColor.opacity(0.22)).interactive() : .regular.interactive(),
                in: .capsule
            )
            .contentShape(.capsule)
            .onTapGesture { state.selectSheet(table.id, in: workbook) }
            .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }
}
