import AppKit
import HandaCore

/// The first thing people see: the brand, an Open button, recent files and a drop target.
final class WelcomeWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private var recent: [URL] = []
    private var tableView: NSTableView!
    private var emptyLabel: NSTextField!
    private var defaultCard: NSView!
    private var defaultLabel: NSTextField!
    private var defaultButtons: NSStackView!

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 470),
                              styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.title = "Welcome to Handa"
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        build()
    }

    override func showWindow(_ sender: Any?) {
        reloadRecent()
        updateDefaultCard()
        super.showWindow(sender)
        if let window = window {
            DispatchQueue.main.async { Automation.windowReady(window, kind: "welcome", file: nil) }
        }
    }

    private func build() {
        guard let window = window else { return }
        let root = DropView(frame: NSRect(x: 0, y: 0, width: 780, height: 470))
        root.onDrop = { [weak self] urls in self?.open(urls) }
        window.contentView = root

        // Brand column
        let brand = NSView()
        brand.wantsLayer = true
        brand.layer?.backgroundColor = Theme.paperTint.cgColor
        brand.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(brand)

        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 112).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 112).isActive = true

        let wordmark = NSTextField(labelWithString: "handa")
        wordmark.font = Theme.rounded(46, weight: .heavy)
        wordmark.textColor = Theme.dynamic(light: Theme.ink, dark: Theme.hex(0xFFF4EC))

        let slogan = NSTextField(wrappingLabelWithString: AppInfo.slogan)
        slogan.font = Theme.rounded(15, weight: .semibold)
        slogan.textColor = .secondaryLabelColor
        slogan.alignment = .center
        slogan.preferredMaxLayoutWidth = 240

        let open = NSButton(title: "Open a File…", target: self, action: #selector(openFile(_:)))
        open.bezelStyle = .rounded
        open.controlSize = .large
        open.keyEquivalent = "\r"
        open.bezelColor = Theme.coral
        let dropHint = NSTextField(labelWithString: "or drop any file here")
        dropHint.font = .systemFont(ofSize: 12)
        dropHint.textColor = .tertiaryLabelColor

        let settings = NSButton(title: "Settings", target: NSApp.delegate, action: #selector(AppDelegate.showSettings(_:)))
        settings.isBordered = false
        settings.contentTintColor = .secondaryLabelColor
        settings.font = .systemFont(ofSize: 12)
        let version = NSTextField(labelWithString: "Version \(AppInfo.version)")
        version.font = .systemFont(ofSize: 11)
        version.textColor = .tertiaryLabelColor
        let footer = NSStackView(views: [version, settings])
        footer.spacing = 12

        let brandStack = NSStackView(views: [icon, wordmark, slogan, spacer(18), open, dropHint])
        brandStack.orientation = .vertical
        brandStack.alignment = .centerX
        brandStack.spacing = 6
        brandStack.setCustomSpacing(-2, after: wordmark)
        brandStack.translatesAutoresizingMaskIntoConstraints = false
        footer.translatesAutoresizingMaskIntoConstraints = false
        brand.addSubview(brandStack)
        brand.addSubview(footer)

        // Recent files
        let title = NSTextField(labelWithString: "Recent Files")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .secondaryLabelColor
        title.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(title)

        tableView = NSTableView()
        tableView.headerView = nil
        tableView.style = .inset
        tableView.rowHeight = 44
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = .clear
        tableView.doubleAction = #selector(openSelected(_:))
        tableView.target = self
        tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file")))
        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)

        emptyLabel = NSTextField(wrappingLabelWithString: "Files you open will show up here.\nDouble-click any file in Finder, or drag it onto this window.")
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(emptyLabel)

        // Default app card
        defaultLabel = NSTextField(wrappingLabelWithString: "Open PDFs, Word documents, CSV, Markdown, text and images with Handa by default?")
        defaultLabel.font = .systemFont(ofSize: 12)
        let makeDefault = NSButton(title: "Make Default", target: self, action: #selector(makeDefault(_:)))
        makeDefault.bezelStyle = .rounded
        makeDefault.bezelColor = Theme.coral
        let notNow = NSButton(title: "Not Now", target: self, action: #selector(dismissDefault(_:)))
        notNow.bezelStyle = .rounded
        defaultButtons = NSStackView(views: [makeDefault, notNow])
        defaultButtons.spacing = 8
        let cardStack = NSStackView(views: [defaultLabel, defaultButtons])
        cardStack.orientation = .vertical
        cardStack.alignment = .leading
        cardStack.spacing = 8
        cardStack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        defaultCard = NSView()
        defaultCard.wantsLayer = true
        defaultCard.layer?.cornerRadius = 10
        defaultCard.layer?.backgroundColor = Theme.coral.withAlphaComponent(0.1).cgColor
        defaultCard.translatesAutoresizingMaskIntoConstraints = false
        defaultCard.addSubview(cardStack)
        root.addSubview(defaultCard)

        NSLayoutConstraint.activate([
            brand.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            brand.topAnchor.constraint(equalTo: root.topAnchor),
            brand.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            brand.widthAnchor.constraint(equalToConstant: 320),
            brandStack.centerXAnchor.constraint(equalTo: brand.centerXAnchor),
            brandStack.centerYAnchor.constraint(equalTo: brand.centerYAnchor, constant: -8),
            footer.centerXAnchor.constraint(equalTo: brand.centerXAnchor),
            footer.bottomAnchor.constraint(equalTo: brand.bottomAnchor, constant: -14),

            title.leadingAnchor.constraint(equalTo: brand.trailingAnchor, constant: 24),
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 40),
            scroll.leadingAnchor.constraint(equalTo: brand.trailingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: defaultCard.topAnchor, constant: -12),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor, constant: -40),

            defaultCard.leadingAnchor.constraint(equalTo: brand.trailingAnchor, constant: 24),
            defaultCard.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            defaultCard.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            cardStack.leadingAnchor.constraint(equalTo: defaultCard.leadingAnchor),
            cardStack.trailingAnchor.constraint(equalTo: defaultCard.trailingAnchor),
            cardStack.topAnchor.constraint(equalTo: defaultCard.topAnchor),
            cardStack.bottomAnchor.constraint(equalTo: defaultCard.bottomAnchor),
        ])
    }

    private func spacer(_ height: CGFloat) -> NSView {
        let view = NSView()
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        return view
    }

    private func reloadRecent() {
        recent = NSDocumentController.shared.recentDocumentURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
        tableView?.reloadData()
        emptyLabel?.isHidden = !recent.isEmpty
    }

    private func updateDefaultCard() {
        let everything = DefaultApps.categories.allSatisfy(DefaultApps.isHandaDefault(for:))
        defaultCard?.isHidden = everything || Preferences.offeredDefaultApp
    }

    // MARK: Actions

    @objc private func openFile(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose files to open in Handa"
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard response == .OK else { return }
            self?.open(panel.urls)
        }
    }

    @objc private func openSelected(_ sender: Any?) {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard recent.indices.contains(row) else { return }
        open([recent[row]])
    }

    private func open(_ urls: [URL]) {
        guard let controller = NSDocumentController.shared as? DocumentController else { return }
        for url in urls { controller.open(url) }
        if !urls.isEmpty { close() }
    }

    @objc private func makeDefault(_ sender: Any?) {
        Preferences.offeredDefaultApp = true
        DefaultApps.makeDefault(DefaultApps.categories) { [weak self] errors in
            self?.defaultButtons.isHidden = true
            self?.defaultLabel.stringValue = errors.isEmpty
                ? "Done. Handa now opens these files when you double-click them."
                : "macOS didn't accept every change (\(errors.count) failed). You can try again in Settings."
        }
    }

    @objc private func dismissDefault(_ sender: Any?) {
        Preferences.offeredDefaultApp = true
        defaultCard.isHidden = true
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { recent.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let url = recent[row]
        let cell = NSTableCellView()
        let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: url.path))
        icon.imageScaling = .scaleProportionallyUpOrDown
        let name = NSTextField(labelWithString: url.lastPathComponent)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.lineBreakMode = .byTruncatingMiddle
        let folder = NSTextField(labelWithString: (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
        folder.font = .systemFont(ofSize: 11)
        folder.textColor = .secondaryLabelColor
        folder.lineBreakMode = .byTruncatingHead
        let text = NSStackView(views: [name, folder])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let row = NSStackView(views: [icon, text])
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(row)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 32),
            icon.heightAnchor.constraint(equalToConstant: 32),
            row.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            row.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        cell.toolTip = url.path
        return cell
    }
}

/// Accepts dropped files.
final class DropView: NSView {
    var onDrop: (([URL]) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        urls(from: sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = urls(from: sender)
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }

    private func urls(from info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
}
