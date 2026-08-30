import Foundation

/// Minimal `multipart/form-data` builder for OpenAI-compatible file upload
/// endpoints (Groq's `/openai/v1/audio/transcriptions`).
///
/// Exists because the alternative — base64-ing the audio into a JSON body, which
/// is how the OpenRouter path sends it — inflates the payload by a third and
/// materialises the whole clip twice in memory (once as `Data`, once as a
/// base64 `String`) on the dictation path. Multipart sends the bytes as bytes.
///
/// Pure and deterministic: the boundary is injected, never generated internally,
/// so the produced body is byte-for-byte assertable in tests.
public struct MultipartBody: Sendable {
    public let boundary: String
    private var body = Data()

    public init(boundary: String = "skylark-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    /// `Content-Type` header value naming this body's boundary.
    public var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    /// Append a plain text field. Values are written verbatim; callers pass
    /// short API parameters (a model id, a locale), never user content.
    public mutating func addField(name: String, value: String) {
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        body.append(value)
        body.append("\r\n")
    }

    /// Append a binary file part.
    public mutating func addFile(
        name: String, filename: String, contentType: String, data: Data
    ) {
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        body.append("Content-Type: \(contentType)\r\n\r\n")
        body.append(data)
        body.append("\r\n")
    }

    /// The finished body, with the closing boundary. Call once.
    public func finalized() -> Data {
        var out = body
        out.append("--\(boundary)--\r\n")
        return out
    }
}

private extension Data {
    /// Append ASCII/UTF-8 scaffolding. Force-unwrap is safe: `String.utf8`
    /// encoding cannot fail.
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}
