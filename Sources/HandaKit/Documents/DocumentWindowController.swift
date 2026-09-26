import AppKit
import HandaCore

extension NSToolbarItem.Identifier {
    static let handaMode = NSToolbarItem.Identifier("handa.mode")
    static let handaEdit = NSToolbarItem.Identifier("handa.edit")
    static let handaSearch = NSToolbarItem.Identifier("handa.search")
    static let handaShare = NSToolbarItem.Identifier("handa.share")
    static let handaReview = NSToolbarItem.Identifier("handa.review")
    static let handaReviews = NSToolbarItem.Identifier("handa.reviews")
    static let handaThumbnails = NSToolbarItem.Identifier("handa.thumbnails")
}

/// One window per document: toolbar, the current viewer, a status bar and the optional review panel.
final class DocumentWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation,
                                      NSToolbarItemValidation, NSSearchFieldDelegate, NSSharingServicePickerToolbarItemDelegate {
    // Strong on purpose: the document drops its window controllers when it closes.
    private let handaDocument: Document
    private(set) var viewer: Viewer
    private(set) var mode: ViewMode
    private(set) var isEditingEnabled = false
    private let container = ContainerViewController()
    private let split = NSSplitViewController()
    private var reviewItem: NSSplitViewItem?
    private var reviewPanel: ReviewPanelController?
    private var autoSwitchedToSource = false
    private weak var editItem: NSToolbarItem?
    private weak var modeGroup: NSToolbarItemGroup?
    private weak var searchItem: NSSearchToolbarItem?
    private var preferenceObserver: NSObjectProtocol?
    private static var lastTopLeft: NSPoint?

    private var kind: DocumentKind { handaDocument.kind }
    private var modes: [ViewMode] { ViewMode.modes(for: kind) }

    init(document: Document) {
        handaDocument = document
        let modes = ViewMode.modes(for: document.kind)
        mode = Automation.initialMode.flatMap { modes.contains($0) ? $0 : nil } ?? .standard
        viewer = DocumentWindowController.makeViewer(for: document, mode: mode)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: true)
        window.toolbarStyle = .unified
        window.tabbingMode = .automatic
        window.tabbingIdentifier = "HandaDocument"
        window.minSize = NSSize(width: 460, height: 320)
        window.animationBehavior = .documentWindow
        window.isReleasedWhenClosed = false
        window.subtitle = document.kind.displayName
        super.init(window: window)

        window.delegate = self
        split.splitView.dividerStyle = .thin
        let main = NSSplitViewItem(viewController: container)
        main.minimumThickness = 360
        split.addSplitViewItem(main)
        window.contentViewController = split

        let toolbar = NSToolbar(identifier: "HandaDocumentToolbar.\(document.kind.category.rawValue)")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        installViewer(viewer)
        window.setContentSize(defaultContentSize())
        position(window)

        preferenceObserver = NotificationCenter.default.addObserver(forName: .handaPreferencesChanged, object: nil, queue: .main) { [weak self] _ in
            self?.preferencesChanged()
        }
        if Preferences.openInEditMode || Automation.startEditing, document.supportsEditing {
            setEditing(true, confirmed: true)
        }
        if Automation.showReviews { toggleReviews(nil) }
        if Automation.showSidebar, viewer.supportsSidebar { viewer.toggleSidebar() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        if let observer = preferenceObserver { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: Viewers

    static func makeViewer(for document: Document, mode: ViewMode) -> Viewer {
        switch (document.content, mode) {
        case (.text, .quickLook), (.richText, .quickLook):
            return QuickLookViewer(document: document)
        case (.text(let text), _):
            let readOnly = document.readOnlyReason != nil
            return TextViewer(document: document, content: text, language: document.kind.language, readOnly: readOnly)
        case (.markdown(let text), .source):
            return TextViewer(document: document, content: text, language: .markdown)
        case (.markdown(let text), _):
            return MarkdownViewer(document: document, content: text)
        case (.table(let table), .source):
            return TextViewer(document: document, content: TextContent(text: table.textForDisplay), language: nil, readOnly: true)
        case (.table(let table), _):
            return TableViewer(document: document, content: table)
        case (.richText(let rich), _):
            return RichTextViewer(document: document, content: rich)
        case (.pdf(let pdf), _):
            return PDFViewer(document: document, pdf: pdf)
        case (.image(let info), _):
            return ImageViewer(document: document, info: info)
        case (.quickLook, _):
            return QuickLookViewer(document: document)
        case (.binary(let data), _):
            return HexViewer(document: document, data: data)
        }
    }

    private func installViewer(_ newViewer: Viewer) {
        if newViewer !== viewer { viewer.tearDown() }
        viewer = newViewer
        newViewer.onStatusChange = { [weak self] in self?.updateStatus() }
        container.show(newViewer)
        container.setBanner(handaDocument.readOnlyReason)
        newViewer.setEditing(isEditingEnabled && newViewer.supportsEditing)
        if let responder = newViewer.preferredFirstResponder { window?.makeFirstResponder(responder) }
        updateStatus()
        window?.toolbar?.validateVisibleItems()
    }

    func setMode(_ newMode: ViewMode) {
        guard newMode != mode, modes.contains(newMode) else { return }
        viewer.finishEditing()
        if newMode == .quickLook, isEditingEnabled { setEditing(false) }
        mode = newMode
        installViewer(DocumentWindowController.makeViewer(for: handaDocument, mode: newMode))
        modeGroup?.selectedIndex = modes.firstIndex(of: newMode) ?? 0
    }

    /// Called after the file was reloaded from disk or reverted.
    func documentDidReload() {
        if !handaDocument.supportsEditing { isEditingEnabled = false }
        if !modes.contains(mode) { mode = .standard }
        window?.subtitle = kind.displayName
        installViewer(DocumentWindowController.makeViewer(for: handaDocument, mode: mode))
        reviewPanel?.reload()
    }

    /// Something about the document changed that affects the toolbar (loading finished, PDF unlocked…).
    func documentStateChanged() {
        viewer.setEditing(isEditingEnabled && viewer.supportsEditing)
        container.setBanner(handaDocument.readOnlyReason)
        updateStatus()
        window?.toolbar?.validateVisibleItems()
    }

    func finishEditing() { viewer.finishEditing() }

    // MARK: Editing

    @objc func toggleEditing(_ sender: Any?) {
        setEditing(!isEditingEnabled)
    }

    func setEditing(_ editing: Bool, confirmed: Bool = false) {
        guard editing != isEditingEnabled else { return }
        if editing {
            guard handaDocument.supportsEditing else { NSSound.beep(); return }
            if !confirmed, case .richText(let rich) = handaDocument.content, rich.format.savingMaySimplify,
               !UserDefaults.standard.bool(forKey: "SkipSimplifyWarning"), let window = window {
                let alert = NSAlert()
                alert.messageText = "Edit this \(rich.format.displayName)?"
                alert.informativeText = "Handa keeps your text, formatting, lists and tables when it saves. Comments, tracked changes, headers and some layout details may be simplified. Nothing changes on disk until you save."
                alert.addButton(withTitle: "Edit")
                alert.addButton(withTitle: "Cancel")
                alert.showsSuppressionButton = true
                alert.beginSheetModal(for: window) { [weak self] response in
                    if alert.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: "SkipSimplifyWarning") }
                    if response == .alertFirstButtonReturn { self?.setEditing(true, confirmed: true) }
                }
                return
            }
            if kind.category == .markdown, mode == .standard {
                autoSwitchedToSource = true
                isEditingEnabled = true
                setMode(.source)
            } else if mode == .quickLook || (kind.category == .table && mode == .source) {
                isEditingEnabled = true
                setMode(.standard)
            }
        }
        isEditingEnabled = editing
        viewer.setEditing(editing)
        if !editing, autoSwitchedToSource {
            autoSwitchedToSource = false
            setMode(.standard)
        }
        updateEditItem()
        updateStatus()
    }

    private func updateEditItem() {
        guard let item = editItem else { return }
        item.label = isEditingEnabled ? "Done" : "Edit"
        item.image = NSImage(systemSymbolName: isEditingEnabled ? "checkmark.circle.fill" : "pencil", accessibilityDescription: item.label)
        item.toolTip = isEditingEnabled ? "Stop editing (⇧⌘E)" : "Edit this file (⇧⌘E)"
    }

    // MARK: Status

    func updateStatus() {
        container.statusBar.setLeft(viewer.statusText)
        if handaDocument.readOnlyReason != nil {
            container.statusBar.setRight("Read only", highlighted: false)
        } else if isEditingEnabled {
            container.statusBar.setRight(handaDocument.isDocumentEdited ? "Editing · Unsaved changes" : "Editing", highlighted: true)
        } else {
            container.statusBar.setRight(handaDocument.supportsEditing ? "Preview · ⇧⌘E to edit" : "Preview", highlighted: false)
        }
    }

    private var lastEditedState = false

    func windowDidUpdate(_ notification: Notification) {
        // Runs often, so only refresh when the edited flag actually flips.
        let edited = handaDocument.isDocumentEdited
        if edited != lastEditedState {
            lastEditedState = edited
            updateStatus()
        }
    }

    // MARK: Window

    private func defaultContentSize() -> NSSize {
        if let size = Automation.windowSize { return size }
        let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        var size: NSSize
        switch kind.category {
        case .pdf, .richText: size = NSSize(width: 860, height: screen.height * 0.88)
        case .table: size = NSSize(width: 1120, height: 720)
        case .image:
            if case .image(let info) = handaDocument.content {
                let scale = min(1, min(screen.width * 0.8 / CGFloat(info.width), screen.height * 0.8 / CGFloat(info.height)))
                size = NSSize(width: max(520, CGFloat(info.width) * scale), height: max(400, CGFloat(info.height) * scale + 30))
            } else {
                size = NSSize(width: 900, height: 700)
            }
        case .binary: size = NSSize(width: 820, height: 640)
        case .quickLook: size = NSSize(width: 980, height: 720)
        default: size = NSSize(width: 920, height: 760)
        }
        return NSSize(width: min(size.width, screen.width - 40), height: min(size.height, screen.height - 20))
    }

    private func position(_ window: NSWindow) {
        if let last = DocumentWindowController.lastTopLeft,
           NSApp.windows.contains(where: { $0.isVisible && $0.windowController is DocumentWindowController }) {
            DocumentWindowController.lastTopLeft = window.cascadeTopLeft(from: last)
        } else {
            window.center()
            DocumentWindowController.lastTopLeft = window.cascadeTopLeft(from: NSPoint(x: window.frame.minX, y: window.frame.maxY))
        }
    }

    override func showWindow(_ sender: Any?) {
        let firstShow = !(window?.isVisible ?? false)
        super.showWindow(sender)
        guard firstShow, let window = window else { return }
        if let responder = viewer.preferredFirstResponder { window.makeFirstResponder(responder) }
        if let query = Automation.searchText {
            searchItem?.searchField.stringValue = query
            viewer.search(query)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let window = self.window else { return }
            window.displayIfNeeded()
            Automation.windowReady(window, kind: self.kind.category.rawValue, file: self.handaDocument.fileURL?.path)
            ReviewCoordinator.shared.documentOpened(self.handaDocument)
            SessionPublisher.shared.update()
        }
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        handaDocument.undoManager
    }

    func windowDidBecomeKey(_ notification: Notification) {
        SessionPublisher.shared.update()
    }

    func windowWillClose(_ notification: Notification) {
        viewer.tearDown()
        DispatchQueue.main.async { SessionPublisher.shared.update() }
    }

    /// Esc closes a preview, the way Quick Look does. Returns true when it handled the key.
    func handleEscape() -> Bool {
        guard let window = window, window.attachedSheet == nil else { return false }
        if let text = window.firstResponder as? NSTextView, text.isEditable { return false }
        if isEditingEnabled { return false }
        if let scrollView = findScrollView(in: viewer.view), scrollView.isFindBarVisible {
            scrollView.isFindBarVisible = false
            return true
        }
        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
            return true
        }
        guard Preferences.escClosesPreview, !handaDocument.isDocumentEdited else { return false }
        window.performClose(nil)
        return true
    }

    private func findScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        for subview in view.subviews {
            if let found = findScrollView(in: subview) { return found }
        }
        return nil
    }

    // MARK: Actions

    @objc func selectViewMode(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, modes.indices.contains(item.tag) else { return }
        setMode(modes[item.tag])
    }

    @objc private func modeChanged(_ sender: NSToolbarItemGroup) {
        guard modes.indices.contains(sender.selectedIndex) else { return }
        setMode(modes[sender.selectedIndex])
    }

    @objc func toggleThumbnails(_ sender: Any?) {
        viewer.toggleSidebar()
    }

    @objc func showInFinder(_ sender: Any?) {
        guard let url = handaDocument.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc func goToNextFile(_ sender: Any?) { goToSibling(offset: 1) }
    @objc func goToPreviousFile(_ sender: Any?) { goToSibling(offset: -1) }

    private func goToSibling(offset: Int) {
        guard let url = handaDocument.fileURL, let target = FolderNavigator.sibling(of: url, offset: offset) else {
            NSSound.beep()
            return
        }
        let frame = window?.frame
        let oldWindow = window
        let oldDocument = handaDocument
        NSDocumentController.shared.openDocument(withContentsOf: target, display: false) { document, alreadyOpen, error in
            guard let document = document as? Document else {
                if let error = error { NSApp.presentError(error) }
                return
            }
            if document.windowControllers.isEmpty { document.makeWindowControllers() }
            if !alreadyOpen, let newWindow = document.windowController?.window, let frame = frame {
                newWindow.setFrame(frame, display: false)
                if let oldWindow = oldWindow, (oldWindow.tabbedWindows?.count ?? 0) > 1 {
                    oldWindow.addTabbedWindow(newWindow, ordered: .above)
                }
            }
            document.showWindows()
            if !alreadyOpen, !oldDocument.isDocumentEdited { oldDocument.close() }
        }
    }

    @objc func searchInDocument(_ sender: Any?) {
        guard viewer.supportsSearch, let item = searchItem else { return }
        window?.makeFirstResponder(item.searchField)
    }

    /// ⌘F, ⌘G and ⇧⌘G for viewers that search through the toolbar (tables and PDFs).
    /// Text views handle these themselves before the action gets here.
    override func performTextFinderAction(_ sender: Any?) {
        let tag = (sender as? NSMenuItem)?.tag ?? NSTextFinder.Action.showFindInterface.rawValue
        switch NSTextFinder.Action(rawValue: tag) {
        case .nextMatch?: viewer.searchNext(backwards: false)
        case .previousMatch?: viewer.searchNext(backwards: true)
        default: searchInDocument(sender)
        }
    }

    @objc private func searchFieldChanged(_ sender: NSSearchField) {
        viewer.search(sender.stringValue)
    }

    @objc func toggleReviews(_ sender: Any?) {
        guard Preferences.aiEnabled || Automation.showReviews else { return }
        if reviewItem == nil {
            let panel = ReviewPanelController(document: handaDocument)
            let item = NSSplitViewItem(inspectorWithViewController: panel)
            item.minimumThickness = 280
            item.maximumThickness = 520
            item.canCollapse = true
            item.isCollapsed = true
            split.addSplitViewItem(item)
            reviewItem = item
            reviewPanel = panel
        }
        reviewItem?.animator().isCollapsed.toggle()
    }

    @objc func reviewWithAI(_ sender: Any?) {
        if reviewItem?.isCollapsed ?? true { toggleReviews(nil) }
        ReviewCoordinator.shared.review(handaDocument, instruction: nil, automatic: false)
    }

    private func preferencesChanged() {
        guard let toolbar = window?.toolbar else { return }
        let wanted = Preferences.aiEnabled
        let has = toolbar.items.contains { $0.itemIdentifier == .handaReview }
        if wanted != has {
            if wanted {
                let index = max(0, toolbar.items.count - 1)
                toolbar.insertItem(withItemIdentifier: .handaReviews, at: index)
                toolbar.insertItem(withItemIdentifier: .handaReview, at: index)
            } else {
                for identifier in [NSToolbarItem.Identifier.handaReview, .handaReviews] {
                    if let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == identifier }) { toolbar.removeItem(at: index) }
                }
                if let item = reviewItem, !item.isCollapsed { item.isCollapsed = true }
            }
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleEditing(_:)):
            menuItem.title = isEditingEnabled ? "Stop Editing" : "Edit Document"
            return handaDocument.supportsEditing
        case #selector(selectViewMode(_:)):
            let available = modes.indices.contains(menuItem.tag) && modes.count > 1
            menuItem.isHidden = !available
            if available {
                menuItem.title = modes[menuItem.tag].title(for: kind)
                menuItem.state = modes[menuItem.tag] == mode ? .on : .off
            }
            return available
        case #selector(toggleThumbnails(_:)):
            menuItem.state = (viewer as? PDFViewer)?.isSidebarVisible == true ? .on : .off
            return viewer.supportsSidebar
        case #selector(toggleReviews(_:)):
            menuItem.title = (reviewItem?.isCollapsed ?? true) ? "Show Reviews" : "Hide Reviews"
            return Preferences.aiEnabled
        case #selector(reviewWithAI(_:)):
            return Preferences.aiEnabled && handaDocument.fileURL != nil
        case #selector(searchInDocument(_:)), #selector(performTextFinderAction(_:)):
            return viewer.supportsSearch
        case #selector(goToNextFile(_:)), #selector(goToPreviousFile(_:)), #selector(showInFinder(_:)):
            return handaDocument.fileURL != nil
        default:
            return true
        }
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case .handaEdit: return handaDocument.supportsEditing
        case .handaSearch: return viewer.supportsSearch
        case .handaThumbnails: return viewer.supportsSidebar
        default: return true
        }
    }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        var items: [NSToolbarItem.Identifier] = []
        if kind.category == .pdf { items.append(.handaThumbnails) }
        if modes.count > 1 { items.append(.handaMode) }
        items.append(.flexibleSpace)
        if kind.category == .table || kind.category == .pdf { items.append(.handaSearch) }
        if [.text, .markdown, .table, .richText, .pdf].contains(kind.category) { items.append(.handaEdit) }
        if Preferences.aiEnabled { items += [.handaReview, .handaReviews] }
        items.append(.handaShare)
        return items
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.handaThumbnails, .handaMode, .flexibleSpace, .space, .handaSearch, .handaEdit, .handaReview, .handaReviews, .handaShare]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch identifier {
        case .handaMode:
            let titles = modes.map { $0.title(for: kind) }
            let group = NSToolbarItemGroup(itemIdentifier: identifier, titles: titles, selectionMode: .selectOne,
                                           labels: titles, target: self, action: #selector(modeChanged(_:)))
            group.selectedIndex = modes.firstIndex(of: mode) ?? 0
            group.label = "View"
            modeGroup = group
            return group
        case .handaEdit:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.isBordered = true
            item.target = self
            item.action = #selector(toggleEditing(_:))
            editItem = item
            updateEditItem()
            return item
        case .handaSearch:
            let item = NSSearchToolbarItem(itemIdentifier: identifier)
            item.searchField.placeholderString = kind.category == .pdf ? "Search PDF" : "Filter rows"
            item.searchField.target = self
            item.searchField.action = #selector(searchFieldChanged(_:))
            item.searchField.sendsWholeSearchString = kind.category == .pdf
            item.searchField.delegate = self
            searchItem = item
            return item
        case .handaShare:
            let item = NSSharingServicePickerToolbarItem(itemIdentifier: identifier)
            item.delegate = self
            item.toolTip = "Share"
            return item
        case .handaReview:
            return button(identifier, label: "Review", symbol: "sparkles", tip: "Ask AI to review this file", action: #selector(reviewWithAI(_:)))
        case .handaReviews:
            return button(identifier, label: "Reviews", symbol: "sidebar.right", tip: "Show or hide reviews", action: #selector(toggleReviews(_:)))
        case .handaThumbnails:
            return button(identifier, label: "Pages", symbol: "sidebar.left", tip: "Show or hide page thumbnails", action: #selector(toggleThumbnails(_:)))
        default:
            return nil
        }
    }

    private func button(_ identifier: NSToolbarItem.Identifier, label: String, symbol: String, tip: String, action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.toolTip = tip
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.isBordered = true
        item.target = self
        item.action = action
        return item
    }

    func items(for pickerToolbarItem: NSSharingServicePickerToolbarItem) -> [Any] {
        handaDocument.fileURL.map { [$0] } ?? []
    }
}

/// Holds the viewer, an optional notice banner and the status bar.
final class ContainerViewController: NSViewController {
    let statusBar = StatusBar()
    private let banner = BannerView()
    private let stack = NSStackView()
    private weak var current: Viewer?

    override func loadView() {
        stack.orientation = .vertical
        stack.spacing = 0
        stack.distribution = .fill
        stack.alignment = .width
        stack.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        stack.addArrangedSubview(banner)
        stack.addArrangedSubview(statusBar)
        banner.isHidden = true
        view = stack
    }

    func show(_ viewer: Viewer) {
        _ = view
        if let current = current {
            current.view.removeFromSuperview()
            current.removeFromParent()
        }
        addChild(viewer)
        let content = viewer.view
        content.setContentHuggingPriority(.defaultLow, for: .vertical)
        content.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        stack.insertArrangedSubview(content, at: 1)
        current = viewer
    }

    func setBanner(_ text: String?) {
        _ = view
        banner.text = text ?? ""
        banner.isHidden = text == nil
    }
}

final class StatusBar: NSView {
    private let left = NSTextField(labelWithString: "")
    private let right = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 26).isActive = true
        let separator = NSBox()
        separator.boxType = .separator
        for label in [left, right] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        left.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        right.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)
        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            left.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            right.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            left.trailingAnchor.constraint(lessThanOrEqualTo: right.leadingAnchor, constant: -16),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }

    func setLeft(_ text: String) {
        if left.stringValue != text { left.stringValue = text }
    }

    func setRight(_ text: String, highlighted: Bool) {
        if right.stringValue != text { right.stringValue = text }
        right.textColor = highlighted ? Theme.accent : .secondaryLabelColor
        right.font = highlighted ? .systemFont(ofSize: 11, weight: .semibold) : .systemFont(ofSize: 11)
    }
}

final class BannerView: NSView {
    private let label = NSTextField(wrappingLabelWithString: "")

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.dynamic(light: Theme.hex(0xFFF1E0), dark: Theme.hex(0x3A2E22)).cgColor
        let icon = NSImageView(image: NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = Theme.accent
        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor
        let row = NSStackView(views: [icon, label])
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateLayer() {
        layer?.backgroundColor = Theme.dynamic(light: Theme.hex(0xFFF1E0), dark: Theme.hex(0x3A2E22)).cgColor
    }
}
