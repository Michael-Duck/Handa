import Foundation

/// A JSON value with a strict parser and a deterministic writer (sorted keys, integers stay integers).
public enum JSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    public subscript(key: String) -> JSON? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var double: Double? { if case .number(let n) = self { return n }; return nil }
    public var int: Int? {
        guard case .number(let n) = self, n.rounded() == n, abs(n) < 9.0e15 else { return nil }
        return Int(n)
    }
    public var array: [JSON]? { if case .array(let a) = self { return a }; return nil }
    public var object: [String: JSON]? { if case .object(let o) = self { return o }; return nil }
    public var isNull: Bool { self == .null }

    public struct ParseError: Error, CustomStringConvertible {
        public let message: String
        public let offset: Int
        public var description: String { "\(message) at byte \(offset)" }
    }

    public static func parse(_ text: String) throws -> JSON {
        try parse(Data(text.utf8))
    }

    public static func parse(_ data: Data) throws -> JSON {
        var parser = Parser(bytes: [UInt8](data))
        parser.skipWhitespace()
        let value = try parser.value(depth: 0)
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else { throw parser.error("Unexpected trailing characters") }
        return value
    }

    public func serialized(pretty: Bool = false) -> String {
        var out = ""
        write(into: &out, pretty: pretty, indent: 0)
        return out
    }

    public var data: Data { Data(serialized().utf8) }

    private func write(into out: inout String, pretty: Bool, indent: Int) {
        switch self {
        case .null:
            out += "null"
        case .bool(let b):
            out += b ? "true" : "false"
        case .number(let n):
            if !n.isFinite {
                out += "null"
            } else if n.rounded() == n, abs(n) < 9.0e15 {
                out += String(Int64(n))
            } else {
                out += "\(n)"
            }
        case .string(let s):
            JSON.writeString(s, into: &out)
        case .array(let items):
            if items.isEmpty { out += "[]"; return }
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += "," }
                if pretty { out += "\n" + String(repeating: "  ", count: indent + 1) }
                item.write(into: &out, pretty: pretty, indent: indent + 1)
            }
            if pretty { out += "\n" + String(repeating: "  ", count: indent) }
            out += "]"
        case .object(let object):
            if object.isEmpty { out += "{}"; return }
            out += "{"
            for (i, key) in object.keys.sorted().enumerated() {
                if i > 0 { out += "," }
                if pretty { out += "\n" + String(repeating: "  ", count: indent + 1) }
                JSON.writeString(key, into: &out)
                out += pretty ? ": " : ":"
                object[key]!.write(into: &out, pretty: pretty, indent: indent + 1)
            }
            if pretty { out += "\n" + String(repeating: "  ", count: indent) }
            out += "}"
        }
    }

    private static func writeString(_ s: String, into out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 || scalar == "\u{2028}" || scalar == "\u{2029}" {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        func error(_ message: String) -> ParseError { ParseError(message: message, offset: index) }

        mutating func skipWhitespace() {
            while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x0A || bytes[index] == 0x0D || bytes[index] == 0x09 {
                index += 1
            }
        }

        mutating func value(depth: Int) throws -> JSON {
            guard depth < 512 else { throw error("Nesting too deep") }
            guard index < bytes.count else { throw error("Unexpected end of input") }
            switch bytes[index] {
            case UInt8(ascii: "{"): return try object(depth: depth)
            case UInt8(ascii: "["): return try array(depth: depth)
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try literal("true"); return .bool(true)
            case UInt8(ascii: "f"): try literal("false"); return .bool(false)
            case UInt8(ascii: "n"): try literal("null"); return .null
            default: return try number()
            }
        }

        mutating func literal(_ word: String) throws {
            let expected = Array(word.utf8)
            guard index + expected.count <= bytes.count, Array(bytes[index..<index + expected.count]) == expected else {
                throw error("Invalid literal")
            }
            index += expected.count
        }

        mutating func object(depth: Int) throws -> JSON {
            index += 1
            var result: [String: JSON] = [:]
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(result) }
            while true {
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw error("Expected a key") }
                let key = try string()
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw error("Expected ':'") }
                index += 1
                skipWhitespace()
                result[key] = try value(depth: depth + 1)
                skipWhitespace()
                guard index < bytes.count else { throw error("Unterminated object") }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(result) }
                throw error("Expected ',' or '}'")
            }
        }

        mutating func array(depth: Int) throws -> JSON {
            index += 1
            var result: [JSON] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(result) }
            while true {
                skipWhitespace()
                result.append(try value(depth: depth + 1))
                skipWhitespace()
                guard index < bytes.count else { throw error("Unterminated array") }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(result) }
                throw error("Expected ',' or ']'")
            }
        }

        mutating func hex4() throws -> UInt32 {
            guard index + 4 <= bytes.count else { throw error("Bad unicode escape") }
            var value: UInt32 = 0
            for _ in 0..<4 {
                let c = bytes[index]
                value <<= 4
                switch c {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): value |= UInt32(c - UInt8(ascii: "0"))
                case UInt8(ascii: "a")...UInt8(ascii: "f"): value |= UInt32(c - UInt8(ascii: "a") + 10)
                case UInt8(ascii: "A")...UInt8(ascii: "F"): value |= UInt32(c - UInt8(ascii: "A") + 10)
                default: throw error("Bad unicode escape")
                }
                index += 1
            }
            return value
        }

        mutating func string() throws -> String {
            index += 1
            var out: [UInt8] = []
            while index < bytes.count {
                let c = bytes[index]
                if c == UInt8(ascii: "\"") {
                    index += 1
                    return String(decoding: out, as: UTF8.self)
                }
                if c < 0x20 { throw error("Control character in string") }
                if c != UInt8(ascii: "\\") {
                    out.append(c)
                    index += 1
                    continue
                }
                index += 1
                guard index < bytes.count else { break }
                let escape = bytes[index]
                index += 1
                switch escape {
                case UInt8(ascii: "\""): out.append(0x22)
                case UInt8(ascii: "\\"): out.append(0x5C)
                case UInt8(ascii: "/"): out.append(0x2F)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    var scalar = try hex4()
                    if (0xD800...0xDBFF).contains(scalar) {
                        if index + 6 <= bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                            index += 2
                            let low = try hex4()
                            if (0xDC00...0xDFFF).contains(low) {
                                scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                            } else {
                                scalar = 0xFFFD
                            }
                        } else {
                            scalar = 0xFFFD
                        }
                    } else if (0xDC00...0xDFFF).contains(scalar) {
                        scalar = 0xFFFD
                    }
                    out.append(contentsOf: Array(String(Character(Unicode.Scalar(scalar) ?? "\u{FFFD}")).utf8))
                default:
                    throw error("Bad escape")
                }
            }
            throw error("Unterminated string")
        }

        mutating func number() throws -> JSON {
            let start = index
            if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
            let digitsStart = index
            while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1 }
            guard index > digitsStart else { throw error("Unexpected character") }
            if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
                index += 1
                let fraction = index
                while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1 }
                guard index > fraction else { throw error("Bad number") }
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
                index += 1
                if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
                let exponent = index
                while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1 }
                guard index > exponent else { throw error("Bad number") }
            }
            let text = String(decoding: bytes[start..<index], as: UTF8.self)
            guard let value = Double(text) else { throw error("Bad number") }
            return .number(value)
        }
    }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByStringInterpolation, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
                ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral, ExpressibleByFloatLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSON)...) {
        var object: [String: JSON] = [:]
        for (key, value) in elements { object[key] = value }
        self = .object(object)
    }
    public init(nilLiteral: ()) { self = .null }
}
