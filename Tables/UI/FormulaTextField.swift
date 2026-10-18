import SwiftUI
import TablesEngine
import UIKit

/// A single-line field that writes each reference in a formula in the colour
/// it is outlined in on the grid, so the two can be matched at a glance.
///
/// UIKit rather than SwiftUI's `TextField`, which has no way to colour part of
/// what is being typed.
struct FormulaTextField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var placeholder = ""
    var font: UIFont
    var accessibilityIdentifier: String
    var returnKeyType: UIReturnKeyType = .default
    /// Formulas are code: corrections and capitals only get in the way.
    var isPlainInput = false
    var onSubmit: () -> Void

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.textChanged(_:)), for: .editingChanged)
        // Sized by SwiftUI, never by how much has been typed.
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        field.placeholder = placeholder
        field.accessibilityIdentifier = accessibilityIdentifier
        field.returnKeyType = returnKeyType
        field.autocorrectionType = isPlainInput ? .no : .default
        field.autocapitalizationType = isPlainInput ? .none : .sentences
        field.spellCheckingType = isPlainInput ? .no : .default

        if field.text != text {
            Self.style(field, text: text, font: font)
            // Text arriving from outside is a reference pointed at on the grid;
            // the next keystroke belongs after it.
            field.selectedTextRange = field.textRange(from: field.endOfDocument, to: field.endOfDocument)
        } else if field.font != font {
            Self.style(field, text: text, font: font)
        }

        if isFocused != field.isFirstResponder {
            // Deferred: responder changes during a view update are ignored, and
            // by the time this runs the request may already be stale.
            DispatchQueue.main.async {
                let wanted = context.coordinator.parent.isFocused
                if wanted, !field.isFirstResponder {
                    field.becomeFirstResponder()
                } else if !wanted, field.isFirstResponder {
                    field.resignFirstResponder()
                }
            }
        }
    }

    /// As wide as offered, as tall as one line: left to itself a representable
    /// takes all the height it is given.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView field: UITextField, context _: Context) -> CGSize? {
        CGSize(
            width: proposal.width ?? field.intrinsicContentSize.width,
            height: field.intrinsicContentSize.height
        )
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    /// Rewrites the field's contents with each reference coloured, keeping the
    /// caret where it was.
    fileprivate static func style(_ field: UITextField, text: String, font: UIFont) {
        let styled = NSMutableAttributedString(
            string: text, attributes: [.font: font, .foregroundColor: UIColor.label]
        )
        for reference in FormulaReferenceScanner.references(in: text) {
            let lower = text.index(text.startIndex, offsetBy: reference.range.lowerBound)
            let upper = text.index(text.startIndex, offsetBy: reference.range.upperBound)
            styled.addAttribute(
                .foregroundColor,
                value: FormulaReferenceColors.uiColor(at: reference.colorIndex),
                range: NSRange(lower..<upper, in: text)
            )
        }
        let selection = field.selectedTextRange
        field.font = font
        field.attributedText = styled
        field.selectedTextRange = selection
        // Otherwise typing straight after a reference carries its colour on.
        field.typingAttributes = [.font: font, .foregroundColor: UIColor.label]
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: FormulaTextField

        init(parent: FormulaTextField) {
            self.parent = parent
        }

        @objc func textChanged(_ field: UITextField) {
            let text = field.text ?? ""
            // Restyling mid-composition would commit half-converted kana.
            if field.markedTextRange == nil {
                FormulaTextField.style(field, text: text, font: parent.font)
            }
            parent.text = text
        }

        func textFieldDidBeginEditing(_: UITextField) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func textFieldDidEndEditing(_: UITextField) {
            if parent.isFocused { parent.isFocused = false }
        }

        func textFieldShouldReturn(_: UITextField) -> Bool {
            parent.onSubmit()
            return false
        }
    }
}
