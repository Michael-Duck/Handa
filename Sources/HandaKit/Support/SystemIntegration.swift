import AppKit
import Security
import ServiceManagement
import UniformTypeIdentifiers
import HandaCore

/// Finds the next and previous file in a folder, in Finder's name order.
enum FolderNavigator {
    static func sibling(of url: URL, offset: Int) -> URL? {
        let folder = url.deletingLastPathComponent()
        let keys: [URLResourceKey] = [.isRegularFileKey, .isPackageKey, .isHiddenKey]
        guard let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                       options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else { return nil }
        let files = items.filter { item in
            let values = try? item.resourceValues(forKeys: Set(keys))
            return values?.isRegularFile == true || values?.isPackage == true
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard !files.isEmpty else { return nil }
        let current = files.firstIndex { $0.standardizedFileURL.path == url.standardizedFileURL.path } ?? -1
        let next = current + offset
        guard files.indices.contains(next) else { return nil }
        return files[next]
    }
}

/// Setting Handa as the app that opens common file types.
enum DefaultApps {
    struct Category {
        let title: String
        /// ".doc, .rtf, .odt" and so on, shown next to the title.
        let extensions: String
        let types: [UTType]
        /// Part of the short list that Make Default changes. From macOS 26.4 each file type can need
        /// its own confirmation, so the short list sticks to the files people open most.
        var isEssential = false
    }

    static let categories: [Category] = [
        Category(title: "PDF", extensions: ".pdf", types: [.pdf], isEssential: true),
        Category(title: "Word", extensions: ".docx", types: [UTType("org.openxmlformats.wordprocessingml.document")].compactMap { $0 },
                 isEssential: true),
        Category(title: "CSV", extensions: ".csv", types: [.commaSeparatedText], isEssential: true),
        Category(title: "Markdown", extensions: ".md", types: [UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)],
                 isEssential: true),
        Category(title: "Plain text", extensions: ".txt", types: [.plainText], isEssential: true),
        Category(title: "Older Word, RTF and OpenDocument", extensions: ".doc, .rtf, .rtfd, .odt", types: [
            UTType("com.microsoft.word.doc"), .rtf, .rtfd, UTType("org.oasis-open.opendocument.text"),
        ].compactMap { $0 }),
        Category(title: "TSV", extensions: ".tsv", types: [.tabSeparatedText]),
        Category(title: "JSON, XML, YAML and logs", extensions: ".json, .xml, .yaml, .log", types: [.json, .xml, .yaml, .log]),
        Category(title: "Source code", extensions: ".swift, .py, .sh, .js, .c, .cpp, .h, .rb, .pl, .php", types: [
            .swiftSource, .pythonScript, .shellScript, .javaScript, .cSource, .cPlusPlusSource, .cHeader,
            .rubyScript, .perlScript, .phpScript,
        ]),
        Category(title: "Images", extensions: ".png, .jpg, .heic, .gif, .webp, .tiff, .bmp",
                 types: [.png, .jpeg, .heic, .gif, .webP, .tiff, .bmp]),
    ]

    static var essentials: [Category] { categories.filter(\.isEssential) }

    /// macOS 26.4 and later ask the user before an app takes over a file type from another one.
    static var asksToConfirm: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 26, minorVersion: 4, patchVersion: 0))
    }

    static var appURL: URL { Bundle.main.bundleURL }

    /// The app that opens the category's files now: the first one that isn't Handa, if any.
    static func currentApp(for category: Category) -> URL? {
        let apps = category.types.compactMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
        return apps.first { !isHanda($0) } ?? apps.first
    }

    /// True when Handa opens every file type in the category.
    static func isHandaDefault(for category: Category) -> Bool {
        category.types.allSatisfy { type in
            NSWorkspace.shared.urlForApplication(toOpen: type).map(isHanda) ?? false
        }
    }

    private static func isHanda(_ app: URL) -> Bool {
        app.standardizedFileURL.resolvingSymlinksInPath() == appURL.standardizedFileURL.resolvingSymlinksInPath()
            || Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    static func appName(for url: URL?) -> String {
        guard let url = url else { return "No app" }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    /// Makes Handa the default for every type in the given categories. Goes one type at a time, so
    /// when macOS asks for confirmation the questions come one after another. Calls back on the main queue.
    static func makeDefault(_ categories: [Category], progress: ((UTType, Error?) -> Void)? = nil,
                            completion: @escaping ([Error]) -> Void) {
        var remaining = categories.flatMap(\.types)
        var errors: [Error] = []
        func next() {
            guard !remaining.isEmpty else { return completion(errors) }
            let type = remaining.removeFirst()
            NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: type) { error in
                DispatchQueue.main.async {
                    if let error = error { errors.append(error) }
                    progress?(type, error)
                    next()
                }
            }
        }
        next()
    }
}

/// Starting Handa at login, without a window, so the first file of the day opens as fast as the rest.
enum KeepReady {
    static var isOn: Bool { SMAppService.mainApp.status == .enabled }

    /// macOS can hold the login item until it's allowed in System Settings → General → Login Items.
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func set(_ on: Bool) throws {
        if on {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    /// True while Handa handles the launch macOS started at login.
    static var isLoginLaunch: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == AEEventID(kAEOpenApplication) else { return false }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }
}

/// Stores the Claude API key in the login keychain.
enum Keychain {
    private static let service = "io.github.michael-duck.handa"

    static func read(_ account: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ value: String, account: String) -> Bool {
        delete(account)
        guard !value.isEmpty else { return true }
        let item: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrLabel: "Handa – Claude API key",
            kSecValueData: Data(value.utf8),
        ]
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ account: String) {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        SecItemDelete(query as CFDictionary)
    }

    static let claudeAccount = "claude-api-key"
}

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    static let slogan = "Giving a hand, with your daily tasks"
    static let repository = URL(string: "https://github.com/Michael-Duck/Handa")!

    /// The executable inside the app bundle, used for the MCP server command.
    static var executablePath: String {
        Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
    }
}
