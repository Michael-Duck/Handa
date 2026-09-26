import Foundation

/// Text read from disk plus the details needed to save it back byte-for-byte compatible.
public struct DecodedText: Sendable {
    /// The text with line endings normalised to "\n".
    public var text: String
    public var encoding: String.Encoding
    public var hasBOM: Bool
    public var lineEnding: LineEnding

    public init(text: String, encoding: String.Encoding, hasBOM: Bool, lineEnding: LineEnding) {
        self.text = text
        self.encoding = encoding
        self.hasBOM = hasBOM
        self.lineEnding = lineEnding
    }
}

public enum TextDecoding {
    /// Decodes bytes using the BOM if there is one, then UTF-8, then UTF-16 heuristics,
    /// and finally Windows Latin 1, which accepts any byte sequence.
    public static func decode(_ data: Data) -> DecodedText {
        var encoding: String.Encoding = .utf8
        var hasBOM = false
        var raw: String?

        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            hasBOM = true
            let body = data.dropFirst(3)
            if let utf8 = String(data: body, encoding: .utf8) {
                raw = utf8
            } else {
                // Some Windows tools put a UTF-8 BOM in front of text that isn't UTF-8. Read the rest
                // byte for byte so nothing is lost; saving writes the BOM back in front.
                (raw, encoding) = singleByte(body)
            }
        } else if data.starts(with: [0xFF, 0xFE]), data.count % 2 == 0,
                  let utf16 = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) {
            hasBOM = true
            encoding = .utf16LittleEndian
            raw = utf16
        } else if data.starts(with: [0xFE, 0xFF]), data.count % 2 == 0,
                  let utf16 = String(data: data.dropFirst(2), encoding: .utf16BigEndian) {
            hasBOM = true
            encoding = .utf16BigEndian
            raw = utf16
        } else if let guess = utf16Guess(data), let utf16 = String(data: data, encoding: guess) {
            // Checked before UTF-8 because zero bytes are technically valid UTF-8.
            encoding = guess
            raw = utf16
        } else if let utf8 = String(data: data, encoding: .utf8) {
            raw = utf8
        }

        if raw == nil {
            (raw, encoding) = singleByte(data)
        }

        let text = raw ?? ""
        let lineEnding = detectLineEnding(text)
        return DecodedText(text: normalizeLineEndings(text), encoding: encoding, hasBOM: hasBOM, lineEnding: lineEnding)
    }

    /// Windows Latin 1, or ISO Latin 1 for the few bytes Windows leaves undefined. Every byte maps
    /// to a character and back again, so nothing is lost on save.
    private static func singleByte<Bytes: DataProtocol>(_ bytes: Bytes) -> (String, String.Encoding) {
        let data = Data(bytes)
        if let text = String(data: data, encoding: .windowsCP1252) { return (text, .windowsCP1252) }
        return (String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self), .isoLatin1)
    }

    /// Encodes text for saving, restoring the original line endings and BOM.
    /// Returns nil when the text contains characters the encoding cannot represent.
    public static func encode(_ text: String, encoding: String.Encoding, hasBOM: Bool, lineEnding: LineEnding) -> Data? {
        let body = lineEnding == .lf ? text : text.replacingOccurrences(of: "\n", with: lineEnding.rawValue)
        guard let bytes = body.data(using: encoding, allowLossyConversion: false) else { return nil }
        var data = Data()
        if hasBOM {
            switch encoding {
            case .utf16LittleEndian: data.append(contentsOf: [0xFF, 0xFE])
            case .utf16BigEndian: data.append(contentsOf: [0xFE, 0xFF])
            // UTF-8, or a UTF-8 BOM that came in front of single-byte text.
            default: data.append(contentsOf: [0xEF, 0xBB, 0xBF])
            }
        }
        data.append(bytes)
        return data
    }

    /// Strict UTF-8 check that doesn't allocate a String, for large files.
    public static func isValidUTF8(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            let bytes = raw.bindMemory(to: UInt8.self)
            var i = 0
            let n = bytes.count
            while i < n {
                let b = bytes[i]
                if b < 0x80 { i += 1; continue }
                let length: Int
                var minimum: UInt32
                var scalar: UInt32
                switch b {
                case 0xC2...0xDF: length = 2; minimum = 0x80; scalar = UInt32(b & 0x1F)
                case 0xE0...0xEF: length = 3; minimum = 0x800; scalar = UInt32(b & 0x0F)
                case 0xF0...0xF4: length = 4; minimum = 0x10000; scalar = UInt32(b & 0x07)
                default: return false
                }
                guard i + length <= n else { return false }
                for k in 1..<length {
                    let c = bytes[i + k]
                    guard c & 0xC0 == 0x80 else { return false }
                    scalar = (scalar << 6) | UInt32(c & 0x3F)
                }
                if scalar < minimum || scalar > 0x10FFFF || (0xD800...0xDFFF).contains(scalar) { return false }
                i += length
            }
            return true
        }
    }

    public static func detectLineEnding(_ text: String) -> LineEnding {
        var crlf = 0, lf = 0, cr = 0
        var previousWasCR = false
        var scanned = 0
        for unit in text.utf8 {
            scanned += 1
            if scanned > 256 * 1024 { break }
            if unit == 0x0A {
                if previousWasCR { crlf += 1; cr -= 1 } else { lf += 1 }
                previousWasCR = false
            } else if unit == 0x0D {
                cr += 1
                previousWasCR = true
            } else {
                previousWasCR = false
            }
        }
        if crlf > 0, crlf >= lf, crlf >= cr { return .crlf }
        if cr > lf { return .cr }
        return .lf
    }

    public static func normalizeLineEndings(_ text: String) -> String {
        guard text.utf8.contains(0x0D) else { return text }
        return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    public static func name(of encoding: String.Encoding) -> String {
        switch encoding {
        case .utf8: return "UTF-8"
        case .utf16, .utf16LittleEndian, .utf16BigEndian: return "UTF-16"
        case .windowsCP1252: return "Windows Latin 1"
        case .isoLatin1: return "ISO Latin 1"
        case .ascii: return "ASCII"
        case .macOSRoman: return "Mac OS Roman"
        default: return "Encoding \(encoding.rawValue)"
        }
    }

    /// UTF-16 text without a BOM has a zero byte in every other position for Latin text.
    static func utf16Guess(_ data: Data) -> String.Encoding? {
        let sample = data.prefix(4096)
        guard sample.count >= 4, sample.count % 2 == 0 else { return nil }
        var evenZeros = 0, oddZeros = 0
        for (index, byte) in sample.enumerated() where byte == 0 {
            if index % 2 == 0 { evenZeros += 1 } else { oddZeros += 1 }
        }
        let pairs = sample.count / 2
        if oddZeros * 10 >= pairs * 7, evenZeros * 10 < pairs { return .utf16LittleEndian }
        if evenZeros * 10 >= pairs * 7, oddZeros * 10 < pairs { return .utf16BigEndian }
        return nil
    }
}

public enum FileSniffer {
    /// A quick guess at whether bytes are text. Looks at the first 8 KB only.
    public static func looksLikeText(_ data: Data) -> Bool {
        let sample = data.prefix(8192)
        if sample.isEmpty { return true }
        if sample.starts(with: [0xEF, 0xBB, 0xBF]) || sample.starts(with: [0xFF, 0xFE]) || sample.starts(with: [0xFE, 0xFF]) {
            return true
        }
        if TextDecoding.utf16Guess(data) != nil { return true }
        var suspicious = 0
        for byte in sample {
            if byte == 0 { return false }
            if byte < 0x20, byte != 0x09, byte != 0x0A, byte != 0x0D, byte != 0x0C, byte != 0x1B { suspicious += 1 }
        }
        return suspicious * 100 < sample.count * 2
    }
}
