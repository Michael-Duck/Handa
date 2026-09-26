import AppKit
import Darwin
import HandaCore

/// Hooks used by CI to measure launch time and take screenshots. All of them are driven by
/// environment variables and do nothing in normal use.
enum Automation {
    private static let environment = ProcessInfo.processInfo.environment
    private static var reported = false

    static var readyFile: String? { environment["HANDA_READY_FILE"] }
    static var windowSize: NSSize? {
        guard let value = environment["HANDA_WINDOW_SIZE"] else { return nil }
        let parts = value.lowercased().split(separator: "x").compactMap { Double($0) }
        return parts.count == 2 ? NSSize(width: parts[0], height: parts[1]) : nil
    }
    static var initialMode: ViewMode? { environment["HANDA_MODE"].flatMap(ViewMode.init(rawValue:)) }
    static var startEditing: Bool { environment["HANDA_EDIT"] == "1" }
    static var showReviews: Bool { environment["HANDA_SHOW_REVIEWS"] == "1" }
    static var showSidebar: Bool { environment["HANDA_SIDEBAR"] == "1" }
    static var showOnLaunch: String? { environment["HANDA_SHOW"] }
    static var searchText: String? { environment["HANDA_SEARCH"] }

    static func applyAppearance() {
        switch environment["HANDA_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
    }

    /// Opens each file in the running app and times it until its window has drawn,
    /// which is what double-clicking a file feels like once Handa is running.
    private static func benchmarkOpens(_ files: [URL], results: [JSON] = []) {
        guard let url = files.first, let controller = NSDocumentController.shared as? DocumentController else {
            let data = Data(JSON.array(results).serialized().utf8)
            if let output = environment["HANDA_BENCH_RESULT"] {
                try? data.write(to: URL(fileURLWithPath: output), options: .atomic)
            } else {
                FileHandle.standardError.write(data)
            }
            _exit(0)
        }
        let start = Date()
        controller.open(url) { document in
            DispatchQueue.main.async {
                document?.windowController?.window?.displayIfNeeded()
                let ms = (Date().timeIntervalSince(start) * 10_000).rounded() / 10
                let entry: JSON = ["file": .string(url.lastPathComponent), "kind": .string(document?.kind.category.rawValue ?? "failed"), "milliseconds": .number(ms)]
                document?.close()
                benchmarkOpens(Array(files.dropFirst()), results: results + [entry])
            }
        }
    }

    /// When the process started, according to the kernel. Includes dyld and runtime set-up.
    static let processStart: Date? = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }()

    private static var phases: [(String, Double)] = []
    private static let phaseLock = NSLock()

    /// Records how long after launch a step happened. Only active while measuring.
    static func mark(_ name: String) {
        guard readyFile != nil else { return }
        let ms = millisecondsSinceLaunch
        phaseLock.lock()
        phases.append((name, (ms * 10).rounded() / 10))
        phaseLock.unlock()
    }

    private static func recordedPhases() -> [(String, Double)] {
        phaseLock.lock()
        defer { phaseLock.unlock() }
        return phases
    }

    static var millisecondsSinceLaunch: Double {
        guard let start = processStart else { return -1 }
        return Date().timeIntervalSince(start) * 1000
    }

    /// Called once a window has drawn for the first time.
    static func windowReady(_ window: NSWindow, kind: String, file: String?) {
        guard !reported, let path = readyFile else { return }
        reported = true
        let elapsed = millisecondsSinceLaunch
        let payload: JSON = [
            "windowNumber": .number(Double(window.windowNumber)),
            "milliseconds": .number((elapsed * 10).rounded() / 10),
            "kind": .string(kind),
            "file": file.map(JSON.string) ?? .null,
            "frame": [.number(window.frame.origin.x), .number(window.frame.origin.y), .number(window.frame.width), .number(window.frame.height)],
            "phases": .object(Dictionary(recordedPhases().map { ($0.0, JSON.number($0.1)) }, uniquingKeysWith: { first, _ in first })),
        ]
        try? Data(payload.serialized().utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        FileHandle.standardError.write(Data("HANDA_READY \(payload.serialized())\n".utf8))
        if let files = environment["HANDA_BENCH_FILES"], !files.isEmpty {
            DispatchQueue.main.async { benchmarkOpens(files.split(separator: ":").map { URL(fileURLWithPath: String($0)) }) }
        } else if let quit = environment["HANDA_QUIT_AFTER"].flatMap({ Double($0) }) {
            // _exit skips exit-time handlers, which can wait on framework threads and hang a benchmark.
            DispatchQueue.main.asyncAfter(deadline: .now() + quit) { _exit(0) }
        }
    }
}
