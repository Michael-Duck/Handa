import XCTest
@testable import HandaCore

final class CSVTests: XCTestCase {
    private func parse(_ text: String, delimiter: UInt8? = nil) -> CSVParseResult {
        CSV.parse(Data(text.utf8), delimiter: delimiter)
    }

    func testSimpleRows() {
        let result = parse("name,age\nAda,36\nGrace,45\n")
        XCTAssertEqual(result.rows, [["name", "age"], ["Ada", "36"], ["Grace", "45"]])
        XCTAssertEqual(result.format.delimiter, CSV.comma)
        XCTAssertEqual(result.format.lineEnding, .lf)
        XCTAssertTrue(result.format.endsWithNewline)
        XCTAssertFalse(result.isTruncated)
    }

    func testQuotedFieldsWithDelimitersQuotesAndNewlines() {
        let result = parse("a,b\n\"x, y\",\"say \"\"hi\"\"\"\n\"line1\nline2\",z")
        XCTAssertEqual(result.rows, [["a", "b"], ["x, y", "say \"hi\""], ["line1\nline2", "z"]])
        XCTAssertFalse(result.format.endsWithNewline)
    }

    func testCRLFAndBOM() {
        let data = Data([0xEF, 0xBB, 0xBF] + Array("a;b\r\n1;2\r\n".utf8))
        let result = CSV.parse(data)
        XCTAssertTrue(result.format.hasBOM)
        XCTAssertEqual(result.format.delimiter, CSV.semicolon)
        XCTAssertEqual(result.format.lineEnding, .crlf)
        XCTAssertEqual(result.rows, [["a", "b"], ["1", "2"]])
    }

    func testDetectsTabsEvenWhenCommasAppearInText() {
        let result = parse("city\tnote\nParis\tbig, old\nOslo\tcold, calm\n")
        XCTAssertEqual(result.format.delimiter, CSV.tab)
        XCTAssertEqual(result.rows[1], ["Paris", "big, old"])
    }

    func testTitleLineDoesNotFoolDelimiterDetection() {
        let result = parse("Monthly report\na,b,c\n1,2,3\n4,5,6\n7,8,9\n")
        XCTAssertEqual(result.format.delimiter, CSV.comma)
    }

    func testEmptyFieldsTrailingDelimiterAndBlankLines() {
        let result = parse("a,,c,\n\n1,2,3,4\n")
        XCTAssertEqual(result.rows, [["a", "", "c", ""], [""], ["1", "2", "3", "4"]])
    }

    func testUnterminatedQuoteKeepsRestOfFile() {
        let result = parse("a,\"never closed\nb,c")
        XCTAssertEqual(result.rows, [["a", "never closed\nb,c"]])
    }

    func testTextAfterClosingQuoteIsKept() {
        let result = parse("\"5\" inch,x\n")
        XCTAssertEqual(result.rows, [["5 inch", "x"]])
    }

    func testMaxRowsTruncates() {
        let result = CSV.parse(Data("1\n2\n3\n4\n".utf8), maxRows: 2)
        XCTAssertEqual(result.rows, [["1"], ["2"]])
        XCTAssertTrue(result.isTruncated)
    }

    func testEmptyInput() {
        let result = parse("")
        XCTAssertEqual(result.rows, [])
        XCTAssertFalse(result.isTruncated)
    }

    func testRoundTripPreservesBytes() {
        let samples = [
            "name,age\nAda,36\nGrace,45\n",
            "a;b\r\n1;2\r\n",
            "\"a\",\"b\"\n\"1\",\"2\"\n",
            "\"a\",\"\",\"c\"\n",
            "x,\"y, z\",\"q\"\"uote\"\nlast,row,\"multi\nline\"",
            "col\n\nafter blank\n",
            "\t\tleading tabs\n",
        ]
        for sample in samples {
            let result = parse(sample)
            let written = String(decoding: CSV.serialize(result.rows, format: result.format), as: UTF8.self)
            XCTAssertEqual(written, sample, "round trip changed: \(sample.debugDescription)")
        }
    }

    func testRoundTripWithBOM() {
        let data = Data([0xEF, 0xBB, 0xBF] + Array("h1,h2\n1,2\n".utf8))
        let result = CSV.parse(data)
        XCTAssertEqual(CSV.serialize(result.rows, format: result.format), data)
    }

    func testSerializeQuotesWhenNeeded() {
        let format = CSVFormat(delimiter: CSV.comma)
        let data = CSV.serialize([["plain", "with,comma", "with \"quote\"", "two\nlines"]], format: format)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "plain,\"with,comma\",\"with \"\"quote\"\"\",\"two\nlines\"\n")
    }

    func testHeaderDetection() {
        XCTAssertTrue(CSV.looksLikeHeader([["Date", "Amount"], ["2026-01-02", "12.50"]]))
        XCTAssertFalse(CSV.looksLikeHeader([["1", "2"], ["3", "4"]]))
        XCTAssertFalse(CSV.looksLikeHeader([["a", "a"], ["x", "y"]]))
        XCTAssertFalse(CSV.looksLikeHeader([["only one row"]]))
    }

    func testNumericColumns() {
        let rows: [[String]] = [["Item", "Qty", "Price"], ["Tea", "2", "$3.50"], ["Cake", "10", "$12.00"], ["Pie", "", "$1,200.00"]]
        XCTAssertEqual(CSV.numericColumns(rows.dropFirst(), columnCount: 3), [1, 2])
    }

    func testNumberParsing() {
        XCTAssertEqual(NumberParsing.number(from: "1,234.5"), 1234.5)
        XCTAssertEqual(NumberParsing.number(from: "-3.5%"), -3.5)
        XCTAssertEqual(NumberParsing.number(from: "(42)"), -42)
        XCTAssertEqual(NumberParsing.number(from: "$12"), 12)
        XCTAssertEqual(NumberParsing.number(from: "1e3"), 1000)
        XCTAssertEqual(NumberParsing.number(from: " 7 "), 7)
        XCTAssertEqual(NumberParsing.number(from: "€9.99"), 9.99)
        XCTAssertNil(NumberParsing.number(from: "1,2"))
        XCTAssertNil(NumberParsing.number(from: "abc"))
        XCTAssertNil(NumberParsing.number(from: "12abc"))
        XCTAssertNil(NumberParsing.number(from: ""))
        XCTAssertNil(NumberParsing.number(from: "2026-01-02"))
    }

    func testClipboardText() {
        XCTAssertEqual(CSV.clipboardText([["a", "b\tc"], ["d\ne", "f"]]), "a\tb c\nd e\tf")
    }

    func testLargeInputIsFast() {
        var text = "id,name,amount\n"
        for i in 0..<100_000 { text += "\(i),\"Name \(i)\",\(Double(i) * 1.5)\n" }
        let data = Data(text.utf8)
        let start = Date()
        let result = CSV.parse(data)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(result.rows.count, 100_001)
        XCTAssertEqual(result.rows.last, ["99999", "Name 99999", "149998.5"])
        XCTAssertLessThan(elapsed, 5, "parsing 100k rows took \(elapsed)s")
    }

    func testCountRecordsMatchesParse() {
        let cases = ["", "a", "a\n", "a,b\nc,d", "a,b\r\nc,d\r\n", "\"x\ny\",z\nq", "a,\n", "a,", "\n\n",
                     "\"unterminated\nstill", "\u{FEFF}h1,h2\n1,2\n", "a\rb\rc", "\"a\"\"b\",c\n", "x;y\n1;\"2\n3\"\n"]
        for text in cases {
            let data = Data(text.utf8)
            XCTAssertEqual(CSV.countRecords(data), CSV.parse(data).rows.count, text.debugDescription)
        }
        // And thousands of random inputs made only of the characters that matter.
        var random = SeededRandom(seed: 42)
        let alphabet = Array("a,\";\n\r".utf8)
        for _ in 0..<5000 {
            let data = Data((0..<Int.random(in: 0...24, using: &random)).map { _ in alphabet.randomElement(using: &random)! })
            XCTAssertEqual(CSV.countRecords(data), CSV.parse(data).rows.count, String(decoding: data, as: UTF8.self).debugDescription)
        }
    }
}

/// A tiny SplitMix64, so random tests run the same way every time.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
