import Foundation

// Auto-learn dictionary from corrections (PRD §8 / Wispr-Flow-style, adapted
// local-first). After Skylark injects a transcript into an AX-verified field,
// this watcher re-reads that field a couple of times over the following seconds.
// If the user fixed a word Skylark misheard (a misspelled name/term), the
// (from→to) pair is added to the custom dictionary. Opt-in, default OFF.
//
// This file is the pure, fully-testable engine: the 2-poll schedule (injectable
// clock), the conservative filter, and the diff windowing. The Accessibility
// re-read lives behind `CorrectionFieldReading`, implemented over AX in
// `AXCorrectionFieldReader`. Privacy: only the learned word pair ever leaves
// this actor; the field text read back is never logged or persisted.

/// A settled AX insertion to watch: the exact text we believe currently occupies
/// the inserted range (`finalText`, post-cleanup) plus the AX token and the
/// UTF-16 location where that text begins (captured at settle time, when the
/// caret sits collapsed at its end).
public struct CorrectionWatch: Sendable {
    public let token: InsertionToken
    public let finalText: String
    public let anchorLocation: Int

    public init(token: InsertionToken, finalText: String, anchorLocation: Int) {
        self.token = token
        self.finalText = finalText
        self.anchorLocation = anchorLocation
    }
}

/// The result of re-reading a watched insertion's on-screen text.
public enum CorrectionReadback: Sendable, Equatable {
    /// The current text occupying the watched region.
    case text(String)
    /// The target can no longer be read safely: focus moved, the element became
    /// invalid, or it turned into a secure field. Watching stops.
    case invalid
}

/// Re-reads the on-screen text of a watched insertion. Implemented over AX in
/// the Injection layer; faked in tests so the watcher logic stays pure.
public protocol CorrectionFieldReading: Sendable {
    func readback(_ watch: CorrectionWatch) async -> CorrectionReadback
}

/// Injectable clock for the 2-poll schedule. Returns `false` when the sleep was
/// cancelled (the watcher then stops).
public protocol WatchClock: Sendable {
    func sleep(for duration: Duration) async -> Bool
}

/// Live clock backed by `Task.sleep`.
public struct RealWatchClock: WatchClock {
    public init() {}
    public func sleep(for duration: Duration) async -> Bool {
        do {
            try await Task.sleep(for: duration)
            return true
        } catch {
            return false
        }
    }
}

/// Predicates for skipping targets we must never watch (privacy invariant §5):
/// secure/password fields and known password-manager apps. Pure so they're unit
/// testable without AX.
public enum CorrectionTarget {
    /// Bundle-id prefixes of password managers — never watched.
    public static let excludedBundlePrefixes = [
        "com.agilebits",        // 1Password (legacy)
        "com.1password",        // 1Password 8
        "com.bitwarden",        // Bitwarden
        "com.callpod.keeper",   // Keeper
        "com.keepersecurity",   // Keeper
        "com.lastpass",         // LastPass
        "com.dashlane",         // Dashlane
    ]

    public static func isExcludedApp(_ bundleID: String?) -> Bool {
        guard let bundleID = bundleID?.lowercased() else { return false }
        return excludedBundlePrefixes.contains { bundleID.hasPrefix($0) }
    }

    /// The AX subrole macOS gives password fields.
    public static let secureTextFieldSubrole = "AXSecureTextField"

    public static func isSecureSubrole(_ subrole: String?) -> Bool {
        subrole == secureTextFieldSubrole
    }
}

/// Bounded, detached watcher that turns in-place user corrections into
/// dictionary entries. Owns no per-session state that outlives a `run`.
public actor CorrectionWatcher {
    private let reader: any CorrectionFieldReading
    private let clock: any WatchClock
    private let dictionary: any DictionaryProviding
    private let isCommonWord: @Sendable (String) -> Bool
    private let learn: @Sendable (DictionaryEntry) async -> Void
    private let schedule: [Duration]
    private let maxPerUtterance: Int

    /// - Parameters:
    ///   - schedule: delays *between* successive polls. Default re-reads at
    ///     ~+8 s and ~+25 s (8 then 17 more), then stops.
    ///   - maxPerUtterance: cap on learned pairs per settled insertion (2).
    public init(
        reader: any CorrectionFieldReading,
        clock: any WatchClock = RealWatchClock(),
        dictionary: any DictionaryProviding,
        isCommonWord: @escaping @Sendable (String) -> Bool,
        learn: @escaping @Sendable (DictionaryEntry) async -> Void,
        schedule: [Duration] = [.seconds(8), .seconds(17)],
        maxPerUtterance: Int = 2
    ) {
        self.reader = reader
        self.clock = clock
        self.dictionary = dictionary
        self.isCommonWord = isCommonWord
        self.learn = learn
        self.schedule = schedule
        self.maxPerUtterance = maxPerUtterance
    }

    /// Fire-and-forget entry point: schedules the bounded poll loop on a detached
    /// lowest-priority task so nothing touches the audio/paste path.
    public nonisolated func start(_ watch: CorrectionWatch) {
        Task.detached(priority: .background) { [self] in
            await run(watch)
        }
    }

    /// The bounded poll loop. Public so tests can await it deterministically with
    /// a fake clock. Stops early on cancellation, an invalid target, or once the
    /// per-utterance cap is reached.
    public func run(_ watch: CorrectionWatch) async {
        let entries = (try? await dictionary.entries()) ?? []
        var known = Self.knownKeys(entries)
        var learnedCount = 0

        for delay in schedule {
            guard await clock.sleep(for: delay) else { return }
            let readback = await reader.readback(watch)
            guard case let .text(current) = readback else { return }

            let newEntries = Self.candidates(
                finalText: watch.finalText,
                currentText: current,
                known: known,
                isCommonWord: isCommonWord,
                cap: maxPerUtterance - learnedCount
            )
            for entry in newEntries {
                await learn(entry)
                known.insert(entry.phrase.lowercased())
                if let misspelling = entry.misspellings.first { known.insert(misspelling.lowercased()) }
                learnedCount += 1
            }
            if learnedCount >= maxPerUtterance { return }
        }
    }

    // MARK: - Pure filtering (unit-tested)

    /// Every phrase and misspelling, lowercased — the "already known" set the
    /// filter checks against in both directions.
    static func knownKeys(_ entries: [DictionaryEntry]) -> Set<String> {
        Set(entries.flatMap { [$0.phrase.lowercased()] + $0.misspellings.map { $0.lowercased() } })
    }

    /// Test-facing convenience over `candidates(finalText:currentText:known:…)`.
    public static func candidates(
        finalText: String,
        currentText: String,
        entries: [DictionaryEntry],
        isCommonWord: (String) -> Bool,
        maxPerUtterance: Int = 2
    ) -> [DictionaryEntry] {
        candidates(
            finalText: finalText,
            currentText: currentText,
            known: knownKeys(entries),
            isCommonWord: isCommonWord,
            cap: maxPerUtterance
        )
    }

    /// Conservative filter: false positives poison the dictionary, so a pair is
    /// only learned when it clears every gate. Emits at most `cap` entries.
    static func candidates(
        finalText: String,
        currentText: String,
        known: Set<String>,
        isCommonWord: (String) -> Bool,
        cap: Int
    ) -> [DictionaryEntry] {
        guard cap > 0 else { return [] }
        // CorrectionDiff already gives only single-token 1→(1|2) substitutions
        // with source length ≥ 3 and no pure case/punctuation changes.
        let pairs = CorrectionDiff.pairs(raw: finalText, edited: currentText)
        var result: [DictionaryEntry] = []
        var localKnown = known
        for pair in pairs {
            guard accept(pair, known: localKnown, isCommonWord: isCommonWord) else { continue }
            result.append(DictionaryEntry(phrase: pair.to, misspellings: [pair.from], source: .autoCorrection))
            localKnown.insert(pair.to.lowercased())
            localKnown.insert(pair.from.lowercased())
            if result.count >= cap { break }
        }
        return result
    }

    /// Accept `(from→to)` only when: `from` is long enough, the pair is unknown
    /// in either direction, and `to` is a distinctive term — i.e. NOT a common
    /// English word, OR a proper-noun-looking respelling (leading capital + a
    /// small case-insensitive edit distance).
    static func accept(
        _ pair: CorrectionDiff.Pair,
        known: Set<String>,
        isCommonWord: (String) -> Bool
    ) -> Bool {
        let from = pair.from
        let to = pair.to
        guard from.count >= 3 else { return false }
        let fromKey = from.lowercased()
        let toKey = to.lowercased()
        guard !known.contains(fromKey), !known.contains(toKey) else { return false }

        // Distinctive: the system doesn't recognise `to` as a common word.
        if !isCommonWord(to) { return true }

        // `to` is a common word — only learn it if it reads like a proper-noun
        // respelling of `from` (leading capital + a tiny edit distance).
        let leadingCapital = to.first?.isUppercase ?? false
        return leadingCapital && levenshtein(fromKey, toKey) <= 3
    }

    /// Classic Levenshtein edit distance (case handled by the caller lowercasing).
    static func levenshtein(_ a: String, _ b: String) -> Int {
        let s = Array(a), t = Array(b)
        if s.isEmpty { return t.count }
        if t.isEmpty { return s.count }
        var prev = Array(0...t.count)
        var curr = [Int](repeating: 0, count: t.count + 1)
        for i in 1...s.count {
            curr[0] = i
            for j in 1...t.count {
                let cost = s[i - 1] == t[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[t.count]
    }
}
