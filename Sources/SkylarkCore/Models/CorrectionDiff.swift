import Foundation

/// Pure word-level differ that proposes custom-dictionary auto-add pairs when a
/// user edits a history entry (PRD §8 auto-correction). The UI lands in Phase 5;
/// this is the engine.
///
/// Emits only conservative single-token substitutions: one word replaced by one
/// or two words, source length ≥ 3, and not a pure case/punctuation change.
public enum CorrectionDiff {
    public struct Pair: Sendable, Equatable {
        public let from: String
        public let to: String
        public init(from: String, to: String) {
            self.from = from
            self.to = to
        }
    }

    /// Candidate `(from, to)` substitutions turning `raw` into `edited`.
    public static func diff(raw: String, edited: String) -> [(from: String, to: String)] {
        pairs(raw: raw, edited: edited).map { ($0.from, $0.to) }
    }

    /// Same as `diff` but returns `Equatable` `Pair`s (convenient for tests).
    public static func pairs(raw: String, edited: String) -> [Pair] {
        let a = tokens(raw)
        let b = tokens(edited)
        let ops = alignment(a, b)

        var result: [Pair] = []
        var i = 0
        while i < ops.count {
            // Gather a maximal run of deletes immediately followed by inserts.
            var deletes: [String] = []
            var inserts: [String] = []
            while i < ops.count, case let .delete(word) = ops[i] {
                deletes.append(word)
                i += 1
            }
            while i < ops.count, case let .insert(word) = ops[i] {
                inserts.append(word)
                i += 1
            }
            if deletes.isEmpty, inserts.isEmpty {
                i += 1 // an .equal op
                continue
            }
            if let pair = candidate(deletes: deletes, inserts: inserts) {
                result.append(pair)
            }
        }
        return result
    }

    // MARK: - Filtering

    private static func candidate(deletes: [String], inserts: [String]) -> Pair? {
        // Single token → one or two tokens only.
        guard deletes.count == 1, (1...2).contains(inserts.count) else { return nil }
        let from = deletes[0]
        let to = inserts.joined(separator: " ")
        guard from.count >= 3 else { return nil }
        // Reject pure case / punctuation differences.
        guard normalized(from) != normalized(to) else { return nil }
        return Pair(from: from, to: to)
    }

    /// Lowercased, punctuation/symbols removed, whitespace kept — so a pure
    /// case or punctuation change normalizes to equal (and is filtered), but a
    /// word split ("realtime" → "real time") stays a real substitution.
    private static func normalized(_ s: String) -> String {
        let kept = s.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || CharacterSet.whitespaces.contains($0)
        }
        return String(String.UnicodeScalarView(kept)).lowercased()
    }

    // MARK: - Tokenization + alignment

    private enum Op { case equal(String); case delete(String); case insert(String) }

    private static func tokens(_ s: String) -> [String] {
        s.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// LCS-based edit script over word arrays.
    private static func alignment(_ a: [String], _ b: [String]) -> [Op] {
        let n = a.count, m = b.count
        // lcs[i][j] = LCS length of a[i...] and b[j...].
        var lcs = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        if n > 0, m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    if a[i] == b[j] {
                        lcs[i][j] = lcs[i + 1][j + 1] + 1
                    } else {
                        lcs[i][j] = max(lcs[i + 1][j], lcs[i][j + 1])
                    }
                }
            }
        }

        var ops: [Op] = []
        var i = 0, j = 0
        while i < n, j < m {
            if a[i] == b[j] {
                ops.append(.equal(a[i])); i += 1; j += 1
            } else if lcs[i + 1][j] >= lcs[i][j + 1] {
                ops.append(.delete(a[i])); i += 1
            } else {
                ops.append(.insert(b[j])); j += 1
            }
        }
        while i < n { ops.append(.delete(a[i])); i += 1 }
        while j < m { ops.append(.insert(b[j])); j += 1 }
        return ops
    }
}
