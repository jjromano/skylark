import AppKit
import Foundation
import SkylarkCore
import UniformTypeIdentifiers
import OSLog

#if canImport(FoundationModels)
import FoundationModels
#endif

/// App-layer glue for the "Diagnostics Export" feature: fetches recent
/// unified-log entries and history metadata, assembles them through the pure
/// `DiagnosticsReport` generator, and writes the result to a file the user
/// hands to a developer. Everything here is off the audio/paste path (it runs
/// from a Settings button).
///
/// PRIVACY: our logs mark every metadata field `privacy: .public` and never log
/// transcript/audio content, so `composedMessage` is safe to include; any
/// `.private` interpolation shows up as `<private>`. `DiagnosticsReport` is the
/// single auditable point that guarantees no transcript text leaks.
enum DiagnosticsExporter {
    /// Subsystem all Skylark loggers share.
    private static let subsystem = "com.jjromano.skylark"
    /// Cap on log lines included, so a chatty session can't produce a huge file.
    private static let maxLogEntries = 800

    /// Assemble the full report string. Nonisolated + async so it runs OFF the
    /// main actor (OSLogStore fetching and history reads never block the UI).
    static func buildReport(
        appVersion: String,
        buildInfo: BuildInfo?,
        settings: DiagnosticsReport.Settings,
        historyStore: HistoryStore?,
        historyLimit: Int = 40,
        logWindow: TimeInterval = 2 * 60 * 60
    ) async -> String {
        let dictations = (try? await historyStore?.recent(limit: historyLimit)) ?? []
        let (logs, logNote) = fetchLogs(window: logWindow)
        let environment = makeEnvironment(appVersion: appVersion, buildInfo: buildInfo)
        return DiagnosticsReport.build(
            environment: environment,
            settings: settings,
            dictations: dictations,
            logs: logs,
            logNote: logNote
        )
    }

    /// Present a save panel, write the report as UTF-8, and reveal it in Finder.
    /// Main-actor (AppKit). `onNote` reports a failure back to the menu-bar note.
    @MainActor
    static func save(report: String, onNote: @MainActor @escaping (String) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Skylark-Diagnostics-\(filenameStamp()).txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.title = "Export Skylark Diagnostics"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try report.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            onNote("Couldn't save diagnostics: \(error.localizedDescription)")
        }
    }

    // MARK: - Unified log

    /// Fetch recent log entries for our subsystem via `OSLogStore`. Returns the
    /// entries plus an optional human-readable note explaining an empty/partial
    /// result (the API can throw or be unavailable — we degrade, never crash).
    private static func fetchLogs(window: TimeInterval) -> (logs: [DiagnosticsReport.LogEntry], note: String?) {
        do {
            // Prefer the SYSTEM store: `.currentProcessIdentifier` only sees the
            // CURRENT launch, so an export taken after any relaunch silently
            // returned a couple of lines covering one dictation while the
            // history table showed dozens — the reader had no way to tell that
            // apart from "the app barely logged anything". `.system` needs a
            // logging entitlement we may not have, so fall back and SAY WHICH
            // scope produced the result rather than leaving it ambiguous.
            var scopeNote: String?
            let store: OSLogStore
            if let system = try? OSLogStore(scope: .system) {
                store = system
            } else {
                store = try OSLogStore(scope: .currentProcessIdentifier)
                scopeNote = "current app launch only (system log scope unavailable to this build)"
            }
            let position = store.position(date: Date().addingTimeInterval(-window))
            let predicate = NSPredicate(format: "subsystem == %@", subsystem)
            var result: [DiagnosticsReport.LogEntry] = []
            for entry in try store.getEntries(at: position, matching: predicate) {
                guard let log = entry as? OSLogEntryLog else { continue }
                result.append(DiagnosticsReport.LogEntry(
                    timestamp: log.date,
                    category: log.category,
                    level: levelString(log.level),
                    message: log.composedMessage
                ))
            }
            if result.count > maxLogEntries {
                result = Array(result.suffix(maxLogEntries))
            }
            let hours = Int((window / 3600).rounded())
            let note: String?
            if result.isEmpty {
                note = "no matching log entries in the last \(hours)h"
                    + (scopeNote.map { " — \($0)" } ?? "")
            } else {
                note = scopeNote.map { "scope: \($0); older dictations in the table above have no log lines here" }
            }
            return (result, note)
        } catch {
            return ([], "unified log unavailable: \(error.localizedDescription)")
        }
    }

    private static func levelString(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .undefined: return "?"
        case .debug: return "debug"
        case .info: return "info"
        case .notice: return "notice"
        case .error: return "error"
        case .fault: return "fault"
        @unknown default: return "?"
        }
    }

    // MARK: - Environment

    private static func makeEnvironment(appVersion: String, buildInfo: BuildInfo?) -> DiagnosticsReport.Environment {
        DiagnosticsReport.Environment(
            appVersion: appVersion,
            buildCommit: buildInfo?.commit,
            buildDate: buildInfo?.date,
            machineModel: machineModel(),
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            appleIntelligence: appleIntelligenceStatus(),
            generatedAt: Date()
        )
    }

    /// Hardware model identifier (e.g. "Mac15,3") via sysctl.
    private static func machineModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "unknown" }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func appleIntelligenceStatus() -> String {
        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available:
            return "available"
        case .unavailable(let reason):
            return "unavailable (\(describe(reason)))"
        @unknown default:
            return "unavailable (unknown)"
        }
        #else
        return "not available (FoundationModels not importable)"
        #endif
    }

    #if canImport(FoundationModels)
    private static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .appleIntelligenceNotEnabled: return "Apple Intelligence not enabled"
        case .deviceNotEligible: return "device not eligible"
        case .modelNotReady: return "model not ready"
        @unknown default: return "unknown reason"
        }
    }
    #endif

    // MARK: - Filename

    private static func filenameStamp(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
