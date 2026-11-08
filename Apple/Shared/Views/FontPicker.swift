#if canImport(UIKit)
import SwiftUI
import UIKit

/// The system font picker, choosing a family for the selected cells.
struct FontPicker: UIViewControllerRepresentable {
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIFontPickerViewController {
        let configuration = UIFontPickerViewController.Configuration()
        // Families, not faces: bold and italic are the cell's own switches.
        configuration.includeFaces = false
        let picker = UIFontPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIFontPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UIFontPickerViewControllerDelegate {
        private let parent: FontPicker

        init(_ parent: FontPicker) {
            self.parent = parent
        }

        func fontPickerViewControllerDidPickFont(_ picker: UIFontPickerViewController) {
            if let descriptor = picker.selectedFontDescriptor,
               let family = descriptor.object(forKey: .family) as? String {
                parent.onPick(family)
            }
            parent.dismiss()
        }

        func fontPickerViewControllerDidCancel(_ picker: UIFontPickerViewController) {
            parent.dismiss()
        }
    }
}
#endif
