import Foundation
import SkylarkCore
import Testing

/// The picker availability matrix. Every combination a real install can be in
/// is listed here, so "the menu offered an engine I cannot use" is a failing
/// test rather than a QA finding.
@Suite("Speech engine picker availability")
struct SpeechEngineOptionsTests {
    private let cloud: [ModelRegistryEntry] = [
        .init(slug: "microsoft/mai-transcribe-2", label: "MAI Transcribe 2", providerPin: nil, kind: .stt, sort: 0),
        .init(slug: "openai/gpt-oss-20b", label: "GPT-OSS 20B", providerPin: "groq", kind: .cleanup, sort: 0),
    ]

    private func options(
        current: STTChoice = .localParakeet,
        parakeet: Bool = true, whisper: Bool = true, apple: Bool = true,
        groqKey: Bool, openRouterKey: Bool
    ) -> SpeechEngineOptions {
        SpeechEngineOptions(
            current: current,
            parakeetAvailable: parakeet, whisperAvailable: whisper, appleSpeechAvailable: apple,
            hasGroqKey: groqKey, hasOpenRouterKey: openRouterKey, cloudModels: cloud
        )
    }

    @Test("No keys: no cloud engines, one add-OpenRouter-key prompt, Groq absent")
    func noKeys() {
        let o = options(groqKey: false, openRouterKey: false)
        #expect(o.openRouter.isEmpty)
        #expect(o.needsOpenRouterKey)
        #expect(!o.groqDirect)
    }

    @Test("OpenRouter key only: STT models offered, cleanup rows never leak in, Groq absent")
    func openRouterOnly() {
        let o = options(groqKey: false, openRouterKey: true)
        #expect(o.openRouter.map(\.slug) == ["microsoft/mai-transcribe-2"])
        #expect(!o.needsOpenRouterKey)
        #expect(!o.groqDirect)
    }

    @Test("Groq key only: Groq direct offered, OpenRouter still asks for its key")
    func groqOnly() {
        let o = options(groqKey: true, openRouterKey: false)
        #expect(o.groqDirect)
        #expect(o.openRouter.isEmpty)
        #expect(o.needsOpenRouterKey)
    }

    @Test("Both keys: everything cloud is offered")
    func bothKeys() {
        let o = options(groqKey: true, openRouterKey: true)
        #expect(o.groqDirect)
        #expect(!o.openRouter.isEmpty)
        #expect(!o.needsOpenRouterKey)
    }

    @Test("Undownloaded on-device engines are hidden")
    func undownloadedHidden() {
        let o = options(whisper: false, apple: false, groqKey: false, openRouterKey: false)
        #expect(o.onDevice == [.localParakeet])
    }

    @Test("Selected Groq direct stays listed after its key is removed")
    func currentGroqListed() {
        let o = options(current: .groqDirect, groqKey: false, openRouterKey: false)
        #expect(o.groqDirect)
    }

    @Test("The current engine stays listed even when unavailable, so the checkmark never vanishes")
    func currentAlwaysListed() {
        let o = options(current: .localWhisper, whisper: false, groqKey: false, openRouterKey: false)
        #expect(o.onDevice.contains(.localWhisper))
    }
}
