import Foundation

/// Error taxonomy for OpenRouter requests (phase-3 spec). Never carries
/// request/response bodies — those may contain transcript content.
public enum OpenRouterError: Error, Sendable {
    case noKey
    case invalidKey
    case rateLimited
    case timeout
    case network(any Error)
    case server(status: Int, message: String)
    case decoding
    /// The model hit its token cap mid-answer (`finish_reason == "length"`) — the
    /// returned text is truncated, so callers should treat it as a failure (e.g.
    /// cleanup degrades to local) rather than use a half-answer.
    case responseTruncated
}

/// One chat message for `/api/v1/chat/completions`.
public struct ChatMessage: Sendable, Equatable {
    public enum Role: String, Sendable, Equatable {
        case system
        case user
        case assistant
    }

    public let role: Role
    public let content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

/// Response shape for `/api/v1/audio/transcriptions`.
public struct TranscriptionResponse: Sendable, Equatable, Decodable {
    public struct Usage: Sendable, Equatable, Decodable {
        public let cost: Double?
    }

    public let text: String
    public let usage: Usage?
}

/// Response shape for `/api/v1/key`.
public struct KeyInfo: Sendable, Equatable {
    public let label: String?
    public let limit: Double?
    public let limitRemaining: Double?
    public let usage: Double?
}

/// Thin client over the OpenRouter HTTP API (facts verified against live API +
/// docs, ARCHITECTURE §6). `URLSession` is injectable so tests can stub
/// requests with `URLProtocol`.
public struct OpenRouterClient: Sendable {
    private let keyProvider: @Sendable () -> String?
    private let session: URLSession
    private let baseURL: URL

    public init(
        keyProvider: @escaping @Sendable () -> String?,
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://openrouter.ai")!
    ) {
        self.keyProvider = keyProvider
        self.session = session
        self.baseURL = baseURL
    }

    // MARK: - Transcription

    /// POST `/api/v1/audio/transcriptions`. 60 s request timeout.
    public func transcribe(
        audio: Data,
        format: String,
        model: String,
        language: String?
    ) async throws -> TranscriptionResponse {
        var request = try makeRequest(path: "/api/v1/audio/transcriptions")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let inputAudio: [String: Any] = ["data": audio.base64EncodedString(), "format": format]
        var body: [String: Any] = ["model": model, "input_audio": inputAudio]
        if let language {
            body["language"] = language
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await send(request)
        try Self.validate(response: response, data: data)
        do {
            return try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        } catch {
            throw OpenRouterError.decoding
        }
    }

    // MARK: - Chat completion

    /// POST `/api/v1/chat/completions`. Streams via SSE when `stream == true`
    /// (`data:` lines, ignore `:`-prefixed keep-alives, terminate on
    /// `[DONE]`); otherwise yields the full text once.
    public func complete(
        messages: [ChatMessage],
        model: String,
        providerPin: String?,
        stream: Bool,
        temperature: Double?,
        maxTokens: Int?
    ) async throws -> AsyncThrowingStream<String, Error> {
        var request = try makeRequest(path: "/api/v1/chat/completions")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "model": model,
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] },
            "stream": stream,
        ]
        if let providerPin {
            body["provider"] = ["order": [providerPin], "allow_fallbacks": true]
        }
        if let temperature {
            body["temperature"] = temperature
        }
        if let maxTokens {
            body["max_tokens"] = maxTokens
        }
        if model.hasPrefix("openai/gpt-oss") {
            // gpt-oss models are reasoning models; default effort inflates
            // time-to-first-answer-token ~5x (4.88s vs 0.85s measured on Groq
            // gpt-oss-120b). Force low effort for latency.
            body["reasoning"] = ["effort": "low"]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        if stream {
            return try await streamCompletion(request)
        }

        let (data, response) = try await send(request)
        try Self.validate(response: response, data: data)
        let text = try Self.extractNonStreamingContent(from: data)
        return AsyncThrowingStream { continuation in
            continuation.yield(text)
            continuation.finish()
        }
    }

    private func streamCompletion(_ request: URLRequest) async throws -> AsyncThrowingStream<String, Error> {
        let (bytes, response) = try await sendBytes(request)

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            var collected = Data()
            for try await byte in bytes {
                collected.append(byte)
            }
            try Self.validate(response: response, data: collected)
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        if line.hasPrefix(":") { continue } // keep-alive comment
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let payloadData = payload.data(using: .utf8) else { continue }
                        if let message = Self.extractMidStreamError(from: payloadData) {
                            continuation.finish(throwing: OpenRouterError.server(status: 0, message: message))
                            return
                        }
                        if let delta = Self.extractDelta(from: payloadData) {
                            continuation.yield(delta)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Key validation

    /// GET `/api/v1/key`. Maps `data.{label,limit,limit_remaining,usage}`.
    public func validateKey() async throws -> KeyInfo {
        let request = try makeRequest(path: "/api/v1/key", method: "GET")
        let (data, response) = try await send(request)

        if let http = response as? HTTPURLResponse, http.statusCode == 401 {
            throw OpenRouterError.invalidKey
        }
        try Self.validate(response: response, data: data)

        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let info = object["data"] as? [String: Any]
        else {
            throw OpenRouterError.decoding
        }
        return KeyInfo(
            label: info["label"] as? String,
            limit: info["limit"] as? Double,
            limitRemaining: info["limit_remaining"] as? Double,
            usage: info["usage"] as? Double
        )
    }

    // MARK: - Request plumbing

    private func makeRequest(path: String, method: String = "POST") throws -> URLRequest {
        guard let key = keyProvider(), !key.isEmpty else { throw OpenRouterError.noKey }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 60
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("https://github.com/jjromano/skylark", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("Skylark", forHTTPHeaderField: "X-OpenRouter-Title")
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let urlError as URLError {
            throw urlError.code == .timedOut ? OpenRouterError.timeout : OpenRouterError.network(urlError)
        } catch {
            throw OpenRouterError.network(error)
        }
    }

    private func sendBytes(_ request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        do {
            return try await session.bytes(for: request)
        } catch let urlError as URLError {
            throw urlError.code == .timedOut ? OpenRouterError.timeout : OpenRouterError.network(urlError)
        } catch {
            throw OpenRouterError.network(error)
        }
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200..<300:
            return
        case 401:
            throw OpenRouterError.invalidKey
        case 429:
            throw OpenRouterError.rateLimited
        default:
            let message = extractErrorMessage(from: data) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw OpenRouterError.server(status: http.statusCode, message: message)
        }
    }

    private static func extractErrorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        return nil
    }

    private static func extractMidStreamError(from data: Data) -> String? {
        extractErrorMessage(from: data)
    }

    private static func extractDelta(from data: Data) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = object["choices"] as? [[String: Any]],
            let first = choices.first,
            let delta = first["delta"] as? [String: Any],
            let content = delta["content"] as? String
        else { return nil }
        return content
    }

    private static func extractNonStreamingContent(from data: Data) throws -> String {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = object["choices"] as? [[String: Any]],
            let first = choices.first,
            let message = first["message"] as? [String: Any],
            let content = message["content"] as? String
        else {
            throw OpenRouterError.decoding
        }
        // A "length" finish means the generation was cut at the token cap — the
        // content is a truncated fragment (the reasoning-model "first few words
        // only" bug). Surface it as an error so cleanup degrades to local instead
        // of pasting half an answer.
        if first["finish_reason"] as? String == "length" {
            throw OpenRouterError.responseTruncated
        }
        return content
    }
}
