import Foundation

/// Builds the plain-text "Diagnostics Export" a user hands to a developer to
/// debug a dictation problem on a machine they can't develop on. A PURE function
/// of its injected inputs — no OSLog, no database, no `UserDefaults`, no clock —
/// so it's fully unit-testable and the privacy invariant (metadata only, never
/// transcript/audio content) is auditable in one place.
///
/// HARD PRIVACY RULE: this report NEVER contains transcript text, cleaned text,
/// audio, API keys, or anything the user said. The recent-dictation section
/// reports only *counts and timings* derived from the text. The caller is
/// responsible for handing this generator only metadata (log messages here are
/// already `privacy: .public` and content-free by construction).
public enum DiagnosticsReport {
    /// Machine/build/runtime facts (Part 1 §1). All already-resolved by the
    /// caller so the generator stays I/O-free.
    public struct Environment: Sendable {
        public var appVersion: String
        public var buildCommit: String?
        public var buildDate: Date?
        public var machineModel: String
        public var osVersion: String
        /// Human-readable Apple Intelligence availability ("available",
        /// "unavailable — Apple Intelligence is not enabled", "not importable").
        public var appleIntelligence: String
        public var generatedAt: Date

        public init(
            appVersion: String,
            buildCommit: String?,
            buildDate: Date?,
            machineModel: String,
            osVersion: String,
            appleIntelligence: String,
            generatedAt: Date
        ) {
            self.appVersion = appVersion
            self.buildCommit = buildCommit
            self.buildDate = buildDate
            self.machineModel = machineModel
            self.osVersion = osVersion
            self.appleIntelligence = appleIntelligence
            self.generatedAt = generatedAt
        }
    }

    /// The user's current configuration (Part 1 §2). Non-secret metadata only —
    /// no API keys, no file paths.
    public struct Settings: Sendable {
        public var sttEngine: String
        public var cleanupOverride: String
        public var cleanupModelSlug: String
        public var cleanupIntensity: String
        public var cleanupTimeoutSeconds: Int
        public var whisperModeOn: Bool
        public var hotkeyKeyboard: String
        public var hotkeyMouse: String?
        public var hotkeyCommand: String?
        public var contextAwareCleanup: Bool
        public var translationEnabled: Bool
        public var translationLanguage: String
        public var audioRetentionEnabled: Bool
        public var audioRetentionDays: Int
        public var historyRetentionDays: Int
        public var pressEnterEnabled: Bool
        public var livePreviewEnabled: Bool
        public var pauseMediaEnabled: Bool
        public var deepVocabEnabled: Bool
        /// nil = system default input device.
        public var inputDeviceSelected: Bool

        public init(
            sttEngine: String,
            cleanupOverride: String,
            cleanupModelSlug: String,
            cleanupIntensity: String,
            cleanupTimeoutSeconds: Int,
            whisperModeOn: Bool,
            hotkeyKeyboard: String,
            hotkeyMouse: String?,
            hotkeyCommand: String?,
            contextAwareCleanup: Bool,
            translationEnabled: Bool,
            translationLanguage: String,
            audioRetentionEnabled: Bool,
            audioRetentionDays: Int,
            historyRetentionDays: Int,
            pressEnterEnabled: Bool,
            livePreviewEnabled: Bool,
            pauseMediaEnabled: Bool,
            deepVocabEnabled: Bool,
            inputDeviceSelected: Bool
        ) {
            self.sttEngine = sttEngine
            self.cleanupOverride = cleanupOverride
            self.cleanupModelSlug = cleanupModelSlug
            self.cleanupIntensity = cleanupIntensity
            self.cleanupTimeoutSeconds = cleanupTimeoutSeconds
            self.whisperModeOn = whisperModeOn
            self.hotkeyKeyboard = hotkeyKeyboard
            self.hotkeyMouse = hotkeyMouse
            self.hotkeyCommand = hotkeyCommand
            self.contextAwareCleanup = contextAwareCleanup
            self.translationEnabled = translationEnabled
            self.translationLanguage = translationLanguage
            self.audioRetentionEnabled = audioRetentionEnabled
            self.audioRetentionDays = audioRetentionDays
            self.historyRetentionDays = historyRetentionDays
            self.pressEnterEnabled = pressEnterEnabled
            self.livePreviewEnabled = livePreviewEnabled
            self.pauseMediaEnabled = pauseMediaEnabled
            self.deepVocabEnabled = deepVocabEnabled
            self.inputDeviceSelected = inputDeviceSelected
        }
    }

    /// One already-fetched unified-log record (Part 1 §4). The OSLog fetch lives
    /// in the app layer (`DiagnosticsExporter`); this generator only formats
    /// what it's handed.
    public struct LogEntry: Sendable {
        public var timestamp: Date
        public var category: String
        public var level: String
        public var message: String

        public init(timestamp: Date, category: String, level: String, message: String) {
            self.timestamp = timestamp
            self.category = category
            self.level = level
            self.message = message
        }
    }

    /// Build the full report string from the injected inputs. `logNote` (if any)
    /// explains why the log section is empty/partial (e.g. OSLogStore failed);
    /// keeping it a parameter preserves the generator's purity.
    public static func build(
        environment: Environment,
        settings: Settings,
        dictations: [HistoryRecord],
        logs: [LogEntry],
        logNote: String? = nil
    ) -> String {
        var out = ""
        out += header()
        out += "\n"
        out += environmentSection(environment)
        out += "\n"
        out += settingsSection(settings)
        out += "\n"
        out += dictationsSection(dictations)
        out += "\n"
        out += logsSection(logs, note: logNote)
        return out
    }

    // MARK: - Sections

    private static func header() -> String {
        """
        ============================================================
        Skylark Diagnostics Report
        ============================================================
        PRIVACY: This report contains ONLY metadata — app version,
        settings, per-dictation counts/timings, and content-free log
        lines. No transcript text, no cleaned text, no audio, and no
        API keys are included.

        """
    }

    private static func environmentSection(_ env: Environment) -> String {
        var lines: [(String, String)] = []
        lines.append(("App version", env.appVersion))
        lines.append(("Build commit", env.buildCommit.map { String($0.prefix(12)) } ?? "(dev build — not installed via install.sh)"))
        lines.append(("Build date", env.buildDate.map { timestamp($0) } ?? "—"))
        lines.append(("Machine model", env.machineModel))
        lines.append(("macOS", env.osVersion))
        lines.append(("Apple Intelligence", env.appleIntelligence))
        lines.append(("Report generated", timestamp(env.generatedAt)))
        return section("ENVIRONMENT", keyValues: lines)
    }

    private static func settingsSection(_ s: Settings) -> String {
        var lines: [(String, String)] = []
        lines.append(("STT engine", s.sttEngine))
        lines.append(("Cleanup override", s.cleanupOverride))
        lines.append(("Cleanup model", s.cleanupModelSlug))
        lines.append(("Cleanup intensity", s.cleanupIntensity))
        lines.append(("Cleanup timeout", s.cleanupTimeoutSeconds <= 0 ? "disabled (wait unbounded)" : "\(s.cleanupTimeoutSeconds)s"))
        lines.append(("Whisper Mode", onOff(s.whisperModeOn)))
        lines.append(("Hotkey (dictation)", s.hotkeyKeyboard))
        lines.append(("Hotkey (mouse)", s.hotkeyMouse ?? "none"))
        lines.append(("Hotkey (command mode)", s.hotkeyCommand ?? "unbound"))
        lines.append(("Context-aware cleanup", onOff(s.contextAwareCleanup)))
        lines.append(("Translation", s.translationEnabled ? "on → \(s.translationLanguage)" : "off"))
        lines.append(("Audio retention", s.audioRetentionEnabled ? "on (\(s.audioRetentionDays) days)" : "off"))
        lines.append(("History retention", s.historyRetentionDays <= 0 ? "keep forever" : "\(s.historyRetentionDays) days"))
        lines.append(("Spoken \"press enter\"", onOff(s.pressEnterEnabled)))
        lines.append(("Live preview", onOff(s.livePreviewEnabled)))
        lines.append(("Pause media while dictating", onOff(s.pauseMediaEnabled)))
        lines.append(("Deep vocabulary", onOff(s.deepVocabEnabled)))
        lines.append(("Input device", s.inputDeviceSelected ? "custom (UID withheld)" : "system default"))
        return section("SETTINGS SNAPSHOT", keyValues: lines)
    }

    /// Per-dictation metadata table + the truncation/silent-tail heuristics that
    /// have surfaced real bugs (cloud cleanup truncation; silent-tail capture).
    /// Only counts and timings — never the text itself.
    private static func dictationsSection(_ records: [HistoryRecord]) -> String {
        var out = "RECENT DICTATIONS (metadata only — no transcript text)\n"
        out += String(repeating: "-", count: 60) + "\n"

        guard !records.isEmpty else {
            out += "(no recent dictations)\n"
            return out
        }

        let header = ["#", "timestamp", "app", "stt", "dur_ms", "raw_w", "cln_w", "cleanup", "lat_ms"]
        var rows: [[String]] = [header]

        var truncationCount = 0
        var silentTailCount = 0

        for (idx, r) in records.enumerated() {
            let rawWords = WordCount.count(r.rawText)
            let cleanWords: Int? = r.cleanText.map { WordCount.count($0) }
            let durationSec = Double(r.durationMs) / 1000.0

            // Likely cloud/cleanup truncation: a clean text that dropped more
            // than half the raw words (the "raw 20 → clean 8" bug class).
            if let cleanWords, rawWords > 0, Double(cleanWords) < 0.5 * Double(rawWords) {
                truncationCount += 1
            }
            // Likely silent-tail / dead-mic: a long clip that produced very few
            // words per second (full duration, few words).
            if r.durationMs > 4000, durationSec > 0,
               Double(rawWords) / durationSec < 1.2 {
                silentTailCount += 1
            }

            rows.append([
                "\(idx + 1)",
                timestamp(r.timestamp),
                r.appName ?? "—",
                r.engine,
                "\(r.durationMs)",
                "\(rawWords)",
                cleanWords.map { "\($0)" } ?? "-",
                r.cleanupEngine ?? "-",
                "\(r.latencyMs)",
            ])
        }

        out += table(rows) + "\n"
        out += "\nSummary:\n"
        out += "  dictations shown: \(records.count)\n"
        out += "  likely cleanup truncation (clean words < 50% of raw): \(truncationCount)\n"
        out += "  likely mic/silent-tail (words/sec < 1.2 over >4s clip): \(silentTailCount)\n"
        return out
    }

    private static func logsSection(_ logs: [LogEntry], note: String?) -> String {
        var out = "RECENT LOG ENTRIES (subsystem com.jjromano.skylark)\n"
        out += String(repeating: "-", count: 60) + "\n"
        if let note {
            out += "note: \(note)\n"
        }
        guard !logs.isEmpty else {
            out += "(no log entries)\n"
            return out
        }
        for entry in logs {
            out += "\(timestamp(entry.timestamp)) [\(entry.level)] \(entry.category): \(entry.message)\n"
        }
        return out
    }

    // MARK: - Formatting helpers

    private static func section(_ title: String, keyValues: [(String, String)]) -> String {
        var out = title + "\n"
        out += String(repeating: "-", count: 60) + "\n"
        let width = keyValues.map { $0.0.count }.max() ?? 0
        for (key, value) in keyValues {
            let padded = key.padding(toLength: width, withPad: " ", startingAt: 0)
            out += "\(padded)  \(value)\n"
        }
        return out
    }

    /// Render a fixed-width, left-aligned table (rows[0] is the header).
    private static func table(_ rows: [[String]]) -> String {
        guard let columnCount = rows.first?.count else { return "" }
        var widths = [Int](repeating: 0, count: columnCount)
        for row in rows {
            for (i, cell) in row.enumerated() where i < columnCount {
                widths[i] = max(widths[i], cell.count)
            }
        }
        var out = ""
        for (rowIdx, row) in rows.enumerated() {
            var cells: [String] = []
            for (i, cell) in row.enumerated() where i < columnCount {
                cells.append(cell.padding(toLength: widths[i], withPad: " ", startingAt: 0))
            }
            out += cells.joined(separator: "  ") + "\n"
            if rowIdx == 0 {
                let ruleWidth = widths.reduce(0, +) + 2 * (columnCount - 1)
                out += String(repeating: "-", count: ruleWidth) + "\n"
            }
        }
        return out
    }

    private static func onOff(_ value: Bool) -> String { value ? "on" : "off" }

    /// Deterministic UTC timestamp so the report reads the same on any machine
    /// (and tests can assert against it). A fresh formatter per call keeps the
    /// generator free of shared mutable state (Swift 6 Sendable); this is off
    /// any latency path (report generation only).
    private static func timestamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}
