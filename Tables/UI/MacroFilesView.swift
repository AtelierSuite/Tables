import SwiftUI
import TablesEngine

/// The files in a workbook's working folder: what its macros wrote, and
/// what they can read. Files can be shared out or deleted here, and the
/// folder opened in the Files app or Finder to add more.
struct MacroFilesView: View {
    let folder: URL
    /// The working folder itself, rather than a folder inside it.
    var isRoot = true
    @State private var entries: [MacroFiles.Entry] = []
    @State private var entryToDelete: MacroFiles.Entry?
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            if isRoot {
                Section {
                    Text("Macros.Files.Explanation")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(folder.path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    openInSystemButton
                }
            }
            Section {
                if entries.isEmpty {
                    Text("Macros.Files.Empty")
                        .foregroundStyle(.secondary)
                }
                ForEach(entries) { entry in
                    row(for: entry)
                }
            }
        }
        .navigationTitle(isRoot ? String(localized: "Macros.Files.Title") : folder.lastPathComponent)
        .onAppear(perform: reload)
        .refreshable { reload() }
        .confirmationDialog(
            "Macros.Files.Delete.Title",
            isPresented: Binding(get: { entryToDelete != nil }, set: { if !$0 { entryToDelete = nil } }),
            titleVisibility: .visible,
            presenting: entryToDelete
        ) { entry in
            Button("Macros.Files.Delete", role: .destructive) {
                try? FileManager.default.removeItem(at: entry.url)
                reload()
            }
        } message: { entry in
            Text(String(format: String(localized: "Macros.Files.Delete.Message"), entry.name))
        }
    }

    @ViewBuilder
    private func row(for entry: MacroFiles.Entry) -> some View {
        Group {
            if entry.isDirectory {
                NavigationLink {
                    MacroFilesView(folder: entry.url, isRoot: false)
                } label: {
                    Label(entry.name, systemImage: "folder")
                }
            } else {
                ShareLink(item: entry.url) { fileLabel(for: entry) }
            }
        }
        .swipeActions {
            Button("Macros.Files.Delete", systemImage: "trash", role: .destructive) { entryToDelete = entry }
        }
        .contextMenu {
            if !entry.isDirectory {
                ShareLink(item: entry.url)
            }
            Button("Macros.Files.Delete", systemImage: "trash", role: .destructive) { entryToDelete = entry }
        }
    }

    private func fileLabel(for entry: MacroFiles.Entry) -> some View {
        HStack {
            Label(entry.name, systemImage: "doc")
                .foregroundStyle(.primary)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Int64(entry.size), format: .byteCount(style: .file))
                Text(entry.modified, format: .dateTime.day().month().hour().minute())
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var openInSystemButton: some View {
        #if os(macOS)
        Button("Macros.Files.ShowInFinder", systemImage: "folder") {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        }
        #else
        Button("Macros.Files.OpenInFiles", systemImage: "folder") {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // The Files app's own scheme, which opens a path inside an app's
            // shared Documents.
            if let path = folder.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
               let url = URL(string: "shareddocuments://" + path) {
                openURL(url)
            }
        }
        #endif
    }

    private func reload() {
        entries = MacroFiles.contents(of: folder)
    }
}
