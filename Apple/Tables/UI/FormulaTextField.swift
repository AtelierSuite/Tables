import SwiftUI
import TablesEngine
import UIKit

/// A single-line field that sets each reference in a formula in a capsule of
/// the colour it is outlined in on the grid, so the two can be matched at a
/// glance.
///
/// UIKit rather than SwiftUI's `TextField`, which has no way to style part of
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

    func makeUIView(context: Context) -> ReferenceCapsuleTextField {
        let field = ReferenceCapsuleTextField()
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.textChanged(_:)), for: .editingChanged)
        // Sized by SwiftUI, never by how much has been typed.
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: ReferenceCapsuleTextField, context: Context) {
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
    func sizeThatFits(_ proposal: ProposedViewSize, uiView field: ReferenceCapsuleTextField, context _: Context) -> CGSize? {
        CGSize(
            width: proposal.width ?? field.intrinsicContentSize.width,
            height: field.intrinsicContentSize.height
        )
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    /// Rewrites the field's contents with each reference coloured and set
    /// apart for its capsule, keeping the caret where it was.
    fileprivate static func style(
        _ field: ReferenceCapsuleTextField, text: String, font: UIFont, editing: Bool? = nil
    ) {
        let styled = NSMutableAttributedString(
            string: text, attributes: [.font: font, .foregroundColor: UIColor.label]
        )
        var capsules: [ReferenceCapsuleTextField.Capsule] = []
        let gap = ReferenceCapsuleTextField.gap(for: font)
        for reference in FormulaReferenceScanner.references(in: text) {
            let lower = text.index(text.startIndex, offsetBy: reference.range.lowerBound)
            let upper = text.index(text.startIndex, offsetBy: reference.range.upperBound)
            let range = NSRange(lower..<upper, in: text)
            let color = FormulaReferenceColors.uiColor(at: reference.colorIndex)
            styled.addAttribute(.foregroundColor, value: color, range: range)
            // Room either side for the capsule, so it never touches its neighbours.
            if range.location > 0 {
                styled.addAttribute(.kern, value: gap, range: NSRange(location: range.location - 1, length: 1))
            }
            // A trailing gap at rest spreads the whole truncated line, so only while typing.
            if NSMaxRange(range) < styled.length || (editing ?? field.isEditing) {
                styled.addAttribute(.kern, value: gap, range: NSRange(location: NSMaxRange(range) - 1, length: 1))
            }
            capsules.append(.init(range: range, color: color))
        }
        let selection = field.selectedTextRange
        // Typing after a reference copies its kern into these, which then
        // letter-spaces all the text once editing ends.
        field.defaultTextAttributes = [.font: font, .foregroundColor: UIColor.label]
        field.attributedText = styled
        field.selectedTextRange = selection
        // Otherwise typing straight after a reference carries its colour on.
        field.typingAttributes = [.font: font, .foregroundColor: UIColor.label]
        field.capsules = capsules
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: FormulaTextField

        init(parent: FormulaTextField) {
            self.parent = parent
        }

        @objc func textChanged(_ field: ReferenceCapsuleTextField) {
            let text = field.text ?? ""
            // Restyling mid-composition would commit half-converted kana.
            if field.markedTextRange == nil {
                FormulaTextField.style(field, text: text, font: parent.font)
            }
            parent.text = text
        }

        func textFieldDidBeginEditing(_ field: UITextField) {
            if !parent.isFocused { parent.isFocused = true }
            restyle(field, editing: true)
        }

        func textFieldDidEndEditing(_ field: UITextField) {
            if parent.isFocused { parent.isFocused = false }
            restyle(field, editing: false)
        }

        /// The gap after a reference that ends the text exists only while editing.
        private func restyle(_ field: UITextField, editing: Bool) {
            guard let field = field as? ReferenceCapsuleTextField, field.markedTextRange == nil else { return }
            FormulaTextField.style(field, text: field.text ?? "", font: parent.font, editing: editing)
        }

        /// Moving the caret can scroll the text under the capsules.
        func textFieldDidChangeSelection(_ field: UITextField) {
            (field as? ReferenceCapsuleTextField)?.setNeedsLayout()
        }

        func textFieldShouldReturn(_: UITextField) -> Bool {
            parent.onSubmit()
            return false
        }
    }
}

/// A text field that draws a rounded capsule behind each of a set of ranges of
/// its text, following the text as it scrolls.
final class ReferenceCapsuleTextField: UITextField {
    struct Capsule {
        var range: NSRange
        var color: UIColor
    }

    var capsules: [Capsule] = [] {
        didSet { setNeedsLayout() }
    }

    private let capsuleLayer = CALayer()
    private weak var observedScroller: UIScrollView?
    private var scrollObservation: NSKeyValueObservation?

    /// The space left between a capsule and the text either side of it.
    static func gap(for font: UIFont) -> CGFloat {
        (font.pointSize * 0.3).rounded()
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.insertSublayer(capsuleLayer, at: 0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        observeScrolling()
        layoutCapsules()
    }

    /// The field scrolls its text after layout, so capsules follow the scroll.
    private func observeScrolling() {
        let scroller = firstScrollView(in: self)
        guard scroller !== observedScroller else { return }
        observedScroller = scroller
        scrollObservation = scroller?.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.layoutCapsules() }
        }
    }

    private func firstScrollView(in view: UIView) -> UIScrollView? {
        for subview in view.subviews {
            if let scroller = subview as? UIScrollView { return scroller }
            if let found = firstScrollView(in: subview) { return found }
        }
        return nil
    }

    /// UIKit puts the caret before a trailing kern, inside the last capsule.
    override func caretRect(for position: UITextPosition) -> CGRect {
        var rect = super.caretRect(for: position)
        let length = (text ?? "").utf16.count
        if isEditing, let font, let last = capsules.last, NSMaxRange(last.range) == length,
           offset(from: beginningOfDocument, to: position) == length {
            rect.origin.x += Self.gap(for: font)
        }
        return rect
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        setNeedsLayout()
    }

    private func layoutCapsules() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        capsuleLayer.frame = bounds
        capsuleLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        guard !capsules.isEmpty, let font else { return }
        let length = (text ?? "").utf16.count
        let padding = Self.gap(for: font) / 2
        let visible = textRect(forBounds: bounds)
        let height = ceil(font.lineHeight) + 2
        for capsule in capsules where NSMaxRange(capsule.range) <= length {
            guard var box = rect(for: capsule.range, in: visible) else { continue }
            // The trailing kern belongs to the gap after the capsule.
            if NSMaxRange(capsule.range) < length || isEditing { box.size.width -= Self.gap(for: font) }
            box = CGRect(x: box.minX - padding, y: box.midY - height / 2,
                         width: box.width + padding * 2, height: height)
            guard box.maxX > visible.minX - padding, box.minX < visible.maxX + padding else { continue }
            // At rest, a reference cut short by the ellipsis gets no capsule.
            if !isEditing, box.maxX > visible.maxX + padding { continue }
            let pill = CALayer()
            pill.frame = box.integral
            pill.cornerRadius = min(pill.frame.height / 2, 6)
            pill.cornerCurve = .continuous
            pill.backgroundColor = capsule.color.resolvedColor(with: traitCollection)
                .withAlphaComponent(0.16).cgColor
            capsuleLayer.addSublayer(pill)
        }
        capsuleLayer.mask = clipMask(to: visible.insetBy(dx: -padding, dy: -bounds.height))
    }

    /// Measured from the text itself: UIKit's own rects split the kerned gaps
    /// unevenly, leaving capsules lopsided.
    private func rect(for range: NSRange, in visible: CGRect) -> CGRect? {
        guard let styled = attributedText, let origin = textOrigin(in: visible) else { return nil }
        let lead = styled.attributedSubstring(from: NSRange(location: 0, length: range.location)).size().width
        let width = styled.attributedSubstring(from: range).size().width
        let line = font?.lineHeight ?? visible.height
        return CGRect(x: origin.x + lead, y: origin.y - line / 2, width: width, height: line)
    }

    /// Where the first character starts, and the line's vertical centre.
    private func textOrigin(in visible: CGRect) -> CGPoint? {
        // At rest the text is drawn truncated, where firstRect is unreliable.
        guard isEditing else { return CGPoint(x: visible.minX, y: visible.midY) }
        guard let end = position(from: beginningOfDocument, offset: 1),
              let first = textRange(from: beginningOfDocument, to: end) else { return nil }
        let box = firstRect(for: first)
        guard !box.isNull, !box.isInfinite else { return nil }
        // Rects come back as if the text had not scrolled.
        return CGPoint(x: box.minX - (observedScroller?.contentOffset.x ?? 0), y: box.midY)
    }

    /// Capsules scrolled past either edge are cut off where the text is.
    private func clipMask(to rect: CGRect) -> CALayer {
        let mask = CALayer()
        mask.frame = rect
        mask.backgroundColor = UIColor.black.cgColor
        return mask
    }
}
