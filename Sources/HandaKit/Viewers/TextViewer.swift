import AppKit
import HandaCore

/// Plain text and code: monospaced, syntax coloured, with line numbers. Editable on request.
final class TextViewer: Viewer, NSTextViewDelegate {
    private let content: TextContent
    private let language: Language?
    private let readOnly: Bool
    private let isLarge: Bool
    private var scrollView: NSScrollView!
    private(set) var textView: CodeTextView!
    private var layoutManager: NSLayoutManager!
    private var ruler: LineNumberRuler?
    private var highlightGeneration = 0
    private var pendingHighlight: DispatchWorkItem?
    private var stats: TextStats?
    private var statsWork: DispatchWorkItem?
    private var wraps: Bool

    init(document: Document, content: TextContent, language: Language?, readOnly: Bool = false) {
        self.content = content
        self.language = language
        self.readOnly = readOnly
        isLarge = content.storage.length > Document.largeTextBytes
        wraps = language == nil || language?.wrapsByDefault == true || Preferences.wrapCode
        super.init(document: document)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var supportsEditing: Bool { !readOnly && document.isWritable }
    override var supportsZoom: Bool { true }
    override var preferredFirstResponder: NSView? { textView }

    override func loadView() {
        let font = Theme.monospaced(Preferences.textSize)
        layoutManager = NSLayoutManager()
        layoutManager.allowsNonContiguousLayout = true
        content.storage.addLayoutManager(layoutManager)

        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.addTextContainer(container)

        // Start the scroll view and text view at matching sizes so autoresizing keeps them in step.
        scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        textView = CodeTextView(frame: NSRect(origin: .zero, size: scrollView.contentSize), textContainer: container)
        textView.delegate = self
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isEditable = false
        textView.isSelectable = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.textContainerInset = NSSize(width: 10, height: 12)
        textView.font = font
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.drawsBackground = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.typingAttributes = baseAttributes(font: font)

        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.documentView = textView
        view = scrollView

        applyWrapping()
        applyBaseAttributes()
        if Preferences.showLineNumbers, !isLarge { installRuler() }
        scheduleHighlight(delay: 0)
        scheduleStats()
    }

    private var isTornDown = false

    override func tearDown() {
        guard !isTornDown, isViewLoaded else { return }
        isTornDown = true
        highlightGeneration += 1
        pendingHighlight?.cancel()
        statsWork?.cancel()
        ruler?.detach()
        content.storage.removeLayoutManager(layoutManager)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if wraps, abs(textView.frame.width - scrollView.contentSize.width) > 0.5 {
            textView.frame.size.width = scrollView.contentSize.width
        }
    }

    private func baseAttributes(font: NSFont) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: NSColor.textColor, .paragraphStyle: Theme.codeParagraphStyle(font: font, wraps: wraps)]
    }

    private func applyBaseAttributes() {
        let font = Theme.monospaced(Preferences.textSize)
        let storage = content.storage
        storage.beginEditing()
        storage.setAttributes(baseAttributes(font: font), range: NSRange(location: 0, length: storage.length))
        storage.endEditing()
        textView.typingAttributes = baseAttributes(font: font)
        ruler?.font = Theme.monospaced(max(9, Preferences.textSize - 2))
    }

    private func applyWrapping() {
        guard let container = textView.textContainer else { return }
        if wraps {
            scrollView.hasHorizontalScroller = false
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            container.widthTracksTextView = true
            container.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
            textView.frame.size.width = scrollView.contentSize.width
        } else {
            scrollView.hasHorizontalScroller = true
            textView.isHorizontallyResizable = true
            textView.autoresizingMask = []
            container.widthTracksTextView = false
            container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
    }

    private func installRuler() {
        let ruler = LineNumberRuler(textView: textView, scrollView: scrollView)
        ruler.font = Theme.monospaced(max(9, Preferences.textSize - 2))
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        self.ruler = ruler
    }

    override func editingDidChange() {
        textView.isEditable = isEditing
        if isEditing { view.window?.makeFirstResponder(textView) }
        statusChanged()
    }

    // MARK: Highlighting

    private func scheduleHighlight(delay: TimeInterval) {
        guard let language = language, !isLarge else { return }
        pendingHighlight?.cancel()
        highlightGeneration += 1
        let generation = highlightGeneration
        let text = content.storage.string
        let work = DispatchWorkItem { [weak self] in
            let tokens = SyntaxHighlighter.tokens(in: text, language: language)
            DispatchQueue.main.async {
                guard let self = self, !self.isTornDown, generation == self.highlightGeneration else { return }
                self.apply(tokens)
            }
        }
        pendingHighlight = work
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func apply(_ tokens: [Token]) {
        guard layoutManager.textStorage === content.storage else { return }
        let length = content.storage.length
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: length))
        var colors: [TokenKind: NSColor] = [:]
        for token in tokens where NSMaxRange(token.range) <= length {
            let color = colors[token.kind] ?? Theme.color(for: token.kind)
            colors[token.kind] = color
            layoutManager.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: token.range)
        }
    }

    func textDidChange(_ notification: Notification) {
        // Re-colour after typing pauses; small files feel instant, big ones don't stall typing.
        scheduleHighlight(delay: content.storage.length < 200_000 ? 0.15 : 0.6)
        scheduleStats()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        statusChanged()
    }

    // MARK: Status

    private func scheduleStats() {
        statsWork?.cancel()
        let text = content.storage.string
        let work = DispatchWorkItem { [weak self] in
            let stats = TextStats(text)
            DispatchQueue.main.async {
                self?.stats = stats
                self?.statusChanged()
            }
        }
        statsWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    override var statusText: String {
        var parts: [String] = []
        if let language = language { parts.append(language.displayName) }
        if let stats = stats {
            parts.append(Formatting.count(stats.lines, "line"))
            parts.append(Formatting.count(stats.words, "word"))
        }
        let selection = textView?.selectedRange() ?? NSRange(location: 0, length: 0)
        if selection.length > 0 { parts.append("\(Formatting.count(selection.length, "character")) selected") }
        parts.append(content.summary)
        if isLarge { parts.append("Large file: colouring off") }
        return parts.joined(separator: " · ")
    }

    override func selectedText() -> String? {
        guard let textView = textView else { return nil }
        let range = textView.selectedRange()
        guard range.length > 0 else { return nil }
        return (content.storage.string as NSString).substring(with: range)
    }

    override func printOperation(printInfo: NSPrintInfo) -> NSPrintOperation? {
        let copy = NSMutableAttributedString(string: content.storage.string,
                                             attributes: [.font: Theme.monospaced(10), .foregroundColor: NSColor.black])
        return Viewer.printOperation(for: copy, printInfo: printInfo)
    }

    // MARK: Zoom & view options

    override func zoomIn(_ sender: Any?) { changeTextSize(by: 1) }
    override func zoomOut(_ sender: Any?) { changeTextSize(by: -1) }
    override func zoomToActualSize(_ sender: Any?) { Preferences.textSize = 13; applyBaseAttributes() }
    override func zoomToFit(_ sender: Any?) {}

    private func changeTextSize(by delta: CGFloat) {
        Preferences.textSize = Preferences.textSize + delta
        applyBaseAttributes()
    }

    @objc func toggleWrapLines(_ sender: Any?) {
        wraps.toggle()
        applyBaseAttributes()
        applyWrapping()
    }

    @objc func toggleLineNumbers(_ sender: Any?) {
        Preferences.showLineNumbers.toggle()
        if let ruler = ruler {
            scrollView.rulersVisible = false
            scrollView.hasVerticalRuler = false
            scrollView.verticalRulerView = nil
            ruler.detach()
            self.ruler = nil
        } else if !isLarge {
            installRuler()
        }
    }

    @objc func goToLocation(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Go to Line"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.placeholderString = "Line number"
        alert.accessoryView = field
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let line = Int(field.stringValue.trimmingCharacters(in: .whitespaces)) else { return }
            self?.select(line: line)
        }
    }

    func select(line: Int) {
        let text = content.storage.string as NSString
        var current = 1
        var location = 0
        while current < line, location < text.length {
            let range = text.lineRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(range)
            current += 1
        }
        let lineRange = text.lineRange(for: NSRange(location: min(location, text.length), length: 0))
        textView.setSelectedRange(lineRange)
        textView.scrollRangeToVisible(lineRange)
        textView.showFindIndicator(for: lineRange)
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleWrapLines(_:)):
            menuItem.state = wraps ? .on : .off
            return true
        case #selector(toggleLineNumbers(_:)):
            menuItem.state = ruler != nil ? .on : .off
            return !isLarge
        case #selector(goToLocation(_:)):
            return true
        default:
            return super.validateMenuItem(menuItem)
        }
    }
}

/// The text view used for code.
final class CodeTextView: NSTextView {
    override var acceptsFirstResponder: Bool { true }
}

/// Line numbers in the gutter. Only draws the lines that are visible.
final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?
    private var lineStarts: [Int] = [0]
    private var needsRecount = true
    var font: NSFont = Theme.monospaced(11) {
        didSet { updateThickness(); needsDisplay = true }
    }

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 40
        NotificationCenter.default.addObserver(self, selector: #selector(textChanged), name: NSText.didChangeNotification, object: textView)
        NotificationCenter.default.addObserver(self, selector: #selector(redraw), name: NSView.frameDidChangeNotification, object: textView)
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(redraw), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    required init(coder: NSCoder) { fatalError("not used") }

    func detach() {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func textChanged() {
        needsRecount = true
        needsDisplay = true
    }

    @objc private func redraw() { needsDisplay = true }

    override var isOpaque: Bool { true }

    private func recount() {
        guard let string = textView?.textStorage?.string as NSString? else { return }
        let length = string.length
        var starts = [0]
        starts.reserveCapacity(length / 30 + 1)
        let chunk = 65_536
        var buffer = [unichar](repeating: 0, count: chunk)
        var location = 0
        while location < length {
            let count = min(chunk, length - location)
            string.getCharacters(&buffer, range: NSRange(location: location, length: count))
            for i in 0..<count where buffer[i] == 10 { starts.append(location + i + 1) }
            location += count
        }
        lineStarts = starts
        needsRecount = false
        updateThickness()
    }

    private func updateThickness() {
        let digits = max(3, String(lineStarts.count).count)
        let width = ceil(("8" as NSString).size(withAttributes: [.font: font]).width * CGFloat(digits)) + 18
        if abs(width - ruleThickness) > 0.5 { ruleThickness = width }
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        if needsRecount { recount() }
        NSColor.textBackgroundColor.setFill()
        bounds.fill()

        let origin = textView.textContainerOrigin
        let visible = textView.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let length = textView.textStorage?.length ?? 0
        // The ruler is flipped like the text view; y = 0 is the top of the visible area.
        let yOffset = origin.y - (scrollView?.contentView.bounds.minY ?? 0)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]
        let selectedLine = lineIndex(for: textView.selectedRange().location)

        var index = lineIndex(for: charRange.location)
        while index < lineStarts.count {
            let start = lineStarts[index]
            if start > NSMaxRange(charRange) { break }
            var lineRect: NSRect
            if start >= length {
                lineRect = layoutManager.extraLineFragmentRect
                if lineRect.isEmpty { break }
            } else {
                let glyph = layoutManager.glyphIndexForCharacter(at: start)
                lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil, withoutAdditionalLayout: true)
            }
            let label = "\(index + 1)" as NSString
            var drawAttributes = attributes
            if index == selectedLine { drawAttributes[.foregroundColor] = NSColor.secondaryLabelColor }
            let size = label.size(withAttributes: drawAttributes)
            let y = yOffset + lineRect.minY + (min(lineRect.height, font.boundingRectForFont.height * 1.4) - size.height) / 2
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: y), withAttributes: drawAttributes)
            index += 1
        }
    }

    private func lineIndex(for location: Int) -> Int {
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= location { low = mid } else { high = mid - 1 }
        }
        return low
    }
}
