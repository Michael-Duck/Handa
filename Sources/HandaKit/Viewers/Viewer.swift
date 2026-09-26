import AppKit
import HandaCore

/// Base class for everything that shows a document. Subclasses override what they support.
class Viewer: NSViewController, NSMenuItemValidation {
    unowned let document: Document

    /// Called whenever the status bar text should be refreshed.
    var onStatusChange: (() -> Void)?

    init(document: Document) {
        self.document = document
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    var supportsEditing: Bool { false }
    private(set) var isEditing = false

    func setEditing(_ editing: Bool) {
        isEditing = editing && supportsEditing
        editingDidChange()
    }

    func editingDidChange() {}

    /// Details for the status bar, like "248 lines · UTF-8 · LF".
    var statusText: String { "" }

    /// Finish any in-progress edit (like a table cell being typed in) before saving.
    func finishEditing() {}

    /// The view that should have keyboard focus when the window opens.
    var preferredFirstResponder: NSView? { nil }

    var supportsSearch: Bool { false }
    func search(_ query: String) {}
    func searchNext(backwards: Bool) {}

    var supportsSidebar: Bool { false }
    func toggleSidebar() {}

    /// Text currently selected, if any. Shared with AI assistants.
    func selectedText() -> String? { nil }

    func printOperation(printInfo: NSPrintInfo) -> NSPrintOperation? { nil }

    /// Release resources that outlive the view (layout managers, previews) before the viewer is swapped out.
    func tearDown() {}

    func statusChanged() { onStatusChange?() }

    // Zoom, routed from the View menu through the responder chain.
    @objc func zoomIn(_ sender: Any?) {}
    @objc func zoomOut(_ sender: Any?) {}
    @objc func zoomToActualSize(_ sender: Any?) {}
    @objc func zoomToFit(_ sender: Any?) {}
    var supportsZoom: Bool { false }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(zoomIn(_:)), #selector(zoomOut(_:)), #selector(zoomToActualSize(_:)), #selector(zoomToFit(_:)):
            return supportsZoom
        default:
            return true
        }
    }

    /// Builds a print job for attributed text, laid out to the page width.
    static func printOperation(for text: NSAttributedString, printInfo: NSPrintInfo) -> NSPrintOperation {
        let info = printInfo.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isVerticallyCentered = false
        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        textView.textStorage?.setAttributedString(text)
        textView.isVerticallyResizable = true
        textView.appearance = NSAppearance(named: .aqua)
        if let layoutManager = textView.layoutManager, let container = textView.textContainer {
            layoutManager.ensureLayout(for: container)
        }
        textView.sizeToFit()
        return NSPrintOperation(view: textView, printInfo: info)
    }
}

/// A scroll view that keeps small content centred, for images and pages.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView = documentView else { return rect }
        let frame = documentView.frame
        if rect.width > frame.width { rect.origin.x = frame.minX - (rect.width - frame.width) / 2 }
        if rect.height > frame.height { rect.origin.y = frame.minY - (rect.height - frame.height) / 2 }
        return rect
    }
}

/// A plain flipped view, handy as a scroll view's document view.
class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
