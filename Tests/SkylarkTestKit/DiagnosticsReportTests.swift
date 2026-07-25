import Foundation
import Testing
@testable import SkylarkCore

@Suite("DiagnosticsReport")
struct DiagnosticsReportTests {
    // A fixed instant so the report renders deterministically.
    private static let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func environment() -> DiagnosticsReport.Environment {
        DiagnosticsReport.Environment(
            appVersion: "0.8.0",
            buildCommit: "abcdef1234567890",
            buildDate: Self.fixedDate,
            machineModel: "Mac15,3",
            osVersion: "Version 26.0",
            appleIntelligence: "unavailable (Apple Intelligence not enabled)",
            generatedAt: Self.fixedDate
        )
    }

    private func settings() -> DiagnosticsReport.Settings {
        DiagnosticsReport.Settings(
            sttEngine: "Parakeet (local)",
            cleanupOverride: "auto",
            cleanupModelSlug: "openai/gpt-oss-20b",
            cleanupIntensity: "standard",
            cleanupTimeoutSeconds: 2,
            whisperModeOn: false,
            hotkeyKeyboard: "Fn (Globe)",
            hotkeyMouse: nil,
            hotkeyCommand: nil,
            contextAwareCleanup: false,
            translationEnabled: false,
            translationLanguage: "en",
            audioRetentionEnabled: false,
            audioRetentionDays: 7,
            historyRetentionDays: 0,
            pressEnterEnabled: false,
            livePreviewEnabled: false,
            pauseMediaEnabled: false,
            deepVocabEnabled: false,
            inputDeviceSelected: false
        )
    }

    // The distinctive transcript strings we feed in — the report must NEVER
    // contain any of these (privacy regression guard).
    private static let secretRaw = "SECRETRAWTRANSCRIPTMARKER quick brown fox jumps"
    private static let secretClean = "SECRETCLEANTRANSCRIPTMARKER fox"

    private func records() -> [DiagnosticsRecordFixture] {
        [
            // Normal dictation: clean words ≈ raw words, healthy WPM.
            DiagnosticsRecordFixture(
                rawText: "hello there this is a normal sentence with several words",
                cleanText: "Hello there, this is a normal sentence with several words.",
                engine: "parakeet",
                durationMs: 3000,
                latencyMs: 220,
                appName: "Notes",
                cleanupEngine: "local"
            ),
            // Truncation case: raw has the secret markers (8 words), clean has 2.
            DiagnosticsRecordFixture(
                rawText: Self.secretRaw,           // 5 words
                cleanText: Self.secretClean,       // 2 words → < 50% of 5
                engine: "parakeet",
                durationMs: 2000,
                latencyMs: 900,
                appName: "Slack",
                cleanupEngine: "openai/gpt-oss-20b"
            ),
            // Silent-tail case: long clip (6s), very few words (2 → 0.33 w/s).
            DiagnosticsRecordFixture(
                rawText: "um yeah",
                cleanText: nil,
                engine: "parakeet",
                durationMs: 6000,
                latencyMs: 180,
                appName: "Mail",
                cleanupEngine: "raw"
            ),
        ]
    }

    private func build() -> String {
        DiagnosticsReport.build(
            environment: environment(),
            settings: settings(),
            dictations: records().map(\.record),
            logs: [
                DiagnosticsReport.LogEntry(
                    timestamp: Self.fixedDate, category: "pipeline", level: "notice",
                    message: "dictation summary — stt: parakeet, latency-ms: 220.0"
                ),
                DiagnosticsReport.LogEntry(
                    timestamp: Self.fixedDate, category: "injection", level: "error",
                    message: "direct injection failed: some AX error"
                ),
            ],
            logNote: nil
        )
    }

    @Test("Report has all four sections")
    func sections() {
        let report = build()
        #expect(report.contains("ENVIRONMENT"))
        #expect(report.contains("SETTINGS SNAPSHOT"))
        #expect(report.contains("RECENT DICTATIONS"))
        #expect(report.contains("RECENT LOG ENTRIES"))
    }

    @Test("Environment + settings metadata is rendered")
    func environmentAndSettings() {
        let report = build()
        #expect(report.contains("0.8.0"))
        #expect(report.contains("Mac15,3"))
        #expect(report.contains("abcdef123456"))       // 12-char commit prefix
        #expect(report.contains("Apple Intelligence not enabled"))
        #expect(report.contains("Parakeet (local)"))
        #expect(report.contains("openai/gpt-oss-20b"))
    }

    @Test("Metadata table has the column headers and per-row counts")
    func metadataTable() {
        let report = build()
        // Table headers.
        for column in ["timestamp", "app", "stt", "dur_ms", "raw_w", "cln_w", "cleanup", "lat_ms"] {
            #expect(report.contains(column))
        }
        // App names (metadata, not transcript) appear.
        #expect(report.contains("Notes"))
        #expect(report.contains("Slack"))
        #expect(report.contains("Mail"))
        // Durations appear.
        #expect(report.contains("6000"))
    }

    @Test("Truncation and silent-tail summary counts are correct")
    func summaryCounts() {
        let report = build()
        #expect(report.contains("dictations shown: 3"))
        // Exactly one truncation row (secret markers: 2 < 0.5*5).
        #expect(report.contains("likely cleanup truncation (clean words < 50% of raw): 1"))
        // Exactly one silent-tail row (6s clip, 2 words → 0.33 w/s).
        #expect(report.contains("likely mic/silent-tail (words/sec < 1.2 over >4s clip): 1"))
    }

    @Test("PRIVACY: no transcript or cleaned text leaks into the report")
    func noTranscriptContent() {
        let report = build()
        // The distinctive markers we fed as raw/clean text must be absent.
        #expect(!report.contains("SECRETRAWTRANSCRIPTMARKER"))
        #expect(!report.contains("SECRETCLEANTRANSCRIPTMARKER"))
        #expect(!report.contains("quick brown fox"))
        // A normal transcript's words must not appear either.
        #expect(!report.contains("normal sentence with several words"))
        // But the DERIVED word counts must (5 raw words for the truncation row).
        #expect(report.contains("RECENT DICTATIONS"))
    }

    @Test("Empty inputs render without crashing and note the absence")
    func emptyInputs() {
        let report = DiagnosticsReport.build(
            environment: environment(),
            settings: settings(),
            dictations: [],
            logs: [],
            logNote: "unified log unavailable: test"
        )
        #expect(report.contains("(no recent dictations)"))
        #expect(report.contains("unified log unavailable: test"))
    }
}

/// Test fixture that constructs a `HistoryRecord` with only the fields the
/// report reads, so the test reads cleanly.
private struct DiagnosticsRecordFixture {
    let record: HistoryRecord

    init(
        rawText: String,
        cleanText: String?,
        engine: String,
        durationMs: Int,
        latencyMs: Int,
        appName: String,
        cleanupEngine: String
    ) {
        record = HistoryRecord(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            rawText: rawText,
            cleanText: cleanText,
            engine: engine,
            durationMs: durationMs,
            latencyMs: latencyMs,
            appName: appName,
            cleanupEngine: cleanupEngine
        )
    }
}
