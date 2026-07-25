import Testing
import Foundation
import SkylarkCore

/// Intercepts requests made against a per-test unique `baseURL` (host is a
/// fresh UUID each call) and answers with a canned response, recording the
/// outgoing request/body for assertions. State is keyed by host and guarded
/// by a lock rather than kept in one shared global — swift-testing runs
/// `@Test`s concurrently by default, and a single shared handler/lastRequest
/// slot lets tests stomp on each other's stubbed responses.
final class OpenRouterStubURLProtocol: URLProtocol, @unchecked Sendable {
    struct StubResponse: Sendable {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: @Sendable (URLRequest) -> StubResponse] = [:]
    nonisolated(unsafe) private static var lastRequests: [String: URLRequest] = [:]
    nonisolated(unsafe) private static var lastBodies: [String: Data] = [:]

    /// Registers a handler for `host` and returns a fresh session that routes
    /// through this protocol. Call `unregister(host:)` when the test is done.
    static func makeSession(host: String, handler: @escaping @Sendable (URLRequest) -> StubResponse) -> URLSession {
        lock.lock()
        handlers[host] = handler
        lastRequests[host] = nil
        lastBodies[host] = nil
        lock.unlock()

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OpenRouterStubURLProtocol.self]
        return URLSession(configuration: config)
    }

    static func unregister(host: String) {
        lock.lock()
        handlers[host] = nil
        lastRequests[host] = nil
        lastBodies[host] = nil
        lock.unlock()
    }

    static func lastRequest(host: String) -> URLRequest? {
        lock.lock(); defer { lock.unlock() }
        return lastRequests[host]
    }

    static func lastRequestBody(host: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return lastBodies[host]
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        lock.lock(); defer { lock.unlock() }
        return handlers[host] != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let host = request.url?.host else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        Self.lock.lock()
        let handler = Self.handlers[host]
        Self.lastRequests[host] = request
        Self.lastBodies[host] = Self.bodyData(from: request)
        Self.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let stub = handler(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.status,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

@Suite("OpenRouterClient (URLProtocol-stubbed)")
struct OpenRouterClientTests {
    /// Builds a client + stubbed session pair wired to a host unique to this
    /// call, so concurrent tests never share stub state.
    private func withStubbedClient(
        _ handler: @escaping @Sendable (URLRequest) -> OpenRouterStubURLProtocol.StubResponse,
        _ body: (OpenRouterClient, String) async throws -> Void
    ) async throws {
        let host = "stub-\(UUID().uuidString).test"
        let session = OpenRouterStubURLProtocol.makeSession(host: host, handler: handler)
        defer { OpenRouterStubURLProtocol.unregister(host: host) }

        let client = OpenRouterClient(
            keyProvider: { "test-key" },
            session: session,
            baseURL: URL(string: "https://\(host)")!
        )
        try await body(client, host)
    }

    // MARK: - Transcription request shape

    @Test("transcribe() sends model, base64 audio, format, and language in the JSON body")
    func transcribeRequestShape() async throws {
        try await withStubbedClient({ _ in
            .init(status: 200, headers: ["Content-Type": "application/json"],
                  body: Data(#"{"text":"hello world","usage":{"cost":0.0001}}"#.utf8))
        }) { client, host in
            let audio = Data([0x01, 0x02, 0x03, 0x04])
            let response = try await client.transcribe(
                audio: audio, format: "wav", model: "openai/whisper-large-v3-turbo", language: "en"
            )

            #expect(response.text == "hello world")
            #expect(response.usage?.cost == 0.0001)

            let request = try #require(OpenRouterStubURLProtocol.lastRequest(host: host))
            #expect(request.url?.path == "/api/v1/audio/transcriptions")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
            #expect(request.value(forHTTPHeaderField: "X-OpenRouter-Title") == "Skylark")

            let bodyData = try #require(OpenRouterStubURLProtocol.lastRequestBody(host: host))
            let json = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
            #expect(json["model"] as? String == "openai/whisper-large-v3-turbo")
            #expect(json["language"] as? String == "en")
            let inputAudio = try #require(json["input_audio"] as? [String: Any])
            #expect(inputAudio["format"] as? String == "wav")
            #expect(inputAudio["data"] as? String == audio.base64EncodedString())
        }
    }

    // MARK: - Provider pin

    @Test("complete() with a provider pin sends provider.order + allow_fallbacks")
    func completeProviderPin() async throws {
        try await withStubbedClient({ _ in
            .init(status: 200, headers: [:], body: Data("data: [DONE]\n".utf8))
        }) { client, host in
            _ = try await client.complete(
                messages: [ChatMessage(role: .user, content: "hi")],
                model: "meta-llama/llama-3.1-8b-instruct",
                providerPin: "groq",
                stream: true,
                temperature: 0.1,
                maxTokens: 100
            )

            let bodyData = try #require(OpenRouterStubURLProtocol.lastRequestBody(host: host))
            let json = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
            let provider = try #require(json["provider"] as? [String: Any])
            #expect((provider["order"] as? [String]) == ["groq"])
            #expect(provider["allow_fallbacks"] as? Bool == true)
            #expect(json["temperature"] as? Double == 0.1)
            #expect(json["max_tokens"] as? Int == 100)
        }
    }

    // MARK: - Truncation guard (non-streaming)

    @Test("complete() throws responseTruncated when finish_reason is length")
    func completeRejectsLengthTruncation() async throws {
        try await withStubbedClient({ _ in
            .init(status: 200, headers: ["Content-Type": "application/json"],
                  body: Data(#"{"choices":[{"finish_reason":"length","message":{"content":"the first few"}}]}"#.utf8))
        }) { client, _ in
            await #expect(throws: OpenRouterError.self) {
                _ = try await client.complete(
                    messages: [ChatMessage(role: .user, content: "clean this")],
                    model: "openai/gpt-oss-20b", providerPin: "groq",
                    stream: false, temperature: 0.1, maxTokens: 64
                )
            }
        }
    }

    @Test("complete() returns full content when finish_reason is stop")
    func completeReturnsWhenComplete() async throws {
        try await withStubbedClient({ _ in
            .init(status: 200, headers: ["Content-Type": "application/json"],
                  body: Data(#"{"choices":[{"finish_reason":"stop","message":{"content":"Clean sentence."}}]}"#.utf8))
        }) { client, _ in
            let stream = try await client.complete(
                messages: [ChatMessage(role: .user, content: "clean this")],
                model: "openai/gpt-oss-20b", providerPin: "groq",
                stream: false, temperature: 0.1, maxTokens: 1024
            )
            var collected = ""
            for try await chunk in stream { collected += chunk }
            #expect(collected == "Clean sentence.")
        }
    }

    // MARK: - Reasoning effort (gpt-oss)

    @Test("complete() sends reasoning: {effort: low} for gpt-oss model slugs")
    func completeGptOssReasoningEffort() async throws {
        try await withStubbedClient({ _ in
            .init(status: 200, headers: [:], body: Data("data: [DONE]\n".utf8))
        }) { client, host in
            _ = try await client.complete(
                messages: [ChatMessage(role: .user, content: "hi")],
                model: "openai/gpt-oss-20b",
                providerPin: "groq",
                stream: true,
                temperature: nil,
                maxTokens: nil
            )

            let bodyData = try #require(OpenRouterStubURLProtocol.lastRequestBody(host: host))
            let json = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
            let reasoning = try #require(json["reasoning"] as? [String: Any])
            #expect(reasoning["effort"] as? String == "low")
        }
    }

    @Test("complete() omits reasoning field for non-gpt-oss model slugs")
    func completeNonGptOssOmitsReasoningEffort() async throws {
        try await withStubbedClient({ _ in
            .init(status: 200, headers: [:], body: Data("data: [DONE]\n".utf8))
        }) { client, host in
            _ = try await client.complete(
                messages: [ChatMessage(role: .user, content: "hi")],
                model: "meta-llama/llama-3.1-8b-instruct",
                providerPin: "groq",
                stream: true,
                temperature: nil,
                maxTokens: nil
            )

            let bodyData = try #require(OpenRouterStubURLProtocol.lastRequestBody(host: host))
            let json = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
            #expect(json["reasoning"] == nil)
        }
    }

    // MARK: - SSE streaming

    @Test("complete() streaming parses chunks, ignores keep-alive comments, and stops at [DONE]")
    func completeStreamParsesChunks() async throws {
        let sse = """
        data: {"choices":[{"delta":{"content":"Hello"}}]}
        : OPENROUTER PROCESSING
        data: {"choices":[{"delta":{"content":" world"}}]}
        data: [DONE]
        data: {"choices":[{"delta":{"content":"should not appear"}}]}
        """
        try await withStubbedClient({ _ in
            .init(status: 200, headers: ["Content-Type": "text/event-stream"], body: Data(sse.utf8))
        }) { client, _ in
            let stream = try await client.complete(
                messages: [ChatMessage(role: .user, content: "hi")],
                model: "m", providerPin: nil, stream: true, temperature: nil, maxTokens: nil
            )
            var chunks: [String] = []
            for try await chunk in stream { chunks.append(chunk) }
            #expect(chunks == ["Hello", " world"])
        }
    }

    @Test("complete() streaming surfaces a mid-stream SSE error event and stops")
    func completeMidStreamError() async throws {
        let sse = """
        data: {"choices":[{"delta":{"content":"partial"}}]}
        data: {"error":{"message":"rate limited mid-stream"}}
        data: {"choices":[{"delta":{"content":"never seen"}}]}
        """
        try await withStubbedClient({ _ in
            .init(status: 200, headers: [:], body: Data(sse.utf8))
        }) { client, _ in
            let stream = try await client.complete(
                messages: [ChatMessage(role: .user, content: "hi")],
                model: "m", providerPin: nil, stream: true, temperature: nil, maxTokens: nil
            )

            var received: [String] = []
            var thrown: Error?
            do {
                for try await chunk in stream { received.append(chunk) }
            } catch {
                thrown = error
            }
            #expect(received == ["partial"])
            guard case .server(_, let message) = thrown as? OpenRouterError else {
                Issue.record("expected OpenRouterError.server, got \(String(describing: thrown))")
                return
            }
            #expect(message == "rate limited mid-stream")
        }
    }

    @Test("complete() non-streaming returns the full message content as a single yield")
    func completeNonStreaming() async throws {
        try await withStubbedClient({ _ in
            .init(status: 200, headers: [:], body: Data(#"{"choices":[{"message":{"content":"full reply"}}]}"#.utf8))
        }) { client, _ in
            let stream = try await client.complete(
                messages: [ChatMessage(role: .user, content: "hi")],
                model: "m", providerPin: nil, stream: false, temperature: nil, maxTokens: nil
            )
            var chunks: [String] = []
            for try await chunk in stream { chunks.append(chunk) }
            #expect(chunks == ["full reply"])
        }
    }

    // MARK: - Key validation

    @Test("validateKey() 200 maps data fields into KeyInfo")
    func validateKeySuccess() async throws {
        try await withStubbedClient({ _ in
            .init(status: 200, headers: [:],
                  body: Data(#"{"data":{"label":"test","limit":10.0,"limit_remaining":9.5,"usage":0.5}}"#.utf8))
        }) { client, _ in
            let info = try await client.validateKey()
            #expect(info.label == "test")
            #expect(info.limit == 10.0)
            #expect(info.limitRemaining == 9.5)
            #expect(info.usage == 0.5)
        }
    }

    @Test("validateKey() 401 throws invalidKey")
    func validateKeyUnauthorized() async throws {
        try await withStubbedClient({ _ in
            .init(status: 401, headers: [:], body: Data("{}".utf8))
        }) { client, _ in
            do {
                _ = try await client.validateKey()
                Issue.record("expected invalidKey to be thrown")
            } catch OpenRouterError.invalidKey {
                // expected
            }
        }
    }

    @Test("A nil key throws noKey before any request is sent")
    func noKeyThrowsBeforeRequest() async throws {
        let host = "stub-\(UUID().uuidString).test"
        let session = OpenRouterStubURLProtocol.makeSession(host: host) { _ in
            .init(status: 200, headers: [:], body: Data())
        }
        defer { OpenRouterStubURLProtocol.unregister(host: host) }

        let client = OpenRouterClient(keyProvider: { nil }, session: session, baseURL: URL(string: "https://\(host)")!)
        do {
            _ = try await client.validateKey()
            Issue.record("expected noKey to be thrown")
        } catch OpenRouterError.noKey {
            // expected
        }
        #expect(OpenRouterStubURLProtocol.lastRequest(host: host) == nil)
    }
}
