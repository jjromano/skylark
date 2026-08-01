import Testing
import Foundation
import SkylarkCore

/// The optional cleanup-cycle hotkey (PRD §7). The ring itself is pure logic —
/// what the presses land on, in what order, and what persists — so it is tested
/// here rather than through the controller.
@Suite("Cleanup cycle (optional hotkey)")
struct CleanupCycleTests {
    private let cloud: [ModelRegistryEntry] = [
        .init(slug: "meta-llama/llama-3.1-8b-instruct", label: "Llama 3.1 8B (Groq)", providerPin: "groq", kind: .cleanup, sort: 0),
        .init(slug: "openai/gpt-oss-20b", label: "GPT-OSS 20B (Groq)", providerPin: "groq", kind: .cleanup, sort: 1),
        // An stt row must never appear in a CLEANUP ring.
        .init(slug: "deepgram/nova-3", label: "Deepgram Nova-3", providerPin: nil, kind: .stt, sort: 3),
    ]

    private let qwen = LocalCleanupModel.qwen3_4BInstruct

    // MARK: - Ring composition

    @Test("Order: Auto → Raw → Apple → on-disk local models → cloud models")
    func order() {
        let options = CleanupCycle.options(localModels: [qwen], cloudModels: cloud, hasAPIKey: true)
        #expect(options.map(\.id) == [
            "auto",
            "raw",
            "local:apple",
            "local:llama:qwen3-4b-instruct",
            "cloud:meta-llama/llama-3.1-8b-instruct",
            "cloud:openai/gpt-oss-20b",
        ])
    }

    @Test("A local model that isn't on disk is not a stop on the ring")
    func onlyInstalledLocalModels() {
        let options = CleanupCycle.options(localModels: [], cloudModels: cloud, hasAPIKey: true)
        #expect(!options.contains { $0.id.hasPrefix("local:llama") })
        // Apple Intelligence needs no download, so it is always offered.
        #expect(options.contains { $0.id == "local:apple" })
    }

    @Test("No API key: the cloud models are left out (they could only degrade)")
    func cloudNeedsKey() {
        let options = CleanupCycle.options(localModels: [qwen], cloudModels: cloud, hasAPIKey: false)
        #expect(!options.contains { $0.id.hasPrefix("cloud:") })
        #expect(options.map(\.id) == ["auto", "raw", "local:apple", "local:llama:qwen3-4b-instruct"])
    }

    // MARK: - Advancing

    @Test("Each press advances one stop and the ring wraps")
    func advanceAndWrap() {
        let options = CleanupCycle.options(localModels: [], cloudModels: cloud, hasAPIKey: true)
        var current: CleanupCycleOption? = .auto
        var visited: [String] = []
        for _ in 0..<options.count {
            current = CleanupCycle.next(after: current, in: options)
            visited.append(current?.id ?? "nil")
        }
        // A full lap ends where it started: the hotkey can never strand the user.
        #expect(visited == [
            "raw",
            "local:apple",
            "cloud:meta-llama/llama-3.1-8b-instruct",
            "cloud:openai/gpt-oss-20b",
            "auto",
        ])
    }

    @Test("A selection that is not on the ring restarts from the first stop")
    func unknownCurrentRestarts() {
        let options = CleanupCycle.options(localModels: [], cloudModels: cloud, hasAPIKey: true)
        #expect(CleanupCycle.next(after: nil, in: options)?.id == "auto")
    }

    @Test("An empty ring advances to nothing (no crash, no change)")
    func emptyRing() {
        #expect(CleanupCycle.next(after: .raw, in: []) == nil)
    }

    // MARK: - Mapping live settings onto the ring

    @Test("Current stop is derived from the persisted tier + engine + slug")
    func currentFromState() {
        let options = CleanupCycle.options(localModels: [qwen], cloudModels: cloud, hasAPIKey: true)

        #expect(CleanupCycle.current(
            tierOverride: "auto", localEngine: .appleFoundationModels,
            cloudSlug: "openai/gpt-oss-20b", options: options)?.id == "auto")
        #expect(CleanupCycle.current(
            tierOverride: "raw", localEngine: .appleFoundationModels,
            cloudSlug: "openai/gpt-oss-20b", options: options)?.id == "raw")
        #expect(CleanupCycle.current(
            tierOverride: "local", localEngine: .llama(modelID: qwen.id),
            cloudSlug: "openai/gpt-oss-20b", options: options)?.id == "local:llama:qwen3-4b-instruct")
        #expect(CleanupCycle.current(
            tierOverride: "cloud", localEngine: .appleFoundationModels,
            cloudSlug: "openai/gpt-oss-20b", options: options)?.id == "cloud:openai/gpt-oss-20b")
    }

    @Test("Cloud tier with no key on the ring reads as 'not on the ring'")
    func currentOffRing() {
        let options = CleanupCycle.options(localModels: [], cloudModels: cloud, hasAPIKey: false)
        let current = CleanupCycle.current(
            tierOverride: "cloud", localEngine: .appleFoundationModels,
            cloudSlug: "openai/gpt-oss-20b", options: options)
        #expect(current == nil)
        // …so the next press lands on a stop that actually exists.
        #expect(CleanupCycle.next(after: current, in: options)?.id == "auto")
    }

    // MARK: - What each stop persists

    @Test("Every stop maps to the tier-override string the menus persist")
    func tierOverrides() {
        #expect(CleanupCycleOption.auto.tierOverride == "auto")
        #expect(CleanupCycleOption.raw.tierOverride == "raw")
        #expect(CleanupCycleOption.local(.appleFoundationModels).tierOverride == "local")
        #expect(CleanupCycleOption.local(.llama(modelID: qwen.id)).tierOverride == "local")
        #expect(CleanupCycleOption.cloud(slug: "x/y", label: "X").tierOverride == "cloud")
        // The local stop carries the engine value that is persisted verbatim.
        #expect(LocalCleanupEngine.llama(modelID: qwen.id).persistedValue == "llama:qwen3-4b-instruct")
    }

    @Test("Note labels name the choice the user just cycled to")
    func displayNames() {
        #expect(CleanupCycleOption.local(.llama(modelID: qwen.id)).displayName == "Qwen3 4B Instruct")
        #expect(CleanupCycleOption.local(.appleFoundationModels).displayName == "Apple Intelligence (local)")
        #expect(CleanupCycleOption.cloud(slug: "openai/gpt-oss-20b", label: "GPT-OSS 20B (Groq)").displayName
            == "GPT-OSS 20B (Groq)")
        #expect(CleanupCycleOption.raw.displayName == "Raw (no cleanup)")
    }

    // MARK: - Binding

    @Test("The cycle binding has its own defaults key and is UNBOUND by default")
    func bindingSlot() {
        #expect(HotkeyBinding.defaultsKeyCycleCleanup == "hotkey.cycleCleanup")
        #expect(HotkeyBinding.defaultsKeyCycleCleanup != HotkeyBinding.defaultsKeyKeyboard)
        #expect(HotkeyBinding.defaultsKeyCycleCleanup != HotkeyBinding.defaultsKeyCommand)
        #expect(HotkeyBinding.defaultsKeyCycleCleanup != HotkeyBinding.defaultsKeyMouse)

        // Default = unbound: an absent key must decode to no binding at all
        // (PRD §7 makes the cycle hotkey optional).
        let defaults = UserDefaults(suiteName: "cleanup-cycle-test-\(UUID().uuidString)")!
        let stored = defaults.string(forKey: HotkeyBinding.defaultsKeyCycleCleanup)
            .flatMap(HotkeyBinding.init(rawValue:))
        #expect(stored == nil)

        // And a captured binding round-trips through the same rawValue
        // serialization the other two slots use.
        for binding: HotkeyBinding in [
            .chord(modifiers: [.control, .option], keyCode: 8),
            .functionKey(107),
            .rightControl,
        ] {
            defaults.set(binding.rawValue, forKey: HotkeyBinding.defaultsKeyCycleCleanup)
            let restored = defaults.string(forKey: HotkeyBinding.defaultsKeyCycleCleanup)
                .flatMap(HotkeyBinding.init(rawValue:))
            #expect(restored == binding)
        }
    }

    @Test("Cycle keyDown matching: chords need an exact modifier match")
    func keyDownMatching() {
        let chord = HotkeyBinding.chord(modifiers: [.control, .option], keyCode: 8)
        let ctrlOpt: UInt64 = (1 << 18) | (1 << 19)
        let ctrlOptShift: UInt64 = ctrlOpt | (1 << 17)
        #expect(HotkeyMonitor.keyDownMatches(chord, keycode: 8, eventFlagsRawValue: ctrlOpt))
        // ⌃⌥⇧C is NOT ⌃⌥C — it must pass through as ordinary typing.
        #expect(!HotkeyMonitor.keyDownMatches(chord, keycode: 8, eventFlagsRawValue: ctrlOptShift))
        #expect(!HotkeyMonitor.keyDownMatches(chord, keycode: 9, eventFlagsRawValue: ctrlOpt))
        // F-keys match bare; modifier bindings never arrive as a keyDown.
        #expect(HotkeyMonitor.keyDownMatches(.functionKey(107), keycode: 107, eventFlagsRawValue: 0))
        #expect(!HotkeyMonitor.keyDownMatches(.rightControl, keycode: 62, eventFlagsRawValue: 0))
    }
}
