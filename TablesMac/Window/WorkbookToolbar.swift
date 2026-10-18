import AppKit
import TablesEngine

/// The workbook window's toolbar: text styles, alignment, colours, number
/// formats, borders, and inserting charts and functions.
///
/// Items send the same actions as the menu bar, up the responder chain, so
/// both are validated and carried out in one place.
@MainActor
final class WorkbookToolbar: NSObject, NSToolbarDelegate {
    let toolbar = NSToolbar(identifier: "Workbook")
    private weak var document: WorkbookDocument?
    private var styleGroup: NSToolbarItemGroup?
    private var alignmentGroup: NSToolbarItemGroup?

    private enum Item {
        static let style = NSToolbarItem.Identifier("style")
        static let alignment = NSToolbarItem.Identifier("alignment")
        static let fill = NSToolbarItem.Identifier("fill")
        static let textColor = NSToolbarItem.Identifier("textColor")
        static let numberFormat = NSToolbarItem.Identifier("numberFormat")
        static let borders = NSToolbarItem.Identifier("borders")
        static let merge = NSToolbarItem.Identifier("merge")
        static let chart = NSToolbarItem.Identifier("chart")
        static let function = NSToolbarItem.Identifier("function")
        static let unsupported = NSToolbarItem.Identifier("unsupported")
    }

    init(document: WorkbookDocument) {
        self.document = document
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Item.style, Item.alignment, Item.fill, Item.textColor, Item.numberFormat, Item.borders, .space,
         Item.function, Item.chart, .flexibleSpace, Item.unsupported]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Item.style, Item.alignment, Item.fill, Item.textColor, Item.numberFormat, Item.borders, Item.merge,
         Item.chart, Item.function, Item.unsupported, .space, .flexibleSpace]
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch identifier {
        case Item.style:
            let group = NSToolbarItemGroup(
                itemIdentifier: identifier,
                images: ["bold", "italic", "underline", "strikethrough"].compactMap {
                    NSImage(systemSymbolName: $0, accessibilityDescription: nil)
                },
                selectionMode: .selectAny,
                labels: [String(localized: "Toolbar.Bold"), String(localized: "Toolbar.Italic"),
                         String(localized: "Toolbar.Underline"), String(localized: "Mac.Toolbar.Strikethrough")],
                target: self, action: #selector(styleGroupChanged(_:))
            )
            group.label = String(localized: "Mac.Toolbar.Style")
            styleGroup = group
            return group
        case Item.alignment:
            let group = NSToolbarItemGroup(
                itemIdentifier: identifier,
                images: ["text.alignleft", "text.aligncenter", "text.alignright"].compactMap {
                    NSImage(systemSymbolName: $0, accessibilityDescription: nil)
                },
                selectionMode: .selectOne,
                labels: [HorizontalTextAlignment.leading.label, HorizontalTextAlignment.center.label,
                         HorizontalTextAlignment.trailing.label],
                target: self, action: #selector(alignmentGroupChanged(_:))
            )
            group.label = String(localized: "Format.Section.Alignment")
            alignmentGroup = group
            return group
        case Item.fill:
            return button(identifier, symbol: "paintbrush.pointed", label: String(localized: "Format.Section.Fill"),
                          action: #selector(WorkbookViewController.orderFrontFillColorPanel(_:)))
        case Item.textColor:
            return button(identifier, symbol: "character.textbox", label: String(localized: "Mac.Menu.TextColor"),
                          action: #selector(WorkbookViewController.orderFrontTextColorPanel(_:)))
        case Item.numberFormat:
            let menu = NSMenu()
            for preset in NumberFormatPreset.allCases {
                let item = MainMenu.item(preset.label, #selector(WorkbookViewController.setNumberFormat(_:)))
                item.representedObject = preset.rawValue
                menu.addItem(item)
            }
            return menuItem(identifier, symbol: "number", label: String(localized: "Toolbar.NumberFormat"), menu: menu)
        case Item.borders:
            return menuItem(identifier, symbol: "square.grid.3x3", label: String(localized: "Format.Section.Borders"),
                            menu: MainMenu.bordersMenu())
        case Item.merge:
            return button(identifier, symbol: "arrow.right.and.line.vertical.and.arrow.left",
                          label: String(localized: "Format.Merge.Merge"),
                          action: #selector(WorkbookViewController.mergeCells(_:)))
        case Item.chart:
            let menu = NSMenu()
            for kind in ChartKind.allCases {
                let item = MainMenu.item(kind.label, #selector(WorkbookViewController.insertChart(_:)))
                item.representedObject = kind.rawValue
                item.image = NSImage(systemSymbolName: kind.symbolName, accessibilityDescription: nil)
                menu.addItem(item)
            }
            return menuItem(identifier, symbol: "chart.bar.xaxis", label: String(localized: "Toolbar.InsertChart"),
                            menu: menu)
        case Item.function:
            let menu = NSMenu()
            for name in ["SUM", "AVERAGE", "COUNT", "MIN", "MAX"] {
                let item = MainMenu.item(name, #selector(WorkbookViewController.insertFunction(_:)))
                item.representedObject = name
                menu.addItem(item)
            }
            return menuItem(identifier, symbol: "sum", label: String(localized: "Toolbar.Sum"), menu: menu)
        case Item.unsupported:
            return button(identifier, symbol: "exclamationmark.triangle",
                          label: String(localized: "Toolbar.UnsupportedFeatures.Label"),
                          action: #selector(WorkbookViewController.showUnsupportedFeatures(_:)))
        default:
            return nil
        }
    }

    private func button(_ identifier: NSToolbarItem.Identifier, symbol: String, label: String, action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.label = label
        item.toolTip = label
        item.action = action
        item.isBordered = true
        return item
    }

    private func menuItem(_ identifier: NSToolbarItem.Identifier, symbol: String, label: String, menu: NSMenu) -> NSToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: identifier)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.label = label
        item.toolTip = label
        item.menu = menu
        item.showsIndicator = true
        return item
    }

    // MARK: - Groups

    private var controller: WorkbookViewController? {
        (document?.windowControllers.first as? WorkbookWindowController)?.workbookViewController
    }

    @objc private func styleGroupChanged(_ group: NSToolbarItemGroup) {
        guard let controller, let document else { return }
        let style = document.state.representativeStyle(in: document.workbook)
        // The segment that changed is the one whose state differs from the cell's.
        let current = [style.isBold, style.isItalic, style.isUnderlined, style.isStruckThrough]
        for index in 0..<4 where group.isSelected(at: index) != current[index] {
            switch index {
            case 0: controller.toggleBold(group)
            case 1: controller.toggleItalic(group)
            case 2: controller.toggleUnderline(group)
            default: controller.toggleStrikethrough(group)
            }
        }
    }

    @objc private func alignmentGroupChanged(_ group: NSToolbarItemGroup) {
        let alignments: [HorizontalTextAlignment] = [.leading, .center, .trailing]
        guard let controller, group.selectedIndex >= 0, group.selectedIndex < alignments.count else { return }
        let item = NSMenuItem()
        item.representedObject = alignments[group.selectedIndex].rawValue
        controller.alignHorizontally(item)
    }

    /// Shows the selected cell's styles in the groups.
    func refresh() {
        guard let document else { return }
        let style = document.state.representativeStyle(in: document.workbook)
        let enabled = document.state.formatting.contains(.styles) && !document.activeSheet.isChartSheet
        if let styleGroup {
            for (index, on) in [style.isBold, style.isItalic, style.isUnderlined, style.isStruckThrough].enumerated() {
                styleGroup.setSelected(on, at: index)
            }
            styleGroup.isEnabled = enabled
        }
        if let alignmentGroup {
            let natural = style.horizontalAlignment == .automatic
                ? CellFormatter.naturalAlignment(for: document.activeSheet[document.state.selectedAddress].value)
                : style.horizontalAlignment
            let index: Int
            switch natural {
            case .center: index = 1
            case .trailing: index = 2
            default: index = 0
            }
            alignmentGroup.selectedIndex = index
            alignmentGroup.isEnabled = enabled
        }
        if let warning = toolbar.items.first(where: { $0.itemIdentifier == Item.unsupported }) {
            warning.isHidden = document.unsupportedFeatures.isEmpty
        }
        // Tools for formatting the document has nowhere to keep — any, in
        // delimited text — are left out rather than shown switched off.
        let kept = document.state.formatting
        for item in toolbar.items {
            switch item.itemIdentifier {
            case Item.style, Item.alignment, Item.fill, Item.textColor: item.isHidden = !kept.contains(.styles)
            case Item.numberFormat: item.isHidden = !kept.contains(.numberFormats)
            case Item.borders: item.isHidden = !kept.contains(.borders)
            case Item.merge: item.isHidden = !kept.contains(.merging)
            case Item.chart: item.isHidden = document.isPlainText || document.isNumbers
            default: break
            }
        }
    }
}
