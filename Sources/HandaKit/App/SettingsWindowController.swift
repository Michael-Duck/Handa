import AppKit
import HandaCore

/// Settings: General (default apps), Viewer, and AI (MCP, reviews, automatic reviews).
final class SettingsWindowController: NSWindowController {
    private let tabs = NSTabViewController()

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        self.init(window: window)
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = []
        addTab(GeneralSettings(), "General", "gearshape")
        addTab(ViewerSettings(), "Viewer", "doc.text.magnifyingglass")
        addTab(AISettings(), "AI", "sparkles")
        window.contentViewController = tabs
        window.center()
    }

    private func addTab(_ controller: NSViewController, _ label: String, _ symbol: String) {
        let item = NSTabViewItem(viewController: controller)
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        tabs.addTabViewItem(item)
    }

    func select(tab index: Int) {
        tabs.selectedTabViewItemIndex = min(max(index, 0), tabs.tabViewItems.count - 1)
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        if let window = window {
            DispatchQueue.main.async { Automation.windowReady(window, kind: "settings", file: nil) }
        }
    }
}

/// Small helpers for building settings forms.
private enum Form {
    static func section(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    static func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = Form.width - 48
        return label
    }

    static func checkbox(_ title: String, _ on: Bool, _ target: AnyObject, _ action: Selector) -> NSButton {
        let box = NSButton(checkboxWithTitle: title, target: target, action: action)
        box.state = on ? .on : .off
        return box
    }

    static let width: CGFloat = 640

    static func stack(_ views: [NSView], spacing: CGFloat = 10) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        return stack
    }

    /// Sizes a pane to the fixed width and whatever height its content needs.
    static func install(_ stack: NSStackView, in controller: NSViewController) {
        stack.frame = NSRect(x: 0, y: 0, width: width, height: 100)
        stack.layoutSubtreeIfNeeded()
        let size = NSSize(width: width, height: ceil(stack.fittingSize.height))
        stack.frame.size = size
        controller.preferredContentSize = size
        controller.view = stack
    }

    static func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.spacing = 8
        return stack
    }
}

private final class GeneralSettings: NSViewController {
    private var checks: [NSButton] = []
    private var status: [NSTextField] = []
    private var result: NSTextField!

    override func loadView() {
        var views: [NSView] = [Form.section("Default viewer"),
                               Form.note("Choose which files open in Handa when you double-click them in Finder.")]
        for category in DefaultApps.categories {
            let check = NSButton(checkboxWithTitle: category.title, target: nil, action: nil)
            check.state = .on
            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            checks.append(check)
            status.append(label)
            views.append(Form.row([check, label]))
        }
        let button = NSButton(title: "Make Handa the Default", target: self, action: #selector(makeDefault(_:)))
        button.bezelStyle = .rounded
        result = NSTextField(labelWithString: "")
        result.font = .systemFont(ofSize: 11)
        result.textColor = .secondaryLabelColor
        views.append(Form.row([button, result]))

        views.append(spacer())
        views.append(Form.section("Opening files"))
        views.append(Form.checkbox("Open files ready to edit (instead of as a preview)", Preferences.openInEditMode, self, #selector(toggleEditMode(_:))))
        views.append(Form.checkbox("Close previews with the Esc key", Preferences.escClosesPreview, self, #selector(toggleEsc(_:))))
        Form.install(Form.stack(views), in: self)
        refresh()
    }

    private func spacer() -> NSView {
        let view = NSView()
        view.heightAnchor.constraint(equalToConstant: 6).isActive = true
        return view
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
    }

    private func refresh() {
        for (index, category) in DefaultApps.categories.enumerated() {
            let handa = DefaultApps.isHandaDefault(for: category)
            status[index].stringValue = handa ? "✓ Handa" : "Now: \(DefaultApps.appName(for: DefaultApps.currentApp(for: category)))"
            status[index].textColor = handa ? Theme.accent : .secondaryLabelColor
        }
    }

    @objc private func makeDefault(_ sender: Any?) {
        let chosen = DefaultApps.categories.enumerated().filter { checks[$0.offset].state == .on }.map(\.element)
        guard !chosen.isEmpty else { return }
        result.stringValue = "Updating…"
        DefaultApps.makeDefault(chosen) { [weak self] errors in
            self?.result.stringValue = errors.isEmpty ? "Done." : "\(errors.count) type(s) couldn't be changed."
            Preferences.offeredDefaultApp = true
            self?.refresh()
        }
    }

    @objc private func toggleEditMode(_ sender: NSButton) { Preferences.openInEditMode = sender.state == .on }
    @objc private func toggleEsc(_ sender: NSButton) { Preferences.escClosesPreview = sender.state == .on }
}

private final class ViewerSettings: NSViewController {
    private var sizeLabel: NSTextField!

    override func loadView() {
        let stepper = NSStepper()
        stepper.minValue = 9
        stepper.maxValue = 32
        stepper.increment = 1
        stepper.doubleValue = Double(Preferences.textSize)
        stepper.target = self
        stepper.action = #selector(sizeChanged(_:))
        sizeLabel = NSTextField(labelWithString: "\(Int(Preferences.textSize)) pt")
        let stack = Form.stack([
            Form.section("Text and code"),
            Form.row([NSTextField(labelWithString: "Text size:"), stepper, sizeLabel]),
            Form.checkbox("Wrap long lines in code files", Preferences.wrapCode, self, #selector(toggleWrap(_:))),
            Form.checkbox("Show line numbers", Preferences.showLineNumbers, self, #selector(toggleLineNumbers(_:))),
            Form.note("Plain text and Markdown always wrap. Files over 4 MB open without colouring so they stay fast."),
        ])
        Form.install(stack, in: self)
    }

    @objc private func sizeChanged(_ sender: NSStepper) {
        Preferences.textSize = CGFloat(sender.doubleValue)
        sizeLabel.stringValue = "\(Int(sender.doubleValue)) pt"
    }

    @objc private func toggleWrap(_ sender: NSButton) { Preferences.wrapCode = sender.state == .on }
    @objc private func toggleLineNumbers(_ sender: NSButton) { Preferences.showLineNumbers = sender.state == .on }
}

private final class AISettings: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private var rules: [ReviewRule] = Preferences.reviewRules
    private var rulesTable: NSTableView!
    private var provider: NSPopUpButton!
    private var keyField: NSSecureTextField!
    private var modelField: NSTextField!
    private var commandField: NSTextField!
    private var instructionField: NSTextField!
    private var feedback: NSTextField!
    private var dependent: [NSView] = []

    override func loadView() {
        let enable = Form.checkbox("Turn on AI features", Preferences.aiEnabled, self, #selector(toggleAI(_:)))
        enable.font = .systemFont(ofSize: 13, weight: .medium)
        let privacy = Form.note("Off by default. When it's on, Handa shares the list of open files with assistants you connect over MCP, and sends a file to Claude or your command only when you ask for a review or a rule matches.")

        // MCP
        let addDesktop = NSButton(title: "Add to Claude Desktop", target: self, action: #selector(addToClaudeDesktop(_:)))
        let copyCode = NSButton(title: "Copy Claude Code Command", target: self, action: #selector(copyClaudeCode(_:)))
        let copyJSON = NSButton(title: "Copy JSON", target: self, action: #selector(copyJSON(_:)))
        for button in [addDesktop, copyCode, copyJSON] { button.bezelStyle = .rounded }
        feedback = NSTextField(labelWithString: "")
        feedback.font = .systemFont(ofSize: 11)
        feedback.textColor = Theme.accent

        // Reviews
        provider = NSPopUpButton(frame: .zero, pullsDown: false)
        provider.addItems(withTitles: ["Claude (API key)", "A command, e.g. Claude Code"])
        provider.selectItem(at: Preferences.reviewProvider == .claude ? 0 : 1)
        provider.target = self
        provider.action = #selector(providerChanged(_:))
        keyField = NSSecureTextField()
        keyField.placeholderString = Keychain.read(Keychain.claudeAccount) == nil ? "sk-ant-…" : "Saved in your keychain"
        keyField.widthAnchor.constraint(equalToConstant: 250).isActive = true
        let saveKey = NSButton(title: "Save Key", target: self, action: #selector(saveKey(_:)))
        saveKey.bezelStyle = .rounded
        modelField = NSTextField(string: Preferences.claudeModel)
        modelField.widthAnchor.constraint(equalToConstant: 180).isActive = true
        modelField.delegate = self
        commandField = NSTextField(string: Preferences.reviewCommand)
        commandField.widthAnchor.constraint(equalToConstant: 360).isActive = true
        commandField.delegate = self
        instructionField = NSTextField(string: Preferences.reviewInstruction)
        instructionField.widthAnchor.constraint(equalToConstant: 500).isActive = true
        instructionField.delegate = self

        // Automatic review rules
        let auto = Form.checkbox("Review files that match these rules when I open them", Preferences.autoReview, self, #selector(toggleAuto(_:)))
        rulesTable = NSTableView()
        rulesTable.dataSource = self
        rulesTable.delegate = self
        rulesTable.rowHeight = 22
        rulesTable.usesAlternatingRowBackgroundColors = true
        for (id, title, width) in [("pattern", "Files (e.g. *.csv or ~/Contracts/**/*.pdf)", 230.0), ("instruction", "What to check", 300.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            rulesTable.addTableColumn(column)
        }
        let scroll = NSScrollView()
        scroll.documentView = rulesTable
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: 84).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: Form.width - 48).isActive = true
        let add = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Add rule") ?? NSImage(), target: self, action: #selector(addRule(_:)))
        let remove = NSButton(image: NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove rule") ?? NSImage(), target: self, action: #selector(removeRule(_:)))
        for button in [add, remove] { button.bezelStyle = .smallSquare }

        let mcpRow = Form.row([addDesktop, copyCode, copyJSON])
        let keyRow = Form.row([NSTextField(labelWithString: "API key:"), keyField, saveKey])
        let modelRow = Form.row([NSTextField(labelWithString: "Model:"), modelField])
        let commandRow = Form.row([NSTextField(labelWithString: "Command:"), commandField])
        let instructionRow = Form.row([NSTextField(labelWithString: "Ask for:"), instructionField])
        dependent = [mcpRow, provider, keyRow, modelRow, commandRow, instructionRow, auto, scroll, add, remove]

        let stack = Form.stack([
            enable, privacy,
            Form.section("Connect an assistant (MCP)"),
            Form.note("Handa comes with an MCP server. Once connected, Claude can see the file you have open, read PDFs and Word documents as text, and leave reviews that appear next to the file."),
            mcpRow, feedback,
            Form.section("Reviews"),
            Form.row([NSTextField(labelWithString: "Review with:"), provider]),
            keyRow, modelRow, commandRow,
            Form.note("The command gets the file's text on stdin. {file} and {instruction} are filled in for you."),
            instructionRow,
            Form.section("Automatic reviews"),
            auto, scroll, Form.row([add, remove]),
        ], spacing: 8)
        Form.install(stack, in: self)
        updateEnabled()
    }

    private func updateEnabled() {
        let on = Preferences.aiEnabled
        for view in dependent { setEnabled(view, on) }
        let claude = provider.indexOfSelectedItem == 0
        keyField.isEnabled = on && claude
        modelField.isEnabled = on && claude
        commandField.isEnabled = on && !claude
    }

    private func setEnabled(_ view: NSView, _ on: Bool) {
        if let control = view as? NSControl { control.isEnabled = on }
        if let scroll = view as? NSScrollView, let table = scroll.documentView as? NSTableView { table.isEnabled = on }
        for subview in (view as? NSStackView)?.arrangedSubviews ?? [] { setEnabled(subview, on) }
    }

    @objc private func toggleAI(_ sender: NSButton) {
        Preferences.aiEnabled = sender.state == .on
        updateEnabled()
    }

    @objc private func toggleAuto(_ sender: NSButton) { Preferences.autoReview = sender.state == .on }

    @objc private func providerChanged(_ sender: NSPopUpButton) {
        Preferences.reviewProvider = sender.indexOfSelectedItem == 0 ? .claude : .command
        updateEnabled()
    }

    @objc private func saveKey(_ sender: Any?) {
        let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        feedback.stringValue = Keychain.save(key, account: Keychain.claudeAccount) ? "API key saved to your keychain." : "Couldn't save the key."
        keyField.stringValue = ""
        keyField.placeholderString = "Saved in your keychain"
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === modelField { Preferences.claudeModel = field.stringValue }
        if field === commandField { Preferences.reviewCommand = field.stringValue }
        if field === instructionField { Preferences.reviewInstruction = field.stringValue }
        let row = rulesTable.row(for: field), column = rulesTable.column(for: field)
        if rules.indices.contains(row), column >= 0 {
            if rulesTable.tableColumns[column].identifier.rawValue == "pattern" {
                rules[row].pattern = field.stringValue
            } else {
                rules[row].instruction = field.stringValue
            }
            Preferences.reviewRules = rules
        }
    }

    @objc private func addToClaudeDesktop(_ sender: Any?) {
        do {
            try HandaMCP.addToClaudeDesktop()
            feedback.stringValue = "Added. Restart Claude Desktop to connect."
        } catch {
            feedback.stringValue = error.localizedDescription
        }
    }

    @objc private func copyClaudeCode(_ sender: Any?) {
        putOnPasteboard(HandaMCP.claudeCodeCommand)
        feedback.stringValue = "Copied. Paste it into Terminal."
    }

    @objc private func copyJSON(_ sender: Any?) {
        putOnPasteboard(HandaMCP.claudeDesktopSnippet)
        feedback.stringValue = "Copied the MCP server config."
    }

    private func putOnPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func addRule(_ sender: Any?) {
        rules.append(ReviewRule(pattern: "*.csv", instruction: "Check that totals add up and flag odd values."))
        Preferences.reviewRules = rules
        rulesTable.reloadData()
        rulesTable.editColumn(0, row: rules.count - 1, with: nil, select: true)
    }

    @objc private func removeRule(_ sender: Any?) {
        let row = rulesTable.selectedRow
        guard rules.indices.contains(row) else { return }
        rules.remove(at: row)
        Preferences.reviewRules = rules
        rulesTable.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rules.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let isPattern = tableColumn?.identifier.rawValue == "pattern"
        let field = NSTextField(string: isPattern ? rules[row].pattern : rules[row].instruction)
        field.isBordered = false
        field.drawsBackground = false
        field.isEditable = true
        field.delegate = self
        field.font = isPattern ? Theme.monospaced(11) : .systemFont(ofSize: 12)
        let cell = NSTableCellView()
        cell.addSubview(field)
        cell.textField = field
        field.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
