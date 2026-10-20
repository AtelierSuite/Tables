import SwiftUI
import TablesEngine

/// Presents the platform's own menu on demand.
///
/// SwiftUI's `contextMenu` can only be raised by the system's long-press or
/// right-click — there is no API to show it programmatically. To get a genuine
/// system menu from a double tap we drop to UIKit/AppKit, which both expose a
/// way to present one directly.
///
/// The view itself is invisible and does not take hits: it exists only to own a
/// window-attached responder the menu can hang from. Bump `trigger` to present.
struct NativeMenuPresenter: View {
    /// The menu's contents, built when it is presented rather than when the
    /// view is made. Headers and cells are rebuilt on every scroll frame, and
    /// assembling a platform menu for each of them at that rate costs far more
    /// than building one the moment somebody actually asks for it.
    var actions: () -> [HeaderMenuAction]
    var trigger: Int

    var body: some View {
        // Fills its container rather than sitting in a corner: a one-point view
        // pinned to the edge of a clipped header can fall outside the visible
        // bounds, and the menu has nothing to anchor to.
        Representable(actions: actions, trigger: trigger)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

#if canImport(UIKit)
import UIKit

private extension NativeMenuPresenter {
    struct Representable: UIViewRepresentable {
        var actions: () -> [HeaderMenuAction]
        var trigger: Int

        func makeUIView(context: Context) -> UIButton {
            let button = UIButton(type: .custom)
            // The menu becomes the button's primary action so it can be raised
            // with `performPrimaryAction()`. The button stays enabled, since a
            // disabled one ignores that call; `allowsHitTesting(false)` on the
            // SwiftUI wrapper keeps touches away so the header owns single-tap
            // selection.
            button.showsMenuAsPrimaryAction = true
            button.isAccessibilityElement = false
            button.accessibilityElementsHidden = true
            return button
        }

        func updateUIView(_ button: UIButton, context: Context) {
            // A deferred element defers the whole list: nothing is built until
            // the menu is on its way up, which is what makes reassigning it on
            // every update cheap enough to do at scroll rate.
            let build = actions
            button.menu = UIMenu(children: [
                UIDeferredMenuElement.uncached { completion in
                    completion(Self.menuElements(for: build()))
                },
            ])
            guard context.coordinator.lastTrigger != trigger else { return }
            context.coordinator.lastTrigger = trigger
            // A trigger of zero is the initial state, not a request.
            guard trigger > 0 else { return }
            DispatchQueue.main.async { button.performPrimaryAction() }
        }

        func makeCoordinator() -> Coordinator { Coordinator() }

        final class Coordinator {
            var lastTrigger = 0
        }

        /// UIKit has no separator element, so runs between separators become
        /// inline sub-menus, which is how the system draws grouped items.
        private static func menuElements(for actions: [HeaderMenuAction]) -> [UIMenuElement] {
            var groups: [[HeaderMenuAction]] = [[]]
            for action in actions {
                if case .separator = action.kind {
                    groups.append([])
                } else {
                    groups[groups.count - 1].append(action)
                }
            }
            return groups.filter { !$0.isEmpty }.map { group in
                UIMenu(options: .displayInline, children: group.map(command))
            }
        }

        private static func command(for action: HeaderMenuAction) -> UIAction {
            let command = UIAction(
                title: action.title,
                image: UIImage(systemName: action.symbol),
                attributes: action.kind == .destructive ? .destructive : []
            ) { _ in
                action.perform()
            }
            if !action.isEnabled { command.attributes.insert(.disabled) }
            return command
        }
    }
}
#else
import AppKit

private extension NativeMenuPresenter {
    struct Representable: NSViewRepresentable {
        var actions: () -> [HeaderMenuAction]
        var trigger: Int

        func makeNSView(context: Context) -> NSView {
            NSView()
        }

        func updateNSView(_ view: NSView, context: Context) {
            guard context.coordinator.lastTrigger != trigger else { return }
            context.coordinator.lastTrigger = trigger
            guard trigger > 0 else { return }

            let menu = NSMenu()
            for action in actions() {
                menu.addItem(context.coordinator.item(for: action))
            }
            DispatchQueue.main.async {
                menu.popUp(positioning: nil, at: .zero, in: view)
            }
        }

        func makeCoordinator() -> Coordinator { Coordinator() }

        final class Coordinator: NSObject {
            var lastTrigger = 0
            private var handlers: [ObjectIdentifier: () -> Void] = [:]

            func item(for action: HeaderMenuAction) -> NSMenuItem {
                if case .separator = action.kind { return .separator() }

                let item = NSMenuItem(title: action.title, action: #selector(run(_:)), keyEquivalent: "")
                item.target = self
                item.isEnabled = action.isEnabled
                item.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
                handlers[ObjectIdentifier(item)] = action.perform
                return item
            }

            @objc private func run(_ sender: NSMenuItem) {
                handlers[ObjectIdentifier(sender)]?()
            }
        }
    }
}
#endif
