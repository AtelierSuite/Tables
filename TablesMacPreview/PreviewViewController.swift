import AppKit
import QuickLookUI
import TablesEngine
import UniformTypeIdentifiers

/// The Quick Look preview of a workbook: every sheet, one under another,
/// each its used cells drawn as the app draws them, small and read-only.
final class PreviewViewController: NSViewController, QLPreviewingController {
    private let scrollView = NSScrollView()
    private let stack = NSStackView()

    override func loadView() {
        let document = FlippedView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 28
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 24, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        document.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        scrollView.documentView = document
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .underPageBackgroundColor
        view = scrollView
        preferredContentSize = NSSize(width: 880, height: 640)
    }

    func preparePreviewOfFile(at url: URL) async throws {
        let workbook = try await Task.detached { try Self.workbook(at: url) }.value
        await MainActor.run { show(workbook) }
    }

    /// Reads the file the way the app would, by its type.
    nonisolated private static func workbook(at url: URL) throws -> Workbook {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: url.pathExtension) ?? .data
        if type.conforms(to: .commaSeparatedText) || type.conforms(to: .tabSeparatedText)
            || ["csv", "tsv"].contains(url.pathExtension.lowercased()) {
            return CSVCodec.workbook(from: try Data(contentsOf: url), sheetName: url.deletingPathExtension().lastPathComponent)
        }
        if url.pathExtension.lowercased() == "numbers" {
            let wrapper = try FileWrapper(url: url)
            return wrapper.isDirectory
                ? try NumbersReader.workbook(from: wrapper)
                : try NumbersReader.workbook(from: try Data(contentsOf: url))
        }
        return try XLSXReader.workbook(from: try Data(contentsOf: url))
    }

    @MainActor
    private func show(_ workbook: Workbook) {
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
        for sheet in workbook.visibleSheets {
            stack.addArrangedSubview(SheetPreviewSection(sheet: sheet))
        }
        if let document = scrollView.documentView {
            document.frame.size = stack.fittingSize
            document.scroll(.zero)
        }
    }
}

/// A document view that starts at the top, as a page does.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
