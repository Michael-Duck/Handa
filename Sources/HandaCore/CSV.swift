import Foundation

/// How lines end in a text file.
public enum LineEnding: String, Sendable, CaseIterable {
    case lf = "\n"
    case crlf = "\r\n"
    case cr = "\r"

    public var label: String {
        switch self {
        case .lf: return "LF"
        case .crlf: return "CRLF"
        case .cr: return "CR"
        }
    }
}

/// Everything needed to write a table back the way it was read.
public struct CSVFormat: Equatable, Sendable {
    public var delimiter: UInt8
    public var lineEnding: LineEnding
    public var hasBOM: Bool
    /// The source quoted every non-empty field, so we do too.
    public var quoteAllFields: Bool
    /// In quote-everything files, empty fields were written as "" too.
    public var quoteEmptyFields: Bool
    public var endsWithNewline: Bool

    public init(delimiter: UInt8 = UInt8(ascii: ","), lineEnding: LineEnding = .lf, hasBOM: Bool = false,
                quoteAllFields: Bool = false, quoteEmptyFields: Bool = false, endsWithNewline: Bool = true) {
        self.delimiter = delimiter
        self.lineEnding = lineEnding
        self.hasBOM = hasBOM
        self.quoteAllFields = quoteAllFields
        self.quoteEmptyFields = quoteEmptyFields
        self.endsWithNewline = endsWithNewline
    }

    public var delimiterName: String {
        switch delimiter {
        case UInt8(ascii: ","): return "Comma"
        case UInt8(ascii: "\t"): return "Tab"
        case UInt8(ascii: ";"): return "Semicolon"
        case UInt8(ascii: "|"): return "Pipe"
        default: return String(UnicodeScalar(delimiter))
        }
    }
}

public struct CSVParseResult: Sendable {
    public var rows: [[String]]
    public var format: CSVFormat
    /// Parsing stopped at `maxRows` before the end of the input.
    public var isTruncated: Bool
    /// Number of input bytes consumed (useful when truncated).
    public var bytesRead: Int
}

/// A small, fast, forgiving RFC 4180 reader and writer.
///
/// It works on UTF-8 bytes. Quoted fields may contain delimiters, doubled quotes and line breaks.
/// Malformed input never fails: stray quotes are kept as text and an unterminated quote runs to
/// the end of the file, which is what spreadsheet apps do too.
public enum CSV {
    public static let comma = UInt8(ascii: ",")
    public static let tab = UInt8(ascii: "\t")
    public static let semicolon = UInt8(ascii: ";")
    public static let pipe = UInt8(ascii: "|")
    public static let candidateDelimiters: [UInt8] = [comma, tab, semicolon, pipe]

    private static let quote = UInt8(ascii: "\"")
    private static let lf = UInt8(ascii: "\n")
    private static let cr = UInt8(ascii: "\r")

    public static func parse(_ data: Data, delimiter: UInt8? = nil, maxRows: Int = .max) -> CSVParseResult {
        data.withUnsafeBytes { raw -> CSVParseResult in
            let all = raw.bindMemory(to: UInt8.self)
            var start = 0
            var hasBOM = false
            if all.count >= 3, all[0] == 0xEF, all[1] == 0xBB, all[2] == 0xBF {
                start = 3
                hasBOM = true
            }
            let bytes = UnsafeBufferPointer(rebasing: all[start...])
            let delim = delimiter ?? detectDelimiter(bytes)
            var result = parseRows(bytes, delimiter: delim, maxRows: maxRows)
            result.format.hasBOM = hasBOM
            result.bytesRead += start
            return result
        }
    }

    /// How many records `parse` would find, counted without building them, for sizing up big files.
    public static func countRecords(_ data: Data, delimiter: UInt8? = nil) -> Int {
        data.withUnsafeBytes { raw -> Int in
            let all = raw.bindMemory(to: UInt8.self)
            let start = all.count >= 3 && all[0] == 0xEF && all[1] == 0xBB && all[2] == 0xBF ? 3 : 0
            let bytes = UnsafeBufferPointer(rebasing: all[start...])
            let delim = delimiter ?? detectDelimiter(bytes)
            let n = bytes.count
            var i = 0, records = 0
            // The same walk as parseRows, one field at a time, keeping nothing.
            while i < n {
                if bytes[i] == quote {
                    i += 1
                    while i < n {
                        if bytes[i] == quote {
                            if i + 1 < n, bytes[i + 1] == quote { i += 2; continue }
                            break
                        }
                        i += 1
                    }
                    if i < n { i += 1 }
                }
                while i < n, bytes[i] != delim, bytes[i] != lf, bytes[i] != cr { i += 1 }
                if i >= n {
                    records += 1
                    break
                }
                if bytes[i] == delim {
                    i += 1
                    if i >= n { records += 1 }
                    continue
                }
                if bytes[i] == cr, i + 1 < n, bytes[i + 1] == lf { i += 2 } else { i += 1 }
                records += 1
            }
            return records
        }
    }

    private static func parseRows(_ bytes: UnsafeBufferPointer<UInt8>, delimiter delim: UInt8, maxRows: Int) -> CSVParseResult {
        let n = bytes.count
        var rows: [[String]] = []
        var row: [String] = []
        var field: [UInt8] = []
        var i = 0
        var quoted = 0, unquotedFilled = 0, unquotedEmpty = 0
        var crlfCount = 0, lfCount = 0, crCount = 0
        var truncated = false

        @inline(__always) func isEnd(_ b: UInt8) -> Bool { b == delim || b == lf || b == cr }

        while i < n {
            if bytes[i] == quote {
                i += 1
                var segment = i
                field.removeAll(keepingCapacity: true)
                while i < n {
                    if bytes[i] == quote {
                        if i + 1 < n, bytes[i + 1] == quote {
                            field.append(contentsOf: bytes[segment...i])
                            i += 2
                            segment = i
                            continue
                        }
                        break
                    }
                    i += 1
                }
                field.append(contentsOf: bytes[segment..<min(i, n)])
                if i < n { i += 1 } // closing quote
                // Anything between the closing quote and the next delimiter is kept, not dropped.
                while i < n, !isEnd(bytes[i]) {
                    field.append(bytes[i])
                    i += 1
                }
                row.append(String(decoding: field, as: UTF8.self))
                quoted += 1
            } else {
                let s = i
                while i < n, !isEnd(bytes[i]) { i += 1 }
                row.append(String(decoding: UnsafeBufferPointer(rebasing: bytes[s..<i]), as: UTF8.self))
                if i > s { unquotedFilled += 1 } else { unquotedEmpty += 1 }
            }

            if i >= n {
                rows.append(row)
                row = []
                break
            }
            let b = bytes[i]
            if b == delim {
                i += 1
                if i >= n {
                    row.append("")
                    unquotedEmpty += 1
                    rows.append(row)
                    row = []
                }
                continue
            }
            if b == cr {
                if i + 1 < n, bytes[i + 1] == lf { crlfCount += 1; i += 2 } else { crCount += 1; i += 1 }
            } else {
                lfCount += 1
                i += 1
            }
            rows.append(row)
            row = []
            if rows.count >= maxRows {
                truncated = i < n
                break
            }
        }

        let lineEnding: LineEnding
        if crlfCount >= lfCount && crlfCount >= crCount && crlfCount > 0 {
            lineEnding = .crlf
        } else if crCount > lfCount {
            lineEnding = .cr
        } else {
            lineEnding = .lf
        }
        let endsWithNewline = n > 0 && (bytes[n - 1] == lf || bytes[n - 1] == cr)
        let quoteAll = quoted > 0 && unquotedFilled == 0
        let format = CSVFormat(delimiter: delim, lineEnding: lineEnding, hasBOM: false,
                               quoteAllFields: quoteAll, quoteEmptyFields: quoteAll && unquotedEmpty == 0,
                               endsWithNewline: endsWithNewline || n == 0)
        return CSVParseResult(rows: rows, format: format, isTruncated: truncated, bytesRead: i)
    }

    /// Picks the delimiter that splits the first lines most consistently.
    public static func detectDelimiter(_ bytes: UnsafeBufferPointer<UInt8>) -> UInt8 {
        let limit = min(bytes.count, 64 * 1024)
        var best = comma
        var bestScore = -1.0
        for candidate in candidateDelimiters {
            var counts: [Int] = []
            var current = 0
            var inQuotes = false
            var i = 0
            while i < limit, counts.count < 20 {
                let b = bytes[i]
                if b == quote {
                    inQuotes.toggle()
                } else if !inQuotes {
                    if b == candidate {
                        current += 1
                    } else if b == lf || b == cr {
                        if b == cr, i + 1 < limit, bytes[i + 1] == lf { i += 1 }
                        counts.append(current)
                        current = 0
                    }
                }
                i += 1
            }
            if current > 0 || counts.isEmpty { counts.append(current) }
            let nonEmpty = counts.filter { $0 > 0 }
            guard !nonEmpty.isEmpty else { continue }
            // The most common non-zero count is the likely column separator count.
            var frequency: [Int: Int] = [:]
            for count in nonEmpty { frequency[count, default: 0] += 1 }
            let mode = frequency.max { a, b in a.value == b.value ? a.key > b.key : a.value < b.value }!
            // Consistency matters most, then how many columns it produces.
            let score = Double(mode.value) / Double(counts.count) * 100 + Double(min(mode.key, 50))
            if score > bestScore {
                bestScore = score
                best = candidate
            }
        }
        return best
    }

    public static func serialize(_ rows: [[String]], format: CSVFormat) -> Data {
        var out: [UInt8] = []
        out.reserveCapacity(rows.count * 32)
        if format.hasBOM { out.append(contentsOf: [0xEF, 0xBB, 0xBF]) }
        let eol = Array(format.lineEnding.rawValue.utf8)
        let delim = format.delimiter
        for (r, row) in rows.enumerated() {
            for (c, value) in row.enumerated() {
                if c > 0 { out.append(delim) }
                let bytes = Array(value.utf8)
                let needsQuotes: Bool
                if bytes.isEmpty {
                    needsQuotes = format.quoteEmptyFields && row.count > 1
                } else if format.quoteAllFields {
                    needsQuotes = true
                } else {
                    needsQuotes = bytes.contains { $0 == delim || $0 == quote || $0 == lf || $0 == cr }
                }
                if needsQuotes {
                    out.append(quote)
                    for b in bytes {
                        if b == quote { out.append(quote) }
                        out.append(b)
                    }
                    out.append(quote)
                } else {
                    out.append(contentsOf: bytes)
                }
            }
            if r < rows.count - 1 || format.endsWithNewline { out.append(contentsOf: eol) }
        }
        return Data(out)
    }

    /// Serialises rows as tab-separated text, the format spreadsheets expect on the clipboard.
    public static func clipboardText(_ rows: [[String]]) -> String {
        rows.map { row in
            row.map { $0.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
                .joined(separator: "\t")
        }.joined(separator: "\n")
    }

    /// Most tables start with a header row. We say no only when the first row looks like data.
    public static func looksLikeHeader(_ rows: [[String]]) -> Bool {
        guard rows.count >= 2, let first = rows.first, !first.isEmpty else { return false }
        let names = first.map { $0.trimmingCharacters(in: .whitespaces) }
        let filled = names.filter { !$0.isEmpty }
        if filled.count * 2 < names.count { return false }
        if filled.contains(where: { NumberParsing.number(from: $0) != nil }) { return false }
        if Set(filled.map { $0.lowercased() }).count != filled.count { return false }
        return true
    }

    /// Columns where most filled values are numbers get right alignment and numeric sorting.
    public static func numericColumns(_ rows: ArraySlice<[String]>, columnCount: Int) -> Set<Int> {
        var result = Set<Int>()
        for column in 0..<columnCount {
            var numbers = 0, filled = 0
            for row in rows where column < row.count {
                let value = row[column]
                if value.isEmpty { continue }
                filled += 1
                if NumberParsing.number(from: value) != nil { numbers += 1 }
            }
            if filled > 0, Double(numbers) / Double(filled) >= 0.8 { result.insert(column) }
        }
        return result
    }
}

/// Lenient number reading for table cells: "1,234.50", "$12", "-3.5%", "(42)", "1e6".
public enum NumberParsing {
    public static func number(from text: String) -> Double? {
        var s = Substring(text).trimmingCharacters(in: .whitespaces)[...]
        guard !s.isEmpty, s.count <= 40 else { return nil }
        var negative = false
        if s.hasPrefix("("), s.hasSuffix(")") {
            negative = true
            s = s.dropFirst().dropLast()
        }
        if s.hasPrefix("-") || s.hasPrefix("−") {
            negative.toggle()
            s = s.dropFirst()
        } else if s.hasPrefix("+") {
            s = s.dropFirst()
        }
        let currency: Set<Character> = ["$", "€", "£", "¥", "₹", "₩", "₽", "¢"]
        if let c = s.first, currency.contains(c) { s = s.dropFirst() }
        if let c = s.last, currency.contains(c) { s = s.dropLast() }
        if s.hasSuffix("%") { s = s.dropLast() }
        s = s.trimmingCharacters(in: .whitespaces)[...]
        guard let firstChar = s.first, firstChar.isASCII, firstChar.isNumber || firstChar == "." else { return nil }
        // Thousands separators: only accept well-formed groups so "1,2" stays text.
        var cleaned = ""
        cleaned.reserveCapacity(s.count)
        var sawDot = false, sawExponent = false
        var digitsSinceComma = -1
        for ch in s {
            switch ch {
            case "0"..."9":
                cleaned.append(ch)
                if digitsSinceComma >= 0 { digitsSinceComma += 1 }
            case ",":
                if sawDot || sawExponent { return nil }
                if digitsSinceComma >= 0, digitsSinceComma != 3 { return nil }
                digitsSinceComma = 0
            case ".":
                if sawDot || sawExponent { return nil }
                if digitsSinceComma >= 0, digitsSinceComma != 3 { return nil }
                digitsSinceComma = -1
                sawDot = true
                cleaned.append(ch)
            case "e", "E":
                if sawExponent || cleaned.isEmpty { return nil }
                if digitsSinceComma >= 0, digitsSinceComma != 3 { return nil }
                digitsSinceComma = -1
                sawExponent = true
                cleaned.append("e")
            case "+", "-":
                guard cleaned.last == "e" else { return nil }
                cleaned.append(ch)
            default:
                return nil
            }
        }
        if digitsSinceComma >= 0, digitsSinceComma != 3 { return nil }
        guard let value = Double(cleaned), value.isFinite else { return nil }
        return negative ? -value : value
    }
}
