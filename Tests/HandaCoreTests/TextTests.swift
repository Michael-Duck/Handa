import XCTest
@testable import HandaCore

final class TextDecodingTests: XCTestCase {
    func testUTF8() {
        let decoded = TextDecoding.decode(Data("héllo\nwörld\n".utf8))
        XCTAssertEqual(decoded.text, "héllo\nwörld\n")
        XCTAssertEqual(decoded.encoding, .utf8)
        XCTAssertFalse(decoded.hasBOM)
        XCTAssertEqual(decoded.lineEnding, .lf)
    }

    func testUTF8BOMAndCRLFRoundTrip() {
        let original = Data([0xEF, 0xBB, 0xBF] + Array("one\r\ntwo\r\n".utf8))
        let decoded = TextDecoding.decode(original)
        XCTAssertEqual(decoded.text, "one\ntwo\n")
        XCTAssertTrue(decoded.hasBOM)
        XCTAssertEqual(decoded.lineEnding, .crlf)
        let encoded = TextDecoding.encode(decoded.text, encoding: decoded.encoding, hasBOM: decoded.hasBOM, lineEnding: decoded.lineEnding)
        XCTAssertEqual(encoded, original)
    }

    func testUTF16LittleEndianWithBOM() {
        var data = Data([0xFF, 0xFE])
        data.append("Hi ✓".data(using: .utf16LittleEndian)!)
        let decoded = TextDecoding.decode(data)
        XCTAssertEqual(decoded.text, "Hi ✓")
        XCTAssertEqual(decoded.encoding, .utf16LittleEndian)
        XCTAssertEqual(TextDecoding.encode(decoded.text, encoding: decoded.encoding, hasBOM: true, lineEnding: .lf), data)
    }

    func testUTF16WithoutBOMIsDetected() {
        let data = "plain ascii text here".data(using: .utf16LittleEndian)!
        let decoded = TextDecoding.decode(data)
        XCTAssertEqual(decoded.encoding, .utf16LittleEndian)
        XCTAssertEqual(decoded.text, "plain ascii text here")
    }

    func testLatin1FallbackRoundTrip() {
        let data = Data([0x63, 0x61, 0x66, 0xE9, 0x0A]) // "café\n" in Windows-1252
        let decoded = TextDecoding.decode(data)
        XCTAssertEqual(decoded.text, "café\n")
        XCTAssertNotEqual(decoded.encoding, .utf8)
        XCTAssertEqual(TextDecoding.encode(decoded.text, encoding: decoded.encoding, hasBOM: false, lineEnding: .lf), data)
    }

    func testEncodeFailsForUnrepresentableCharacters() {
        XCTAssertNil(TextDecoding.encode("emoji 🙂", encoding: .isoLatin1, hasBOM: false, lineEnding: .lf))
    }

    func testClassicMacLineEndings() {
        let decoded = TextDecoding.decode(Data("a\rb\rc".utf8))
        XCTAssertEqual(decoded.lineEnding, .cr)
        XCTAssertEqual(decoded.text, "a\nb\nc")
        XCTAssertEqual(TextDecoding.encode(decoded.text, encoding: .utf8, hasBOM: false, lineEnding: .cr), Data("a\rb\rc".utf8))
    }

    func testUTF8Validation() {
        XCTAssertTrue(TextDecoding.isValidUTF8(Data("plain, ünïcødé ✓ 😀".utf8)))
        XCTAssertTrue(TextDecoding.isValidUTF8(Data()))
        XCTAssertFalse(TextDecoding.isValidUTF8(Data([0x63, 0x61, 0x66, 0xE9])))       // Latin-1 é
        XCTAssertFalse(TextDecoding.isValidUTF8(Data([0xC0, 0x80])))                   // overlong
        XCTAssertFalse(TextDecoding.isValidUTF8(Data([0xED, 0xA0, 0x80])))             // surrogate
        XCTAssertFalse(TextDecoding.isValidUTF8(Data([0xE2, 0x82])))                   // truncated
        XCTAssertFalse(TextDecoding.isValidUTF8(Data([0xF4, 0x90, 0x80, 0x80])))       // above U+10FFFF
    }

    func testSniffer() {
        XCTAssertTrue(FileSniffer.looksLikeText(Data("hello world\n".utf8)))
        XCTAssertTrue(FileSniffer.looksLikeText(Data()))
        XCTAssertTrue(FileSniffer.looksLikeText("utf16 text".data(using: .utf16LittleEndian)!))
        XCTAssertFalse(FileSniffer.looksLikeText(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D])))
        XCTAssertFalse(FileSniffer.looksLikeText(Data((0..<200).map { UInt8($0 % 32) })))
    }

    func testTextStats() {
        let stats = TextStats("Hello there\nsecond line here\n")
        XCTAssertEqual(stats.lines, 2)
        XCTAssertEqual(stats.words, 5)
        XCTAssertEqual(TextStats("").lines, 0)
        XCTAssertEqual(TextStats("no newline").lines, 1)
    }
}

final class FileTypeTests: XCTestCase {
    func testCategories() {
        XCTAssertEqual(FileTypes.category(forFileName: "Sales.CSV"), .table)
        XCTAssertEqual(FileTypes.category(forFileName: "notes.md"), .markdown)
        XCTAssertEqual(FileTypes.category(forFileName: "Report.pdf"), .pdf)
        XCTAssertEqual(FileTypes.category(forFileName: "Letter.docx"), .richText)
        XCTAssertEqual(FileTypes.category(forFileName: "photo.HEIC"), .image)
        XCTAssertEqual(FileTypes.category(forFileName: "budget.xlsx"), .quickLook)
        XCTAssertEqual(FileTypes.category(forFileName: "main.swift"), .text)
        XCTAssertEqual(FileTypes.category(forFileName: "Makefile"), .text)
        XCTAssertEqual(FileTypes.category(forFileName: "server.log"), .text)
        XCTAssertNil(FileTypes.category(forFileName: "mystery.qqq"))
    }

    func testLanguages() {
        XCTAssertEqual(Language.detect(fileName: "App.swift"), .swift)
        XCTAssertEqual(Language.detect(fileName: "Dockerfile.dev"), .dockerfile)
        XCTAssertEqual(Language.detect(fileName: ".zshrc"), .shell)
        XCTAssertEqual(Language.detect(fileName: "Info.plist"), .xml)
        XCTAssertNil(Language.detect(fileName: "readme.txt"))
        XCTAssertEqual(Language.detect(shebang: "#!/usr/bin/env python3"), .python)
        XCTAssertEqual(Language.detect(shebang: "#!/bin/bash"), .shell)
        XCTAssertNil(Language.detect(shebang: "hello"))
        XCTAssertEqual(Language.detect(hint: "js"), .javascript)
        XCTAssertEqual(Language.detect(hint: "Swift"), .swift)
        XCTAssertEqual(Language.detect(hint: "console"), .shell)
        XCTAssertNil(Language.detect(hint: "klingon"))
    }
}

final class SyntaxHighlighterTests: XCTestCase {
    private func kinds(_ text: String, _ language: Language) -> [String: TokenKind] {
        var map: [String: TokenKind] = [:]
        let ns = text as NSString
        for token in SyntaxHighlighter.tokens(in: text, language: language) {
            map[ns.substring(with: token.range)] = token.kind
        }
        return map
    }

    func testEveryGrammarCompiles() {
        for language in Language.allCases {
            XCTAssertNotNil(SyntaxHighlighter.grammar(for: language), "\(language) grammar failed to compile")
        }
    }

    func testSwift() {
        let map = kinds("import Foundation\n// note\nlet x: Int = 42 // done\nfunc go() { print(\"hi\") }\n@MainActor struct S {}", .swift)
        XCTAssertEqual(map["import"], .keyword)
        XCTAssertEqual(map["Foundation"], .type)
        XCTAssertEqual(map["// note"], .comment)
        XCTAssertEqual(map["42"], .number)
        XCTAssertEqual(map["\"hi\""], .string)
        XCTAssertEqual(map["print"], .function)
        XCTAssertEqual(map["@MainActor"], .attribute)
        XCTAssertNil(map["x"])
    }

    func testKeywordsInsideStringsAndCommentsAreNotKeywords() {
        let tokens = SyntaxHighlighter.tokens(in: "let s = \"if else\" /* return */", language: .swift)
        let keywordTexts = tokens.filter { $0.kind == .keyword }.map { ("let s = \"if else\" /* return */" as NSString).substring(with: $0.range) }
        XCTAssertEqual(keywordTexts, ["let"])
    }

    func testPython() {
        let map = kinds("def total(items):\n    \"\"\"Sum.\"\"\"\n    return sum(i.price for i in items)  # money\n", .python)
        XCTAssertEqual(map["def"], .keyword)
        XCTAssertEqual(map["\"\"\"Sum.\"\"\""], .string)
        XCTAssertEqual(map["# money"], .comment)
        XCTAssertEqual(map["sum"], .function)
    }

    func testJSONKeysAreProperties() {
        let map = kinds("{\"name\": \"Handa\", \"ok\": true, \"n\": -1.5}", .json)
        XCTAssertEqual(map["\"name\""], .property)
        XCTAssertEqual(map["\"Handa\""], .string)
        XCTAssertEqual(map["true"], .keyword)
        XCTAssertEqual(map["-1.5"], .number)
    }

    func testHTMLTagsAndAttributes() {
        let text = "<!-- c --><a href=\"/x\">link &amp; more</a>"
        let tokens = SyntaxHighlighter.tokens(in: text, language: .html)
        let ns = text as NSString
        let pairs = tokens.map { (ns.substring(with: $0.range), $0.kind) }
        XCTAssertTrue(pairs.contains { $0.0 == "<!-- c -->" && $0.1 == .comment })
        XCTAssertTrue(pairs.contains { $0.0 == "href" && $0.1 == .property })
        XCTAssertTrue(pairs.contains { $0.0 == "\"/x\"" && $0.1 == .string })
        XCTAssertTrue(pairs.contains { $0.0 == "&amp;" && $0.1 == .attribute })
        XCTAssertTrue(pairs.contains { $0.0 == "</a>" && $0.1 == .tag })
    }

    func testMarkdownSource() {
        let map = kinds("# Title\n\nSome **bold** and `code`.\n\n- [x] done\n> quote\n", .markdown)
        XCTAssertEqual(map["# Title"], .heading)
        XCTAssertEqual(map["**bold**"], .emphasis)
        XCTAssertEqual(map["`code`"], .string)
        XCTAssertEqual(map["> quote"], .comment)
    }

    func testDiff() {
        let map = kinds("--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n+new\n", .diff)
        XCTAssertEqual(map["-old"], .deleted)
        XCTAssertEqual(map["+new"], .inserted)
        XCTAssertEqual(map["--- a/x"], .meta)
        XCTAssertEqual(map["@@ -1 +1 @@"], .heading)
    }

    func testSQLIsCaseInsensitive() {
        let map = kinds("SELECT name FROM users WHERE id = 1 -- first", .sql)
        XCTAssertEqual(map["SELECT"], .keyword)
        XCTAssertEqual(map["FROM"], .keyword)
        XCTAssertEqual(map["-- first"], .comment)
    }

    func testEmptyAndHugeInputs() {
        XCTAssertTrue(SyntaxHighlighter.tokens(in: "", language: .swift).isEmpty)
        XCTAssertTrue(SyntaxHighlighter.tokens(in: String(repeating: "a", count: 20), language: .swift, limit: 10).isEmpty)
    }

    func testHighlightingIsFastOnLargeFiles() {
        let line = "func value(_ x: Int) -> Int { return x * 2 + 0x1F // double it\n"
        let text = String(repeating: line, count: 20_000)
        let start = Date()
        let tokens = SyntaxHighlighter.tokens(in: text, language: .swift)
        XCTAssertGreaterThan(tokens.count, 100_000)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }
}
