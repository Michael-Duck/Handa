import AppKit
import HandaCore

/// Plain text shared between a document and the view showing it.
final class TextContent {
    let storage: NSTextStorage
    var encoding: String.Encoding
    var hasBOM: Bool
    var lineEnding: LineEnding

    init(text: String, encoding: String.Encoding = .utf8, hasBOM: Bool = false, lineEnding: LineEnding = .lf) {
        storage = NSTextStorage(string: text)
        self.encoding = encoding
        self.hasBOM = hasBOM
        self.lineEnding = lineEnding
    }

    convenience init(decoded: DecodedText) {
        self.init(text: decoded.text, encoding: decoded.encoding, hasBOM: decoded.hasBOM, lineEnding: decoded.lineEnding)
    }

    var string: String { storage.string }

    func encoded() -> Data? {
        TextDecoding.encode(storage.string, encoding: encoding, hasBOM: hasBOM, lineEnding: lineEnding)
    }

    var summary: String {
        "\(TextDecoding.name(of: encoding)) · \(lineEnding.label)"
    }
}

/// A CSV or TSV file. Big files show their first rows straight away and load the rest in the background.
final class TableContent {
    static let initialRows = 5_000
    static let maximumRows = 2_000_000
    static let progressiveThreshold = 8 * 1024 * 1024

    private(set) var rows: [[String]]
    var format: CSVFormat
    var encoding: String.Encoding
    var hasHeaderRow: Bool
    private(set) var isTruncated: Bool
    private(set) var isLoading: Bool
    private(set) var columnCount: Int
    private var pendingText: Data?

    init(data: Data, forceTab: Bool) {
        let delimiter: UInt8? = forceTab ? CSV.tab : nil
        let utf8: Data
        var decoded: DecodedText?
        if data.starts(with: [0xEF, 0xBB, 0xBF]) || TextDecoding.isValidUTF8(data) {
            utf8 = data
            encoding = .utf8
        } else {
            let text = TextDecoding.decode(data)
            decoded = text
            utf8 = Data(text.text.utf8)
            encoding = text.encoding
        }
        let progressive = utf8.count > TableContent.progressiveThreshold
        var result = CSV.parse(utf8, delimiter: delimiter, maxRows: progressive ? TableContent.initialRows : TableContent.maximumRows)
        if let decoded = decoded {
            result.format.lineEnding = decoded.lineEnding
            result.format.hasBOM = decoded.hasBOM
        }
        rows = result.rows
        format = result.format
        isLoading = progressive && result.isTruncated
        isTruncated = result.isTruncated && !isLoading
        pendingText = isLoading ? utf8 : nil
        hasHeaderRow = CSV.looksLikeHeader(result.rows)
        columnCount = result.rows.reduce(0) { max($0, $1.count) }
    }

    /// Parses the whole file on a background queue, then calls back on the main queue.
    func loadRemaining(completion: @escaping () -> Void) {
        guard isLoading, let data = pendingText else { return }
        let delimiter = format.delimiter
        let lineEnding = format.lineEnding
        let hasBOM = format.hasBOM
        let fromDecodedText = encoding != .utf8
        DispatchQueue.global(qos: .userInitiated).async {
            var result = CSV.parse(data, delimiter: delimiter, maxRows: TableContent.maximumRows)
            if fromDecodedText {
                result.format.lineEnding = lineEnding
                result.format.hasBOM = hasBOM
            }
            let columns = result.rows.reduce(0) { max($0, $1.count) }
            DispatchQueue.main.async {
                self.rows = result.rows
                self.format = result.format
                self.isTruncated = result.isTruncated
                self.isLoading = false
                self.pendingText = nil
                self.columnCount = columns
                completion()
            }
        }
    }

    var headerNames: [String] {
        (0..<columnCount).map { index in
            if hasHeaderRow, let header = rows.first, index < header.count, !header[index].isEmpty { return header[index] }
            return TableContent.columnLetter(index)
        }
    }

    /// Spreadsheet-style names: A, B, … Z, AA, AB …
    static func columnLetter(_ index: Int) -> String {
        var n = index + 1
        var name = ""
        while n > 0 {
            let remainder = (n - 1) % 26
            name = String(UnicodeScalar(UInt8(65 + remainder))) + name
            n = (n - 1) / 26
        }
        return name
    }

    /// Row index into `rows` for a data row (skipping the header when there is one).
    var firstDataRow: Int { hasHeaderRow ? 1 : 0 }
    var dataRowCount: Int { max(0, rows.count - firstDataRow) }

    func value(row: Int, column: Int) -> String {
        guard rows.indices.contains(row), column < rows[row].count else { return "" }
        return rows[row][column]
    }

    func setValue(_ value: String, row: Int, column: Int) {
        guard rows.indices.contains(row) else { return }
        while rows[row].count <= column { rows[row].append("") }
        rows[row][column] = value
        columnCount = max(columnCount, column + 1)
    }

    func insertRow(_ row: [String], at index: Int) {
        rows.insert(row, at: min(max(index, 0), rows.count))
    }

    @discardableResult
    func removeRow(at index: Int) -> [String] {
        rows.remove(at: index)
    }

    func insertColumn(at index: Int, values: [String]? = nil) {
        for r in rows.indices {
            while rows[r].count < index { rows[r].append("") }
            rows[r].insert(values?[safe: r] ?? "", at: min(index, rows[r].count))
        }
        columnCount += 1
    }

    @discardableResult
    func removeColumn(at index: Int) -> [String] {
        var removed: [String] = []
        for r in rows.indices {
            removed.append(index < rows[r].count ? rows[r].remove(at: index) : "")
        }
        columnCount = rows.reduce(0) { max($0, $1.count) }
        return removed
    }

    func serialized() -> Data? {
        if encoding == .utf8 { return CSV.serialize(rows, format: format) }
        var utf8Format = format
        utf8Format.hasBOM = false
        let text = String(decoding: CSV.serialize(rows, format: utf8Format), as: UTF8.self)
        return TextDecoding.encode(text, encoding: encoding, hasBOM: format.hasBOM, lineEnding: .lf)
    }

    var textForDisplay: String {
        var display = format
        display.hasBOM = false
        return String(decoding: CSV.serialize(rows, format: display), as: UTF8.self)
    }
}

/// A Word, RTF or OpenDocument file, held as attributed text.
final class RichTextContent {
    let storage: NSTextStorage
    let format: RichTextFormat
    let attributes: [NSAttributedString.DocumentAttributeKey: Any]

    init(string: NSAttributedString, format: RichTextFormat, attributes: [NSAttributedString.DocumentAttributeKey: Any]) {
        storage = NSTextStorage(attributedString: string)
        self.format = format
        self.attributes = attributes
    }

    var writingAttributes: [NSAttributedString.DocumentAttributeKey: Any] {
        var result = attributes
        result[.documentType] = format.documentType
        return result
    }

    var pageSize: NSSize {
        (attributes[.paperSize] as? NSValue)?.sizeValue ?? NSSize(width: 612, height: 792)
    }

    var margins: NSEdgeInsets {
        func value(_ key: NSAttributedString.DocumentAttributeKey, _ fallback: CGFloat) -> CGFloat {
            (attributes[key] as? NSNumber).map { CGFloat($0.doubleValue) } ?? fallback
        }
        return NSEdgeInsets(top: value(.topMargin, 72), left: value(.leftMargin, 72),
                            bottom: value(.bottomMargin, 72), right: value(.rightMargin, 72))
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
