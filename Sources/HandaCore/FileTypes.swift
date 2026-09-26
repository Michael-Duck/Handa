import Foundation

/// The broad kind of viewer a file needs.
public enum FileCategory: String, Codable, Sendable, CaseIterable {
    case table
    case markdown
    case text
    case richText
    case pdf
    case image
    case quickLook
    case binary

    public var displayName: String {
        switch self {
        case .table: return "Table"
        case .markdown: return "Markdown"
        case .text: return "Text"
        case .richText: return "Document"
        case .pdf: return "PDF"
        case .image: return "Image"
        case .quickLook: return "Preview"
        case .binary: return "Binary"
        }
    }
}

/// Rich text formats AppKit can read and write.
public enum RichTextFormat: String, Sendable {
    case docx, doc, rtf, rtfd, odt, wordml

    public var displayName: String {
        switch self {
        case .docx: return "Word Document"
        case .doc: return "Word 97 Document"
        case .rtf: return "Rich Text"
        case .rtfd: return "Rich Text with Attachments"
        case .odt: return "OpenDocument Text"
        case .wordml: return "Word XML Document"
        }
    }

    /// Saving through AppKit keeps text and formatting but can drop things like comments,
    /// tracked changes, headers and embedded objects.
    public var savingMaySimplify: Bool {
        switch self {
        case .rtf, .rtfd: return false
        default: return true
        }
    }
}

public enum FileTypes {
    public static let tableExtensions: Set<String> = ["csv", "tsv", "tab", "psv"]
    public static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn", "mdwn", "mdtxt", "mdtext", "rmd"]
    public static let pdfExtensions: Set<String> = ["pdf"]
    public static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "jpe", "gif", "heic", "heif", "tif", "tiff", "bmp", "webp", "ico", "icns",
        "avif", "jp2", "tga", "exr", "hdr", "dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2",
    ]
    /// Formats macOS Quick Look renders well that we have no native viewer for.
    public static let quickLookExtensions: Set<String> = [
        "xlsx", "xlsm", "xls", "pptx", "ppt", "key", "pages", "numbers", "keynote",
        "mp4", "m4v", "mov", "avi", "mkv", "webm", "mpg", "mpeg", "3gp",
        "mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "caf", "ogg", "opus",
        "usdz", "usd", "usda", "usdc", "reality", "obj", "stl", "ply", "abc", "dae", "scn",
        "ttf", "otf", "ttc", "woff", "woff2", "epub", "ics", "vcf", "eml", "webarchive",
    ]
    public static let richTextFormats: [String: RichTextFormat] = [
        "docx": .docx, "docm": .docx, "dotx": .docx, "doc": .doc, "rtf": .rtf, "rtfd": .rtfd, "odt": .odt, "xml-doc": .wordml,
    ]

    /// Category from the file name alone. Returns nil when the extension is unknown and the
    /// caller should look at the content.
    public static func category(forFileName name: String) -> FileCategory? {
        let ext = (name as NSString).pathExtension.lowercased()
        if tableExtensions.contains(ext) { return .table }
        if markdownExtensions.contains(ext) { return .markdown }
        if pdfExtensions.contains(ext) { return .pdf }
        if richTextFormats[ext] != nil { return .richText }
        if imageExtensions.contains(ext) { return .image }
        if quickLookExtensions.contains(ext) { return .quickLook }
        if ext == "svg" || ext == "html" || ext == "htm" { return .text }
        if Language.detect(fileName: name) != nil || plainTextExtensions.contains(ext) { return .text }
        return nil
    }

    public static let plainTextExtensions: Set<String> = [
        "txt", "text", "log", "out", "err", "nfo", "srt", "vtt", "sub", "tex", "bib", "rst", "adoc", "asciidoc", "org",
        "textile", "csv-schema", "lock", "sum", "mod", "cfg", "conf", "properties", "env", "gitignore",
        "gitattributes", "dockerignore", "npmrc", "nvmrc", "editorconfig", "license", "readme", "todo",
    ]
}

/// Languages with syntax highlighting.
public enum Language: String, Sendable, CaseIterable {
    case swift, python, javascript, typescript, json, html, xml, css, shell, c, cpp, objc, go, rust,
         java, kotlin, csharp, ruby, php, sql, yaml, toml, ini, markdown, diff, lua, perl, r, dart, scala,
         dockerfile, makefile

    public var displayName: String {
        switch self {
        case .swift: return "Swift"
        case .python: return "Python"
        case .javascript: return "JavaScript"
        case .typescript: return "TypeScript"
        case .json: return "JSON"
        case .html: return "HTML"
        case .xml: return "XML"
        case .css: return "CSS"
        case .shell: return "Shell Script"
        case .c: return "C"
        case .cpp: return "C++"
        case .objc: return "Objective-C"
        case .go: return "Go"
        case .rust: return "Rust"
        case .java: return "Java"
        case .kotlin: return "Kotlin"
        case .csharp: return "C#"
        case .ruby: return "Ruby"
        case .php: return "PHP"
        case .sql: return "SQL"
        case .yaml: return "YAML"
        case .toml: return "TOML"
        case .ini: return "Config"
        case .markdown: return "Markdown"
        case .diff: return "Diff"
        case .lua: return "Lua"
        case .perl: return "Perl"
        case .r: return "R"
        case .dart: return "Dart"
        case .scala: return "Scala"
        case .dockerfile: return "Dockerfile"
        case .makefile: return "Makefile"
        }
    }

    static let byExtension: [String: Language] = [
        "swift": .swift,
        "py": .python, "pyw": .python, "pyi": .python,
        "js": .javascript, "mjs": .javascript, "cjs": .javascript, "jsx": .javascript,
        "ts": .typescript, "tsx": .typescript, "mts": .typescript, "cts": .typescript,
        "json": .json, "jsonc": .json, "json5": .json, "geojson": .json, "webmanifest": .json, "ipynb": .json, "har": .json,
        "html": .html, "htm": .html, "xhtml": .html, "vue": .html, "svelte": .html,
        "xml": .xml, "plist": .xml, "svg": .xml, "xsd": .xml, "xsl": .xml, "xslt": .xml, "rss": .xml, "atom": .xml,
        "csproj": .xml, "storyboard": .xml, "xib": .xml, "entitlements": .xml, "gpx": .xml, "kml": .xml,
        "css": .css, "scss": .css, "sass": .css, "less": .css,
        "sh": .shell, "bash": .shell, "zsh": .shell, "fish": .shell, "ksh": .shell, "command": .shell, "tool": .shell,
        "c": .c, "h": .c,
        "cpp": .cpp, "cc": .cpp, "cxx": .cpp, "hpp": .cpp, "hh": .cpp, "hxx": .cpp, "ino": .cpp,
        "m": .objc, "mm": .objc,
        "go": .go, "rs": .rust, "java": .java, "kt": .kotlin, "kts": .kotlin, "cs": .csharp,
        "rb": .ruby, "rake": .ruby, "gemspec": .ruby, "php": .php, "sql": .sql,
        "yaml": .yaml, "yml": .yaml, "toml": .toml,
        "ini": .ini, "cfg": .ini, "conf": .ini, "properties": .ini, "env": .ini, "editorconfig": .ini, "gitconfig": .ini,
        "md": .markdown, "markdown": .markdown, "mdown": .markdown, "mkd": .markdown,
        "diff": .diff, "patch": .diff, "lua": .lua, "pl": .perl, "pm": .perl, "r": .r, "dart": .dart,
        "scala": .scala, "sc": .scala, "gradle": .kotlin, "groovy": .java,
    ]

    static let byFileName: [String: Language] = [
        "makefile": .makefile, "gnumakefile": .makefile, "dockerfile": .dockerfile, "containerfile": .dockerfile,
        "gemfile": .ruby, "rakefile": .ruby, "podfile": .ruby, "brewfile": .ruby, "vagrantfile": .ruby,
        ".zshrc": .shell, ".bashrc": .shell, ".bash_profile": .shell, ".zprofile": .shell, ".profile": .shell,
        ".gitconfig": .ini, ".gitignore": .ini, ".env": .ini, "package.resolved": .json,
    ]

    public static func detect(fileName: String) -> Language? {
        let lower = fileName.lowercased()
        if let language = byFileName[lower] { return language }
        if lower.hasPrefix("dockerfile") { return .dockerfile }
        if lower.hasPrefix(".env") { return .ini }
        let ext = (lower as NSString).pathExtension
        return byExtension[ext]
    }

    /// Guess from a shebang line such as `#!/usr/bin/env python3`.
    public static func detect(shebang firstLine: Substring) -> Language? {
        guard firstLine.hasPrefix("#!") else { return nil }
        let line = firstLine.lowercased()
        if line.contains("python") { return .python }
        if line.contains("node") || line.contains("deno") || line.contains("bun") { return .javascript }
        if line.contains("ruby") { return .ruby }
        if line.contains("perl") { return .perl }
        if line.contains("php") { return .php }
        if line.contains("sh") { return .shell }
        return nil
    }

    /// Language hint used in Markdown code fences, e.g. ```swift
    public static func detect(hint: String) -> Language? {
        let h = hint.lowercased().trimmingCharacters(in: .whitespaces)
        if let language = Language(rawValue: h) { return language }
        switch h {
        case "js", "node", "jsx": return .javascript
        case "ts", "tsx": return .typescript
        case "py", "python3": return .python
        case "sh", "bash", "zsh", "console", "terminal": return .shell
        case "yml": return .yaml
        case "c++", "cxx": return .cpp
        case "objective-c", "objectivec", "obj-c": return .objc
        case "rb": return .ruby
        case "rs": return .rust
        case "golang": return .go
        case "kt": return .kotlin
        case "cs", "c#": return .csharp
        case "jsonc", "json5": return .json
        case "patch": return .diff
        case "docker": return .dockerfile
        case "make": return .makefile
        case "htm", "vue": return .html
        case "svg", "plist": return .xml
        case "md": return .markdown
        default: return byExtension[h]
        }
    }

    /// Prose-like languages wrap by default; code does not.
    public var wrapsByDefault: Bool {
        switch self {
        case .markdown: return true
        default: return false
        }
    }
}
