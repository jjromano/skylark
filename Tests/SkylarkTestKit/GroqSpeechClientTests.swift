import Testing
import Foundation
@testable import SkylarkCore

/// URLProtocol stub so the multipart request is inspected byte-for-byte without
/// a network (or a key, or spend).
final class GroqStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var capturedBody: Data?
    nonisolated(unsafe) static var capturedHeaders: [String: String] = [:]
    nonisolated(unsafe) static var capturedURL: URL?
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var responseBody = Data(#"{"text":"hello there"}"#.utf8)

    static func reset() {
        capturedBody = nil
        capturedHeaders = [:]
        capturedURL = nil
        status = 200
        responseBody = Data(#"{"text":"hello there"}"#.utf8)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedURL = request.url
        Self.capturedHeaders = request.allHTTPHeaderFields ?? [:]
        // `httpBody` is nil once URLSession has streamed it; read the stream.
        if let body = request.httpBody {
            Self.capturedBody = body
        } else if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            stream.close()
            Self.capturedBody = data
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("GroqSpeechClient", .serialized)
struct GroqSpeechClientTests {
    private func makeClient(key: String? = "gsk_test") -> GroqSpeechClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GroqStubProtocol.self]
        return GroqSpeechClient(
            keyProvider: { key },
            session: URLSession(configuration: config)
        )
    }

    @Test("No key fails before any request is made")
    func noKeyThrows() async {
        GroqStubProtocol.reset()
        do {
            _ = try await makeClient(key: nil).transcribe(
                audio: Data([1, 2, 3]), filename: "a.wav", contentType: "audio/wav",
                model: "whisper-large-v3-turbo", language: "en"
            )
            Issue.record("expected noKey")
        } catch {
            #expect(error as? GroqError == .noKey)
            #expect(GroqStubProtocol.capturedURL == nil, "must not hit the network without a key")
        }
    }

    @Test("Posts multipart to Groq's OpenAI-compatible path with the audio as raw bytes")
    func multipartShape() async throws {
        GroqStubProtocol.reset()
        // A byte that is NOT valid UTF-8, to prove the audio travels as binary
        // rather than being base64'd or string-coerced anywhere.
        let audio = Data([0xFF, 0x00, 0x52, 0x49, 0x46, 0x46, 0xD8])
        let text = try await makeClient().transcribe(
            audio: audio, filename: "audio.wav", contentType: "audio/wav",
            model: "whisper-large-v3-turbo", language: "en", boundary: "BOUND"
        ).text
        #expect(text == "hello there")

        #expect(GroqStubProtocol.capturedURL?.absoluteString
            == "https://api.groq.com/openai/v1/audio/transcriptions")
        #expect(GroqStubProtocol.capturedHeaders["Authorization"] == "Bearer gsk_test")
        #expect(GroqStubProtocol.capturedHeaders["Content-Type"]
            == "multipart/form-data; boundary=BOUND")

        let body = try #require(GroqStubProtocol.capturedBody)
        // The raw audio bytes appear verbatim in the body.
        #expect(body.range(of: audio) != nil, "audio must be sent as bytes, not base64")
        let ascii = String(decoding: body, as: UTF8.self)
        #expect(ascii.contains(#"name="file"; filename="audio.wav""#))
        #expect(ascii.contains("whisper-large-v3-turbo"))
        #expect(ascii.contains("--BOUND--"), "body must be closed with the terminating boundary")
        // Deterministic decoding: a dictation app must not roll dice on words.
        #expect(ascii.contains("temperature"))
        #expect(ascii.contains("\r\n0\r\n"))
    }

    @Test("Omits the language field entirely when none is given")
    func omitsEmptyLanguage() async throws {
        GroqStubProtocol.reset()
        _ = try await makeClient().transcribe(
            audio: Data([1]), filename: "a.wav", contentType: "audio/wav",
            model: "whisper-large-v3-turbo", language: nil, boundary: "B"
        )
        let ascii = String(decoding: try #require(GroqStubProtocol.capturedBody), as: UTF8.self)
        #expect(!ascii.contains(#"name="language""#))
    }

    @Test("An API error surfaces its status and message, never the raw body")
    func httpErrorSurfacesMessage() async {
        GroqStubProtocol.reset()
        GroqStubProtocol.status = 401
        GroqStubProtocol.responseBody = Data(#"{"error":{"message":"Invalid API Key"}}"#.utf8)
        do {
            _ = try await makeClient().transcribe(
                audio: Data([1]), filename: "a.wav", contentType: "audio/wav",
                model: "m", language: nil
            )
            Issue.record("expected an http error")
        } catch {
            #expect(error as? GroqError == .http(status: 401, message: "Invalid API Key"))
        }
    }

    @Test("A non-JSON body is a decoding failure, not a crash or a bogus transcript")
    func garbageBodyDecodes() async {
        GroqStubProtocol.reset()
        GroqStubProtocol.responseBody = Data("not json".utf8)
        do {
            _ = try await makeClient().transcribe(
                audio: Data([1]), filename: "a.wav", contentType: "audio/wav",
                model: "m", language: nil
            )
            Issue.record("expected decoding failure")
        } catch {
            #expect(error as? GroqError == .decoding)
        }
    }
}

@Suite("MultipartBody")
struct MultipartBodyTests {
    @Test("Field and file parts are framed exactly as multipart/form-data requires")
    func exactFraming() {
        var form = MultipartBody(boundary: "X")
        form.addField(name: "model", value: "m1")
        form.addFile(name: "file", filename: "a.wav", contentType: "audio/wav", data: Data([0xAA]))
        let body = form.finalized()
        let ascii = String(decoding: body, as: UTF8.self)
        #expect(form.contentType == "multipart/form-data; boundary=X")
        #expect(ascii.hasPrefix("--X\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nm1\r\n"))
        #expect(ascii.contains("Content-Type: audio/wav\r\n\r\n"))
        #expect(ascii.hasSuffix("--X--\r\n"))
        #expect(body.range(of: Data([0xAA])) != nil)
    }

    @Test("Binary that is not valid UTF-8 survives intact")
    func binarySafe() {
        var form = MultipartBody(boundary: "X")
        let payload = Data([0xFF, 0xFE, 0x00, 0x80])
        form.addFile(name: "file", filename: "a.bin", contentType: "application/octet-stream", data: payload)
        #expect(form.finalized().range(of: payload) != nil)
    }
}
