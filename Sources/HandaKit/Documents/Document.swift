import AppKit
import PDFKit
import UniformTypeIdentifiers
import HandaCore

/// One open file. Reads happen off the main thread, so opening never blocks the UI.
@objc(HandaDocument)
final class Document: NSDocument {
    enum Content {
        case text(TextContent)
        case markdown(TextContent)
        case table(TableContent)
        case richText(RichTextContent)
        case pdf(PDFDocument)
        case image(ImageInfo)
        case quickLook
        case binary(Data)
    }

    /// Text files bigger than this open in the byte viewer instead.
    static let maxTextBytes = 64 * 1024 * 1024
    /// Above this, text opens without syntax colouring or line numbers.
    static let largeTextBytes = 4 * 1024 * 1024

    private(set) var kind = DocumentKind(category: .binary, displayName: "File")
    private(set) var content: Content = .quickLook
    /// Set when the content can be shown but not saved back safely.
    private(set) var readOnlyReason: String?
    private(set) var fileSize: Int64 = 0

    override class var autosavesInPlace: Bool { false }
    override class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool { true }
    override class func isNativeType(_ type: String) -> Bool { true }
    override class var readableTypes: [String] { [UTType.item.identifier, UTType.data.identifier, UTType.content.identifier] }

    override func makeWindowControllers() {
        addWindowController(DocumentWindowController(document: self))
    }

    var windowController: DocumentWindowController? {
        windowControllers.first as? DocumentWindowController
    }

    // MARK: Reading

    override func read(from url: URL, ofType typeName: String) throws {
        Automation.mark("readStart")
        defer { Automation.mark("readEnd") }
        var kind = DocumentKind.detect(url: url)
        var readOnly: String?
        let ext = url.pathExtension.lowercased()
        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        let loaded: Content

        switch kind.category {
        case .table:
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let table = TableContent(data: data, forceTab: ext == "tsv" || ext == "tab")
            if table.isTruncated {
                readOnly = "Showing the first \(Formatting.count(TableContent.maximumRows, "row")). Editing is off so nothing gets lost."
            }
            loaded = .table(table)
        case .text, .markdown:
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            if data.count > Document.maxTextBytes || !FileSniffer.looksLikeText(data) {
                if data.count > Document.maxTextBytes {
                    readOnly = "This file is too big to show as text, so here are its bytes."
                }
                kind.category = .binary
                loaded = .binary(data)
            } else if ext == "plist", data.starts(with: Array("bplist".utf8)) {
                loaded = .text(TextContent(text: try PropertyLists.xmlText(from: data)))
                kind.language = .xml
                readOnly = "This is a binary property list, shown as XML. It can't be edited here."
            } else {
                let text = TextContent(decoded: TextDecoding.decode(data))
                loaded = kind.category == .markdown ? .markdown(text) : .text(text)
            }
        case .richText:
            let format = kind.richTextFormat ?? .rtf
            var attributes: NSDictionary?
            let string = try NSAttributedString(url: url, options: [.documentType: format.documentType], documentAttributes: &attributes)
            let documentAttributes = attributes as? [NSAttributedString.DocumentAttributeKey: Any] ?? [:]
            loaded = .richText(RichTextContent(string: string, format: format, attributes: documentAttributes))
        case .pdf:
            guard let pdf = PDFDocument(url: url) else { throw CocoaError(.fileReadCorruptFile) }
            loaded = .pdf(pdf)
        case .image:
            if let info = ImageInfo(url: url) {
                loaded = .image(info)
            } else {
                kind.category = .quickLook
                loaded = .quickLook
            }
        case .quickLook:
            loaded = .quickLook
        case .binary:
            loaded = .binary(try Data(contentsOf: url, options: .alwaysMapped))
        }

        self.kind = kind
        self.content = loaded
        self.readOnlyReason = readOnly
        self.fileSize = size
    }

    // MARK: Writing

    var isWritable: Bool {
        guard readOnlyReason == nil else { return false }
        switch content {
        case .text, .markdown, .richText, .pdf: return true
        case .table(let table): return !table.isLoading && !table.isTruncated
        case .image, .quickLook, .binary: return false
        }
    }

    var supportsEditing: Bool { isWritable }

    override func data(ofType typeName: String) throws -> Data {
        windowController?.finishEditing()
        switch content {
        case .text(let text), .markdown(let text):
            if let data = text.encoded() { return data }
            // Characters the original encoding can't store: save as UTF-8 rather than lose them.
            text.encoding = .utf8
            return text.encoded() ?? Data(text.string.utf8)
        case .table(let table):
            if let data = table.serialized() { return data }
            table.encoding = .utf8
            return table.serialized() ?? Data()
        case .richText(let rich):
            return try rich.storage.data(from: NSRange(location: 0, length: rich.storage.length),
                                         documentAttributes: rich.writingAttributes)
        case .pdf(let pdf):
            guard let data = pdf.dataRepresentation() else { throw CocoaError(.fileWriteUnknown) }
            return data
        case .image, .quickLook, .binary:
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    override func fileWrapper(ofType typeName: String) throws -> FileWrapper {
        if case .richText(let rich) = content, rich.format == .rtfd {
            windowController?.finishEditing()
            return try rich.storage.fileWrapper(from: NSRange(location: 0, length: rich.storage.length),
                                                documentAttributes: rich.writingAttributes)
        }
        return try super.fileWrapper(ofType: typeName)
    }

    override func writableTypes(for saveOperation: NSDocument.SaveOperationType) -> [String] {
        guard isWritable, let type = fileType else { return [] }
        return [type]
    }

    override func fileNameExtension(forType typeName: String, saveOperation: NSDocument.SaveOperationType) -> String? {
        if let ext = fileURL?.pathExtension, !ext.isEmpty { return ext }
        return super.fileNameExtension(forType: typeName, saveOperation: saveOperation)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        let saving: [Selector] = [#selector(save(_:)), #selector(saveAs(_:)), #selector(saveTo(_:)),
                                  #selector(duplicate(_:)), #selector(revertToSaved(_:))]
        if let action = item.action, saving.contains(action), !isWritable { return false }
        return super.validateUserInterfaceItem(item)
    }

    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation {
        guard let operation = windowController?.viewer.printOperation(printInfo: printInfo) else {
            throw CocoaError(.featureUnsupported)
        }
        return operation
    }

    // MARK: Changes on disk

    private var reloadWork: DispatchWorkItem?

    /// Unedited documents follow the file on disk, so logs and exports stay current.
    override func presentedItemDidChange() {
        super.presentedItemDidChange()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.reloadWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.reloadIfChangedOnDisk() }
            self.reloadWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
    }

    private func reloadIfChangedOnDisk() {
        guard !isDocumentEdited, let url = fileURL, let type = fileType,
              let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              modified != fileModificationDate else { return }
        try? revert(toContentsOf: url, ofType: type)
    }

    override func revert(toContentsOf url: URL, ofType typeName: String) throws {
        try super.revert(toContentsOf: url, ofType: typeName)
        windowControllers.forEach { ($0 as? DocumentWindowController)?.documentDidReload() }
    }

    // MARK: Text for AI

    /// The document's current text, including unsaved edits. Must be called on the main thread.
    /// What saving would write right now, worked out without changing anything; nil when it can't be.
    func bytesToSave() -> Data? {
        switch content {
        case .text(let text), .markdown(let text): return text.encoded()
        case .table(let table): return table.serialized()
        case .richText(let rich) where rich.format != .rtfd:
            return try? rich.storage.data(from: NSRange(location: 0, length: rich.storage.length), documentAttributes: rich.writingAttributes)
        default: return nil
        }
    }

    func currentText() -> String? {
        switch content {
        case .text(let text), .markdown(let text): return text.string
        case .table(let table): return table.textForDisplay
        case .richText(let rich): return rich.storage.string
        default: return nil
        }
    }
}

final class DocumentController: NSDocumentController {
    override func documentClass(forType typeName: String) -> AnyClass? { Document.self }

    override var documentClassNames: [String] { [NSStringFromClass(Document.self)] }

    override var defaultType: String? { UTType.plainText.identifier }

    override func typeForContents(of url: URL) throws -> String {
        (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.identifier ?? UTType.data.identifier
    }

    /// Small files are read right here on the main thread: it takes a millisecond or two and skips
    /// two thread hops. Bigger files take AppKit's usual path and are read in the background.
    static let synchronousOpenLimit = 512 * 1024

    override func openDocument(withContentsOf url: URL, display displayDocument: Bool,
                               completionHandler: @escaping (NSDocument?, Bool, Error?) -> Void) {
        if let existing = document(for: url) {
            if displayDocument { existing.showWindows() }
            completionHandler(existing, true, nil)
            return
        }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        guard values?.isDirectory != true, let size = values?.fileSize, size < DocumentController.synchronousOpenLimit else {
            super.openDocument(withContentsOf: url, display: displayDocument, completionHandler: completionHandler)
            return
        }
        do {
            let document = try makeDocument(withContentsOf: url, ofType: try typeForContents(of: url))
            Automation.mark("documentMade")
            addDocument(document)
            Automation.mark("documentAdded")
            if displayDocument {
                document.makeWindowControllers()
                document.showWindows()
            }
            // Open Recent can wait until the file is on screen. A plain async block would still run
            // before the first frame is drawn, hence the short delay.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.noteNewRecentDocument(document) }
            completionHandler(document, false, nil)
        } catch {
            completionHandler(nil, false, error)
        }
    }

    /// Any file can be opened, so the panel doesn't filter by type.
    override func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Choose files to open in Handa"
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls { self.open(url) }
        }
    }

    func open(_ url: URL, completion: ((Document?) -> Void)? = nil) {
        openDocument(withContentsOf: url, display: true) { document, _, error in
            if let error = error, (error as NSError).code != NSUserCancelledError {
                NSApp.presentError(error)
            }
            completion?(document as? Document)
        }
    }
}
