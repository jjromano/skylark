import Foundation

/// ChatML prompt assembly for the Qwen family (Qwen2.5 / Qwen3), hand-built
/// rather than run through llama.cpp's chat-template machinery.
///
/// Why hand-built: the interesting knob is Qwen3's `enable_thinking` flag, which
/// only exists in the model's *Jinja* template. The C API's
/// `llama_chat_apply_template` is the legacy non-Jinja path and cannot set it, so
/// we emit the exact token sequence Qwen3's own template produces for
/// `enable_thinking=false` — an assistant turn pre-filled with an EMPTY
/// `<think></think>` block. With the thinking block already closed, the model
/// continues with the answer instead of reasoning, which is the difference
/// between ~0.6 s and ~10 s per cleanup.
///
/// Pure and deterministic so the whole prompt contract is unit-testable without
/// a model on disk.
public enum LlamaChatML {
    /// ChatML control tokens.
    static let imStart = "<|im_start|>"
    static let imEnd = "<|im_end|>"
    static let endOfText = "<|endoftext|>"

    /// Strings that terminate generation. `<|im_end|>` is an end-of-generation
    /// token so llama.cpp normally stops on its own; these are the belt-and-
    /// braces literal forms for a GGUF whose EOG metadata is wrong.
    public static let stopStrings = [imEnd, endOfText, "\(imStart)user", "\(imStart)system"]

    /// Qwen3's `/no_think` soft switch is deliberately NOT used. It exists for
    /// callers who cannot control the template; we build the template ourselves,
    /// so the pre-filled empty think block below already conveys
    /// `enable_thinking=false`. Measured on the smoke model, injecting `/no_think`
    /// into the user turn made a 1.5 B model treat the switch as content and echo
    /// it ("/think") instead of cleaning the transcript — a prompt perturbation
    /// with no upside.

    public struct Message: Sendable, Equatable {
        public enum Role: String, Sendable { case system, user, assistant }
        public let role: Role
        public let content: String

        public init(role: Role, content: String) {
            self.role = role
            self.content = content
        }
    }

    /// Render `messages` as a ChatML prompt and open the assistant turn.
    ///
    /// - Parameter suppressThinking: when true, pre-fills the opened assistant
    ///   turn with an empty `<think></think>` block — byte-for-byte what Qwen3's
    ///   own template emits for `enable_thinking=false`. Pass false for models
    ///   with no thinking mode (the `-Instruct-2507` releases, Qwen2.5): the block
    ///   is out-of-distribution for them and measurably degrades the output.
    public static func prompt(messages: [Message], suppressThinking: Bool) -> String {
        var text = ""
        for message in messages {
            text += "\(imStart)\(message.role.rawValue)\n\(message.content)\(imEnd)\n"
        }
        text += "\(imStart)assistant\n"
        if suppressThinking {
            text += "<think>\n\n</think>\n\n"
        }
        return text
    }

    /// The system-only prefix of `prompt(messages:suppressThinking:)` — the part
    /// that is byte-identical between dictations with the same settings. Warming
    /// this into the KV cache makes the per-utterance prefill only cover the
    /// transcript (see `LlamaRunner.warm`).
    public static func systemPrefix(instructions: String) -> String {
        "\(imStart)system\n\(instructions)\(imEnd)\n"
    }
}
