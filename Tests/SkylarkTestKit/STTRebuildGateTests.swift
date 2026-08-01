import Testing
import SkylarkCore

/// The staleness guard around speech-engine rebuilds (`AppController`'s
/// `rebuildTranscriber` chain). The rebuild itself needs the whole app object
/// graph, so the decision logic it depends on is exercised directly here.
///
/// The bug this guards: selecting a cloud engine kicks off an off-main keychain
/// read (unbounded — an authorization prompt holds it open), switching back to
/// local completes a local rebuild, and then the older cloud completion lands on
/// top and installs a cloud-primary transcriber while the menu reads "Local".
/// The next dictation uploads audio.
@Suite("STT rebuild gate")
struct STTRebuildGateTests {
    /// The exact race: cloud starts, local starts and would install; the cloud
    /// completion must be refused at BOTH checkpoints (construct and install).
    @Test("A cloud rebuild superseded by a local one never installs")
    func supersededCloudRebuildIsDropped() {
        var gate = STTRebuildGate()
        let cloud = gate.begin(.cloud(slug: "openai/whisper-1"))
        let local = gate.begin(.localParakeet)

        #expect(gate.isCurrent(cloud, selection: .localParakeet) == false)
        #expect(gate.isCurrent(local, selection: .localParakeet))
        // Re-checking is stable: the same answer before construction and again
        // before installation.
        #expect(gate.isCurrent(cloud, selection: .localParakeet) == false)
        #expect(gate.isCurrent(local, selection: .localParakeet))
    }

    /// A rebuild that is still the newest keeps ownership across as many checks
    /// as its async path needs (keychain read → warm-up → idle wait → install).
    @Test("The newest rebuild stays current across repeated checks")
    func newestRebuildStaysCurrent() {
        var gate = STTRebuildGate()
        let token = gate.begin(.localWhisper)
        for _ in 0..<5 {
            #expect(gate.isCurrent(token, selection: .localWhisper))
        }
    }

    /// The live selection is checked independently of the counter: if the user's
    /// choice moved on, a rebuild must not install even though no newer rebuild
    /// has started yet (selection is what the menu shows).
    @Test("A selection change alone invalidates an in-flight rebuild")
    func selectionChangeInvalidates() {
        var gate = STTRebuildGate()
        let token = gate.begin(.cloud(slug: "openai/whisper-1"))
        #expect(gate.isCurrent(token, selection: .cloud(slug: "openai/whisper-1")))
        #expect(gate.isCurrent(token, selection: .localApple) == false)
    }

    /// Cloud → cloud counts as a change too: a different slug is a different
    /// provider/model, and the older completion must not win.
    @Test("Switching cloud slugs supersedes the earlier cloud rebuild")
    func cloudSlugChangeSupersedes() {
        var gate = STTRebuildGate()
        let first = gate.begin(.cloud(slug: "openai/whisper-1"))
        let second = gate.begin(.cloud(slug: "openai/gpt-4o-transcribe"))
        #expect(gate.isCurrent(first, selection: .cloud(slug: "openai/gpt-4o-transcribe")) == false)
        #expect(gate.isCurrent(second, selection: .cloud(slug: "openai/gpt-4o-transcribe")))
    }

    /// The keyless-cloud path installs a LOCAL engine under the cloud token
    /// (cloud is still what's selected) — that must remain a valid install.
    @Test("A cloud token stays current while cloud is still selected")
    func keylessCloudFallbackKeepsToken() {
        var gate = STTRebuildGate()
        let token = gate.begin(.cloud(slug: "openai/whisper-1"))
        #expect(gate.isCurrent(token, selection: .cloud(slug: "openai/whisper-1")))
    }
}
