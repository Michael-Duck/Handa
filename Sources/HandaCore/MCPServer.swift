import Foundation

/// The result of a tool call, in MCP's content format.
public struct MCPToolResult: Equatable, Sendable {
    public var content: [JSON]
    public var isError: Bool

    public init(content: [JSON], isError: Bool = false) {
        self.content = content
        self.isError = isError
    }

    public static func text(_ text: String) -> MCPToolResult {
        MCPToolResult(content: [["type": "text", "text": .string(text)]])
    }

    public static func error(_ text: String) -> MCPToolResult {
        MCPToolResult(content: [["type": "text", "text": .string(text)]], isError: true)
    }

    var json: JSON { ["content": .array(content), "isError": .bool(isError)] }
}

public struct MCPTool {
    public var name: String
    public var title: String
    public var description: String
    public var inputSchema: JSON
    public var readOnly: Bool
    public var handler: (JSON) throws -> MCPToolResult

    public init(name: String, title: String, description: String, inputSchema: JSON, readOnly: Bool = true,
                handler: @escaping (JSON) throws -> MCPToolResult) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.readOnly = readOnly
        self.handler = handler
    }

    var listing: JSON {
        ["name": .string(name), "title": .string(title), "description": .string(description), "inputSchema": inputSchema,
         "annotations": ["title": .string(title), "readOnlyHint": .bool(readOnly), "openWorldHint": false]]
    }
}

public struct MCPPrompt {
    public struct Argument {
        public var name: String
        public var description: String
        public var required: Bool
        public init(name: String, description: String, required: Bool = false) {
            self.name = name
            self.description = description
            self.required = required
        }
    }

    public var name: String
    public var title: String
    public var description: String
    public var arguments: [Argument]
    /// Returns the prompt text for the given arguments.
    public var handler: ([String: String]) throws -> String

    public init(name: String, title: String, description: String, arguments: [Argument] = [],
                handler: @escaping ([String: String]) throws -> String) {
        self.name = name
        self.title = title
        self.description = description
        self.arguments = arguments
        self.handler = handler
    }

    var listing: JSON {
        ["name": .string(name), "title": .string(title), "description": .string(description),
         "arguments": .array(arguments.map { ["name": .string($0.name), "description": .string($0.description), "required": .bool($0.required)] })]
    }
}

/// A Model Context Protocol server speaking JSON-RPC 2.0 over newline-delimited stdio.
/// Transport-free: `handle(_:)` maps one message to its response, which keeps it easy to test.
public final class MCPServer {
    public static let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    public enum ErrorCode: Int {
        case parseError = -32700
        case invalidRequest = -32600
        case methodNotFound = -32601
        case invalidParams = -32602
        case internalError = -32603
    }

    public let name: String
    public let title: String
    public let version: String
    public let instructions: String?
    public private(set) var tools: [MCPTool]
    public private(set) var prompts: [MCPPrompt]
    public private(set) var negotiatedProtocolVersion: String?
    public private(set) var clientName: String?

    public init(name: String, title: String, version: String, instructions: String? = nil,
                tools: [MCPTool] = [], prompts: [MCPPrompt] = []) {
        self.name = name
        self.title = title
        self.version = version
        self.instructions = instructions
        self.tools = tools
        self.prompts = prompts
    }

    /// Handles one line of input and returns the line to write back, if any.
    public func handleLine(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let message: JSON
        do {
            message = try JSON.parse(trimmed)
        } catch {
            return MCPServer.errorResponse(id: .null, code: .parseError, message: "Parse error: \(error)").serialized()
        }
        if case .array(let batch) = message {
            guard !batch.isEmpty else {
                return MCPServer.errorResponse(id: .null, code: .invalidRequest, message: "Empty batch").serialized()
            }
            let responses = batch.compactMap { handle($0) }
            return responses.isEmpty ? nil : JSON.array(responses).serialized()
        }
        return handle(message)?.serialized()
    }

    /// Handles a single JSON-RPC message. Returns nil for notifications and stray responses.
    public func handle(_ message: JSON) -> JSON? {
        guard case .object(let object) = message else {
            return MCPServer.errorResponse(id: .null, code: .invalidRequest, message: "Expected a JSON object")
        }
        let id = object["id"]
        guard let method = object["method"]?.string else {
            // A response to a request we never send, or garbage.
            if id != nil, object["result"] != nil || object["error"] != nil { return nil }
            return MCPServer.errorResponse(id: id ?? .null, code: .invalidRequest, message: "Missing method")
        }
        let params = object["params"] ?? .object([:])
        guard let requestID = id, !requestID.isNull else {
            return nil // Notification: never answered.
        }
        switch requestID {
        case .string, .number: break
        default: return MCPServer.errorResponse(id: .null, code: .invalidRequest, message: "Invalid id")
        }

        do {
            let result = try dispatch(method: method, params: params)
            return ["jsonrpc": "2.0", "id": requestID, "result": result]
        } catch let failure as RPCError {
            return MCPServer.errorResponse(id: requestID, code: failure.code, message: failure.message)
        } catch {
            return MCPServer.errorResponse(id: requestID, code: .internalError, message: "\(error)")
        }
    }

    struct RPCError: Error {
        let code: ErrorCode
        let message: String
    }

    private func dispatch(method: String, params: JSON) throws -> JSON {
        switch method {
        case "initialize":
            let requested = params["protocolVersion"]?.string ?? MCPServer.supportedProtocolVersions[0]
            let version = MCPServer.supportedProtocolVersions.contains(requested) ? requested : MCPServer.supportedProtocolVersions[0]
            negotiatedProtocolVersion = version
            clientName = params["clientInfo"]?["name"]?.string
            var capabilities: [String: JSON] = [:]
            if !tools.isEmpty { capabilities["tools"] = ["listChanged": false] }
            if !prompts.isEmpty { capabilities["prompts"] = ["listChanged": false] }
            var result: [String: JSON] = [
                "protocolVersion": .string(version),
                "capabilities": .object(capabilities),
                "serverInfo": ["name": .string(name), "title": .string(title), "version": .string(self.version)],
            ]
            if let instructions = instructions { result["instructions"] = .string(instructions) }
            return .object(result)
        case "ping":
            return .object([:])
        case "tools/list":
            return ["tools": .array(tools.map(\.listing))]
        case "tools/call":
            guard let toolName = params["name"]?.string else { throw RPCError(code: .invalidParams, message: "Missing tool name") }
            guard let tool = tools.first(where: { $0.name == toolName }) else {
                throw RPCError(code: .invalidParams, message: "Unknown tool: \(toolName)")
            }
            let arguments = params["arguments"] ?? .object([:])
            guard arguments.object != nil else { throw RPCError(code: .invalidParams, message: "Arguments must be an object") }
            do {
                return try tool.handler(arguments).json
            } catch {
                return MCPToolResult.error("\(error)").json
            }
        case "prompts/list":
            return ["prompts": .array(prompts.map(\.listing))]
        case "prompts/get":
            guard let promptName = params["name"]?.string else { throw RPCError(code: .invalidParams, message: "Missing prompt name") }
            guard let prompt = prompts.first(where: { $0.name == promptName }) else {
                throw RPCError(code: .invalidParams, message: "Unknown prompt: \(promptName)")
            }
            var arguments: [String: String] = [:]
            for (key, value) in params["arguments"]?.object ?? [:] {
                arguments[key] = value.string ?? value.serialized()
            }
            for argument in prompt.arguments where argument.required && arguments[argument.name] == nil {
                throw RPCError(code: .invalidParams, message: "Missing required argument: \(argument.name)")
            }
            let text = try prompt.handler(arguments)
            return ["description": .string(prompt.description),
                    "messages": [["role": "user", "content": ["type": "text", "text": .string(text)]]]]
        case "resources/list":
            return ["resources": []]
        case "resources/templates/list":
            return ["resourceTemplates": []]
        default:
            throw RPCError(code: .methodNotFound, message: "Method not found: \(method)")
        }
    }

    static func errorResponse(id: JSON, code: ErrorCode, message: String) -> JSON {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code.rawValue)), "message": .string(message)]]
    }

    /// Reads requests from `input` until end of file, writing responses to `output`.
    public func run(input: FileHandle = .standardInput, output: FileHandle = .standardOutput) {
        var buffer = Data()
        while true {
            let chunk = input.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                let line = String(decoding: lineData, as: UTF8.self)
                if let response = handleLine(line) {
                    output.write(Data((response + "\n").utf8))
                }
            }
        }
        if !buffer.isEmpty, let response = handleLine(String(decoding: buffer, as: UTF8.self)) {
            output.write(Data((response + "\n").utf8))
        }
    }
}
