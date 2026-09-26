import XCTest
@testable import HandaCore

final class JSONTests: XCTestCase {
    func testParseAndSerializeRoundTrip() throws {
        let text = #"{"a":[1,2.5,-3e2,true,false,null],"b":{"c":"d\n\"e\" é 😀"}}"#
        let json = try JSON.parse(text)
        XCTAssertEqual(json["a"]?.array?.count, 6)
        XCTAssertEqual(json["a"]?.array?[0].int, 1)
        XCTAssertEqual(json["a"]?.array?[2].double, -300)
        XCTAssertEqual(json["b"]?["c"]?.string, "d\n\"e\" é 😀")
        XCTAssertEqual(try JSON.parse(json.serialized()), json)
        XCTAssertEqual(try JSON.parse(json.serialized(pretty: true)), json)
    }

    func testIntegersStayIntegers() {
        let json: JSON = ["id": 7, "big": 1234567890123]
        XCTAssertEqual(json.serialized(), #"{"big":1234567890123,"id":7}"#)
    }

    func testRejectsInvalidJSON() {
        for bad in ["", "{", "[1,]", "{\"a\" 1}", "tru", "\"unterminated", "{\"a\":1} x", "01x", "[\"\u{01}\"]"] {
            XCTAssertThrowsError(try JSON.parse(bad), "should reject \(bad.debugDescription)")
        }
    }

    func testControlCharactersAreEscaped() throws {
        let json = JSON.string("tab\tbell\u{07}")
        XCTAssertEqual(json.serialized(), "\"tab\\tbell\\u0007\"")
        XCTAssertEqual(try JSON.parse(json.serialized()), json)
    }
}

final class MCPServerTests: XCTestCase {
    private func makeServer() -> MCPServer {
        let echo = MCPTool(name: "echo", title: "Echo", description: "Echoes text",
                           inputSchema: ["type": "object", "properties": ["text": ["type": "string"]], "required": ["text"]]) { args in
            guard let text = args["text"]?.string else { return .error("text is required") }
            return .text(text)
        }
        let boom = MCPTool(name: "boom", title: "Boom", description: "Throws", inputSchema: ["type": "object"]) { _ in
            struct Failure: Error, CustomStringConvertible { var description: String { "kaboom" } }
            throw Failure()
        }
        let prompt = MCPPrompt(name: "review", title: "Review", description: "Review the file",
                               arguments: [.init(name: "focus", description: "What to look at", required: true)]) { args in
            "Please review with focus on \(args["focus"] ?? "")"
        }
        return MCPServer(name: "handa", title: "Handa", version: "1.2.3", instructions: "Be nice", tools: [echo, boom], prompts: [prompt])
    }

    private func call(_ server: MCPServer, _ line: String) throws -> JSON {
        let response = try XCTUnwrap(server.handleLine(line))
        return try JSON.parse(response)
    }

    func testInitializeNegotiatesVersion() throws {
        let server = makeServer()
        let response = try call(server, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"0"}}}"#)
        XCTAssertEqual(response["id"]?.int, 1)
        XCTAssertEqual(response["result"]?["protocolVersion"]?.string, "2025-03-26")
        XCTAssertEqual(response["result"]?["serverInfo"]?["name"]?.string, "handa")
        XCTAssertEqual(response["result"]?["serverInfo"]?["version"]?.string, "1.2.3")
        XCTAssertNotNil(response["result"]?["capabilities"]?["tools"])
        XCTAssertNotNil(response["result"]?["capabilities"]?["prompts"])
        XCTAssertEqual(response["result"]?["instructions"]?.string, "Be nice")
        XCTAssertEqual(server.clientName, "test")

        let future = try call(server, #"{"jsonrpc":"2.0","id":"x","method":"initialize","params":{"protocolVersion":"2099-01-01"}}"#)
        XCTAssertEqual(future["id"]?.string, "x")
        XCTAssertEqual(future["result"]?["protocolVersion"]?.string, MCPServer.supportedProtocolVersions[0])
    }

    func testNotificationsGetNoResponse() {
        let server = makeServer()
        XCTAssertNil(server.handleLine(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
        XCTAssertNil(server.handleLine("   "))
    }

    func testToolsListAndCall() throws {
        let server = makeServer()
        let list = try call(server, #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let names = list["result"]?["tools"]?.array?.compactMap { $0["name"]?.string }
        XCTAssertEqual(names, ["echo", "boom"])
        XCTAssertEqual(list["result"]?["tools"]?.array?.first?["inputSchema"]?["type"]?.string, "object")

        let echo = try call(server, #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hello"}}}"#)
        XCTAssertEqual(echo["result"]?["content"]?.array?.first?["text"]?.string, "hello")
        XCTAssertEqual(echo["result"]?["isError"]?.bool, false)

        let missing = try call(server, #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"echo","arguments":{}}}"#)
        XCTAssertEqual(missing["result"]?["isError"]?.bool, true)

        let thrown = try call(server, #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"boom"}}"#)
        XCTAssertEqual(thrown["result"]?["isError"]?.bool, true)
        XCTAssertEqual(thrown["result"]?["content"]?.array?.first?["text"]?.string, "kaboom")

        let unknown = try call(server, #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"nope"}}"#)
        XCTAssertEqual(unknown["error"]?["code"]?.int, -32602)
    }

    func testPrompts() throws {
        let server = makeServer()
        let list = try call(server, #"{"jsonrpc":"2.0","id":1,"method":"prompts/list"}"#)
        XCTAssertEqual(list["result"]?["prompts"]?.array?.first?["name"]?.string, "review")
        let get = try call(server, #"{"jsonrpc":"2.0","id":2,"method":"prompts/get","params":{"name":"review","arguments":{"focus":"totals"}}}"#)
        XCTAssertEqual(get["result"]?["messages"]?.array?.first?["content"]?["text"]?.string, "Please review with focus on totals")
        let missing = try call(server, #"{"jsonrpc":"2.0","id":3,"method":"prompts/get","params":{"name":"review"}}"#)
        XCTAssertEqual(missing["error"]?["code"]?.int, -32602)
    }

    func testErrors() throws {
        let server = makeServer()
        XCTAssertEqual(try call(server, "{not json")["error"]?["code"]?.int, -32700)
        XCTAssertEqual(try call(server, #"{"jsonrpc":"2.0","id":9,"method":"does/not/exist"}"#)["error"]?["code"]?.int, -32601)
        XCTAssertEqual(try call(server, #"[1]"#).array?.first?["error"]?["code"]?.int, -32600)
        XCTAssertEqual(try call(server, #"{"jsonrpc":"2.0","id":10}"#)["error"]?["code"]?.int, -32600)
        XCTAssertEqual(try call(server, #"{"jsonrpc":"2.0","id":11,"method":"ping"}"#)["result"], .object([:]))
    }

    func testBatch() throws {
        let server = makeServer()
        let response = try call(server, #"[{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","method":"notifications/initialized"},{"jsonrpc":"2.0","id":2,"method":"tools/list"}]"#)
        XCTAssertEqual(response.array?.count, 2)
    }

    func testStdioLoop() throws {
        let server = makeServer()
        let input = Pipe(), output = Pipe()
        let requests = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"echo","arguments":{"text":"über"}}}"#,
        ]
        input.fileHandleForWriting.write(Data((requests.joined(separator: "\n") + "\n").utf8))
        try input.fileHandleForWriting.close()
        server.run(input: input.fileHandleForReading, output: output.fileHandleForWriting)
        try output.fileHandleForWriting.close()
        let lines = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(try JSON.parse(lines[1])["result"]?["content"]?.array?.first?["text"]?.string, "über")
    }
}

final class ReviewTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("handa-tests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testStoreAddListRemove() throws {
        let store = ReviewStore(directory: directory)
        let path = "/Users/me/Documents/Contract.pdf"
        XCTAssertEqual(store.reviews(for: path), [])
        let older = Review(title: "First", body: "Looks fine", source: "Test", createdAt: Date(timeIntervalSince1970: 1), contentHash: "abc", instruction: "check")
        let newer = Review(title: "Second", body: "Clause 4 is odd", source: "Test", createdAt: Date(timeIntervalSince1970: 2))
        try store.add(older, for: path)
        try store.add(newer, for: path)
        XCTAssertEqual(store.reviews(for: path).map(\.title), ["Second", "First"])
        XCTAssertTrue(store.hasReview(for: path, contentHash: "abc", instruction: "check"))
        XCTAssertFalse(store.hasReview(for: path, contentHash: "abc", instruction: "other"))
        // A second store (another process) sees the same data.
        XCTAssertEqual(ReviewStore(directory: directory).reviews(for: path).count, 2)
        try store.remove(id: newer.id, for: path)
        XCTAssertEqual(store.reviews(for: path).map(\.title), ["First"])
        try store.remove(id: older.id, for: path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL(for: path).path))
    }

    func testStoreKeepsHistoryShort() throws {
        let store = ReviewStore(directory: directory)
        for i in 0..<25 { try store.add(Review(title: "\(i)", body: "", source: "t", createdAt: Date(timeIntervalSince1970: Double(i))), for: "/x") }
        XCTAssertEqual(store.reviews(for: "/x").count, 20)
        XCTAssertEqual(store.reviews(for: "/x").first?.title, "24")
    }

    func testRules() {
        let rules = [
            ReviewRule(pattern: "*.csv", instruction: "Check totals"),
            ReviewRule(pattern: "~/Contracts/**/*.pdf", instruction: "Flag risky clauses"),
            ReviewRule(pattern: "*.md", instruction: "off", enabled: false),
        ]
        let home = NSHomeDirectory()
        XCTAssertEqual(ReviewRule.firstMatch(in: rules, path: "/tmp/Sales.CSV")?.instruction, "Check totals")
        XCTAssertEqual(ReviewRule.firstMatch(in: rules, path: home + "/Contracts/2026/lease.pdf")?.instruction, "Flag risky clauses")
        XCTAssertEqual(ReviewRule.firstMatch(in: rules, path: home + "/Contracts/lease.pdf")?.instruction, "Flag risky clauses")
        XCTAssertNil(ReviewRule.firstMatch(in: rules, path: home + "/Other/lease.pdf"))
        XCTAssertNil(ReviewRule.firstMatch(in: rules, path: "/tmp/notes.md"))
    }

    func testSessionStateRoundTrip() throws {
        let url = directory.appendingPathComponent("session.json")
        let state = SessionState(documents: [
            .init(path: "/a.csv", kind: "table", isActive: false),
            .init(path: "/b.pdf", kind: "pdf", isActive: true, isEdited: true, selection: "clause 4"),
        ], updatedAt: Date(timeIntervalSince1970: 1_700_000_000), appVersion: "1.0")
        try state.write(to: url)
        let loaded = try XCTUnwrap(SessionState.load(from: url))
        XCTAssertEqual(loaded, state)
        XCTAssertEqual(loaded.active?.path, "/b.pdf")
    }
}

final class UtilityTests: XCTestCase {
    func testGlob() {
        XCTAssertTrue(Glob("*.csv").matches("/a/b/report.csv"))
        XCTAssertFalse(Glob("*.csv").matches("/a/b/report.csv.bak"))
        XCTAssertTrue(Glob("/a/**/x.txt").matches("/a/x.txt"))
        XCTAssertTrue(Glob("/a/**/x.txt").matches("/a/b/c/x.txt"))
        XCTAssertFalse(Glob("/a/*/x.txt").matches("/a/b/c/x.txt"))
        XCTAssertTrue(Glob("report-{2025,2026}*.xlsx").matches("/q/report-2026-q1.xlsx"))
        XCTAssertFalse(Glob("report-{2025,2026}*.xlsx").matches("/q/report-2024.xlsx"))
        XCTAssertTrue(Glob("file?.[ct]sv").matches("/z/file1.tsv"))
        XCTAssertFalse(Glob("file[!0-9].txt").matches("/z/file1.txt"))
        XCTAssertTrue(Glob("~/Docs/*.pdf", homeDirectory: "/Users/me").matches("/Users/me/Docs/a.pdf"))
        XCTAssertTrue(Glob("a+b (1).txt").matches("/x/a+b (1).txt"))
        XCTAssertFalse(Glob("").matches("/x"))
    }

    func testHexDump() {
        let bytes: [UInt8] = Array("Hello, Handa!\u{0}\u{1}\u{7F}".utf8)
        XCTAssertEqual(HexDump.offset(0x1f0), "000001f0")
        XCTAssertEqual(HexDump.hex(bytes), "48 65 6c 6c 6f 2c 20 48  61 6e 64 61 21 00 01 7f")
        XCTAssertEqual(HexDump.ascii(bytes), "Hello, Handa!...")
        XCTAssertEqual(HexDump.rowCount(byteCount: 33), 3)
        XCTAssertEqual(HexDump.rowCount(byteCount: 0), 0)
    }

    func testStableHash() {
        XCTAssertEqual(StableHash.hex("hello"), StableHash.hex("hello"))
        XCTAssertNotEqual(StableHash.hex("hello"), StableHash.hex("hellO"))
        XCTAssertEqual(StableHash.hex(""), "cbf29ce484222325")
        XCTAssertEqual(StableHash.hex("a"), "af63dc4c8601ec8c")
    }

    func testFormatting() {
        XCTAssertEqual(Formatting.bytes(1), "1 byte")
        XCTAssertEqual(Formatting.bytes(512), "512 bytes")
        XCTAssertEqual(Formatting.bytes(1_500), "1.5 KB")
        XCTAssertEqual(Formatting.bytes(250_000_000), "250 MB")
        XCTAssertEqual(Formatting.count(1, "row"), "1 row")
        XCTAssertEqual(Formatting.count(1204, "row"), "1,204 rows")
    }

    func testCommandQuoting() {
        XCTAssertEqual(CommandRunner.shellQuote("it's"), "'it'\\''s'")
        XCTAssertEqual(CommandRunner.expand("tool {file} --ask {instruction}", file: "/a b/c.pdf", instruction: "Check it"),
                       "tool '/a b/c.pdf' --ask 'Check it'")
        let path = CommandRunner.searchPath(home: "/Users/me", existing: "/usr/bin:/custom")
        XCTAssertTrue(path.hasPrefix("/usr/bin:/custom:/Users/me/.local/bin"))
        XCTAssertEqual(path.components(separatedBy: ":").filter { $0 == "/usr/bin" }.count, 1)
    }

    func testCommandRunner() {
        let done = expectation(description: "command finished")
        CommandRunner.run("tr a-z A-Z; echo \"$HANDA_FILE\"", input: "review me\n", environment: ["HANDA_FILE": "x.txt"], shell: "/bin/sh") { result in
            XCTAssertEqual(try? result.get(), "REVIEW ME\nx.txt")
            done.fulfill()
        }
        let failed = expectation(description: "failing command reported")
        CommandRunner.run("echo oops >&2; exit 3", input: "", shell: "/bin/sh") { result in
            if case .failure(let error) = result {
                XCTAssertTrue(error.localizedDescription.contains("status 3"))
                XCTAssertTrue(error.localizedDescription.contains("oops"))
            } else {
                XCTFail("expected failure")
            }
            failed.fulfill()
        }
        let slow = expectation(description: "slow command stopped")
        CommandRunner.run("sleep 5; echo late", input: "", shell: "/bin/sh", timeout: 0.5) { result in
            if case .failure = result {} else { XCTFail("expected timeout") }
            slow.fulfill()
        }
        wait(for: [done, failed, slow], timeout: 10)
    }
}

final class AnthropicClientTests: XCTestCase {
    func testRequestShape() throws {
        let body = AnthropicClient.requestBody(model: "claude-opus-5", system: "sys", prompt: "hello")
        XCTAssertEqual(body["model"]?.string, "claude-opus-5")
        XCTAssertEqual(body["max_tokens"]?.int, 16000)
        XCTAssertEqual(body["fallbacks"]?.string, "default")
        XCTAssertEqual(body["messages"]?.array?.first?["role"]?.string, "user")
        let request = AnthropicClient.makeRequest(apiKey: "sk-test", body: body)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), AnthropicClient.fallbackBeta)
        XCTAssertEqual(request.httpMethod, "POST")

        let other = AnthropicClient.requestBody(model: "claude-haiku-4-5", system: "s", prompt: "p")
        XCTAssertNil(other["fallbacks"])
        XCTAssertNil(AnthropicClient.makeRequest(apiKey: "k", body: other).value(forHTTPHeaderField: "anthropic-beta"))
    }

    func testParseSuccessSkipsThinkingBlocks() throws {
        let data = Data(###"{"content":[{"type":"thinking","thinking":""},{"type":"text","text":"## Summary\nAll good."}],"stop_reason":"end_turn"}"###.utf8)
        XCTAssertEqual(try AnthropicClient.parseResponse(data, statusCode: 200), "## Summary\nAll good.")
    }

    func testParseRefusalAndErrors() {
        let refusal = Data(#"{"content":[],"stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber"}}"#.utf8)
        XCTAssertThrowsError(try AnthropicClient.parseResponse(refusal, statusCode: 200)) { error in
            XCTAssertEqual(error as? AnthropicClient.ReviewError, .refused(category: "cyber"))
        }
        let unauthorized = Data(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#.utf8)
        XCTAssertThrowsError(try AnthropicClient.parseResponse(unauthorized, statusCode: 401)) { error in
            XCTAssertEqual(error as? AnthropicClient.ReviewError, .api(status: 401, type: "authentication_error", message: "invalid x-api-key"))
        }
        XCTAssertThrowsError(try AnthropicClient.parseResponse(Data("<html>".utf8), statusCode: 200))
        let truncated = Data(#"{"content":[{"type":"text","text":"partial"}],"stop_reason":"max_tokens"}"#.utf8)
        XCTAssertTrue(try AnthropicClient.parseResponse(truncated, statusCode: 200).hasPrefix("partial"))
    }

    func testRefusesHugeDocumentsInsteadOfTruncating() {
        let done = expectation(description: "completion")
        let text = String(repeating: "a", count: AnthropicClient.maxDocumentCharacters + 1)
        AnthropicClient.review(apiKey: "k", model: "claude-opus-5", fileName: "big.txt", kind: "Text", text: text, instruction: "") { result in
            if case .failure(let error) = result, case .documentTooLarge = error as? AnthropicClient.ReviewError {} else { XCTFail("expected documentTooLarge") }
            done.fulfill()
        }
        let noKey = expectation(description: "missing key")
        AnthropicClient.review(apiKey: " ", model: "m", fileName: "a", kind: "b", text: "c", instruction: "") { result in
            if case .failure(let error) = result, case .missingAPIKey = error as? AnthropicClient.ReviewError {} else { XCTFail("expected missingAPIKey") }
            noKey.fulfill()
        }
        wait(for: [done, noKey], timeout: 2)
    }
}
