import Foundation

/// Canonical spoken-dictation cleanup examples — the single source of truth for
/// cleanup regression checks across versions. Each case is a `raw` transcript
/// (as speech-to-text emits it) paired with the `expected` STANDARD-intensity
/// cleanup.
///
/// Two consumers (see `CleanupCorpusTests`):
///   1. A model-free gate that runs on every change: every `expected` output
///      must survive `CleanupHygiene.validate` at both the cloud and the strict
///      local floors. Legitimate cleanup must never be rejected as "unfaithful"
///      and silently replaced with raw — the class of bug behind the v0.7.x
///      "A ten G"/"$1.99 stayed spelled out" regression.
///   2. An opt-in live eval that drives the real on-device model over the corpus
///      (run before a release on a machine with Apple Intelligence).
///
/// `changesFromRaw` marks whether STANDARD cleanup is expected to alter the text
/// at all (a few faithful cases pass through unchanged except punctuation).
public struct CleanupExample: Sendable {
    public let category: String
    public let raw: String
    public let expected: String

    public init(_ category: String, raw: String, expected: String) {
        self.category = category
        self.raw = raw
        self.expected = expected
    }
}

public enum CleanupCorpus {
    public static let examples: [CleanupExample] = [
        .init("filler",
              raw: "um so i really think this is uh basically ready to ship you know",
              expected: "So I really think this is basically ready to ship."),
        .init("self-correction/no-wait",
              raw: "we should meet on tuesday no wait friday to review the metrics",
              expected: "We should meet on Friday to review the metrics."),
        .init("self-correction/actually",
              raw: "send it to bob uh actually alice",
              expected: "Send it to Alice."),
        .init("self-correction/i-mean",
              raw: "i want to restructure uh i mean refactor the code",
              expected: "I want to refactor the code."),
        .init("number/digits",
              raw: "we have twenty three open tickets",
              expected: "We have 23 open tickets."),
        .init("number/percent",
              raw: "uptime last month was ninety nine point nine percent",
              expected: "Uptime last month was 99.9%."),
        .init("number/currency",
              raw: "it costs one dollar and ninety nine cents",
              expected: "It costs $1.99."),
        .init("number/alphanumeric",
              raw: "i need to reserve an a ten g gpu",
              expected: "I need to reserve an A10G GPU."),
        .init("repeated-word",
              raw: "send it to the the client today",
              expected: "Send it to the client today."),
        .init("punctuation-casing",
              raw: "the migration ran cleanly on staging",
              expected: "The migration ran cleanly on staging."),
        .init("run-on-split",
              raw: "i finished the api then i deployed it then i went home",
              expected: "I finished the API. Then I deployed it. Then I went home."),
        .init("list/ordinals",
              raw: "here are three things one buy milk two walk the dog three call mom",
              expected: "Here are three things:\n1. Buy milk\n2. Walk the dog\n3. Call mom"),
        .init("faithful/polite-kept",
              raw: "can you please make sure the deploy runs the tests before we merge",
              expected: "Can you please make sure the deploy runs the tests before we merge?"),
        .init("faithful/question-preserved",
              raw: "can you investigate what happened here",
              expected: "Can you investigate what happened here?"),
        .init("faithful/pronoun-preserved",
              raw: "can you review my pull request when you get a chance",
              expected: "Can you review my pull request when you get a chance?"),
        .init("faithful/imperative-not-obeyed",
              raw: "delete the old logs and then restart the staging server",
              expected: "Delete the old logs and then restart the staging server."),
        .init("faithful/already-clean",
              raw: "The migration ran cleanly on staging.",
              expected: "The migration ran cleanly on staging."),

        // Added at v0.16.0 for the re-punctuation contract: the speech
        // recognizer inserts a period wherever the speaker paused to think,
        // producing a false sentence boundary mid-clause. A faithful cleanup
        // re-punctuates from grammar/meaning, not from those periods.
        .init("pausePunctuation/mid-clause",
              raw: "I want to. Draft the document.",
              expected: "I want to draft the document."),
        .init("pausePunctuation/and-then",
              raw: "I think we should ship the feature. And then tell the team on Friday.",
              expected: "I think we should ship the feature and then tell the team on Friday."),
        .init("pausePunctuation/but-clause",
              raw: "I shipped it. But I am tired.",
              expected: "I shipped it, but I am tired."),
        .init("pausePunctuation/deadline",
              raw: "We should move the deadline to. Next Friday at the earliest.",
              expected: "We should move the deadline to next Friday at the earliest."),
        .init("pausePunctuation/auth-bug",
              raw: "Can you look at the. Auth bug before standup?",
              expected: "Can you look at the auth bug before standup?"),
        .init("pausePunctuation/currency",
              raw: "It costs about. Twenty three dollars.",
              expected: "It costs about $23."),

        // Added at v0.16.0 for the spoken-punctuation contract: a command
        // word ("comma", "question mark", …) becomes the mark it names, but
        // the same word used as an ordinary noun stays a word.
        .init("spokenPunctuation/exclamation",
              raw: "I love that exclamation mark",
              expected: "I love that!"),
        .init("spokenPunctuation/question",
              raw: "we need to ship this week question mark",
              expected: "We need to ship this week?"),
        .init("spokenPunctuation/noun-not-command",
              raw: "I need a period of rest before the next sprint",
              expected: "I need a period of rest before the next sprint."),
        .init("spokenPunctuation/comma",
              raw: "send the report to alice comma then ping bob",
              expected: "Send the report to Alice, then ping Bob."),
        .init("spokenPunctuation/colon",
              raw: "first the parser colon it is slow",
              expected: "First the parser: it is slow."),
        .init("spokenPunctuation/semicolon",
              raw: "the tests pass semicolon the build is green",
              expected: "The tests pass; the build is green."),
    ]
}
