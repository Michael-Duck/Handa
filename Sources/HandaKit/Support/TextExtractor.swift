import AppKit
import PDFKit
import ImageIO
import UniformTypeIdentifiers
import HandaCore

/// Turns any supported file into plain text, for AI reviews, the MCP server and `handa extract`.
enum TextExtractor {
    struct Extraction {
        var text: String
        var kind: String
        var details: String
    }

    enum Failure: Error, LocalizedError {
        case notFound(String)
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .notFound(let path): return "No file at \(path)."
            case .unreadable(let reason): return reason
            }
        }
    }

    static func extract(url: URL) throws -> Extraction {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw Failure.notFound(url.path)
        }
        let kind = DocumentKind.detect(url: url)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
        let sizeText = Formatting.bytes(size)

        switch kind.category {
        case .table:
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let decoded = TextDecoding.decode(data)
            // Counted rather than parsed: building every row would take many times the file's size.
            let size = CSV.measure(decoded.encoding == .utf8 ? data : Data(decoded.text.utf8))
            return Extraction(text: decoded.text, kind: kind.displayName,
                              details: "\(Formatting.count(size.records, "row")), \(Formatting.count(size.columns, "column")), \(sizeText)")
        case .markdown, .text:
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            if url.pathExtension.lowercased() == "plist", data.starts(with: Array("bplist".utf8)) {
                return Extraction(text: try PropertyLists.xmlText(from: data), kind: "Property List", details: sizeText)
            }
            let decoded = TextDecoding.decode(data)
            let stats = TextStats(decoded.text)
            return Extraction(text: decoded.text, kind: kind.displayName,
                              details: "\(Formatting.count(stats.lines, "line")), \(Formatting.count(stats.words, "word")), \(sizeText)")
        case .richText:
            let format = kind.richTextFormat ?? .rtf
            let string = try NSAttributedString(url: url, options: [.documentType: format.documentType], documentAttributes: nil)
            let stats = TextStats(string.string)
            return Extraction(text: string.string, kind: kind.displayName, details: "\(Formatting.count(stats.words, "word")), \(sizeText)")
        case .pdf:
            guard let pdf = PDFDocument(url: url) else { throw Failure.unreadable("This PDF couldn't be opened.") }
            if pdf.isLocked { throw Failure.unreadable("This PDF is password protected.") }
            var parts: [String] = []
            for index in 0..<pdf.pageCount {
                let text = pdf.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                parts.append("--- Page \(index + 1) ---\n\(text)")
            }
            return Extraction(text: parts.joined(separator: "\n\n"), kind: "PDF Document",
                              details: "\(Formatting.count(pdf.pageCount, "page")), \(sizeText)")
        case .image:
            let info = ImageInfo(url: url)
            return Extraction(text: "(An image. Handa doesn't extract text from images.)", kind: kind.displayName,
                              details: [info?.dimensions, sizeText].compactMap { $0 }.joined(separator: ", "))
        case .quickLook, .binary:
            return Extraction(text: "(Handa can show this file but can't extract text from it.)", kind: kind.displayName, details: sizeText)
        }
    }
}

extension RichTextFormat {
    var documentType: NSAttributedString.DocumentType {
        switch self {
        case .docx: return .officeOpenXML
        case .doc: return .docFormat
        case .rtf: return .rtf
        case .rtfd: return .rtfd
        case .odt: return .openDocument
        case .wordml: return .wordML
        }
    }
}

enum PropertyLists {
    /// Binary property lists are shown as XML text.
    static func xmlText(from data: Data) throws -> String {
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        let xml = try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
        return String(decoding: xml, as: UTF8.self)
    }
}

/// Size and format of an image, read from its header without decoding the pixels.
struct ImageInfo {
    var width: Int
    var height: Int
    var typeName: String?
    var hasAlpha: Bool

    init?(url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        hasAlpha = properties[kCGImagePropertyHasAlpha] as? Bool ?? false
        if let uti = CGImageSourceGetType(source) as String? {
            typeName = UTType(uti).map { $0.preferredFilenameExtension?.uppercased() ?? $0.localizedDescription ?? uti }
        }
        guard width > 0, height > 0 else { return nil }
    }

    var dimensions: String { "\(width) × \(height) px" }
}
