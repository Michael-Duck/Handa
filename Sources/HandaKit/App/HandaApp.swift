import AppKit
import HandaCore

/// Entry point. Handles the command line tools first so they never pay for starting the UI.
public enum HandaApp {
    static let usage = """
    Handa \(AppInfo.version) — \(AppInfo.slogan).

    Usage:
      Handa [file …]          Open files in Handa
      Handa extract <file …>  Print the text inside PDFs, Word documents, CSVs and more
      Handa mcp               Run Handa's MCP server over stdio (for Claude and other assistants)
      Handa make-default      Make Handa the default app for PDFs, Word, CSV, Markdown, text and images
      Handa --version
    """

    public static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        switch arguments.first {
        case "mcp":
            HandaMCP.run()
        case "extract":
            exit(extract(Array(arguments.dropFirst())))
        case "make-default":
            exit(makeDefault())
        case "--version", "-v":
            print(AppInfo.version)
            exit(0)
        case "--help", "-h", "help":
            print(usage)
            exit(0)
        default:
            break
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // The first document controller created becomes the shared one.
        _ = DocumentController()
        _ = app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }

    private static func extract(_ paths: [String]) -> Int32 {
        guard !paths.isEmpty else {
            FileHandle.standardError.write(Data("Usage: Handa extract <file …>\n".utf8))
            return 64
        }
        var status: Int32 = 0
        for path in paths {
            do {
                let result = try TextExtractor.extract(url: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
                if paths.count > 1 { print("==> \(path) <==") }
                print(result.text)
            } catch {
                FileHandle.standardError.write(Data("\(path): \(error.localizedDescription)\n".utf8))
                status = 1
            }
        }
        return status
    }

    private static func makeDefault() -> Int32 {
        var finished = false
        var failures: [Error] = []
        DefaultApps.makeDefault(DefaultApps.categories) { errors in
            failures = errors
            finished = true
        }
        let deadline = Date().addingTimeInterval(30)
        while !finished, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        if !finished {
            print("Timed out waiting for macOS.")
            return 1
        }
        if failures.isEmpty {
            print("Handa is now the default app for PDFs, Word documents, CSV, Markdown, text, code and images.")
            return 0
        }
        print("Some file types couldn't be changed: \(failures.map(\.localizedDescription).joined(separator: "; "))")
        return 1
    }
}
