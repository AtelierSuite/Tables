import SwiftUI
import TablesEngine

/// The workbook's title, author and the rest, as Excel's document properties
/// hold them. Changes are made to a copy and handed back on Done, so the
/// whole edit is one undo step rather than one per keystroke.
struct DocumentPropertiesPanel: View {
    /// Called with the edited properties on Done, and with `nil` on Cancel.
    let finish: (DocumentProperties?) -> Void
    @State private var properties: DocumentProperties

    init(properties: DocumentProperties, finish: @escaping (DocumentProperties?) -> Void) {
        self.finish = finish
        _properties = State(initialValue: properties)
    }

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            form
            Divider()
            HStack {
                Spacer()
                Button("DocumentProperties.Cancel", role: .cancel) { finish(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("DocumentProperties.Done") { finish(properties) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 460, height: 520)
        #else
        form
            .navigationTitle("DocumentProperties.Title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { finish(nil) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm) { finish(properties) }
                        .accessibilityIdentifier("documentPropertiesDone")
                }
            }
        #endif
    }

    private var form: some View {
        Form {
            Section {
                field("DocumentProperties.Field.Title", text: $properties.title, identifier: "title")
                field("DocumentProperties.Field.Author", text: $properties.author, identifier: "author")
                field("DocumentProperties.Field.Subject", text: $properties.subject, identifier: "subject")
                field("DocumentProperties.Field.Keywords", text: $properties.keywords, identifier: "keywords")
                field("DocumentProperties.Field.Category", text: $properties.category, identifier: "category")
            }
            Section("DocumentProperties.Field.Comments") {
                TextField("DocumentProperties.Field.Comments", text: $properties.comments, axis: .vertical)
                    .lineLimit(3...8)
                    .labelsHidden()
                    .accessibilityIdentifier("documentProperty.comments")
            }
            Section {
                if let created = properties.created {
                    LabeledContent("DocumentProperties.Created") {
                        Text(created.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                if let modified = properties.modified {
                    LabeledContent("DocumentProperties.Modified") {
                        Text(modified.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                if !properties.lastModifiedBy.isEmpty {
                    LabeledContent("DocumentProperties.LastModifiedBy", value: properties.lastModifiedBy)
                }
                if !properties.application.isEmpty {
                    LabeledContent("DocumentProperties.Application", value: properties.application)
                }
                if !properties.company.isEmpty {
                    LabeledContent("DocumentProperties.Company", value: properties.company)
                }
            } footer: {
                Text("DocumentProperties.Footer")
            }
        }
        .formStyle(.grouped)
    }

    /// A labelled text field. iOS forms show a field's label only as its
    /// placeholder, which disappears once something is typed, so there the
    /// label sits beside it.
    @ViewBuilder
    private func field(_ label: LocalizedStringKey, text: Binding<String>, identifier: String) -> some View {
        #if os(macOS)
        TextField(label, text: text)
            .accessibilityIdentifier("documentProperty.\(identifier)")
        #else
        LabeledContent(label) {
            TextField(label, text: text)
                .multilineTextAlignment(.trailing)
                .accessibilityIdentifier("documentProperty.\(identifier)")
        }
        #endif
    }
}
