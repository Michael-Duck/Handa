import AppKit
import UniformTypeIdentifiers
import HandaCore

/// What a file is and which viewer shows it.
struct DocumentKind: Equatable {
    var category: FileCategory
    var language: Language?
    var richTextFormat: RichTextFormat?
    var displayName: String

    /// Formats where Handa's own rendering can be swapped for Quick Look's.
    var hasQuickLookAlternative: Bool {
        switch category {
        case .richText: return true
        case .text: return language == .html || language == .xml && isSVG
        default: return false
        }
    }

    var isSVG = false

    static func detect(url: URL) -> DocumentKind {
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType ?? UTType(filenameExtension: ext)
        let typeName = type?.localizedDescription

        if let category = FileTypes.category(forFileName: name) {
            var kind = DocumentKind(category: category, language: Language.detect(fileName: name),
                                    richTextFormat: FileTypes.richTextFormats[ext], displayName: typeName ?? category.displayName)
            kind.isSVG = ext == "svg"
            if category == .text, kind.language == nil, let first = firstLine(of: url) {
                kind.language = Language.detect(shebang: first)
            }
            kind.displayName = displayName(for: kind, fallback: typeName)
            return kind
        }

        if let type = type {
            if type.conforms(to: .pdf) { return DocumentKind(category: .pdf, displayName: typeName ?? "PDF Document") }
            if type.conforms(to: .image) { return DocumentKind(category: .image, displayName: typeName ?? "Image") }
            if type.conforms(to: .rtf) { return DocumentKind(category: .richText, richTextFormat: .rtf, displayName: "Rich Text") }
            if type.conforms(to: .rtfd) || type.conforms(to: .flatRTFD) {
                return DocumentKind(category: .richText, richTextFormat: .rtfd, displayName: "Rich Text with Attachments")
            }
            if type.conforms(to: .commaSeparatedText) || type.conforms(to: .tabSeparatedText) {
                return DocumentKind(category: .table, displayName: typeName ?? "Table")
            }
            // Archives are left out on purpose: Quick Look only shows an icon for them, the byte view shows more.
            let quickLookTypes: [UTType] = [.audiovisualContent, .threeDContent, .font, .presentation, .spreadsheet, .package, .application]
            if quickLookTypes.contains(where: { type.conforms(to: $0) }) || type.identifier.hasPrefix("com.apple.iwork") {
                return DocumentKind(category: .quickLook, displayName: typeName ?? "Document")
            }
            if type.conforms(to: .text) || type.conforms(to: .sourceCode) || type.conforms(to: .json) || type.conforms(to: .xml) {
                var kind = DocumentKind(category: .text, displayName: typeName ?? "Text")
                if let first = firstLine(of: url) { kind.language = Language.detect(shebang: first) }
                return kind
            }
        }

        // Unknown: look at the bytes.
        if let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            let sample = handle.readData(ofLength: 8192)
            if FileSniffer.looksLikeText(sample) {
                var kind = DocumentKind(category: .text, displayName: typeName ?? "Plain Text")
                if let firstLine = String(decoding: sample.prefix(200), as: UTF8.self).split(separator: "\n").first {
                    kind.language = Language.detect(shebang: firstLine)
                }
                return kind
            }
        }
        return DocumentKind(category: .binary, displayName: typeName ?? "Binary File")
    }

    private static func firstLine(of url: URL) -> Substring? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 200)
        return String(decoding: data, as: UTF8.self).split(separator: "\n", maxSplits: 1).first
    }

    private static func displayName(for kind: DocumentKind, fallback: String?) -> String {
        switch kind.category {
        case .table: return fallback ?? "Table"
        case .markdown: return "Markdown"
        case .richText: return kind.richTextFormat?.displayName ?? fallback ?? "Document"
        case .text:
            if let language = kind.language { return language == .markdown ? "Markdown" : "\(language.displayName)" }
            return fallback ?? "Plain Text"
        default: return fallback ?? kind.category.displayName
        }
    }
}

/// The ways a document can be shown. Most kinds have one; some have two.
enum ViewMode: String {
    case standard
    case source
    case quickLook

    /// The first mode is the one a file opens in.
    static func modes(for kind: DocumentKind) -> [ViewMode] {
        switch kind.category {
        case .markdown, .table: return [.standard, .source]
        case .richText:
            // AppKit's Word importer drops paragraph styles, so Word files preview through Quick Look,
            // which lays them out like Word does. Editing switches to Handa's own text view.
            switch kind.richTextFormat {
            case .rtf?, .rtfd?, nil: return [.standard, .quickLook]
            default: return [.quickLook, .standard]
            }
        case .text where kind.hasQuickLookAlternative: return [.standard, .quickLook]
        default: return [.standard]
        }
    }

    func title(for kind: DocumentKind) -> String {
        switch (kind.category, self) {
        case (.markdown, .standard): return "Preview"
        case (.markdown, .source): return "Source"
        case (.table, .standard): return "Table"
        case (.table, .source): return "Text"
        case (.richText, .standard): return "Text"
        case (.richText, .quickLook): return "Original"
        case (.text, .standard): return "Source"
        case (.text, .quickLook): return "Rendered"
        default: return "Default"
        }
    }
}
