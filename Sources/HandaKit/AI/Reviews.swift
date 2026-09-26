import AppKit
import HandaCore

/// Runs AI reviews, manual or automatic, and keeps track of which are in flight.
final class ReviewCoordinator {
    static let shared = ReviewCoordinator()

    enum State: Equatable {
        case idle
        case running
        case failed(String)
    }

    let store = ReviewStore()
    private var states: [String: State] = [:]
    private var watcher: DispatchSourceFileSystemObject?

    func state(for path: String?) -> State {
        path.flatMap { states[$0] } ?? .idle
    }

    private func setState(_ state: State, for path: String) {
        states[path] = state
        NotificationCenter.default.post(name: .handaReviewsChanged, object: nil, userInfo: ["path": path])
    }

    /// Automatic reviews: only when AI is on, auto-review is on, a rule matches, and the file changed since last time.
    func documentOpened(_ document: Document) {
        guard Preferences.aiEnabled, Preferences.autoReview, let url = document.fileURL,
              let rule = ReviewRule.firstMatch(in: Preferences.reviewRules, path: url.path),
              state(for: url.path) != .running else { return }
        DispatchQueue.global(qos: .utility).async {
            let hash = ReviewCoordinator.contentHash(of: url)
            DispatchQueue.main.async {
                if self.store.hasReview(for: url.path, contentHash: hash, instruction: rule.instruction) { return }
                self.review(document, instruction: rule.instruction, automatic: true, contentHash: hash)
            }
        }
    }

    func review(_ document: Document, instruction: String?, automatic: Bool, contentHash: String? = nil) {
        guard let url = document.fileURL else { return }
        let path = url.path
        guard state(for: path) != .running else { return }
        let instruction = instruction ?? Preferences.reviewInstruction
        setState(.running, for: path)

        let inMemoryText = document.isDocumentEdited ? document.currentText() : nil
        // Unsaved edits are what gets reviewed, so file the review under the bytes saving them would
        // write: that's what the file hashes to once they're saved.
        let unsavedHash = inMemoryText.map { text in document.bytesToSave().map { StableHash.hex($0) } ?? StableHash.hex(text) }
        let kindName = document.kind.displayName
        let provider = Preferences.reviewProvider
        let model = Preferences.claudeModel
        let command = Preferences.reviewCommand

        DispatchQueue.global(qos: .userInitiated).async {
            let hash = unsavedHash ?? contentHash ?? ReviewCoordinator.contentHash(of: url)
            let text: String
            do {
                text = try inMemoryText ?? TextExtractor.extract(url: url).text
            } catch {
                DispatchQueue.main.async { self.setState(.failed(error.localizedDescription), for: path) }
                return
            }
            let finish: (Result<String, Error>, String) -> Void = { result, source in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let body):
                        let review = Review(title: automatic ? "Automatic review" : "Review", body: body, source: source,
                                            contentHash: hash, instruction: instruction)
                        do {
                            try self.store.add(review, for: path)
                            self.setState(.idle, for: path)
                        } catch {
                            self.setState(.failed("Couldn't save the review: \(error.localizedDescription)"), for: path)
                        }
                    case .failure(let error):
                        self.setState(.failed(error.localizedDescription), for: path)
                    }
                }
            }
            switch provider {
            case .claude:
                let key = Keychain.read(Keychain.claudeAccount) ?? ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? ""
                AnthropicClient.review(apiKey: key, model: model, fileName: url.lastPathComponent, kind: kindName,
                                       text: text, instruction: instruction) { result in
                    finish(result, "Claude · \(model)")
                }
            case .command:
                let expanded = CommandRunner.expand(command, file: path, instruction: instruction)
                CommandRunner.run(expanded, input: text, environment: ["HANDA_FILE": path, "HANDA_INSTRUCTION": instruction]) { result in
                    let name = command.split(separator: " ").first.map(String.init) ?? "command"
                    finish(result, "Command · \(name)")
                }
            }
        }
    }

    static func contentHash(of url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        if let size = values?.fileSize, size > 64 * 1024 * 1024 {
            return "size-\(size)-\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return "missing" }
        return StableHash.hex(data)
    }

    /// Reviews added by MCP clients land on disk; watch the folder so open windows update.
    func startWatching() {
        guard watcher == nil else { return }
        let directory = store.directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler {
            NotificationCenter.default.post(name: .handaReviewsChanged, object: nil)
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
    }

    func stopWatching() {
        watcher?.cancel()
        watcher = nil
    }
}

/// The side panel listing reviews for the current file.
final class ReviewPanelController: NSViewController {
    private let document: Document
    private var textView: NSTextView!
    private var spinner: NSProgressIndicator!
    private var statusLabel: NSTextField!
    private var statusRow: NSStackView!
    private var observer: NSObjectProtocol?

    init(document: Document) {
        self.document = document
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        if let observer = observer { NotificationCenter.default.removeObserver(observer) }
    }

    override func loadView() {
        let title = NSTextField(labelWithString: "Reviews")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let review = NSButton(title: "Review", image: NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil) ?? NSImage(),
                              target: self, action: #selector(reviewNow(_:)))
        review.bezelStyle = .rounded
        review.controlSize = .small
        let clear = NSButton(image: NSImage(systemSymbolName: "trash", accessibilityDescription: "Clear reviews") ?? NSImage(),
                             target: self, action: #selector(clearReviews(_:)))
        clear.isBordered = false
        clear.toolTip = "Delete all reviews of this file"
        title.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        for button in [clear, review] { button.setContentHuggingPriority(.required, for: .horizontal) }
        let header = NSStackView(views: [title, clear, review])
        header.distribution = .fill
        header.spacing = 8
        header.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 8, right: 12)

        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        statusLabel = NSTextField(wrappingLabelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11)
        statusRow = NSStackView(views: [spinner, statusLabel])
        statusRow.spacing = 6
        statusRow.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 6, right: 12)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 500))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        textView = MarkdownTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 10, height: 8)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.linkTextAttributes = [.foregroundColor: Theme.accent, .cursor: NSCursor.pointingHand]
        textView.layoutManager?.allowsNonContiguousLayout = true
        scroll.documentView = textView

        let stack = NSStackView(views: [header, statusRow, scroll])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 0
        stack.distribution = .fill
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: 600)
        view = stack

        observer = NotificationCenter.default.addObserver(forName: .handaReviewsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.reload()
        }
        reload()
    }

    @objc private func reviewNow(_ sender: Any?) {
        ReviewCoordinator.shared.review(document, instruction: nil, automatic: false)
    }

    @objc private func clearReviews(_ sender: Any?) {
        guard let path = document.fileURL?.path else { return }
        for review in ReviewCoordinator.shared.store.reviews(for: path) {
            try? ReviewCoordinator.shared.store.remove(id: review.id, for: path)
        }
        reload()
    }

    func reload() {
        guard isViewLoaded else { return }
        let path = document.fileURL?.path
        switch ReviewCoordinator.shared.state(for: path) {
        case .idle:
            spinner.stopAnimation(nil)
            statusLabel.stringValue = ""
            statusRow.isHidden = true
        case .running:
            spinner.startAnimation(nil)
            statusRow.isHidden = false
            statusLabel.textColor = .secondaryLabelColor
            statusLabel.stringValue = Preferences.reviewProvider == .claude ? "Asking Claude…" : "Running your review command…"
        case .failed(let message):
            spinner.stopAnimation(nil)
            statusRow.isHidden = false
            statusLabel.textColor = .systemRed
            statusLabel.stringValue = message
        }

        let output = NSMutableAttributedString()
        let reviews = path.map { ReviewCoordinator.shared.store.reviews(for: $0) } ?? []
        if reviews.isEmpty {
            let hint = """
            No reviews yet.

            Click Review to ask for feedback on this file, add rules in Settings → AI to review matching files automatically, \
            or let an assistant connected over MCP leave one with add_review.
            """
            output.append(NSAttributedString(string: hint, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        for (index, review) in reviews.enumerated() {
            if index > 0 {
                output.append(NSAttributedString(string: "\n\n", attributes: [.font: NSFont.systemFont(ofSize: 6)]))
            }
            output.append(NSAttributedString(string: review.title + "\n", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor]))
            let meta = "\(review.source) · \(formatter.localizedString(for: review.createdAt, relativeTo: Date()))\n"
            output.append(NSAttributedString(string: meta, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
            output.append(MarkdownRenderer.render(review.body, style: MarkdownRenderer.Style(bodySize: 13, codeSize: 11.5, imageMaxWidth: 260)))
        }
        textView.textStorage?.setAttributedString(output)
    }
}

/// Shares which files are open (and what's selected) with the MCP server, when AI features are on.
final class SessionPublisher {
    static let shared = SessionPublisher()
    private var pending: DispatchWorkItem?

    func update() {
        guard Preferences.aiEnabled else {
            removeFile()
            return
        }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.write() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func write() {
        let key = (NSApp.keyWindow ?? NSApp.mainWindow)?.windowController as? DocumentWindowController
        let documents = NSDocumentController.shared.documents.compactMap { $0 as? Document }
        let entries = documents.compactMap { document -> SessionState.Document? in
            guard let url = document.fileURL else { return nil }
            let controller = document.windowController
            let selection = controller?.viewer.selectedText().map { String($0.prefix(20_000)) }
            return SessionState.Document(path: url.path, kind: document.kind.displayName,
                                         isActive: controller != nil && controller === key,
                                         isEdited: document.isDocumentEdited, selection: selection)
        }
        let state = SessionState(documents: entries, appVersion: AppInfo.version)
        DispatchQueue.global(qos: .utility).async { try? state.write() }
    }

    func removeFile() {
        pending?.cancel()
        try? FileManager.default.removeItem(at: SupportPaths.sessionFile)
    }
}
