import AppKit
import Security
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
        let types: [UTType]
    }

    static let categories: [Category] = [
        Category(title: "PDF documents", types: [.pdf]),
        Category(title: "Word and rich text documents", types: [
            UTType("org.openxmlformats.wordprocessingml.document"), UTType("com.microsoft.word.doc"),
            .rtf, .rtfd, UTType("org.oasis-open.opendocument.text"),
        ].compactMap { $0 }),
        Category(title: "CSV and TSV tables", types: [.commaSeparatedText, .tabSeparatedText]),
        Category(title: "Markdown", types: [UTType("net.daringfireball.markdown")].compactMap { $0 }),
        Category(title: "Plain text and code", types: [
            .plainText, .json, .xml, .yaml, .log, .swiftSource, .pythonScript, .shellScript, .javaScript,
            .cSource, .cPlusPlusSource, .cHeader, .rubyScript, .perlScript, .phpScript,
        ]),
        Category(title: "Images", types: [.png, .jpeg, .gif, .heic, .tiff, .webP, .bmp]),
    ]

    static var appURL: URL { Bundle.main.bundleURL }

    static func currentApp(for category: Category) -> URL? {
        category.types.first.flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
    }

    static func isHandaDefault(for category: Category) -> Bool {
        guard let current = currentApp(for: category) else { return false }
        return current.standardizedFileURL.resolvingSymlinksInPath() == appURL.standardizedFileURL.resolvingSymlinksInPath()
            || Bundle(url: current)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    static func appName(for url: URL?) -> String {
        guard let url = url else { return "No app" }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    /// Makes Handa the default for every type in the given categories.
    static func makeDefault(_ categories: [Category], completion: @escaping ([Error]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var errors: [Error] = []
        for type in categories.flatMap(\.types) {
            group.enter()
            NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: type) { error in
                if let error = error {
                    lock.lock()
                    errors.append(error)
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(errors) }
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
