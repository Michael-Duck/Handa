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
      Handa make-default      Make Handa the default app for PDF, Word, CSV, Markdown and text files
                              (add --all for older Word formats, TSV, JSON, logs, code and images too)
      Handa --version
    """

    public static func main() {
        Automation.mark("main")
        let arguments = Array(CommandLine.arguments.dropFirst())
        switch arguments.first {
        case "mcp":
            HandaMCP.run()
        case "extract":
            exit(extract(Array(arguments.dropFirst())))
        case "make-default":
            exit(makeDefault(all: arguments.contains("--all")))
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
        // Inside Handa.app this is already true, and asking again costs launch time. `swift run` needs it.
        if Bundle.main.bundleIdentifier == nil { _ = app.setActivationPolicy(.regular) }
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

    private static func makeDefault(all: Bool) -> Int32 {
        setvbuf(stdout, nil, _IOLBF, 0) // show progress as it happens, even through a pipe
        let categories = all ? DefaultApps.categories : DefaultApps.essentials
        let count = categories.flatMap(\.types).count
        if DefaultApps.asksToConfirm {
            print("macOS may ask you to confirm some of these \(count) file types.")
        }
        var finished = false
        var failures = 0
        DefaultApps.makeDefault(categories, progress: { type, error in
            let name = type.preferredFilenameExtension.map { "." + $0 } ?? type.identifier
            if let error = error {
                failures += 1
                print("\(name): not changed (\(error.localizedDescription))")
            } else {
                print("\(name): Handa")
            }
        }, completion: { _ in finished = true })
        // Leave time to answer macOS's questions when it asks them.
        let deadline = Date().addingTimeInterval(DefaultApps.asksToConfirm ? 180 : 30)
        while !finished, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        if !finished {
            print("Stopped waiting for macOS. Anything you confirm from now on still takes effect.")
            return 2
        }
        return failures == 0 ? 0 : 1
    }
}
