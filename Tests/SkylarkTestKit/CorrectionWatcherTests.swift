import ApplicationServices
import Foundation
import Testing
import SkylarkCore

// MARK: - Test doubles

/// Clock that never actually sleeps, so poll schedules run instantly.
private struct ImmediateClock: WatchClock {
    func sleep(for duration: Duration) async -> Bool { true }
}

/// Clock whose sleep reports "cancelled" (false) on the Nth call onward.
private actor CancelAfterClock: WatchClock {
    private let cancelAt: Int
    private var calls = 0
    init(cancelAt: Int) { self.cancelAt = cancelAt }
    func sleep(for duration: Duration) async -> Bool {
        calls += 1
        return calls < cancelAt
    }
}

/// Reader that replays a scripted sequence of readbacks and counts its calls.
private actor ScriptedReader: CorrectionFieldReading {
    private var scripted: [CorrectionReadback]
    private var calls = 0
    init(_ scripted: [CorrectionReadback]) { self.scripted = scripted }
    func readback(_ watch: CorrectionWatch) async -> CorrectionReadback {
        calls += 1
        guard !scripted.isEmpty else { return .invalid }
        return scripted.removeFirst()
    }
    func callCount() -> Int { calls }
}

/// Collects every learned entry.
private actor LearnBox {
    private var entries: [DictionaryEntry] = []
    func add(_ entry: DictionaryEntry) { entries.append(entry) }
    func all() -> [DictionaryEntry] { entries }
    func count() -> Int { entries.count }
    func phrases() -> [String] { entries.map(\.phrase) }
}

private func makeWatch(finalText: String) -> CorrectionWatch {
    // The scripted reader ignores the token/anchor; only `finalText` is diffed.
    let token = InsertionToken(method: .ax(AXUIElementCreateSystemWide()), text: finalText, pasteUncertain: false)
    return CorrectionWatch(token: token, finalText: finalText, anchorLocation: 0)
}

private func makeWatcher(
    reader: any CorrectionFieldReading,
    clock: any WatchClock,
    box: LearnBox,
    entries: [DictionaryEntry] = [],
    isCommonWord: @escaping @Sendable (String) -> Bool = { _ in false },
    schedule: [Duration] = [.zero, .zero],
    maxPerUtterance: Int = 2
) -> CorrectionWatcher {
    CorrectionWatcher(
        reader: reader,
        clock: clock,
        dictionary: InMemoryDictionaryProvider(entries: entries),
        isCommonWord: isCommonWord,
        learn: { await box.add($0) },
        schedule: schedule,
        maxPerUtterance: maxPerUtterance
    )
}

// MARK: - Filter matrix

@Suite("Correction auto-learn filter")
struct CorrectionFilterTests {
    /// Deterministic common-word oracle for the matrix.
    private let common: Set<String> = ["their", "real", "time", "open", "page", "the", "skylark"]
    private func isCommon(_ w: String) -> Bool { common.contains(w.lowercased()) }

    @Test("Common English word target is rejected")
    func rejectCommonWord() {
        let out = CorrectionWatcher.candidates(
            finalText: "i saw thier cat", currentText: "i saw their cat",
            entries: [], isCommonWord: isCommon
        )
        #expect(out.isEmpty)
    }

    @Test("Distinctive (unknown) word is accepted")
    func acceptDistinctive() {
        let out = CorrectionWatcher.candidates(
            finalText: "push to gitub now", currentText: "push to github now",
            entries: [], isCommonWord: isCommon
        )
        #expect(out.count == 1)
        #expect(out.first?.phrase == "github")
        #expect(out.first?.misspellings == ["gitub"])
        #expect(out.first?.source == .autoCorrection)
    }

    @Test("Proper-noun respelling of a common word (tiny edit) is accepted")
    func acceptProperNounTinyEdit() {
        // "skylark" is common (a bird), but "Skylark" leading-capital + Levenshtein 1.
        let out = CorrectionWatcher.candidates(
            finalText: "meet at skylarc", currentText: "meet at Skylark",
            entries: [], isCommonWord: isCommon
        )
        #expect(out.first?.phrase == "Skylark")
        #expect(out.first?.misspellings == ["skylarc"])
    }

    @Test("Pure case change is rejected (CorrectionDiff filters it)")
    func rejectCaseOnly() {
        let out = CorrectionWatcher.candidates(
            finalText: "open github page", currentText: "open GitHub page",
            entries: [], isCommonWord: isCommon
        )
        #expect(out.isEmpty)
    }

    @Test("Pair already in the dictionary is rejected")
    func rejectAlreadyKnown() {
        let known = [DictionaryEntry(phrase: "GitHub", misspellings: ["gitub"], source: .manual)]
        let out = CorrectionWatcher.candidates(
            finalText: "push to gitub", currentText: "push to github",
            entries: known, isCommonWord: isCommon
        )
        #expect(out.isEmpty)
    }

    @Test("At most two pairs are learned per utterance")
    func perUtteranceCap() {
        // Three distinct single-token substitutions, separated by stable words.
        let out = CorrectionWatcher.candidates(
            finalText: "foo x bar y baz", currentText: "fooby x barby y bazby",
            entries: [], isCommonWord: isCommon, maxPerUtterance: 2
        )
        #expect(out.count == 2)
    }

    @Test("No edit yields no candidates")
    func noEdit() {
        let out = CorrectionWatcher.candidates(
            finalText: "push to github", currentText: "push to github",
            entries: [], isCommonWord: isCommon
        )
        #expect(out.isEmpty)
    }
}

// MARK: - Secure / excluded targets

@Suite("Correction target guards")
struct CorrectionTargetTests {
    @Test("Secure text field subrole is detected")
    func secureSubrole() {
        #expect(CorrectionTarget.isSecureSubrole("AXSecureTextField"))
        #expect(!CorrectionTarget.isSecureSubrole("AXTextArea"))
        #expect(!CorrectionTarget.isSecureSubrole(nil))
    }

    @Test("Password-manager bundle ids are excluded")
    func excludedApps() {
        #expect(CorrectionTarget.isExcludedApp("com.1password.mac"))
        #expect(CorrectionTarget.isExcludedApp("com.agilebits.onepassword7"))
        #expect(CorrectionTarget.isExcludedApp("com.bitwarden.desktop"))
        #expect(!CorrectionTarget.isExcludedApp("com.apple.Safari"))
        #expect(!CorrectionTarget.isExcludedApp(nil))
    }
}

// MARK: - Watcher lifecycle

@Suite("CorrectionWatcher lifecycle")
struct CorrectionWatcherLifecycleTests {
    @Test("Re-reads at both polls; learns a correction that appears at the second")
    func firesAtBothPolls() async {
        let box = LearnBox()
        let reader = ScriptedReader([.text("push to gitub"), .text("push to github")])
        let watcher = makeWatcher(reader: reader, clock: ImmediateClock(), box: box)

        await watcher.run(makeWatch(finalText: "push to gitub"))

        await #expect(reader.callCount() == 2)
        await #expect(box.count() == 1)
        await #expect(box.phrases() == ["github"])
    }

    @Test("Stops immediately when the target becomes invalid")
    func stopsOnInvalid() async {
        let box = LearnBox()
        let reader = ScriptedReader([.invalid, .text("push to github")])
        let watcher = makeWatcher(reader: reader, clock: ImmediateClock(), box: box)

        await watcher.run(makeWatch(finalText: "push to gitub"))

        // Only the first poll happened; the second never ran.
        await #expect(reader.callCount() == 1)
        await #expect(box.count() == 0)
    }

    @Test("Stops once the per-utterance cap is reached — no further polls")
    func stopsAtCap() async {
        let box = LearnBox()
        // First poll already yields three corrections; cap is 2.
        let reader = ScriptedReader([.text("fooby x barby y bazby"), .text("more zzz changes")])
        let watcher = makeWatcher(reader: reader, clock: ImmediateClock(), box: box)

        await watcher.run(makeWatch(finalText: "foo x bar y baz"))

        await #expect(box.count() == 2)
        await #expect(reader.callCount() == 1) // cap hit at poll 1, poll 2 skipped
    }

    @Test("A cancelled sleep stops the watcher")
    func stopsOnCancel() async {
        let box = LearnBox()
        let reader = ScriptedReader([.text("push to github")])
        let watcher = makeWatcher(reader: reader, clock: CancelAfterClock(cancelAt: 1), box: box)

        await watcher.run(makeWatch(finalText: "push to gitub"))

        // The first sleep reports cancelled, so no readback ever happens.
        await #expect(reader.callCount() == 0)
        await #expect(box.count() == 0)
    }

    @Test("Words already in the store are not re-learned")
    func skipsKnownFromStore() async {
        let box = LearnBox()
        let reader = ScriptedReader([.text("push to github")])
        let known = [DictionaryEntry(phrase: "GitHub", misspellings: ["gitub"], source: .manual)]
        let watcher = makeWatcher(reader: reader, clock: ImmediateClock(), box: box, entries: known)

        await watcher.run(makeWatch(finalText: "push to gitub"))

        await #expect(box.count() == 0)
    }
}

// MARK: - Common-word checker

@Suite("SystemCommonWordChecker")
struct SystemCommonWordCheckerTests {
    @Test("Reads the word list; case-insensitive; multi-word needs all tokens")
    func readsWordList() throws {
        let path = NSTemporaryDirectory() + "skylark-words-\(UUID().uuidString).txt"
        try "Apple\nreal\ntime\nlark\n".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let checker = SystemCommonWordChecker(path: path)
        #expect(checker.isCommonWord("apple"))
        #expect(checker.isCommonWord("REAL"))
        #expect(checker.isCommonWord("real time"))   // both tokens present
        #expect(!checker.isCommonWord("real skylark")) // one token absent
        #expect(!checker.isCommonWord("skylark"))
        #expect(!checker.isCommonWord(""))
    }

    @Test("A missing word list reports everything as not-common")
    func missingFile() {
        let checker = SystemCommonWordChecker(path: "/nonexistent/\(UUID().uuidString)")
        #expect(!checker.isCommonWord("apple"))
    }
}

// MARK: - Setting serialization

@Suite("Correction learning setting")
struct CorrectionLearningSettingTests {
    // Mirrors AppController.learnFromCorrectionsKey (the executable target isn't
    // importable here); this pins the persisted contract: default OFF, round-trips.
    private let key = "dictionary.learnFromCorrections"

    @Test("Defaults to OFF and round-trips through UserDefaults")
    func serializes() {
        let defaults = UserDefaults(suiteName: "skylark.test.\(UUID().uuidString)")!
        #expect(defaults.bool(forKey: key) == false) // default OFF
        defaults.set(true, forKey: key)
        #expect(defaults.bool(forKey: key) == true)
        defaults.set(false, forKey: key)
        #expect(defaults.bool(forKey: key) == false)
    }
}
