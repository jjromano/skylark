import Foundation

/// Staleness guard for speech-engine rebuilds.
///
/// Rebuilding the transcriber is asynchronous in several places at once: the
/// cloud path reads the Keychain off the main actor first (a synchronous
/// `SecItemCopyMatching` that can sit behind an authorization prompt for as long
/// as the dialog is unanswered), every path then warms an engine before
/// installing it. Without a guard the LAST completion wins rather than the last
/// SELECTION — so switching cloud → local can finish local first and have the
/// older cloud rebuild land on top of it. The menu reads "Local" while the
/// installed transcriber is cloud-primary, and the next dictation uploads audio.
/// That is a privacy invariant, not a cosmetic race.
///
/// Usage: `begin(_:)` once per rebuild for a token, then `isCurrent(_:selection:)`
/// before constructing anything expensive AND again immediately before
/// installing. A stale token means a newer rebuild owns the outcome — drop the
/// work, touch nothing.
public struct STTRebuildGate: Sendable, Equatable {
    /// Identifies one rebuild attempt: which selection it was started for, and
    /// where it sits in the sequence.
    public struct Token: Sendable, Equatable {
        public let generation: UInt64
        public let choice: STTChoice
    }

    private var generation: UInt64 = 0

    public init() {}

    /// Open a new rebuild, superseding every rebuild already in flight.
    public mutating func begin(_ choice: STTChoice) -> Token {
        generation &+= 1
        return Token(generation: generation, choice: choice)
    }

    /// Whether `token` still owns the outcome: no newer rebuild has started AND
    /// the live selection is still the one this rebuild was started for. The
    /// selection is checked separately because it is the user-visible source of
    /// truth (the menu reads it); a rebuild whose selection has moved on must
    /// never install, even if no newer rebuild has been kicked off yet.
    public func isCurrent(_ token: Token, selection: STTChoice) -> Bool {
        token.generation == generation && token.choice == selection
    }
}
