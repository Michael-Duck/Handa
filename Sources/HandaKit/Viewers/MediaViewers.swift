import AppKit
import Quartz
import HandaCore

/// Images: fit to the window, zoom with pinch or ⌘+/⌘−, transparency shown on a checkerboard.
final class ImageViewer: Viewer {
    private let info: ImageInfo
    private var scrollView: NSScrollView!
    private var imageView: NSImageView!
    /// Keeps the image fitted to the window until the user zooms themselves.
    private var fitsWindow = true

    init(document: Document, info: ImageInfo) {
        self.info = info
        super.init(document: document)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var supportsZoom: Bool { true }
    override var preferredFirstResponder: NSView? { scrollView }

    override func loadView() {
        scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        scrollView.contentView = CenteringClipView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.02
        scrollView.maxMagnification = 32
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.canvas

        let image = document.fileURL.flatMap { NSImage(contentsOf: $0) } ?? NSImage()
        let size = image.size.width > 0 ? image.size : NSSize(width: info.width, height: info.height)
        imageView = NSImageView(frame: NSRect(origin: .zero, size: size))
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.animates = true
        imageView.imageFrameStyle = .none
        if info.hasAlpha {
            imageView.wantsLayer = true
            imageView.layer?.backgroundColor = NSColor(patternImage: ImageViewer.checkerboard).cgColor
        }
        scrollView.documentView = imageView
        view = scrollView
        NotificationCenter.default.addObserver(self, selector: #selector(magnified), name: NSScrollView.didEndLiveMagnifyNotification, object: scrollView)
    }

    override func tearDown() {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if fitsWindow, scrollView.frame.width > 10 {
            setMagnification(fitMagnification, userInitiated: false)
        }
    }

    @objc private func magnified() {
        fitsWindow = false
        statusChanged()
    }

    private var fitMagnification: CGFloat {
        let available = scrollView.frame.size
        let size = imageView.frame.size
        guard size.width > 0, size.height > 0 else { return 1 }
        return min(1, min((available.width - 24) / size.width, (available.height - 24) / size.height))
    }

    override func zoomIn(_ sender: Any?) { setMagnification(scrollView.magnification * 1.25, userInitiated: true) }
    override func zoomOut(_ sender: Any?) { setMagnification(scrollView.magnification / 1.25, userInitiated: true) }
    override func zoomToActualSize(_ sender: Any?) { setMagnification(1, userInitiated: true) }
    override func zoomToFit(_ sender: Any?) {
        fitsWindow = true
        setMagnification(fitMagnification, userInitiated: false)
    }

    private func setMagnification(_ value: CGFloat, userInitiated: Bool) {
        if userInitiated { fitsWindow = false }
        let clamped = min(max(value, scrollView.minMagnification), scrollView.maxMagnification)
        guard userInitiated || abs(clamped - scrollView.magnification) > 0.001 else { return }
        scrollView.setMagnification(clamped, centeredAt: NSPoint(x: imageView.frame.midX, y: imageView.frame.midY))
        statusChanged()
    }

    override var statusText: String {
        var parts = [info.typeName ?? "Image", info.dimensions, Formatting.bytes(document.fileSize)]
        if let scrollView = scrollView { parts.append("\(Int((scrollView.magnification * 100).rounded()))%") }
        return parts.joined(separator: " · ")
    }

    override func printOperation(printInfo: NSPrintInfo) -> NSPrintOperation? {
        let info = printInfo.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.verticalPagination = .fit
        let view = NSImageView(frame: NSRect(origin: .zero, size: imageView.frame.size))
        view.image = imageView.image
        view.imageScaling = .scaleProportionallyUpOrDown
        return NSPrintOperation(view: view, printInfo: info)
    }

    static let checkerboard: NSImage = {
        let size = NSSize(width: 16, height: 16)
        return NSImage(size: size, flipped: false) { rect in
            NSColor(white: 0.93, alpha: 1).setFill()
            rect.fill()
            NSColor(white: 0.82, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 8, height: 8).fill()
            NSRect(x: 8, y: 8, width: 8, height: 8).fill()
            return true
        }
    }()
}

/// Everything else macOS can preview: video, audio, spreadsheets, presentations, 3D, fonts…
final class QuickLookViewer: Viewer {
    private var preview: QLPreviewView?

    override func loadView() {
        guard let url = document.fileURL, let preview = QLPreviewView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), style: .normal) else {
            view = NSView()
            return
        }
        preview.autostarts = true
        preview.shouldCloseWithWindow = true
        preview.previewItem = url as NSURL
        self.preview = preview
        view = preview
    }

    override var preferredFirstResponder: NSView? { preview }

    override func tearDown() {
        preview?.close()
    }

    override var statusText: String {
        let layout = document.kind.category == .richText || document.kind.category == .text ? " · Original layout, from Quick Look" : ""
        return "\(document.kind.displayName) · \(Formatting.bytes(document.fileSize))\(layout)"
    }
}

/// Bytes, 16 to a row, for files nothing else can show.
final class HexViewer: Viewer, NSTableViewDataSource, NSTableViewDelegate {
    static let maxBytes = 16 * 1024 * 1024
    private let data: Data
    private var tableView: NSTableView!

    init(document: Document, data: Data) {
        self.data = data
        super.init(document: document)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var preferredFirstResponder: NSView? { tableView }

    private var shownBytes: Int { min(data.count, HexViewer.maxBytes) }

    override func loadView() {
        tableView = NSTableView()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.style = .fullWidth
        tableView.rowHeight = 18
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        for (id, title, width) in [("offset", "Offset", 96.0), ("hex", "Bytes", 420.0), ("ascii", "Text", 170.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.isEditable = false
            tableView.addTableColumn(column)
        }
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        view = scrollView
    }

    func numberOfRows(in tableView: NSTableView) -> Int { HexDump.rowCount(byteCount: shownBytes) }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = tableColumn?.identifier.rawValue ?? ""
        let field = (tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier(id), owner: self) as? NSTextField) ?? {
            let field = NSTextField(labelWithString: "")
            field.identifier = NSUserInterfaceItemIdentifier(id)
            field.font = Theme.monospaced(12)
            field.textColor = id == "offset" ? .tertiaryLabelColor : (id == "ascii" ? .secondaryLabelColor : .labelColor)
            field.lineBreakMode = .byClipping
            return field
        }()
        let start = row * HexDump.bytesPerRow
        let end = min(start + HexDump.bytesPerRow, shownBytes)
        let bytes = data[(data.startIndex + start)..<(data.startIndex + end)]
        switch id {
        case "offset": field.stringValue = HexDump.offset(start)
        case "hex": field.stringValue = HexDump.hex(bytes)
        default: field.stringValue = HexDump.ascii(bytes)
        }
        return field
    }

    @objc func copy(_ sender: Any?) {
        let lines = tableView.selectedRowIndexes.map { row -> String in
            let start = row * HexDump.bytesPerRow
            let bytes = data[(data.startIndex + start)..<(data.startIndex + min(start + HexDump.bytesPerRow, shownBytes))]
            return "\(HexDump.offset(start))  \(HexDump.hex(bytes))  |\(HexDump.ascii(bytes))|"
        }
        guard !lines.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    override var statusText: String {
        var text = "\(document.kind.displayName) · \(Formatting.bytes(Int64(data.count)))"
        if data.count > HexViewer.maxBytes { text += " · Showing the first \(Formatting.bytes(Int64(HexViewer.maxBytes)))" }
        return text
    }
}
