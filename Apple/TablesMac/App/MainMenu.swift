import AppKit
import TablesEngine

/// The menu bar, built in code so every item is in one place alongside the
/// action it sends. Items send their actions up the responder chain, where
/// the workbook window's controller answers for the sheet in front.
@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(submenu(appMenu()))
        menu.addItem(submenu(fileMenu()))
        menu.addItem(submenu(editMenu()))
        menu.addItem(submenu(insertMenu()))
        menu.addItem(submenu(formatMenu()))
        menu.addItem(submenu(tableMenu()))
        menu.addItem(submenu(viewMenu()))
        menu.addItem(submenu(toolsMenu()))
        let window = windowMenu()
        menu.addItem(submenu(window))
        NSApp.windowsMenu = window
        let help = helpMenu()
        menu.addItem(submenu(help))
        NSApp.helpMenu = help
        return menu
    }

    // MARK: - Menus

    private static func appMenu() -> NSMenu {
        let name = ProcessInfo.processInfo.processName
        let menu = NSMenu(title: name)
        menu.addItem(item(String(format: String(localized: "Mac.Menu.About"), name),
                          #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())
        let services = NSMenu(title: String(localized: "Mac.Menu.Services"))
        NSApp.servicesMenu = services
        menu.addItem(submenu(services))
        menu.addItem(.separator())
        menu.addItem(item(String(format: String(localized: "Mac.Menu.Hide"), name),
                          #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item(String(localized: "Mac.Menu.HideOthers"),
                          #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item(String(localized: "Mac.Menu.ShowAll"), #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(format: String(localized: "Mac.Menu.Quit"), name),
                          #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Mac.Menu.File"))
        menu.addItem(item(String(localized: "Mac.Menu.New"), #selector(NSDocumentController.newDocument(_:)), "n"))
        menu.addItem(item(String(localized: "Mac.Menu.Open"), #selector(NSDocumentController.openDocument(_:)), "o"))
        // The document controller fills in whichever menu holds Clear Menu.
        let recent = NSMenu(title: String(localized: "Mac.Menu.OpenRecent"))
        recent.addItem(item(String(localized: "Mac.Menu.ClearRecent"),
                            #selector(NSDocumentController.clearRecentDocuments(_:))))
        menu.addItem(submenu(recent))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Mac.Menu.Close"), #selector(NSWindow.performClose(_:)), "w"))
        menu.addItem(item(String(localized: "Mac.Menu.Save"), #selector(NSDocument.save(_:)), "s"))
        menu.addItem(item(String(localized: "Mac.Menu.Duplicate"), #selector(NSDocument.duplicate(_:)),
                          "s", [.command, .shift]))
        menu.addItem(item(String(localized: "Mac.Menu.Rename"), #selector(NSDocument.rename(_:))))
        menu.addItem(item(String(localized: "Mac.Menu.MoveTo"), #selector(NSDocument.move(_:))))
        menu.addItem(item(String(localized: "Mac.Menu.RevertTo"), #selector(NSDocument.revertToSaved(_:))))
        menu.addItem(.separator())
        let export = NSMenu(title: String(localized: "Mac.Menu.ExportTo"))
        export.addItem(item(String(localized: "Mac.Menu.Export.Workbook"),
                            #selector(WorkbookDocument.exportAsWorkbook(_:))))
        export.addItem(item(String(localized: "Mac.Menu.Export.CSV"), #selector(WorkbookDocument.exportAsCSV(_:))))
        export.addItem(item(String(localized: "Mac.Menu.Export.TSV"), #selector(WorkbookDocument.exportAsTSV(_:))))
        menu.addItem(submenu(export))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Mac.Menu.PageSetup"), #selector(NSDocument.runPageLayout(_:)),
                          "p", [.command, .shift]))
        menu.addItem(item(String(localized: "Mac.Menu.Print"), #selector(NSDocument.printDocument(_:)), "p"))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Mac.Menu.Edit"))
        menu.addItem(item(String(localized: "Toolbar.Undo"), Selector(("undo:")), "z"))
        menu.addItem(item(String(localized: "Toolbar.Redo"), Selector(("redo:")), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "CellMenu.Cut"), #selector(NSText.cut(_:)), "x"))
        menu.addItem(item(String(localized: "CellMenu.Copy"), #selector(NSText.copy(_:)), "c"))
        menu.addItem(item(String(localized: "CellMenu.Paste"), #selector(NSText.paste(_:)), "v"))
        menu.addItem(item(String(localized: "Mac.Menu.Delete"), #selector(NSText.delete(_:))))
        menu.addItem(item(String(localized: "Mac.Menu.SelectAll"), #selector(NSText.selectAll(_:)), "a"))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Mac.Menu.ClearContents"),
                          #selector(WorkbookViewController.clearContents(_:))))
        menu.addItem(.separator())
        let find = NSMenu(title: String(localized: "Toolbar.Find"))
        find.addItem(findItem(String(localized: "Mac.Menu.Find"), .showFindPanel, "f"))
        find.addItem(findItem(String(localized: "Mac.Menu.FindNext"), .next, "g"))
        find.addItem(findItem(String(localized: "Mac.Menu.FindPrevious"), .previous, "g", [.command, .shift]))
        find.addItem(findItem(String(localized: "Mac.Menu.UseSelectionForFind"), .setFindString, "e"))
        menu.addItem(submenu(find))
        return menu
    }

    private static func insertMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Mac.Menu.Insert"))
        menu.addItem(item(String(localized: "HeaderMenu.Row.InsertAbove"),
                          #selector(WorkbookViewController.insertRowsAbove(_:))))
        menu.addItem(item(String(localized: "HeaderMenu.Row.InsertBelow"),
                          #selector(WorkbookViewController.insertRowsBelow(_:))))
        menu.addItem(item(String(localized: "HeaderMenu.Row.AddAtEnd"),
                          #selector(WorkbookViewController.addRowAtEnd(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "HeaderMenu.Column.InsertBefore"),
                          #selector(WorkbookViewController.insertColumnsBefore(_:))))
        menu.addItem(item(String(localized: "HeaderMenu.Column.InsertAfter"),
                          #selector(WorkbookViewController.insertColumnsAfter(_:))))
        menu.addItem(item(String(localized: "HeaderMenu.Column.AddAtEnd"),
                          #selector(WorkbookViewController.addColumnAtEnd(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Mac.Menu.NewSheet"), #selector(WorkbookViewController.newSheet(_:)),
                          "t", [.command, .shift]))
        menu.addItem(item(String(localized: "Canvas.NewTable"), #selector(WorkbookViewController.newTable(_:)),
                          "t", [.command, .option]))
        let charts = NSMenu(title: String(localized: "Toolbar.InsertChart"))
        for kind in ChartKind.allCases {
            let entry = item(kind.label, #selector(WorkbookViewController.insertChart(_:)))
            entry.representedObject = kind.rawValue
            entry.image = NSImage(systemSymbolName: kind.symbolName, accessibilityDescription: nil)
            charts.addItem(entry)
        }
        menu.addItem(submenu(charts))
        menu.addItem(item(String(localized: "Toolbar.EditChart"), #selector(WorkbookViewController.editChart(_:))))
        let functions = NSMenu(title: String(localized: "Toolbar.InsertFunction"))
        for name in ["SUM", "AVERAGE", "COUNT", "MIN", "MAX"] {
            let entry = item(name, #selector(WorkbookViewController.insertFunction(_:)))
            entry.representedObject = name
            functions.addItem(entry)
        }
        menu.addItem(submenu(functions))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "CellMenu.NewComment"), #selector(WorkbookViewController.newComment(_:)),
                          "m", [.command, .option]))
        menu.addItem(item(String(localized: "CellMenu.NewNote"), #selector(WorkbookViewController.newNote(_:))))
        return menu
    }

    private static func formatMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Mac.Menu.Format"))
        let font = NSMenu(title: String(localized: "Mac.Menu.Font"))
        font.addItem(item(String(localized: "Toolbar.Bold"), #selector(WorkbookViewController.toggleBold(_:)), "b"))
        font.addItem(item(String(localized: "Toolbar.Italic"), #selector(WorkbookViewController.toggleItalic(_:)), "i"))
        font.addItem(item(String(localized: "Toolbar.Underline"),
                          #selector(WorkbookViewController.toggleUnderline(_:)), "u"))
        font.addItem(item(String(localized: "Mac.Toolbar.Strikethrough"),
                          #selector(WorkbookViewController.toggleStrikethrough(_:)), "x", [.command, .shift]))
        font.addItem(.separator())
        font.addItem(item(String(localized: "Mac.Menu.Bigger"), #selector(WorkbookViewController.increaseFontSize(_:)),
                          "+"))
        font.addItem(item(String(localized: "Mac.Menu.Smaller"),
                          #selector(WorkbookViewController.decreaseFontSize(_:)), "-"))
        font.addItem(.separator())
        font.addItem(item(String(localized: "Mac.Menu.TextColor"),
                          #selector(WorkbookViewController.orderFrontTextColorPanel(_:)), "c", [.command, .shift]))
        menu.addItem(submenu(font))

        let alignment = NSMenu(title: String(localized: "Mac.Menu.Alignment"))
        alignment.addItem(alignmentItem(.leading, "{"))
        alignment.addItem(alignmentItem(.center, "|"))
        alignment.addItem(alignmentItem(.trailing, "}"))
        alignment.addItem(alignmentItem(.automatic, nil))
        alignment.addItem(.separator())
        for vertical in VerticalTextAlignment.allCases {
            let entry = item(vertical.label, #selector(WorkbookViewController.alignVertically(_:)))
            entry.representedObject = vertical.rawValue
            alignment.addItem(entry)
        }
        alignment.addItem(.separator())
        alignment.addItem(item(String(localized: "Format.Alignment.WrapText"), #selector(WorkbookViewController.toggleWrapText(_:))))
        alignment.addItem(item(String(localized: "Mac.Menu.IncreaseIndent"),
                               #selector(WorkbookViewController.increaseIndent(_:)), "]"))
        alignment.addItem(item(String(localized: "Mac.Menu.DecreaseIndent"),
                               #selector(WorkbookViewController.decreaseIndent(_:)), "["))
        menu.addItem(submenu(alignment))

        let numbers = NSMenu(title: String(localized: "Toolbar.NumberFormat"))
        for preset in NumberFormatPreset.allCases {
            let entry = item(preset.label, #selector(WorkbookViewController.setNumberFormat(_:)))
            entry.representedObject = preset.rawValue
            numbers.addItem(entry)
        }
        menu.addItem(submenu(numbers))

        menu.addItem(submenu(bordersMenu()))
        menu.addItem(item(String(localized: "Mac.Menu.FillColor"),
                          #selector(WorkbookViewController.orderFrontFillColorPanel(_:))))
        menu.addItem(item(String(localized: "Mac.Menu.NoFill"), #selector(WorkbookViewController.removeFill(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Format.Merge.Merge"), #selector(WorkbookViewController.mergeCells(_:))))
        menu.addItem(item(String(localized: "Format.Merge.Unmerge"), #selector(WorkbookViewController.unmergeCells(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "CellMenu.ResetFormatting"),
                          #selector(WorkbookViewController.clearFormatting(_:))))
        return menu
    }

    static func bordersMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Mac.Menu.Borders"))
        for preset in BorderPreset.allCases {
            let entry = item(preset.title, #selector(WorkbookViewController.applyBorders(_:)))
            entry.tag = preset.rawValue
            entry.image = NSImage(systemSymbolName: preset.symbolName, accessibilityDescription: nil)
            menu.addItem(entry)
        }
        return menu
    }

    private static func tableMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Mac.Menu.Table"))
        menu.addItem(item(String(localized: "HeaderMenu.Row.Delete"), #selector(WorkbookViewController.deleteRows(_:)),
                          "-", [.command, .option]))
        menu.addItem(item(String(localized: "HeaderMenu.Column.Delete"),
                          #selector(WorkbookViewController.deleteColumns(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "HeaderMenu.Row.Hide"), #selector(WorkbookViewController.hideRows(_:))))
        menu.addItem(item(String(localized: "HeaderMenu.Column.Hide"), #selector(WorkbookViewController.hideColumns(_:))))
        menu.addItem(item(String(localized: "Mac.Menu.UnhideAll"), #selector(WorkbookViewController.unhideAll(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "HeaderMenu.Column.FitToContents"),
                          #selector(WorkbookViewController.fitColumnWidth(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "SheetTabBar.Menu.Rename"), #selector(WorkbookViewController.renameSheet(_:))))
        menu.addItem(item(String(localized: "SheetTabBar.Menu.Duplicate"),
                          #selector(WorkbookViewController.duplicateSheet(_:))))
        menu.addItem(item(String(localized: "SheetTabBar.Menu.Hide"), #selector(WorkbookViewController.hideSheet(_:))))
        menu.addItem(item(String(localized: "SheetTabBar.Menu.Delete"), #selector(WorkbookViewController.deleteSheet(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Canvas.ShowTableName"), #selector(WorkbookViewController.toggleTableName(_:))))
        menu.addItem(item(String(localized: "Canvas.MoveToOwnSheet"),
                          #selector(WorkbookViewController.moveTableToOwnSheet(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Mac.Menu.PreviousSheet"),
                          #selector(WorkbookViewController.selectPreviousSheet(_:)), "{", [.command, .option]))
        menu.addItem(item(String(localized: "Mac.Menu.NextSheet"),
                          #selector(WorkbookViewController.selectNextSheet(_:)), "}", [.command, .option]))
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Mac.Menu.View"))
        menu.addItem(item(String(localized: "Mac.Menu.ZoomIn"), #selector(WorkbookViewController.zoomIn(_:)), ">"))
        menu.addItem(item(String(localized: "Mac.Menu.ZoomOut"), #selector(WorkbookViewController.zoomOut(_:)), "<"))
        menu.addItem(item(String(localized: "Mac.Menu.ActualSize"), #selector(WorkbookViewController.actualSize(_:)),
                          "0"))
        menu.addItem(.separator())
        let freeze = NSMenu(title: String(localized: "Mac.Menu.FreezePanes"))
        freeze.addItem(item(String(localized: "Mac.Menu.FreezeTopRow"), #selector(WorkbookViewController.freezeTopRow(_:))))
        freeze.addItem(item(String(localized: "Mac.Menu.FreezeFirstColumn"),
                            #selector(WorkbookViewController.freezeFirstColumn(_:))))
        freeze.addItem(item(String(localized: "Mac.Menu.FreezeAtSelection"),
                            #selector(WorkbookViewController.freezePanesAtSelection(_:))))
        freeze.addItem(.separator())
        freeze.addItem(item(String(localized: "Mac.Menu.Unfreeze"), #selector(WorkbookViewController.unfreezePanes(_:))))
        menu.addItem(submenu(freeze))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Mac.Menu.ShowInspector"), #selector(NSSplitViewController.toggleInspector(_:)),
                          "i", [.command, .option]))
        menu.addItem(item(String(localized: "Mac.Menu.ShowToolbar"), #selector(NSWindow.toggleToolbarShown(_:)),
                          "t", [.command, .option]))
        menu.addItem(item(String(localized: "Mac.Menu.CustomizeToolbar"),
                          #selector(NSWindow.runToolbarCustomizationPalette(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Mac.Menu.EnterFullScreen"), #selector(NSWindow.toggleFullScreen(_:)),
                          "f", [.command, .control]))
        return menu
    }

    private static func toolsMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Mac.Menu.Tools"))
        menu.addItem(item(String(localized: "Toolbar.Macros"), #selector(WorkbookViewController.showMacros(_:)),
                          "m", [.command, .shift]))
        menu.addItem(item(String(localized: "Toolbar.UnsupportedFeatures.Label"),
                          #selector(WorkbookViewController.showUnsupportedFeatures(_:))))
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Mac.Menu.Window"))
        menu.addItem(item(String(localized: "Mac.Menu.Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item(String(localized: "Mac.Menu.Zoom"), #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Mac.Menu.BringAllToFront"),
                          #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }

    private static func helpMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Mac.Menu.Help"))
        menu.addItem(item(String(localized: "FunctionReference.Title"), #selector(AppDelegate.showFunctionReference(_:))))
        menu.addItem(item(String(localized: "Help.Title"), #selector(AppDelegate.showMacroHelp(_:))))
        return menu
    }

    // MARK: - Items

    static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    static func item(
        _ title: String, _ action: Selector?, _ key: String = "",
        _ modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty { item.keyEquivalentModifierMask = modifiers }
        return item
    }

    private static func findItem(
        _ title: String, _ action: NSFindPanelAction, _ key: String,
        _ modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = item(title, #selector(WorkbookViewController.performFindPanelAction(_:)), key, modifiers)
        item.tag = Int(action.rawValue)
        return item
    }

    private static func alignmentItem(_ alignment: HorizontalTextAlignment, _ key: String?) -> NSMenuItem {
        let entry = item(alignment.label, #selector(WorkbookViewController.alignHorizontally(_:)), key ?? "")
        entry.representedObject = alignment.rawValue
        return entry
    }
}
