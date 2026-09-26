import AppKit
import HandaCore

/// A read-only text view that keeps its text in a comfortable centred column.
final class ReadingTextView: NSTextView {
    var maxColumnWidth: CGFloat = 780
    var minimumInset: CGFloat = 32

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let horizontal = max(minimumInset, (newSize.width - maxColumnWidth) / 2)
        if abs(textContainerInset.width - horizontal) > 0.5 {
            textContainerInset = NSSize(width: horizontal, height: 28)
        }
    }

}

/// Rendered Markdown. Editing switches the window to the source view.
final class MarkdownViewer: Viewer {
    private let content: TextContent
    private var textView: ReadingTextView!
    private var scrollView: NSScrollView!

    init(document: Document, content: TextContent) {
        self.content = content
        super.init(document: document)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var preferredFirstResponder: NSView? { textView }
    override var supportsZoom: Bool { true }

    override func loadView() {
        scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        textView = ReadingTextView(frame: NSRect(origin: .zero, size: scrollView.contentSize))
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.linkTextAttributes = [.foregroundColor: Theme.accent, .cursor: NSCursor.pointingHand]
        textView.layoutManager?.allowsNonContiguousLayout = true
        scrollView.documentView = textView
        view = scrollView
        render()
    }

    private var scale: CGFloat = 1

    func render() {
        let style = MarkdownRenderer.Style(bodySize: 15 * scale, codeSize: 13 * scale)
        let base = document.fileURL?.deletingLastPathComponent()
        let source = content.string
        if source.utf16.count < 300_000 {
            textView.textStorage?.setAttributedString(MarkdownRenderer.render(source, baseURL: base, style: style))
        } else {
            // Long documents render in the background so the window appears immediately.
            textView.textStorage?.setAttributedString(NSAttributedString(string: "Rendering…", attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 13)]))
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let rendered = MarkdownRenderer.render(source, baseURL: base, style: style)
                DispatchQueue.main.async { self?.textView.textStorage?.setAttributedString(rendered) }
            }
        }
    }

    override var statusText: String {
        let stats = TextStats(content.string)
        return "Markdown · \(Formatting.count(stats.words, "word")) · \(content.summary)"
    }

    override func selectedText() -> String? {
        guard let textView = textView, textView.selectedRange().length > 0 else { return nil }
        return (textView.string as NSString).substring(with: textView.selectedRange())
    }

    override func printOperation(printInfo: NSPrintInfo) -> NSPrintOperation? {
        Viewer.printOperation(for: MarkdownRenderer.render(content.string, baseURL: document.fileURL?.deletingLastPathComponent()), printInfo: printInfo)
    }

    override func zoomIn(_ sender: Any?) { scale = min(scale + 0.1, 2.5); render() }
    override func zoomOut(_ sender: Any?) { scale = max(scale - 0.1, 0.6); render() }
    override func zoomToActualSize(_ sender: Any?) { scale = 1; render() }
}

/// Word, RTF and OpenDocument files, laid out on a sheet of paper.
final class RichTextViewer: Viewer, NSTextViewDelegate {
    private let content: RichTextContent
    private var scrollView: NSScrollView!
    private var canvas: FlippedView!
    private var paper: NSView!
    private(set) var textView: ReadingTextView!
    private var layoutManager: NSLayoutManager!
    private var stats: TextStats?

    init(document: Document, content: RichTextContent) {
        self.content = content
        super.init(document: document)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var supportsEditing: Bool { document.isWritable }
    override var supportsZoom: Bool { true }
    override var preferredFirstResponder: NSView? { textView }

    private var pageWidth: CGFloat { max(360, min(content.pageSize.width, 1200)) }
    private var margins: NSEdgeInsets {
        let m = content.margins
        return NSEdgeInsets(top: min(max(m.top, 24), 144), left: min(max(m.left, 24), 144),
                            bottom: min(max(m.bottom, 24), 144), right: min(max(m.right, 24), 144))
    }

    override func loadView() {
        scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        scrollView.contentView = CenteringClipView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.canvas
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.5
        scrollView.maxMagnification = 3

        canvas = FlippedView(frame: NSRect(x: 0, y: 0, width: pageWidth + 80, height: 900))
        paper = NSView(frame: NSRect(x: 40, y: 32, width: pageWidth, height: 800))
        paper.wantsLayer = true
        paper.layer?.backgroundColor = NSColor.white.cgColor
        paper.layer?.cornerRadius = 3
        paper.layer?.shadowColor = NSColor.black.cgColor
        paper.layer?.shadowOpacity = 0.18
        paper.layer?.shadowRadius = 8
        paper.layer?.shadowOffset = CGSize(width: 0, height: -2)
        // Documents are written for white paper, so the page stays light in Dark Mode.
        paper.appearance = NSAppearance(named: .aqua)

        layoutManager = NSLayoutManager()
        layoutManager.allowsNonContiguousLayout = true
        content.storage.addLayoutManager(layoutManager)
        let textWidth = pageWidth - margins.left - margins.right
        let container = NSTextContainer(size: NSSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)

        textView = ReadingTextView(frame: NSRect(x: margins.left, y: margins.top, width: textWidth, height: 600), textContainer: container)
        textView.maxColumnWidth = .greatestFiniteMagnitude
        textView.minimumInset = 0
        textView.textContainerInset = .zero
        textView.delegate = self
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = true
        textView.allowsUndo = true
        textView.usesFontPanel = true
        textView.usesRuler = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: textWidth, height: 200)
        textView.maxSize = NSSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude)
        textView.postsFrameChangedNotifications = true
        textView.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue, .cursor: NSCursor.pointingHand]

        paper.addSubview(textView)
        canvas.addSubview(paper)
        scrollView.documentView = canvas
        view = scrollView

        NotificationCenter.default.addObserver(self, selector: #selector(layoutPaper), name: NSView.frameDidChangeNotification, object: textView)
        scrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(layoutPaper), name: NSView.frameDidChangeNotification, object: scrollView.contentView)
        textView.sizeToFit()
        layoutPaper()
        computeStats()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        layoutPaper()
    }

    @objc private func layoutPaper() {
        guard let textView = textView else { return }
        let m = margins
        let paperHeight = max(textView.frame.height + m.top + m.bottom, content.pageSize.height)
        let visibleWidth = scrollView.contentView.bounds.width
        let canvasWidth = max(visibleWidth, pageWidth + 80)
        let x = ((canvasWidth - pageWidth) / 2).rounded()
        paper.frame = NSRect(x: x, y: 32, width: pageWidth, height: paperHeight)
        textView.setFrameOrigin(NSPoint(x: m.left, y: m.top))
        canvas.frame = NSRect(x: 0, y: 0, width: canvasWidth, height: paperHeight + 64)
    }

    override func tearDown() {
        guard isViewLoaded, layoutManager.textStorage != nil else { return }
        NotificationCenter.default.removeObserver(self)
        content.storage.removeLayoutManager(layoutManager)
    }

    override func editingDidChange() {
        textView.isEditable = isEditing
        if isEditing { view.window?.makeFirstResponder(textView) }
        statusChanged()
    }

    func textDidChange(_ notification: Notification) {
        computeStats()
    }

    private func computeStats() {
        let text = content.storage.string
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let stats = TextStats(text)
            DispatchQueue.main.async {
                self?.stats = stats
                self?.statusChanged()
            }
        }
    }

    override var statusText: String {
        var parts = [content.format.displayName]
        if let stats = stats { parts.append(Formatting.count(stats.words, "word")) }
        let zoom = Int((scrollView?.magnification ?? 1) * 100)
        if zoom != 100 { parts.append("\(zoom)%") }
        if content.format.savingMaySimplify { parts.append("Saving keeps text and formatting; some Word features may be simplified") }
        return parts.joined(separator: " · ")
    }

    override func selectedText() -> String? {
        guard let textView = textView, textView.selectedRange().length > 0 else { return nil }
        return (content.storage.string as NSString).substring(with: textView.selectedRange())
    }

    override func printOperation(printInfo: NSPrintInfo) -> NSPrintOperation? {
        Viewer.printOperation(for: content.storage, printInfo: printInfo)
    }

    override func zoomIn(_ sender: Any?) { setMagnification(scrollView.magnification * 1.2) }
    override func zoomOut(_ sender: Any?) { setMagnification(scrollView.magnification / 1.2) }
    override func zoomToActualSize(_ sender: Any?) { setMagnification(1) }
    override func zoomToFit(_ sender: Any?) {
        setMagnification(scrollView.contentView.frame.width / (pageWidth + 80))
    }

    private func setMagnification(_ value: CGFloat) {
        scrollView.magnification = min(max(value, scrollView.minMagnification), scrollView.maxMagnification)
        layoutPaper()
        statusChanged()
    }
}
