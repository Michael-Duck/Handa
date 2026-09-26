import AppKit

/// The menu bar, built in code so launching doesn't load any nib.
enum MainMenu {
    private static func item(_ title: String, _ action: Selector?, _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = .command, tag: Int = 0, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.tag = tag
        item.target = target
        return item
    }

    private static func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        return holder
    }

    static func build(appDelegate: AppDelegate) -> NSMenu {
        let main = NSMenu(title: "Main")
        let fonts = NSFontManager.shared

        // Handa
        let services = NSMenu(title: "Services")
        NSApp.servicesMenu = services
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        main.addItem(menu("Handa", [
            item("About Handa", #selector(AppDelegate.showAbout(_:)), target: appDelegate),
            .separator(),
            item("Settings…", #selector(AppDelegate.showSettings(_:)), ",", target: appDelegate),
            item("Make Handa the Default Viewer…", #selector(AppDelegate.showDefaultAppSettings(_:)), target: appDelegate),
            .separator(),
            servicesItem,
            .separator(),
            item("Hide Handa", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit Handa", #selector(NSApplication.terminate(_:)), "q"),
        ]))

        // File
        let recent = NSMenu(title: "Open Recent")
        _ = recent.perform(NSSelectorFromString("_setMenuName:"), with: "NSRecentDocumentsMenu")
        recent.addItem(item("Clear Menu", #selector(NSDocumentController.clearRecentDocuments(_:))))
        let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        recentItem.submenu = recent
        let openWith = NSMenu(title: "Open With")
        openWith.delegate = appDelegate
        let openWithItem = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        openWithItem.submenu = openWith
        main.addItem(menu("File", [
            item("Open…", #selector(NSDocumentController.openDocument(_:)), "o"),
            recentItem,
            item("Welcome to Handa", #selector(AppDelegate.showWelcome(_:)), "0", [.command, .shift], target: appDelegate),
            .separator(),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
            item("Save", #selector(NSDocument.save(_:)), "s"),
            item("Save As…", #selector(NSDocument.saveAs(_:)), "s", [.command, .shift]),
            item("Revert to Saved", #selector(NSDocument.revertToSaved(_:))),
            .separator(),
            item("Show in Finder", #selector(DocumentWindowController.showInFinder(_:)), "r", [.command, .option]),
            openWithItem,
            .separator(),
            item("Page Setup…", #selector(NSDocument.runPageLayout(_:)), "p", [.command, .shift]),
            item("Print…", #selector(NSDocument.printDocument(_:)), "p"),
        ]))

        // Edit
        main.addItem(menu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift]),
            item("Delete", #selector(NSText.delete(_:))),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            menu("Find", [
                item("Find…", #selector(NSResponder.performTextFinderAction(_:)), "f", tag: NSTextFinder.Action.showFindInterface.rawValue),
                item("Find Next", #selector(NSResponder.performTextFinderAction(_:)), "g", tag: NSTextFinder.Action.nextMatch.rawValue),
                item("Find Previous", #selector(NSResponder.performTextFinderAction(_:)), "g", [.command, .shift], tag: NSTextFinder.Action.previousMatch.rawValue),
                item("Use Selection for Find", #selector(NSResponder.performTextFinderAction(_:)), "e", tag: NSTextFinder.Action.setSearchString.rawValue),
                item("Jump to Selection", #selector(NSStandardKeyBindingResponding.centerSelectionInVisibleArea(_:)), "j"),
            ]),
            .separator(),
            item("Edit Document", #selector(DocumentWindowController.toggleEditing(_:)), "e", [.command, .shift]),
            item("Review with AI", #selector(DocumentWindowController.reviewWithAI(_:)), "r", [.command, .shift]),
        ]))

        // Format
        main.addItem(menu("Format", [
            menu("Font", [
                item("Show Fonts", #selector(NSFontManager.orderFrontFontPanel(_:)), "t", target: fonts),
                item("Bold", #selector(NSFontManager.addFontTrait(_:)), "b", tag: Int(NSFontTraitMask.boldFontMask.rawValue), target: fonts),
                item("Italic", #selector(NSFontManager.addFontTrait(_:)), "i", tag: Int(NSFontTraitMask.italicFontMask.rawValue), target: fonts),
                item("Underline", #selector(NSText.underline(_:)), "u"),
                .separator(),
                item("Bigger", #selector(NSFontManager.modifyFont(_:)), tag: Int(NSFontAction.sizeUpFontAction.rawValue), target: fonts),
                item("Smaller", #selector(NSFontManager.modifyFont(_:)), tag: Int(NSFontAction.sizeDownFontAction.rawValue), target: fonts),
                .separator(),
                item("Show Colors", #selector(NSApplication.orderFrontColorPanel(_:)), "c", [.command, .shift]),
            ]),
            menu("Text", [
                item("Align Left", #selector(NSText.alignLeft(_:)), "{"),
                item("Center", #selector(NSText.alignCenter(_:)), "|"),
                item("Justify", #selector(NSTextView.alignJustified(_:))),
                item("Align Right", #selector(NSText.alignRight(_:)), "}"),
                .separator(),
                item("Show Ruler", #selector(NSText.toggleRuler(_:))),
            ]),
            .separator(),
            menu("Table", [
                item("Add Row", #selector(TableViewer.addRow(_:)), "\r"),
                item("Add Column", #selector(TableViewer.addColumn(_:)), "\r", [.command, .option]),
                item("Delete Rows", #selector(TableViewer.deleteRows(_:)), "\u{8}"),
                item("Delete Column", #selector(TableViewer.deleteColumn(_:))),
                .separator(),
                item("First Row Is Header", #selector(TableViewer.toggleHeaderRow(_:))),
            ]),
            menu("Annotate", [
                item("Highlight", #selector(PDFViewer.highlightSelection(_:)), "h", [.command, .control]),
                item("Underline", #selector(PDFViewer.underlineSelection(_:)), "u", [.command, .control]),
                item("Strikethrough", #selector(PDFViewer.strikeOutSelection(_:)), "s", [.command, .control]),
                item("Add Note…", #selector(PDFViewer.addNote(_:)), "n", [.command, .control]),
                .separator(),
                item("Rotate Page Left", #selector(PDFViewer.rotatePageLeft(_:)), "l", [.command, .option]),
                item("Rotate Page Right", #selector(PDFViewer.rotatePageRight(_:)), "r", [.command, .control]),
                item("Delete Page", #selector(PDFViewer.deletePage(_:))),
            ]),
        ]))

        // View
        main.addItem(menu("View", [
            item("View Mode 1", #selector(DocumentWindowController.selectViewMode(_:)), "1", tag: 0),
            item("View Mode 2", #selector(DocumentWindowController.selectViewMode(_:)), "2", tag: 1),
            .separator(),
            item("Page Thumbnails", #selector(DocumentWindowController.toggleThumbnails(_:)), "2", [.command, .option]),
            item("Show Reviews", #selector(DocumentWindowController.toggleReviews(_:)), "0", [.command, .option]),
            .separator(),
            item("Wrap Lines", #selector(TextViewer.toggleWrapLines(_:))),
            item("Line Numbers", #selector(TextViewer.toggleLineNumbers(_:))),
            .separator(),
            item("Actual Size", #selector(Viewer.zoomToActualSize(_:)), "0"),
            item("Zoom In", #selector(Viewer.zoomIn(_:)), "+"),
            item("Zoom Out", #selector(Viewer.zoomOut(_:)), "-"),
            item("Zoom to Fit", #selector(Viewer.zoomToFit(_:)), "9"),
        ]))

        // Go
        main.addItem(menu("Go", [
            item("Next File in Folder", #selector(DocumentWindowController.goToNextFile(_:)), "]"),
            item("Previous File in Folder", #selector(DocumentWindowController.goToPreviousFile(_:)), "["),
            .separator(),
            item("Go To Line or Page…", #selector(TextViewer.goToLocation(_:)), "l"),
        ]))

        // Window
        let window = NSMenu(title: "Window")
        window.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        window.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        window.addItem(.separator())
        window.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.windowsMenu = window

        // Help
        let help = NSMenu(title: "Help")
        help.addItem(item("Handa Help", #selector(AppDelegate.openHelp(_:)), "?", target: appDelegate))
        help.addItem(item("Report an Issue…", #selector(AppDelegate.reportIssue(_:)), target: appDelegate))
        let helpItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        helpItem.submenu = help
        main.addItem(helpItem)
        NSApp.helpMenu = help

        return main
    }
}
