import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A minimal Claude Messages API client used for document reviews. Swift has no official
/// Anthropic SDK, so this talks to the REST endpoint directly.
public enum AnthropicClient {
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let apiVersion = "2023-06-01"
    public static let defaultModel = "claude-opus-5"
    /// Beta that lets the API retry a declined request on Anthropic's recommended fallback model.
    public static let fallbackBeta = "server-side-fallback-2026-07-01"
    /// Roughly 400k tokens of text. Larger documents are refused up front instead of being cut short.
    public static let maxDocumentCharacters = 1_500_000

    public enum ReviewError: Error, LocalizedError, Equatable {
        case missingAPIKey
        case documentTooLarge(characters: Int)
        case api(status: Int, type: String, message: String)
        case refused(category: String?)
        case emptyResponse
        case malformedResponse

        public var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "Add your Claude API key in Handa → Settings → AI."
            case .documentTooLarge(let characters):
                return "This file has \(Formatting.count(characters, "character")) of text, which is more than one review can take. Try reviewing a smaller part of it."
            case .api(let status, let type, let message):
                switch status {
                case 401: return "Claude didn't accept the API key (\(message)). Check it in Settings → AI."
                case 429: return "Claude is rate limiting requests right now. Try again in a minute."
                case 529, 503: return "Claude is busy right now. Try again shortly."
                default: return "Claude returned an error (\(status) \(type)): \(message)"
                }
            case .refused(let category):
                return "Claude declined to review this file" + (category.map { " (\($0))" } ?? "") + "."
            case .emptyResponse:
                return "Claude returned an empty review."
            case .malformedResponse:
                return "Claude's response couldn't be read."
            }
        }
    }

    static let fallbackModels: Set<String> = ["claude-opus-5", "claude-opus-5-5", "claude-fable-5", "claude-fable-5-1"]

    public static func requestBody(model: String, system: String, prompt: String, maxTokens: Int = 16000,
                                   useFallbacks: Bool = true) -> JSON {
        var body: [String: JSON] = [
            "model": .string(model),
            "max_tokens": .number(Double(maxTokens)),
            "system": .string(system),
            "messages": [["role": "user", "content": .string(prompt)]],
        ]
        if useFallbacks, fallbackModels.contains(model) { body["fallbacks"] = "default" }
        return .object(body)
    }

    public static func makeRequest(apiKey: String, body: JSON) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        if body["fallbacks"] != nil { request.setValue(fallbackBeta, forHTTPHeaderField: "anthropic-beta") }
        request.httpBody = body.data
        return request
    }

    /// Pulls the review text out of a Messages API response, or explains what went wrong.
    public static func parseResponse(_ data: Data, statusCode: Int) throws -> String {
        let json = try? JSON.parse(data)
        guard (200..<300).contains(statusCode) else {
            let type = json?["error"]?["type"]?.string ?? "error"
            let message = json?["error"]?["message"]?.string ?? String(decoding: data.prefix(300), as: UTF8.self)
            throw ReviewError.api(status: statusCode, type: type, message: message)
        }
        guard let json = json else { throw ReviewError.malformedResponse }
        if json["stop_reason"]?.string == "refusal" {
            throw ReviewError.refused(category: json["stop_details"]?["category"]?.string)
        }
        let text = (json["content"]?.array ?? [])
            .filter { $0["type"]?.string == "text" }
            .compactMap { $0["text"]?.string }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ReviewError.emptyResponse }
        if json["stop_reason"]?.string == "max_tokens" {
            return text + "\n\n*(The review was cut off at the length limit.)*"
        }
        return text
    }

    public static let reviewSystemPrompt = """
    You review files for someone using Handa, a document viewer on their Mac. \
    Reply in Markdown. Start with a two or three sentence summary of what the file is and whether anything needs attention. \
    Then list the concrete problems or suggestions you found, most important first, each pointing at where it is \
    (page, heading, row and column, or a short quote). Prefer specific, checkable observations over general advice. \
    If the file looks fine, say so plainly instead of inventing issues.
    """

    public static func reviewPrompt(fileName: String, kind: String, text: String, instruction: String) -> String {
        """
        <document name="\(fileName)" kind="\(kind)">
        \(text)
        </document>

        \(instruction.isEmpty ? "Review this file." : instruction)
        """
    }

    /// Sends a review request. The completion runs on an arbitrary queue.
    @discardableResult
    public static func review(apiKey: String, model: String, fileName: String, kind: String, text: String,
                              instruction: String, session: URLSession = .shared,
                              completion: @escaping (Result<String, Error>) -> Void) -> URLSessionDataTask? {
        guard !apiKey.trimmingCharacters(in: .whitespaces).isEmpty else {
            completion(.failure(ReviewError.missingAPIKey))
            return nil
        }
        guard text.count <= maxDocumentCharacters else {
            completion(.failure(ReviewError.documentTooLarge(characters: text.count)))
            return nil
        }
        let prompt = reviewPrompt(fileName: fileName, kind: kind, text: text, instruction: instruction)
        return send(apiKey: apiKey, model: model, prompt: prompt, useFallbacks: true, session: session, completion: completion)
    }

    private static func send(apiKey: String, model: String, prompt: String, useFallbacks: Bool, session: URLSession,
                             completion: @escaping (Result<String, Error>) -> Void) -> URLSessionDataTask {
        let body = requestBody(model: model, system: reviewSystemPrompt, prompt: prompt, useFallbacks: useFallbacks)
        let task = session.dataTask(with: makeRequest(apiKey: apiKey, body: body)) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            do {
                completion(.success(try parseResponse(data ?? Data(), statusCode: status)))
            } catch ReviewError.api(let status, _, let message)
                        where status == 400 && body["fallbacks"] != nil && message.lowercased().contains("fallback") {
                // An account or model without access to fallbacks: ask again without them.
                send(apiKey: apiKey, model: model, prompt: prompt, useFallbacks: false, session: session, completion: completion)
            } catch {
                completion(.failure(error))
            }
        }
        task.resume()
        return task
    }
}
