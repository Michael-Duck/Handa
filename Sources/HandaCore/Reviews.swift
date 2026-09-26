import Foundation

/// Where Handa keeps its small bits of state. `HANDA_HOME` overrides it (used by tests and CI).
public enum SupportPaths {
    public static var root: URL {
        if let override = ProcessInfo.processInfo.environment["HANDA_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Handa", isDirectory: true)
    }

    public static var sessionFile: URL { root.appendingPathComponent("session.json") }
    public static var reviewsDirectory: URL { root.appendingPathComponent("Reviews", isDirectory: true) }
}

/// A review of one file, written by Claude, another MCP client, or a command.
public struct Review: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var body: String
    public var source: String
    public var createdAt: Date
    /// Hash of the file's bytes when it was reviewed, so unchanged files aren't reviewed twice.
    public var contentHash: String?
    public var instruction: String?

    public init(id: String = UUID().uuidString, title: String, body: String, source: String, createdAt: Date = Date(),
                contentHash: String? = nil, instruction: String? = nil) {
        self.id = id
        self.title = title
        self.body = body
        self.source = source
        self.createdAt = createdAt
        self.contentHash = contentHash
        self.instruction = instruction
    }
}

/// Stores reviews as one small JSON file per reviewed file. Safe to use from several processes (the
/// app and the MCP server): every change holds a lock file, re-reads, and replaces the file atomically.
public final class ReviewStore {
    public let directory: URL
    private let queue = DispatchQueue(label: "handa.reviews")

    public init(directory: URL = SupportPaths.reviewsDirectory) {
        self.directory = directory
    }

    private struct Entry: Codable {
        var path: String
        var reviews: [Review]
    }

    public func fileURL(for path: String) -> URL {
        directory.appendingPathComponent(StableHash.hex(path) + ".json")
    }

    public func reviews(for path: String) -> [Review] {
        queue.sync { load(path)?.reviews ?? [] }.sorted { $0.createdAt > $1.createdAt }
    }

    public func add(_ review: Review, for path: String) throws {
        try changing {
            var entry = load(path) ?? Entry(path: path, reviews: [])
            entry.reviews.append(review)
            // Keep the history short; old reviews rarely matter.
            if entry.reviews.count > 20 { entry.reviews.removeFirst(entry.reviews.count - 20) }
            try save(entry)
        }
    }

    public func remove(id: String, for path: String) throws {
        try changing {
            guard var entry = load(path) else { return }
            entry.reviews.removeAll { $0.id == id }
            if entry.reviews.isEmpty {
                try? FileManager.default.removeItem(at: fileURL(for: path))
            } else {
                try save(entry)
            }
        }
    }

    /// Runs a read-change-write with an exclusive lock that other processes respect too.
    private func changing(_ body: () throws -> Void) throws {
        try queue.sync {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let lock = open(directory.appendingPathComponent(".lock").path, O_CREAT | O_RDWR, 0o644)
            guard lock >= 0 else { return try body() } // Better an unlocked write than a lost review.
            defer { close(lock) }
            flock(lock, LOCK_EX)
            defer { flock(lock, LOCK_UN) }
            try body()
        }
    }

    /// True when a review with this hash and instruction already exists.
    public func hasReview(for path: String, contentHash: String, instruction: String) -> Bool {
        reviews(for: path).contains { $0.contentHash == contentHash && ($0.instruction ?? "") == instruction }
    }

    private func load(_ path: String) -> Entry? {
        guard let data = try? Data(contentsOf: fileURL(for: path)) else { return nil }
        return try? JSONDecoder.handa.decode(Entry.self, from: data)
    }

    private func save(_ entry: Entry) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder.handa.encode(entry)
        try data.write(to: fileURL(for: entry.path), options: .atomic)
    }
}

/// A rule for automatic reviews: files matching `pattern` get reviewed with `instruction`.
public struct ReviewRule: Codable, Equatable, Sendable {
    public var pattern: String
    public var instruction: String
    public var enabled: Bool

    public init(pattern: String, instruction: String, enabled: Bool = true) {
        self.pattern = pattern
        self.instruction = instruction
        self.enabled = enabled
    }

    public func matches(_ path: String) -> Bool {
        enabled && Glob(pattern).matches(path)
    }

    /// The first enabled rule that matches, if any.
    public static func firstMatch(in rules: [ReviewRule], path: String) -> ReviewRule? {
        rules.first { $0.matches(path) }
    }
}

/// What Handa has open right now, shared with the MCP server so AI assistants can see it.
public struct SessionState: Codable, Equatable, Sendable {
    public struct Document: Codable, Equatable, Sendable {
        public var path: String
        public var kind: String
        public var isActive: Bool
        public var isEdited: Bool
        public var selection: String?

        public init(path: String, kind: String, isActive: Bool, isEdited: Bool = false, selection: String? = nil) {
            self.path = path
            self.kind = kind
            self.isActive = isActive
            self.isEdited = isEdited
            self.selection = selection
        }
    }

    public var documents: [Document]
    public var updatedAt: Date
    public var appVersion: String

    public init(documents: [Document], updatedAt: Date = Date(), appVersion: String) {
        self.documents = documents
        self.updatedAt = updatedAt
        self.appVersion = appVersion
    }

    public var active: Document? { documents.first { $0.isActive } ?? documents.first }

    public static func load(from url: URL = SupportPaths.sessionFile) -> SessionState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.handa.decode(SessionState.self, from: data)
    }

    public func write(to url: URL = SupportPaths.sessionFile) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.handa.encode(self).write(to: url, options: .atomic)
    }
}

extension JSONEncoder {
    public static var handa: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    public static var handa: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Lets exactly one of several racing callbacks through.
/// Reads a pipe to the end on its own thread, so that several pipes can be drained at once.
final class PipeReader: @unchecked Sendable {
    private var contents = Data()
    private let finished = DispatchSemaphore(value: 0)

    init(_ handle: FileHandle) {
        DispatchQueue.global().async {
            self.contents = handle.readDataToEndOfFile()
            self.finished.signal()
        }
    }

    /// Waits for the end of the pipe. Call it once.
    func data() -> Data {
        finished.wait()
        return contents
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// Runs a user-configured review command, e.g. `claude -p "{instruction}"`.
///
/// `{file}` and `{instruction}` are replaced with shell-quoted values. The document's text is
/// piped to stdin and whatever the command prints becomes the review.
public enum CommandRunner {
    public enum RunError: Error, LocalizedError {
        case failed(status: Int32, output: String)
        case crashed(signal: Int32, output: String)
        case timedOut
        case emptyOutput

        public var errorDescription: String? {
            switch self {
            case .failed(let status, let output):
                return "The review command exited with status \(status)" + RunError.detail(output)
            case .crashed(let signal, let output):
                return "The review command stopped unexpectedly (signal \(signal))" + RunError.detail(output)
            case .timedOut: return "The review command took too long and was stopped."
            case .emptyOutput: return "The review command didn't print anything."
            }
        }

        private static func detail(_ output: String) -> String {
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "." : ": \(detail.suffix(400))"
        }
    }

    /// Writing to a command that has stopped reading raises SIGPIPE, whose default is to end the
    /// whole app. Ignoring it turns that into an ordinary write error instead.
    private static let ignoreBrokenPipes: Void = { _ = signal(SIGPIPE, SIG_IGN) }()

    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func expand(_ template: String, file: String, instruction: String) -> String {
        template
            .replacingOccurrences(of: "{file}", with: shellQuote(file))
            .replacingOccurrences(of: "{instruction}", with: shellQuote(instruction))
    }

    /// Common places for command line tools that GUI apps don't have on their PATH.
    public static func searchPath(home: String = NSHomeDirectory(), existing: String? = ProcessInfo.processInfo.environment["PATH"]) -> String {
        var extra = ["\(home)/.local/bin", "\(home)/.claude/local", "\(home)/.npm-global/bin", "\(home)/.bun/bin",
                     "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        // Node installed through nvm keeps each version's tools in its own folder; newest first.
        let nvm = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            extra += versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }.map { "\(nvm)/\($0)/bin" }
        }
        var seen = Set<String>()
        return ((existing?.split(separator: ":").map(String.init) ?? []) + extra)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ":")
    }

    @discardableResult
    public static func run(_ command: String, input: String, environment extra: [String: String] = [:],
                           shell: String = FileManager.default.fileExists(atPath: "/bin/zsh") ? "/bin/zsh" : "/bin/sh",
                           timeout: TimeInterval = 600,
                           completion: @escaping (Result<String, Error>) -> Void) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // Not a login shell: profile scripts sometimes print things that would end up in the review.
        process.arguments = ["-c", command]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = searchPath()
        for (key, value) in extra { environment[key] = value }
        process.environment = environment
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let once = Once()
        let finish: @Sendable (Result<String, Error>) -> Void = { result in
            if once.claim() { completion(result) }
        }

        _ = ignoreBrokenPipes
        do {
            try process.run()
        } catch {
            finish(.failure(error))
            return process
        }

        DispatchQueue.global().async {
            // A command may stop reading early; its exit status says whether that mattered.
            try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
        }
        // Drain both pipes at once. Waiting on one while the command fills the other would hang.
        let output = PipeReader(stdout.fileHandleForReading)
        let errors = PipeReader(stderr.fileHandleForReading)
        let timedOut = Flag()
        DispatchQueue.global().async {
            let text = String(decoding: output.data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let problems = String(decoding: errors.data(), as: UTF8.self)
            process.waitUntilExit()
            if process.terminationReason == .uncaughtSignal {
                finish(.failure(timedOut.isSet ? RunError.timedOut : RunError.crashed(signal: process.terminationStatus, output: problems)))
            } else if process.terminationStatus != 0 {
                finish(.failure(RunError.failed(status: process.terminationStatus, output: problems)))
            } else if text.isEmpty {
                finish(.failure(RunError.emptyOutput))
            } else {
                finish(.success(text))
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            guard process.isRunning else { return }
            timedOut.set()
            process.terminate()
            // Child processes can keep the pipes open, so report the timeout without waiting for them.
            finish(.failure(RunError.timedOut))
        }
        return process
    }
}
