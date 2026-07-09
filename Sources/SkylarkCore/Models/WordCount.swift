import Foundation

/// Whitespace/newline-based word counter shared by the `history.word_count`
/// migration backfill (`SkylarkDatabase` v3) and `HistoryHub`'s at-append
/// computation. Deliberately simple — no locale-aware tokenization, just
/// "runs of non-whitespace separated by whitespace" — since it only ever
/// feeds an approximate WPM/streak stat, never anything user-visible as an
/// exact count.
public enum WordCount {
    public static func count(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}
