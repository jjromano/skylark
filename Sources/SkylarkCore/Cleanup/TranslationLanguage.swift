import Foundation

/// Curated set of translation-target languages for translation mode
/// (Settings → General). Targets are stored as BCP-47 codes; display names are
/// rendered through `Locale` so the picker localizes to the user's UI language,
/// while the name embedded in the (English) cleanup prompt is always English.
public enum TranslationLanguage {
    /// Curated target codes, in display order. English leads because "translate
    /// TO English" is a common case (dictate in your native tongue, type English).
    public static let codes: [String] = [
        "en", "es", "fr", "de", "it", "pt", "ja", "zh-Hans", "ko",
    ]

    /// `true` when `code` is one the app offers as a translation target.
    public static func isSupported(_ code: String) -> Bool { codes.contains(code) }

    /// Localized display name for the picker (e.g. "Spanish", "Chinese,
    /// Simplified"), rendered in `locale` (default: the user's current locale).
    /// Falls back to the raw code if the OS can't name it.
    public static func displayName(_ code: String, locale: Locale = .current) -> String {
        locale.localizedString(forIdentifier: code)
            ?? locale.localizedString(forLanguageCode: code)
            ?? code
    }

    /// English language name to embed in the (English) cleanup prompt. Normalizes
    /// the OS's "Base, Variant" spelling into natural word order so the sentence
    /// reads well ("Chinese, Simplified" → "Simplified Chinese"). Falls back to
    /// the code if the OS can't name it.
    public static func promptName(_ code: String) -> String {
        let english = Locale(identifier: "en_US")
        let name = english.localizedString(forIdentifier: code)
            ?? english.localizedString(forLanguageCode: code)
            ?? code
        if let comma = name.firstIndex(of: ",") {
            let base = name[..<comma].trimmingCharacters(in: .whitespaces)
            let variant = name[name.index(after: comma)...].trimmingCharacters(in: .whitespaces)
            if !variant.isEmpty, !base.isEmpty { return "\(variant) \(base)" }
        }
        return name
    }
}
