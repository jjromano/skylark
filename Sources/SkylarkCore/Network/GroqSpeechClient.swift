import Foundation
import os

/// Errors from the direct Groq speech path. Deliberately mirrors
/// `OpenRouterError`'s shape so the orchestrator's existing degrade handling
/// treats a Groq failure exactly like an OpenRouter one.
public enum GroqError: Error, Sendable, Equatable {
    case noKey
    case timeout
    case http(status: Int, message: String?)
    case decoding
    case network(String)
}

/// Direct client for Groq's OpenAI-compatible transcription endpoint.
///
/// WHY THIS EXISTS, and why it is not just another OpenRouter model row:
/// OpenRouter serves `whisper-large-v3-turbo` from more than one provider and
/// load-balances across them by price. Its transcription endpoint applies NO
/// per-request routing controls (`order`, `only`, `allow_fallbacks`, `sort` are
/// all ignored there, unlike on chat completions) and its response does not say
/// which provider ran. So through OpenRouter you cannot ask for the fast
/// provider and cannot tell which one you got, which is why cloud dictation
/// latency swings by seconds with no relation to clip length.
///
/// Talking to Groq directly fixes all three: one known provider, one less hop,
/// and the audio goes up as bytes in a multipart body instead of base64 inside
/// JSON (a third smaller, and not materialised twice in memory on the dictation
/// path).
///
/// Groq recommends 16 kHz mono, which is exactly what `AudioClip` already
/// carries, so no resampling happens here.
public struct GroqSpeechClient: Sendable {
    /// Groq's OpenAI-compatible base. Injectable for tests.
    public static let defaultBaseURL = URL(string: "https://api.groq.com")!

    private let keyProvider: @Sendable () -> String?
    private let session: URLSession
    private let baseURL: URL
    private let logger = Logger(subsystem: "com.jjromano.skylark", category: "network")

    public init(
        keyProvider: @escaping @Sendable () -> String?,
        session: URLSession = .shared,
        baseURL: URL = GroqSpeechClient.defaultBaseURL
    ) {
        self.keyProvider = keyProvider
        self.session = session
        self.baseURL = baseURL
    }

    /// Response shape. Groq returns OpenAI's `{"text": ...}`; `usage` is present
    /// on newer responses and ignored when absent.
    public struct Response: Sendable, Equatable, Decodable {
        public struct Usage: Sendable, Equatable, Decodable {
            public let seconds: Double?
        }
        public let text: String
        public let usage: Usage?
    }

    /// POST `/openai/v1/audio/transcriptions` as multipart/form-data.
    ///
    /// `boundary` is injectable purely so tests can assert an exact body; live
    /// callers take the random default.
    public func transcribe(
        audio: Data,
        filename: String,
        contentType: String,
        model: String,
        language: String?,
        boundary: String? = nil
    ) async throws -> Response {
        guard let key = keyProvider(), !key.isEmpty else { throw GroqError.noKey }

        var form = boundary.map { MultipartBody(boundary: $0) } ?? MultipartBody()
        form.addFile(name: "file", filename: filename, contentType: contentType, data: audio)
        form.addField(name: "model", value: model)
        // `json` (not `verbose_json`): we want the text and nothing else, and the
        // smaller response is one less thing to parse on the paste path.
        form.addField(name: "response_format", value: "json")
        // Deterministic decoding — a dictation app must not roll dice on words.
        form.addField(name: "temperature", value: "0")
        if let language, !language.isEmpty {
            form.addField(name: "language", value: language)
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("/openai/v1/audio/transcriptions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = form.finalized()

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            throw urlError.code == .timedOut ? GroqError.timeout : GroqError.network(urlError.localizedDescription)
        } catch {
            throw GroqError.network(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            // Never log the body: an error response can echo request content.
            logger.notice("groq transcription failed: HTTP \(http.statusCode, privacy: .public)")
            throw GroqError.http(status: http.statusCode, message: Self.errorMessage(data))
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw GroqError.decoding
        }
    }

    /// Cheap key check: GET the OpenAI-compatible models list. Costs nothing and
    /// transcribes nothing, so the Settings card can confirm a key without
    /// uploading audio. Throws the same `GroqError` cases as `transcribe`.
    public func validateKey() async throws {
        guard let key = keyProvider(), !key.isEmpty else { throw GroqError.noKey }
        var request = URLRequest(url: baseURL.appendingPathComponent("/openai/v1/models"))
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            throw urlError.code == .timedOut ? GroqError.timeout : GroqError.network(urlError.localizedDescription)
        } catch {
            throw GroqError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw GroqError.decoding }
        guard (200..<300).contains(http.statusCode) else {
            throw GroqError.http(status: http.statusCode, message: Self.errorMessage(data))
        }
    }

    /// Pull `error.message` out of an OpenAI-style error body, for a status note.
    /// Returns nil rather than raw body text so nothing unexpected is surfaced.
    static func errorMessage(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any],
              let message = error["message"] as? String
        else { return nil }
        return message.count > 120 ? String(message.prefix(117)) + "…" : message
    }
}
