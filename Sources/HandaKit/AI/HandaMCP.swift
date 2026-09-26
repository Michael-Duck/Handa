import AppKit
import HandaCore

/// Handa's MCP server: `Handa.app/Contents/MacOS/Handa mcp`.
/// Lets Claude (or any MCP client) see what's open in Handa, read files as text and leave reviews.
enum HandaMCP {
    static let defaultPageSize = 60_000

    private final class Context {
        var server: MCPServer?
    }

    static func makeServer(store: ReviewStore = ReviewStore(), session: @escaping () -> SessionState? = { SessionState.load() }) -> MCPServer {
        let context = Context()
        let pageArguments: [String: JSON] = [
            "offset": ["type": "integer", "description": "Character offset to start from, for reading long files in parts. Defaults to 0.", "minimum": 0],
            "max_characters": ["type": "integer", "description": "How many characters to return. Defaults to \(defaultPageSize).", "minimum": 1],
        ]

        let listOpen = MCPTool(
            name: "list_open_files", title: "List open files",
            description: "Lists the files open in Handa, which one is in front, and whether any have unsaved changes.",
            inputSchema: ["type": "object", "properties": [:]]) { _ in
                guard let state = session() else { return .text(notSharingMessage) }
                if state.documents.isEmpty { return .text("Handa has no files open.") }
                let lines = state.documents.map { document -> String in
                    var line = "- \(document.path) (\(document.kind))"
                    if document.isActive { line += " [in front]" }
                    if document.isEdited { line += " [unsaved changes]" }
                    return line
                }
                return .text(lines.joined(separator: "\n"))
            }

        let getActive = MCPTool(
            name: "get_active_file", title: "Read the file in front",
            description: "Returns the text of the file the user is looking at in Handa, plus anything they have selected. Works for PDFs, Word documents, spreadsheets saved as CSV, Markdown, code and plain text.",
            inputSchema: ["type": "object", "properties": .object(pageArguments)]) { arguments in
                guard let state = session() else { return .text(notSharingMessage) }
                guard let active = state.active else { return .text("Handa has no files open.") }
                var header = "File: \(active.path)\nKind: \(active.kind)\n"
                if active.isEdited { header += "Note: this file has unsaved changes in Handa. The text below is the saved version.\n" }
                if let selection = active.selection, !selection.isEmpty {
                    header += "\nThe user has selected:\n<selection>\n\(selection)\n</selection>\n"
                }
                let extraction = try TextExtractor.extract(url: URL(fileURLWithPath: active.path))
                return .text(header + "\n" + page(extraction.text, arguments: arguments))
            }

        var readProperties = pageArguments
        readProperties["path"] = ["type": "string", "description": "Absolute path to the file. ~ is expanded."]
        let readFile = MCPTool(
            name: "read_file", title: "Read a file as text",
            description: "Extracts the text of a file on this Mac: PDF (with page markers), Word (.docx, .doc), RTF, OpenDocument, CSV/TSV, Markdown, code and plain text. Other files return a short description.",
            inputSchema: ["type": "object", "properties": .object(readProperties), "required": ["path"]]) { arguments in
                guard let path = arguments["path"]?.string, !path.isEmpty else { return .error("path is required") }
                let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                let extraction = try TextExtractor.extract(url: url)
                let header = "File: \(url.path)\nKind: \(extraction.kind) (\(extraction.details))\n\n"
                return .text(header + page(extraction.text, arguments: arguments))
            }

        let openFile = MCPTool(
            name: "open_file", title: "Open a file in Handa",
            description: "Opens a file in Handa so the user can see it.",
            inputSchema: ["type": "object", "properties": ["path": ["type": "string", "description": "Absolute path to the file. ~ is expanded."]], "required": ["path"]],
            readOnly: false) { arguments in
                guard let path = arguments["path"]?.string, !path.isEmpty else { return .error("path is required") }
                let expanded = (path as NSString).expandingTildeInPath
                guard FileManager.default.fileExists(atPath: expanded) else { return .error("No file at \(expanded).") }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                process.arguments = ["-a", Bundle.main.bundleURL.path, expanded]
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { return .error("Couldn't open \(expanded).") }
                return .text("Opened \((expanded as NSString).lastPathComponent) in Handa.")
            }

        let addReview = MCPTool(
            name: "add_review", title: "Add a review to a file",
            description: "Saves a review or notes about a file. Handa shows it in the Reviews panel next to that file. Use Markdown.",
            inputSchema: ["type": "object", "properties": [
                "path": ["type": "string", "description": "Absolute path of the reviewed file."],
                "review": ["type": "string", "description": "The review, in Markdown."],
                "title": ["type": "string", "description": "Optional short title, like \"Contract review\"."],
            ], "required": ["path", "review"]],
            readOnly: false) { arguments in
                guard let path = arguments["path"]?.string, let body = arguments["review"]?.string, !body.isEmpty else {
                    return .error("path and review are required")
                }
                let expanded = (path as NSString).expandingTildeInPath
                let client = context.server?.clientName ?? "an assistant"
                let review = Review(title: arguments["title"]?.string ?? "Review", body: body, source: "MCP · \(client)")
                try store.add(review, for: expanded)
                return .text("Saved. It appears in Handa's Reviews panel for \((expanded as NSString).lastPathComponent).")
            }

        let reviewPrompt = MCPPrompt(
            name: "review_active_file", title: "Review the file open in Handa",
            description: "Reviews whatever file is in front in Handa.",
            arguments: [.init(name: "focus", description: "What to pay attention to, e.g. \"totals\" or \"risky clauses\".")]) { arguments in
                guard let active = session()?.active else { return "Handa isn't sharing an open file. Ask me to open one first." }
                let text = (try? TextExtractor.extract(url: URL(fileURLWithPath: active.path)).text) ?? "(No text could be extracted.)"
                let focus = arguments["focus"].map { "\nFocus on: \($0)\n" } ?? ""
                return """
                Please review this file that I have open in Handa.
                \(focus)
                <document path="\(active.path)" kind="\(active.kind)">
                \(text.prefix(200_000))
                </document>

                Point out problems and suggestions, most important first. Then save your review with the add_review tool so it shows up next to the file in Handa.
                """
            }

        let summaryPrompt = MCPPrompt(
            name: "summarize_active_file", title: "Summarize the file open in Handa",
            description: "A short summary of the file in front in Handa.") { _ in
                guard let active = session()?.active else { return "Handa isn't sharing an open file." }
                let text = (try? TextExtractor.extract(url: URL(fileURLWithPath: active.path)).text) ?? ""
                return "Summarize this file in a few short paragraphs, then list the key points.\n\n<document path=\"\(active.path)\">\n\(text.prefix(200_000))\n</document>"
            }

        let server = MCPServer(
            name: "handa", title: "Handa", version: AppInfo.version,
            instructions: "Handa is the user's file viewer on macOS. Use get_active_file to see what they're looking at, read_file to read any document as text, and add_review to leave feedback that appears next to the file in Handa.",
            tools: [listOpen, getActive, readFile, openFile, addReview],
            prompts: [reviewPrompt, summaryPrompt])
        context.server = server
        return server
    }

    static let notSharingMessage = "Handa isn't sharing its open files. Open Handa, go to Settings → AI and turn on AI features. (read_file works without it.)"

    /// Returns one page of text with an explicit note when there's more, so nothing is silently cut off.
    static func page(_ text: String, arguments: JSON) -> String {
        let total = text.count
        let offset = min(max(arguments["offset"]?.int ?? 0, 0), total)
        let size = max(arguments["max_characters"]?.int ?? defaultPageSize, 1)
        let start = text.index(text.startIndex, offsetBy: offset)
        let end = text.index(start, offsetBy: min(size, total - offset))
        var result = String(text[start..<end])
        let shownEnd = offset + text.distance(from: start, to: end)
        if offset > 0 || shownEnd < total {
            result += "\n\n[Showing characters \(offset)–\(shownEnd) of \(total)."
            result += shownEnd < total ? " Call again with offset=\(shownEnd) to read more.]" : "]"
        }
        return result
    }

    static func run() -> Never {
        let server = makeServer()
        FileHandle.standardError.write(Data("Handa MCP server \(AppInfo.version) ready on stdio.\n".utf8))
        server.run()
        exit(0)
    }

    // MARK: Connecting clients

    static var claudeDesktopConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
    }

    static var serverConfig: [String: Any] {
        ["command": AppInfo.executablePath, "args": ["mcp"]]
    }

    static var claudeDesktopSnippet: String {
        let object: [String: Any] = ["mcpServers": ["handa": serverConfig]]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static var claudeCodeCommand: String {
        "claude mcp add --scope user handa -- \(CommandRunner.shellQuote(AppInfo.executablePath)) mcp"
    }

    /// Adds Handa to Claude Desktop's config, keeping a backup of the original file.
    static func addToClaudeDesktop() throws {
        let url = claudeDesktopConfigURL
        var config: [String: Any] = [:]
        if let data = try? Data(contentsOf: url), !data.isEmpty {
            guard let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "Claude Desktop's config file isn't valid JSON, so Handa left it alone."])
            }
            config = existing
            try? data.write(to: url.appendingPathExtension("handa-backup"), options: .atomic)
        }
        var servers = config["mcpServers"] as? [String: Any] ?? [:]
        servers["handa"] = serverConfig
        config["mcpServers"] = servers
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }
}
