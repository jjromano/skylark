import Foundation

/// "Is this a common English word?" test for the correction auto-learner.
/// Backed by the system word list at `/usr/share/dict/words` (present on macOS),
/// loaded once, lazily, off the hot path and cached. Case-insensitive; a
/// multi-word phrase counts as common only when *every* whitespace-separated
/// token is common (so "real time" is common, but "Skylark" — a bird, and also
/// in the list — is judged by the caller's proper-noun path).
///
/// Chosen over `NSSpellChecker` deliberately: the checker is invoked from the
/// `CorrectionWatcher` actor (off the main thread), and `NSSpellChecker` is
/// AppKit/main-actor state; the word list keeps the check Sendable, deterministic
/// and testable with no main-actor entanglement. If the list is somehow absent
/// the checker reports "not common", leaning on the filter's other gates
/// (proper-noun respelling, already-known, per-utterance cap) to stay safe.
public final class SystemCommonWordChecker: @unchecked Sendable {
    private let path: String
    private let lock = NSLock()
    private var loaded = false
    private var words: Set<String> = []

    public init(path: String = "/usr/share/dict/words") {
        self.path = path
    }

    public func isCommonWord(_ word: String) -> Bool {
        let tokens = word.split(whereSeparator: { $0.isWhitespace }).map { $0.lowercased() }
        guard !tokens.isEmpty else { return false }
        let set = wordSet()
        guard !set.isEmpty else { return false }
        return tokens.allSatisfy { set.contains($0) }
    }

    private func wordSet() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        if !loaded {
            words = Self.load(path)
            loaded = true
        }
        return words
    }

    private static func load(_ path: String) -> Set<String> {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return Set(content.split(whereSeparator: \.isNewline).map { $0.lowercased() })
    }
}
