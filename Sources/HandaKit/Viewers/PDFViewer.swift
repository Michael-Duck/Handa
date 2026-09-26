import AppKit
import PDFKit
import HandaCore

/// PDFs with thumbnails, search and simple markup: highlight, underline, strike out, notes,
/// rotating and deleting pages. Everything can be undone.
final class PDFViewer: Viewer, PDFViewDelegate {
    private let pdf: PDFDocument
    private(set) var pdfView: PDFView!
    private var thumbnails: PDFThumbnailView!
    private var split: NSSplitView!
    private var sidebarVisible = false
    private var matches: [PDFSelection] = []
    private var matchIndex = 0
    private var lastQuery = ""
    private var unlockView: NSView?

    init(document: Document, pdf: PDFDocument) {
        self.pdf = pdf
        super.init(document: document)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var supportsEditing: Bool { document.isWritable && !pdf.isLocked }
    override var supportsSearch: Bool { true }
    override var supportsSidebar: Bool { true }
    override var supportsZoom: Bool { true }
    override var preferredFirstResponder: NSView? { pdfView }

    override func loadView() {
        pdfView = PDFView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        pdfView.pageBreakMargins = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        pdfView.backgroundColor = Theme.canvas
        pdfView.delegate = self
        pdfView.document = pdf

        thumbnails = PDFThumbnailView(frame: NSRect(x: 0, y: 0, width: 150, height: 700))
        thumbnails.pdfView = pdfView
        thumbnails.thumbnailSize = NSSize(width: 104, height: 136)
        thumbnails.backgroundColor = .windowBackgroundColor
        thumbnails.allowsMultipleSelection = false

        split = NSSplitView(frame: NSRect(x: 0, y: 0, width: 1050, height: 700))
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(thumbnails)
        split.addArrangedSubview(pdfView)
        split.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 0)
        split.setHoldingPriority(NSLayoutConstraint.Priority(240), forSubviewAt: 1)
        let width = thumbnails.widthAnchor.constraint(equalToConstant: 150)
        width.priority = NSLayoutConstraint.Priority(255)
        width.isActive = true
        thumbnails.widthAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
        thumbnails.isHidden = true
        view = split

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(changed), name: .PDFViewPageChanged, object: pdfView)
        center.addObserver(self, selector: #selector(changed), name: .PDFViewScaleChanged, object: pdfView)
        center.addObserver(self, selector: #selector(changed), name: .PDFViewSelectionChanged, object: pdfView)

        if pdf.isLocked { showUnlock() }
    }

    override func tearDown() {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func changed() { statusChanged() }

    override func toggleSidebar() {
        sidebarVisible.toggle()
        thumbnails.isHidden = !sidebarVisible
        split.adjustSubviews()
    }

    var isSidebarVisible: Bool { sidebarVisible }

    override var statusText: String {
        guard pdf.pageCount > 0 else { return "PDF · no pages" }
        let current = pdfView?.currentPage.map { pdf.index(for: $0) + 1 } ?? 1
        var parts = ["PDF", "Page \(current) of \(pdf.pageCount)", "\(Int(((pdfView?.scaleFactor ?? 1) * 100).rounded()))%"]
        if !lastQuery.isEmpty { parts.append(matches.isEmpty ? "No matches" : "Match \(matchIndex + 1) of \(matches.count)") }
        if isEditing { parts.append("Select text, then use Format ▸ Annotate") }
        return parts.joined(separator: " · ")
    }

    override func selectedText() -> String? { pdfView?.currentSelection?.string }

    override func printOperation(printInfo: NSPrintInfo) -> NSPrintOperation? {
        pdf.printOperation(for: printInfo, scalingMode: .pageScaleDownToFit, autoRotate: true)
    }

    // MARK: Search

    override func search(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed == lastQuery, !matches.isEmpty {
            searchNext(backwards: false)
            return
        }
        lastQuery = trimmed
        matches = trimmed.isEmpty ? [] : pdf.findString(trimmed, withOptions: [.caseInsensitive, .diacriticInsensitive])
        matchIndex = 0
        for match in matches { match.color = Theme.coral.withAlphaComponent(0.35) }
        pdfView.highlightedSelections = matches.isEmpty ? nil : matches
        showMatch()
    }

    override func searchNext(backwards: Bool) {
        guard !matches.isEmpty else { return }
        matchIndex = (matchIndex + (backwards ? matches.count - 1 : 1)) % matches.count
        showMatch()
    }

    private func showMatch() {
        if matches.indices.contains(matchIndex) {
            pdfView.setCurrentSelection(matches[matchIndex], animate: true)
            pdfView.scrollSelectionToVisible(nil)
        }
        statusChanged()
    }

    // MARK: Zoom

    override func zoomIn(_ sender: Any?) { pdfView.zoomIn(sender) }
    override func zoomOut(_ sender: Any?) { pdfView.zoomOut(sender) }
    override func zoomToActualSize(_ sender: Any?) { pdfView.autoScales = false; pdfView.scaleFactor = 1 }
    override func zoomToFit(_ sender: Any?) { pdfView.autoScales = true }

    @objc func goToLocation(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Go to Page"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.placeholderString = "1–\(pdf.pageCount)"
        alert.accessoryView = field
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self = self, response == .alertFirstButtonReturn, let number = Int(field.stringValue.trimmingCharacters(in: .whitespaces)),
                  let page = self.pdf.page(at: min(max(number, 1), self.pdf.pageCount) - 1) else { return }
            self.pdfView.go(to: page)
        }
    }

    // MARK: Markup

    @objc func highlightSelection(_ sender: Any?) { markup(.highlight, color: NSColor.systemYellow.withAlphaComponent(0.45)) }
    @objc func underlineSelection(_ sender: Any?) { markup(.underline, color: NSColor.systemRed) }
    @objc func strikeOutSelection(_ sender: Any?) { markup(.strikeOut, color: NSColor.systemRed) }

    private func markup(_ subtype: PDFAnnotationSubtype, color: NSColor) {
        guard isEditing, let selection = pdfView.currentSelection, !(selection.string ?? "").isEmpty else { NSSound.beep(); return }
        var added: [(PDFPage, PDFAnnotation)] = []
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let bounds = line.bounds(for: page)
                guard bounds.width > 0, bounds.height > 0 else { continue }
                let annotation = PDFAnnotation(bounds: bounds, forType: subtype, withProperties: nil)
                annotation.color = color
                annotation.modificationDate = Date()
                page.addAnnotation(annotation)
                added.append((page, annotation))
            }
        }
        registerRemoval(of: added, name: subtype == .highlight ? "Highlight" : subtype == .underline ? "Underline" : "Strikethrough")
        pdfView.clearSelection()
    }

    @objc func addNote(_ sender: Any?) {
        guard isEditing, let page = pdfView.currentPage, let window = view.window else { NSSound.beep(); return }
        let alert = NSAlert()
        alert.messageText = "Add a Note"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 60))
        field.placeholderString = "Your note"
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self = self, response == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return }
            let box = page.bounds(for: .cropBox)
            let anchor = self.pdfView.currentSelection?.bounds(for: page).origin
                ?? NSPoint(x: box.maxX - 48, y: box.maxY - 48)
            let note = PDFAnnotation(bounds: NSRect(x: anchor.x, y: anchor.y, width: 24, height: 24), forType: .text, withProperties: nil)
            note.contents = field.stringValue
            note.color = Theme.coral
            note.modificationDate = Date()
            page.addAnnotation(note)
            self.registerRemoval(of: [(page, note)], name: "Note")
        }
    }

    private func registerRemoval(of annotations: [(PDFPage, PDFAnnotation)], name: String) {
        guard !annotations.isEmpty else { return }
        document.undoManager?.registerUndo(withTarget: self) { viewer in
            for (page, annotation) in annotations { page.removeAnnotation(annotation) }
            viewer.document.undoManager?.registerUndo(withTarget: viewer) { again in
                for (page, annotation) in annotations { page.addAnnotation(annotation) }
                again.registerRemoval(of: annotations, name: name)
            }
        }
        document.undoManager?.setActionName(name)
    }

    @objc func rotatePageLeft(_ sender: Any?) { rotate(by: -90) }
    @objc func rotatePageRight(_ sender: Any?) { rotate(by: 90) }

    private func rotate(by degrees: Int) {
        guard isEditing, let page = pdfView.currentPage else { NSSound.beep(); return }
        page.rotation = (page.rotation + degrees + 360) % 360
        document.undoManager?.registerUndo(withTarget: self) { viewer in
            viewer.pdfView.go(to: page)
            viewer.rotate(by: -degrees)
        }
        document.undoManager?.setActionName("Rotate Page")
        pdfView.layoutDocumentView()
    }

    @objc func deletePage(_ sender: Any?) {
        guard isEditing, pdf.pageCount > 1, let page = pdfView.currentPage else { NSSound.beep(); return }
        let index = pdf.index(for: page)
        pdf.removePage(at: index)
        document.undoManager?.registerUndo(withTarget: self) { viewer in
            viewer.pdf.insert(page, at: index)
            viewer.pdfView.go(to: page)
            viewer.document.undoManager?.registerUndo(withTarget: viewer) { again in
                again.pdfView.go(to: page)
                again.deletePage(nil)
            }
        }
        document.undoManager?.setActionName("Delete Page")
        statusChanged()
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(highlightSelection(_:)), #selector(underlineSelection(_:)), #selector(strikeOutSelection(_:)):
            return isEditing && !(pdfView.currentSelection?.string ?? "").isEmpty
        case #selector(addNote(_:)), #selector(rotatePageLeft(_:)), #selector(rotatePageRight(_:)):
            return isEditing
        case #selector(deletePage(_:)):
            return isEditing && pdf.pageCount > 1
        case #selector(goToLocation(_:)):
            return pdf.pageCount > 1
        default:
            return super.validateMenuItem(menuItem)
        }
    }

    // MARK: Locked PDFs

    private func showUnlock() {
        let field = NSSecureTextField()
        field.placeholderString = "Password"
        field.target = self
        field.action = #selector(unlock(_:))
        let label = NSTextField(labelWithString: "This PDF is protected with a password.")
        label.font = .systemFont(ofSize: 14, weight: .medium)
        let button = NSButton(title: "Unlock", target: self, action: #selector(unlockButton(_:)))
        button.keyEquivalent = "\r"
        let stack = NSStackView(views: [label, field, button])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 240).isActive = true
        pdfView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: pdfView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: pdfView.centerYAnchor),
        ])
        unlockView = stack
    }

    @objc private func unlockButton(_ sender: NSButton) {
        if let field = (unlockView as? NSStackView)?.arrangedSubviews.compactMap({ $0 as? NSSecureTextField }).first {
            unlock(field)
        }
    }

    @objc private func unlock(_ sender: NSSecureTextField) {
        if pdf.unlock(withPassword: sender.stringValue) {
            unlockView?.removeFromSuperview()
            unlockView = nil
            pdfView.document = nil
            pdfView.document = pdf
            document.windowController?.documentStateChanged()
        } else {
            sender.stringValue = ""
            NSSound.beep()
        }
    }
}
