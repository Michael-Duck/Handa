import Foundation

/// Formats bytes the way `hexdump -C` does, one row of 16 bytes at a time.
public enum HexDump {
    public static let bytesPerRow = 16

    public static func rowCount(byteCount: Int) -> Int {
        (byteCount + bytesPerRow - 1) / bytesPerRow
    }

    public static func offset(_ offset: Int) -> String {
        let hex = String(offset, radix: 16)
        return String(repeating: "0", count: max(0, 8 - hex.count)) + hex
    }

    private static let digits = Array("0123456789abcdef".utf8)

    public static func hex<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
        var out: [UInt8] = []
        out.reserveCapacity(bytesPerRow * 3 + 1)
        for (index, byte) in bytes.enumerated() {
            if index > 0 { out.append(0x20) }
            if index == 8 { out.append(0x20) }
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    public static func ascii<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
        String(decoding: bytes.map { $0 >= 0x20 && $0 < 0x7F ? $0 : 0x2E }, as: UTF8.self)
    }
}

/// Shell-style wildcards for review rules: `*.csv`, `~/Contracts/**/*.pdf`, `report-{2025,2026}*.xlsx`.
///
/// A pattern without a slash matches the file name anywhere; a pattern with one matches the full path.
/// Matching ignores case, like the default macOS file system.
public struct Glob: Sendable {
    public let pattern: String
    private let regex: NSRegularExpression?
    private let matchesFullPath: Bool

    public init(_ pattern: String, homeDirectory: String = NSHomeDirectory()) {
        var expanded = pattern.trimmingCharacters(in: .whitespaces)
        if expanded == "~" {
            expanded = homeDirectory
        } else if expanded.hasPrefix("~/") {
            expanded = homeDirectory + expanded.dropFirst()
        }
        self.pattern = expanded
        matchesFullPath = expanded.contains("/")
        regex = try? NSRegularExpression(pattern: Glob.regexPattern(for: expanded), options: [.caseInsensitive])
    }

    public func matches(_ path: String) -> Bool {
        guard let regex = regex, !pattern.isEmpty else { return false }
        let subject = matchesFullPath ? path : (path as NSString).lastPathComponent
        let range = NSRange(subject.startIndex..., in: subject)
        return regex.firstMatch(in: subject, options: [], range: range) != nil
    }

    static func regexPattern(for glob: String) -> String {
        var out = "^"
        let chars = Array(glob)
        var i = 0
        var braceDepth = 0
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "*":
                if i + 1 < chars.count, chars[i + 1] == "*" {
                    i += 1
                    if i + 1 < chars.count, chars[i + 1] == "/" {
                        i += 1
                        out += "(?:.*/)?"
                    } else {
                        out += ".*"
                    }
                } else {
                    out += "[^/]*"
                }
            case "?":
                out += "[^/]"
            case "[":
                if let close = chars[(i + 1)...].firstIndex(of: "]") {
                    var body = String(chars[(i + 1)..<close])
                    if body.hasPrefix("!") { body = "^" + body.dropFirst() }
                    out += "[" + body.replacingOccurrences(of: "\\", with: "\\\\") + "]"
                    i = close
                } else {
                    out += "\\["
                }
            case "{":
                braceDepth += 1
                out += "(?:"
            case "}" where braceDepth > 0:
                braceDepth -= 1
                out += ")"
            case "," where braceDepth > 0:
                out += "|"
            default:
                out += NSRegularExpression.escapedPattern(for: String(c))
            }
            i += 1
        }
        out += String(repeating: ")", count: braceDepth)
        return out + "$"
    }
}

/// FNV-1a: a tiny, stable hash for file names and change detection. Not for security.
public enum StableHash {
    public static func fnv1a<S: Sequence>(_ bytes: S) -> UInt64 where S.Element == UInt8 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    public static func hex(_ string: String) -> String {
        String(format: "%016llx", fnv1a(string.utf8))
    }

    public static func hex(_ data: Data) -> String {
        String(format: "%016llx", fnv1a(data))
    }
}

/// Line, word and character counts for the status bar.
public struct TextStats: Equatable, Sendable {
    public var lines: Int
    public var words: Int
    public var characters: Int

    public init(_ text: String) {
        var lines = text.isEmpty ? 0 : 1
        var words = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            if scalar == "\n" { lines += 1 }
            let isSpace = scalar.properties.isWhitespace
            if isSpace {
                inWord = false
            } else if !inWord {
                inWord = true
                words += 1
            }
        }
        if text.hasSuffix("\n") { lines -= 1 }
        self.lines = lines
        self.words = words
        self.characters = text.count
    }
}

public enum Formatting {
    public static func bytes(_ count: Int64) -> String {
        let units = ["bytes", "KB", "MB", "GB", "TB"]
        var value = Double(count)
        var unit = 0
        while value >= 1000, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        if unit == 0 { return count == 1 ? "1 byte" : "\(count) bytes" }
        return String(format: value >= 100 ? "%.0f" : "%.1f", value) + " " + units[unit]
    }

    public static func count(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let number = formatter.string(from: NSNumber(value: n)) ?? "\(n)"
        return "\(number) \(n == 1 ? singular : (plural ?? singular + "s"))"
    }
}
