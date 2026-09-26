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

    /// Well-formed CSV comes back byte for byte however its fields were quoted, including files that
    /// quote only some fields, as many exporters do with text columns.
    func testQuotingSurvivesARoundTrip() {
        var random = SeededRandom(seed: 7)
        let pieces = ["a", "Zoë", "1", "2.5", " ", ",", "\"", "\n", "\r\n", ""]
        for _ in 0..<3000 {
            let rowCount = Int.random(in: 1...5, using: &random)
            let columns = Int.random(in: 1...4, using: &random)
            let ending = Bool.random(using: &random) ? "\n" : "\r\n"
            var text = ""
            for r in 0..<rowCount {
                var fields: [String] = []
                for _ in 0..<columns {
                    let value = (0..<Int.random(in: 0...2, using: &random)).map { _ in pieces.randomElement(using: &random)! }.joined()
                    let mustQuote = value.contains { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" || $0 == "\r\n" }
                    let quoted = mustQuote || Bool.random(using: &random)
                    fields.append(quoted ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : value)
                }
                text += fields.joined(separator: ",")
                if r < rowCount - 1 || Bool.random(using: &random) { text += ending }
            }
            let data = Data(text.utf8)
            let parsed = CSV.parse(data, delimiter: CSV.comma)
            XCTAssertEqual(CSV.serialize(parsed.rows, format: parsed.format, quoted: parsed.quoted), data, text.debugDescription)
        }
    }

    func testQuoteMasksFollowColumnEdits() {
        let mask: UInt64 = 0b1011 // columns 0, 1 and 3 quoted
        XCTAssertEqual(CSV.quoteMask(mask, insertingColumnAt: 2), 0b10011)
        XCTAssertEqual(CSV.quoteMask(mask, insertingColumnAt: 0), 0b10110)
        XCTAssertEqual(CSV.quoteMask(mask, removingColumnAt: 1), 0b101)
        XCTAssertEqual(CSV.quoteMask(mask, removingColumnAt: 0), 0b101)
        XCTAssertEqual(CSV.quoteMask(UInt64.max, insertingColumnAt: 63), UInt64.max >> 1)
        XCTAssertEqual(CSV.quoteMask(mask, insertingColumnAt: 70), mask)
        // Files that quote by a single rule don't need masks at all.
        XCTAssertNil(CSV.parse(Data("a,b\n1,2\n".utf8)).quoted)
        XCTAssertNil(CSV.parse(Data("\"a\",\"b\"\n\"1\",\"2\"\n".utf8)).quoted)
        XCTAssertNotNil(CSV.parse(Data("\"name\",score\n\"Zoë\",7\n".utf8)).quoted)
    }

    func testMeasureMatchesParse() {
        func check(_ data: Data, _ label: String) {
            let rows = CSV.parse(data).rows
            let measured = CSV.measure(data)
            XCTAssertEqual(measured.records, rows.count, label)
            XCTAssertEqual(measured.columns, rows.map(\.count).max() ?? 0, label)
        }
        let cases = ["", "a", "a\n", "a,b\nc,d", "a,b\r\nc,d\r\n", "\"x\ny\",z\nq", "a,\n", "a,", "\n\n",
                     "\"unterminated\nstill", "\u{FEFF}h1,h2\n1,2\n", "a\rb\rc", "\"a\"\"b\",c\n", "x;y\n1;\"2\n3\"\n",
                     "a,b\n1,2,3,4\n5"]
        for text in cases { check(Data(text.utf8), text.debugDescription) }
        // And thousands of random inputs made only of the characters that matter.
        var random = SeededRandom(seed: 42)
        let alphabet = Array("a,\";\n\r".utf8)
        for _ in 0..<5000 {
            let data = Data((0..<Int.random(in: 0...24, using: &random)).map { _ in alphabet.randomElement(using: &random)! })
            check(data, String(decoding: data, as: UTF8.self).debugDescription)
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
