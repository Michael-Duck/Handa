import XCTest
import AppKit
import PDFKit
@testable import HandaKit
@testable import HandaCore

/// Tests that need AppKit: reading and saving real files, rendering, viewers and the MCP tools.
final class HandaKitTests: XCTestCase {
    static let samples = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Samples")

    private var temp: URL!

    override class func setUp() {
        super.setUp()
        _ = NSApplication.shared
        Preferences.register()
    }

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("handa-kit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    private func sample(_ name: String) -> URL { Self.samples.appendingPathComponent(name) }

    private func open(_ url: URL) throws -> Document {
        let document = Document()
        try document.read(from: url, ofType: "public.data")
        document.fileURL = url
        return document
    }

    private func copyOfSample(_ name: String) throws -> URL {
        let destination = temp.appendingPathComponent(name)
        try FileManager.default.copyItem(at: sample(name), to: destination)
        return destination
    }

    // MARK: Detection

    func testSampleKinds() throws {
        let expected: [String: FileCategory] = [
            "Quarterly Report.pdf": .pdf, "Team Meeting.docx": .richText, "Sales.csv": .table,
            "Opening Checklist.md": .markdown, "inventory.py": .text, "recipes.json": .text,
            "Harbor.png": .image, "Budget.xlsx": .quickLook,
        ]
        for (name, category) in expected {
            XCTAssertEqual(DocumentKind.detect(url: sample(name)).category, category, name)
        }
        XCTAssertEqual(DocumentKind.detect(url: sample("inventory.py")).language, .python)
    }

    func testUnknownFilesAreSniffed() throws {
        let text = temp.appendingPathComponent("notes.unknownext")
        try Data("#!/bin/bash\necho hi\n".utf8).write(to: text)
        let kind = DocumentKind.detect(url: text)
        XCTAssertEqual(kind.category, .text)
        XCTAssertEqual(kind.language, .shell)

        let binary = temp.appendingPathComponent("blob.unknownext")
        try Data((0..<512).map { UInt8($0 % 256) }).write(to: binary)
        XCTAssertEqual(DocumentKind.detect(url: binary).category, .binary)
        let document = try open(binary)
        guard case .binary(let data) = document.content else { return XCTFail("expected bytes") }
        XCTAssertEqual(data.count, 512)
        XCTAssertFalse(document.isWritable)
    }

    // MARK: Saving

    func testCSVEditRoundTrip() throws {
        let url = try copyOfSample("Sales.csv")
        let original = try Data(contentsOf: url)
        let document = try open(url)
        guard case .table(let table) = document.content else { return XCTFail("expected a table") }
        XCTAssertTrue(table.hasHeaderRow)
        XCTAssertEqual(table.columnCount, 7)
        XCTAssertEqual(table.dataRowCount, 150)

        // Unchanged tables save byte for byte.
        XCTAssertEqual(try document.data(ofType: "public.comma-separated-values-text"), original)

        table.setValue("Rye bread, large", row: 1, column: 2)
        let saved = try document.data(ofType: "public.comma-separated-values-text")
        let reparsed = CSV.parse(saved)
        XCTAssertEqual(reparsed.rows.count, 151)
        XCTAssertEqual(reparsed.rows[1][2], "Rye bread, large")
        let originalRows = CSV.parse(original).rows
        XCTAssertEqual(Array(reparsed.rows.dropFirst(2)), Array(originalRows.dropFirst(2)))
    }

    func testLatin1TextStaysLatin1() throws {
        let url = temp.appendingPathComponent("menu.txt")
        try Data([0x43, 0x61, 0x66, 0xE9, 0x0D, 0x0A]).write(to: url) // "Café\r\n" in Windows Latin 1
        let document = try open(url)
        guard case .text(let text) = document.content else { return XCTFail("expected text") }
        XCTAssertEqual(text.string, "Café\n")
        text.storage.append(NSAttributedString(string: "Crème\n"))
        let saved = try document.data(ofType: "public.plain-text")
        XCTAssertEqual(saved, Data([0x43, 0x61, 0x66, 0xE9, 0x0D, 0x0A, 0x43, 0x72, 0xE8, 0x6D, 0x65, 0x0D, 0x0A]))
    }

    func testUnrepresentableCharactersFallBackToUTF8() throws {
        let url = temp.appendingPathComponent("latin.txt")
        try Data([0x63, 0x61, 0x66, 0xE9]).write(to: url)
        let document = try open(url)
        guard case .text(let text) = document.content else { return XCTFail("expected text") }
        text.storage.append(NSAttributedString(string: " 🙂"))
        let saved = try document.data(ofType: "public.plain-text")
        XCTAssertEqual(String(data: saved, encoding: .utf8), "café 🙂")
    }

    func testWordDocumentOpensAndSaves() throws {
        let document = try open(sample("Team Meeting.docx"))
        guard case .richText(let rich) = document.content else { return XCTFail("expected rich text") }
        XCTAssertTrue(rich.storage.string.contains("Action items"))
        XCTAssertTrue(rich.storage.string.contains("Finalise chestnut tart recipe"))
        let saved = try document.data(ofType: "org.openxmlformats.wordprocessingml.document")
        let reopened = try NSAttributedString(data: saved, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil)
        XCTAssertTrue(reopened.string.contains("Action items"))
        XCTAssertTrue(reopened.string.contains("Good bread is worth waking up early for"))
    }

    func testPDFAnnotationsAreSaved() throws {
        let document = try open(sample("Quarterly Report.pdf"))
        guard case .pdf(let pdf) = document.content, let page = pdf.page(at: 0) else { return XCTFail("expected a PDF") }
        XCTAssertEqual(pdf.pageCount, 2)
        let highlight = PDFAnnotation(bounds: NSRect(x: 72, y: 700, width: 200, height: 14), forType: .highlight, withProperties: nil)
        page.addAnnotation(highlight)
        let saved = try document.data(ofType: "com.adobe.pdf")
        let reopened = try XCTUnwrap(PDFDocument(data: saved))
        XCTAssertEqual(reopened.pageCount, 2)
        XCTAssertTrue(reopened.page(at: 0)?.annotations.contains { $0.type == "Highlight" } ?? false)
    }

    func testReadOnlyKindsRefuseToSave() throws {
        for name in ["Harbor.png", "Budget.xlsx"] {
            let document = try open(sample(name))
            XCTAssertFalse(document.isWritable, name)
            XCTAssertThrowsError(try document.data(ofType: "public.data"), name)
        }
    }

    // MARK: Text extraction

    func testTextExtraction() throws {
        XCTAssertTrue(try TextExtractor.extract(url: sample("Quarterly Report.pdf")).text.contains("Third Quarter Report"))
        XCTAssertTrue(try TextExtractor.extract(url: sample("Quarterly Report.pdf")).text.contains("--- Page 2 ---"))
        XCTAssertTrue(try TextExtractor.extract(url: sample("Team Meeting.docx")).text.contains("Who was there"))
        XCTAssertTrue(try TextExtractor.extract(url: sample("Sales.csv")).details.contains("7 columns"))
        XCTAssertTrue(try TextExtractor.extract(url: sample("Sales.csv")).text.contains("Cinnamon bun"))
        XCTAssertTrue(try TextExtractor.extract(url: sample("Opening Checklist.md")).text.contains("# Opening checklist"))
        XCTAssertEqual(try TextExtractor.extract(url: sample("Harbor.png")).details.hasPrefix("1440 × 900 px"), true)
        XCTAssertThrowsError(try TextExtractor.extract(url: temp.appendingPathComponent("missing.pdf")))
    }

    // MARK: Markdown

    func testMarkdownRendering() throws {
        let source = try String(contentsOf: sample("Opening Checklist.md"), encoding: .utf8)
        let rendered = MarkdownRenderer.render(source)
        let text = rendered.string
        XCTAssertTrue(text.hasPrefix("Opening checklist"))
        XCTAssertFalse(text.contains("# "), "heading markers should be gone")
        XCTAssertTrue(text.contains("☑\t"), "done tasks get a ticked box")
        XCTAssertTrue(text.contains("☐\t"), "open tasks get an empty box")
        XCTAssertTrue(text.contains("1.\tTurn on both deck ovens"))
        XCTAssertTrue(text.contains("./till open"))

        let titleFont = rendered.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertGreaterThan(titleFont?.pointSize ?? 0, 20)

        let codeLocation = (text as NSString).range(of: "./till open").location
        let codeFont = rendered.attribute(.font, at: codeLocation, effectiveRange: nil) as? NSFont
        XCTAssertTrue(codeFont?.isFixedPitch ?? false, "code blocks are monospaced")
        XCTAssertNotNil(rendered.attribute(MarkdownRenderer.codeBlockKey, at: codeLocation, effectiveRange: nil), "code blocks get a drawn box")
        let quoteLocation = (text as NSString).range(of: "If an oven shows error").location
        XCTAssertNotNil(rendered.attribute(MarkdownRenderer.quoteKey, at: quoteLocation, effectiveRange: nil), "quotes get a bar")
        XCTAssertNotNil(rendered.attribute(MarkdownRenderer.ruleKey, at: 0, effectiveRange: nil), "big headings get a rule")

        var sawTableCell = false, sawLink = false
        rendered.enumerateAttributes(in: NSRange(location: 0, length: rendered.length)) { attributes, _, _ in
            if let style = attributes[.paragraphStyle] as? NSParagraphStyle, style.textBlocks.contains(where: { $0 is NSTextTableBlock }) {
                sawTableCell = true
            }
            if attributes[.link] != nil { sawLink = true }
        }
        XCTAssertTrue(sawTableCell, "tables become real text tables")
        XCTAssertTrue(sawLink)
    }

    func testMarkdownEdgeCases() {
        for source in ["", "plain", "| a |\n|---|\n|  |", "- [ ] only task", "```\nno language\n```", "> quote\n>\n> more", "* a\n  * b\n    * c"] {
            _ = MarkdownRenderer.render(source) // must not crash
        }
        let nested = MarkdownRenderer.render("* a\n  * b\n    * c").string
        XCTAssertTrue(nested.contains("•\ta"))
        XCTAssertTrue(nested.contains("◦\tb"))
        XCTAssertTrue(nested.contains("▪\tc"))
    }

    // MARK: Windows and viewers

    func testEveryViewerLoads() throws {
        let expected: [String: Viewer.Type] = [
            "Quarterly Report.pdf": PDFViewer.self, "Team Meeting.docx": QuickLookViewer.self, "Sales.csv": TableViewer.self,
            "Opening Checklist.md": MarkdownViewer.self, "inventory.py": TextViewer.self, "recipes.json": TextViewer.self,
            "Harbor.png": ImageViewer.self, "Budget.xlsx": QuickLookViewer.self,
        ]
        for (name, type) in expected {
            let document = try open(sample(name))
            document.makeWindowControllers()
            let controller = try XCTUnwrap(document.windowController, name)
            XCTAssertNotNil(controller.window, name)
            XCTAssertTrue(Swift.type(of: controller.viewer) == type, "\(name) opened in \(Swift.type(of: controller.viewer))")
            XCTAssertFalse(controller.viewer.statusText.isEmpty, name)
            controller.window?.close()
            document.close()
        }
    }

    func testEditingAndModes() throws {
        let url = try copyOfSample("Opening Checklist.md")
        let document = try open(url)
        document.makeWindowControllers()
        let controller = try XCTUnwrap(document.windowController)
        XCTAssertTrue(controller.viewer is MarkdownViewer)
        controller.setEditing(true, confirmed: true)
        XCTAssertTrue(controller.isEditingEnabled)
        XCTAssertTrue(controller.viewer is TextViewer, "editing Markdown shows the source")
        controller.setEditing(false)
        XCTAssertTrue(controller.viewer is MarkdownViewer, "and goes back to the preview")
        controller.setMode(.source)
        XCTAssertEqual(controller.mode, .source)
        controller.window?.close()
        document.close()
    }

    func testWordPreviewsOriginalAndEditsAsText() throws {
        let url = try copyOfSample("Team Meeting.docx")
        let document = try open(url)
        document.makeWindowControllers()
        let controller = try XCTUnwrap(document.windowController)
        XCTAssertEqual(controller.mode, .quickLook, "Word files open in their original layout")
        XCTAssertTrue(controller.viewer is QuickLookViewer)
        controller.setEditing(true, confirmed: true)
        XCTAssertTrue(controller.viewer is RichTextViewer, "editing uses Handa's text view")
        XCTAssertTrue(controller.isEditingEnabled)
        controller.setEditing(false)
        XCTAssertTrue(controller.viewer is QuickLookViewer, "and goes back when nothing changed")
        XCTAssertEqual(DocumentKind.detect(url: url).category, .richText)
        controller.window?.close()
        document.close()
    }

    func testRTFStaysNative() throws {
        let url = temp.appendingPathComponent("letter.rtf")
        try Data(#"{\rtf1\ansi{\fonttbl\f0 Helvetica;}\f0 Hello \b there\b0.}"#.utf8).write(to: url)
        let document = try open(url)
        document.makeWindowControllers()
        XCTAssertTrue(document.windowController?.viewer is RichTextViewer)
        document.windowController?.window?.close()
        document.close()
    }

    /// Lays out and draws rendered Markdown in a real window. Text layout bugs only show up here.
    func testMarkdownLaysOutAndDraws() throws {
        let document = try open(sample("Opening Checklist.md"))
        document.makeWindowControllers()
        let controller = try XCTUnwrap(document.windowController)
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 900, height: 700))
        window.orderFront(nil)
        window.displayIfNeeded()
        let textView = try XCTUnwrap(findTextView(in: controller.viewer.view))
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        layoutManager.ensureLayout(for: try XCTUnwrap(textView.textContainer))
        let title = layoutManager.boundingRect(forGlyphRange: NSRange(location: 0, length: 17), in: textView.textContainer!)
        XCTAssertGreaterThan(title.width, 150, "the title is laid out on one line")
        XCTAssertLessThan(title.height, 60)
        window.close()
        document.close()
    }

    private func findTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView { return textView }
        for subview in view.subviews { if let found = findTextView(in: subview) { return found } }
        return nil
    }

    func testTableViewerFilterAndStatus() throws {
        let document = try open(sample("Sales.csv"))
        document.makeWindowControllers()
        let viewer = try XCTUnwrap(document.windowController?.viewer as? TableViewer)
        XCTAssertEqual(viewer.tableView.numberOfRows, 150)
        viewer.search("cinnamon")
        XCTAssertGreaterThan(viewer.tableView.numberOfRows, 0)
        XCTAssertLessThan(viewer.tableView.numberOfRows, 150)
        XCTAssertTrue(viewer.statusText.contains("match"))
        viewer.search("")
        XCTAssertEqual(viewer.tableView.numberOfRows, 150)
        document.windowController?.window?.close()
        document.close()
    }

    /// Two windows of the same kind can have different buttons (HTML has a view switch, plain text
    /// doesn't). Turning AI off and on must leave each toolbar with its own buttons.
    func testToolbarsOfTheSameKindStayIndependent() throws {
        let html = temp.appendingPathComponent("page.html")
        try Data("<p>Hello</p>".utf8).write(to: html)
        let text = temp.appendingPathComponent("notes.txt")
        try Data("Hello".utf8).write(to: text)
        let wasOn = Preferences.aiEnabled
        defer { Preferences.aiEnabled = wasOn }
        Preferences.aiEnabled = true
        let documents = try [html, text].map { try open($0) }
        documents.forEach { $0.makeWindowControllers() }
        let toolbars = try documents.map { try XCTUnwrap($0.windowController?.window?.toolbar) }
        XCTAssertNotEqual(toolbars[0].items.count, toolbars[1].items.count, "the HTML window has the view switch")
        let before = toolbars.map { $0.items.map(\.itemIdentifier) }

        Preferences.aiEnabled = false
        for toolbar in toolbars {
            XCTAssertFalse(toolbar.items.contains { $0.itemIdentifier == .handaReview })
            XCTAssertTrue(toolbar.items.contains { $0.itemIdentifier == .handaShare })
        }
        Preferences.aiEnabled = true
        XCTAssertEqual(toolbars.map { $0.items.map(\.itemIdentifier) }, before)
        for document in documents {
            document.windowController?.window?.close()
            document.close()
        }
    }

    /// Numbers sort as numbers ahead of text, and equal values ("1" and "1.0") keep the file's order
    /// both ways round.
    func testTableSortsNumbersAndTiesConsistently() throws {
        let url = temp.appendingPathComponent("scores.csv")
        try Data("name,score\na,10\nb,n/a\nc,9\nd,1\ne,1.0\n".utf8).write(to: url)
        let document = try open(url)
        document.makeWindowControllers()
        let viewer = try XCTUnwrap(document.windowController?.viewer as? TableViewer)
        let table = try XCTUnwrap(viewer.tableView)
        func names() -> [String] {
            let column = table.tableColumns[1]
            return (0..<table.numberOfRows).map { row in
                (viewer.tableView(table, viewFor: column, row: row) as? NSTableCellView)?.textField?.stringValue ?? ""
            }
        }
        table.sortDescriptors = [NSSortDescriptor(key: "c1", ascending: true)]
        XCTAssertEqual(names(), ["d", "e", "c", "a", "b"])
        table.sortDescriptors = [NSSortDescriptor(key: "c1", ascending: false)]
        XCTAssertEqual(names(), ["b", "a", "c", "d", "e"])
        document.windowController?.window?.close()
        document.close()
    }

    /// Table cells are placed by hand rather than with constraints, so check they fill their column.
    func testTableCellsFillTheirColumns() throws {
        let document = try open(sample("Sales.csv"))
        document.makeWindowControllers()
        let controller = try XCTUnwrap(document.windowController)
        let viewer = try XCTUnwrap(controller.viewer as? TableViewer)
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 900, height: 600))
        window.orderFront(nil)
        window.displayIfNeeded()
        for column in [0, 3, 5] {
            let cell = try XCTUnwrap(viewer.tableView.view(atColumn: column, row: 0, makeIfNecessary: true) as? NSTableCellView)
            let field = try XCTUnwrap(cell.textField)
            XCTAssertEqual(cell.frame.width, viewer.tableView.tableColumns[column].width, accuracy: 1)
            XCTAssertEqual(field.frame.width, cell.bounds.width - 16, accuracy: 1, "column \(column)")
            XCTAssertEqual(field.frame.midY, cell.bounds.midY, accuracy: 1.5, "column \(column)")
            XCTAssertFalse(field.stringValue.isEmpty, "column \(column)")
        }
        window.close()
        document.close()
    }

    func testDefaultAppChoices() {
        // macOS 26.4 and later ask to confirm each file type, so Make Default keeps to five.
        XCTAssertEqual(DefaultApps.essentials.map(\.title), ["PDF", "Word", "CSV", "Markdown", "Plain text"])
        XCTAssertEqual(DefaultApps.essentials.flatMap(\.types).count, 5)
        XCTAssertTrue(DefaultApps.essentials.map(\.extensions).contains(".pdf"))
        let all = DefaultApps.categories.flatMap(\.types)
        XCTAssertEqual(Set(all).count, all.count, "no file type is listed twice")
        for category in DefaultApps.categories {
            XCTAssertFalse(category.types.isEmpty, category.title)
            XCTAssertFalse(category.extensions.isEmpty, category.title)
        }
    }

    // MARK: MCP

    func testMCPToolsOnRealFiles() throws {
        let store = ReviewStore(directory: temp.appendingPathComponent("Reviews"))
        let pdf = sample("Quarterly Report.pdf").path
        let session = SessionState(documents: [
            .init(path: sample("Sales.csv").path, kind: "CSV", isActive: false),
            .init(path: pdf, kind: "PDF Document", isActive: true, selection: "Revenue by month"),
        ], appVersion: "test")
        let server = HandaMCP.makeServer(store: store, session: { session })

        func call(_ name: String, _ arguments: JSON) throws -> String {
            let request: JSON = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": .string(name), "arguments": arguments]]
            let response = try XCTUnwrap(server.handle(request))
            XCTAssertEqual(response["result"]?["isError"]?.bool, false, "\(name) failed: \(response.serialized())")
            return response["result"]?["content"]?.array?.first?["text"]?.string ?? ""
        }

        XCTAssertTrue(try call("list_open_files", [:]).contains("[in front]"))
        let active = try call("get_active_file", [:])
        XCTAssertTrue(active.contains("Third Quarter Report"))
        XCTAssertTrue(active.contains("Revenue by month"))
        XCTAssertTrue(try call("read_file", ["path": .string(sample("Team Meeting.docx").path)]).contains("Action items"))
        let paged = try call("read_file", ["path": .string(sample("Sales.csv").path), "max_characters": 100])
        XCTAssertTrue(paged.contains("Call again with offset=100"))
        XCTAssertTrue(try call("add_review", ["path": .string(pdf), "review": "Looks **great**.", "title": "Check"]).contains("Saved"))
        XCTAssertEqual(store.reviews(for: pdf).first?.title, "Check")

        let noSession = HandaMCP.makeServer(store: store, session: { nil })
        let request: JSON = ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "get_active_file", "arguments": [:]]]
        XCTAssertTrue(noSession.handle(request)?["result"]?["content"]?.array?.first?["text"]?.string?.contains("Settings → AI") ?? false)

        let prompt: JSON = ["jsonrpc": "2.0", "id": 3, "method": "prompts/get", "params": ["name": "review_active_file", "arguments": ["focus": "totals"]]]
        let text = server.handle(prompt)?["result"]?["messages"]?.array?.first?["content"]?["text"]?.string ?? ""
        XCTAssertTrue(text.contains("Focus on: totals"))
        XCTAssertTrue(text.contains("Third Quarter Report"))
    }

    func testPaging() {
        XCTAssertEqual(HandaMCP.page("abcdef", arguments: [:]), "abcdef")
        XCTAssertEqual(HandaMCP.page("abcdef", arguments: ["max_characters": 4]), "abcd\n\n[Showing characters 0–4 of 6. Call again with offset=4 to read more.]")
        XCTAssertEqual(HandaMCP.page("abcdef", arguments: ["offset": 4, "max_characters": 4]), "ef\n\n[Showing characters 4–6 of 6.]")
        XCTAssertEqual(HandaMCP.page("abc", arguments: ["offset": 99]), "\n\n[Showing characters 3–3 of 3.]")
    }

    // MARK: Misc

    func testFolderNavigation() {
        let names = ["Budget.xlsx", "Harbor.png", "inventory.py", "Opening Checklist.md", "Quarterly Report.pdf", "recipes.json", "Sales.csv", "Team Meeting.docx"]
        let next = FolderNavigator.sibling(of: sample("Budget.xlsx"), offset: 1)
        XCTAssertEqual(next?.lastPathComponent, names[1])
        XCTAssertNil(FolderNavigator.sibling(of: sample("Budget.xlsx"), offset: -1))
        XCTAssertEqual(FolderNavigator.sibling(of: sample("Team Meeting.docx"), offset: -1)?.lastPathComponent, "Sales.csv")
    }

    func testClaudeConfigSnippet() throws {
        let snippet = HandaMCP.claudeDesktopSnippet
        let json = try JSON.parse(snippet)
        XCTAssertEqual(json["mcpServers"]?["handa"]?["args"]?.array?.first?.string, "mcp")
        XCTAssertTrue(HandaMCP.claudeCodeCommand.hasPrefix("claude mcp add --scope user handa -- "))
    }
}
