import Foundation
import GRDB

/// One aggregate snapshot of usage stats (workstream B spec §3), computed
/// fresh from `history` on every `summary()` call rather than a maintained
/// rollup — the table is one row per dictation, small enough that this is
/// cheap and never risks drifting out of sync.
///
/// Deviation from the spec's literal tuple types: `topApps: [(name: String,
/// words: Int)]` and `dailyWords: [(day: Date, words: Int)]` are expressed
/// here as `[AppUsage]`/`[DailyWordCount]` instead of bare tuples. Swift can't
/// synthesize `Equatable`/`Sendable` conformance through a stored tuple
/// property — tuples don't conform to protocols — so `StatsSummary` itself
/// would fail to compile as `Equatable` with tuple-typed fields. Field names
/// and order are unchanged.
public struct StatsSummary: Sendable, Equatable {
    public struct AppUsage: Sendable, Equatable {
        public var name: String
        public var words: Int

        public init(name: String, words: Int) {
            self.name = name
            self.words = words
        }
    }

    public struct DailyWordCount: Sendable, Equatable {
        public var day: Date
        public var words: Int

        public init(day: Date, words: Int) {
            self.day = day
            self.words = words
        }
    }

    public var totalWords: Int
    public var totalSessions: Int
    public var totalSpeakingSeconds: Double
    public var averageWPM: Double
    public var estimatedMinutesSaved: Double
    public var wordsToday: Int
    public var sessionsToday: Int
    public var currentStreakDays: Int
    public var longestStreakDays: Int
    /// Top 5 apps by summed `word_count`, descending. Rows with no
    /// `app_name` are excluded entirely (not bucketed as "unknown").
    public var topApps: [AppUsage]
    /// One entry per day, in the last 84 days, that has at least one session
    /// — sorted ascending by day. Days with zero words are omitted (not
    /// zero-filled); a heatmap view should treat any day absent from this
    /// array as 0.
    public var dailyWords: [DailyWordCount]

    public init(
        totalWords: Int,
        totalSessions: Int,
        totalSpeakingSeconds: Double,
        averageWPM: Double,
        estimatedMinutesSaved: Double,
        wordsToday: Int,
        sessionsToday: Int,
        currentStreakDays: Int,
        longestStreakDays: Int,
        topApps: [AppUsage],
        dailyWords: [DailyWordCount]
    ) {
        self.totalWords = totalWords
        self.totalSessions = totalSessions
        self.totalSpeakingSeconds = totalSpeakingSeconds
        self.averageWPM = averageWPM
        self.estimatedMinutesSaved = estimatedMinutesSaved
        self.wordsToday = wordsToday
        self.sessionsToday = sessionsToday
        self.currentStreakDays = currentStreakDays
        self.longestStreakDays = longestStreakDays
        self.topApps = topApps
        self.dailyWords = dailyWords
    }
}

/// Read-only aggregate stats over `history` (workstream B spec §3), for a
/// future Settings/Stats view. One entry point, `summary()`. Off any latency
/// path — this actor is never touched by the audio or paste path.
public actor StatsStore {
    private let db: SkylarkDatabase

    public init(db: SkylarkDatabase) {
        self.db = db
    }

    /// - Parameter typingWPM: assumed typing speed used to estimate
    ///   `estimatedMinutesSaved` (typing minutes at this rate, minus actual
    ///   speaking minutes, floored at 0).
    public func summary(typingWPM: Double = 40) async throws -> StatsSummary {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: Date())
        let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? todayStart
        let heatmapCutoff = calendar.date(byAdding: .day, value: -84, to: todayStart) ?? todayStart

        return try await db.dbQueue.read { db in
            let totalSessions = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM history") ?? 0
            let totalWords = try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(word_count), 0) FROM history") ?? 0
            let totalDurationMs = try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(duration_ms), 0) FROM history") ?? 0
            let totalSpeakingSeconds = Double(totalDurationMs) / 1000

            let speakingMinutes = totalSpeakingSeconds / 60
            let averageWPM = speakingMinutes > 0 ? Double(totalWords) / speakingMinutes : 0
            let typingMinutes = typingWPM > 0 ? Double(totalWords) / typingWPM : 0
            let estimatedMinutesSaved = max(0, typingMinutes - speakingMinutes)

            let sessionsToday = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM history WHERE timestamp >= ? AND timestamp < ?",
                arguments: [todayStart, tomorrowStart]
            ) ?? 0
            let wordsToday = try Int.fetchOne(
                db,
                sql: "SELECT COALESCE(SUM(word_count), 0) FROM history WHERE timestamp >= ? AND timestamp < ?",
                arguments: [todayStart, tomorrowStart]
            ) ?? 0

            // Streaks — computed in Swift over the distinct set of calendar
            // days that have at least one session, in the current time zone
            // (spec §3: "compute in Swift ... using the current calendar/
            // timezone"). Over full history, not just the 84-day heatmap
            // window.
            let timestamps = try Date.fetchAll(db, sql: "SELECT timestamp FROM history")
            let sessionDays = Set(timestamps.map { calendar.startOfDay(for: $0) })
            let currentStreakDays = Self.currentStreak(days: sessionDays, calendar: calendar, today: todayStart)
            let longestStreakDays = Self.longestStreak(days: sessionDays, calendar: calendar)

            let appRows = try Row.fetchAll(
                db,
                sql: """
                SELECT app_name AS name, SUM(word_count) AS words
                FROM history
                WHERE app_name IS NOT NULL
                GROUP BY app_name
                ORDER BY words DESC
                LIMIT 5
                """
            )
            let topApps: [StatsSummary.AppUsage] = appRows.map {
                StatsSummary.AppUsage(name: $0["name"], words: $0["words"])
            }

            let recentRows = try Row.fetchAll(
                db,
                sql: "SELECT timestamp, word_count FROM history WHERE timestamp >= ?",
                arguments: [heatmapCutoff]
            )
            var wordsByDay: [Date: Int] = [:]
            for row in recentRows {
                let timestamp: Date = row["timestamp"]
                let words: Int = row["word_count"]
                let day = calendar.startOfDay(for: timestamp)
                wordsByDay[day, default: 0] += words
            }
            let dailyWords = wordsByDay
                .map { StatsSummary.DailyWordCount(day: $0.key, words: $0.value) }
                .sorted { $0.day < $1.day }

            return StatsSummary(
                totalWords: totalWords,
                totalSessions: totalSessions,
                totalSpeakingSeconds: totalSpeakingSeconds,
                averageWPM: averageWPM,
                estimatedMinutesSaved: estimatedMinutesSaved,
                wordsToday: wordsToday,
                sessionsToday: sessionsToday,
                currentStreakDays: currentStreakDays,
                longestStreakDays: longestStreakDays,
                topApps: topApps,
                dailyWords: dailyWords
            )
        }
    }

    /// Consecutive calendar days, ending today if today already has a
    /// session, or ending yesterday if today has none yet (so the streak
    /// doesn't reset to 0 the moment midnight passes and before the day's
    /// first dictation).
    private static func currentStreak(days: Set<Date>, calendar: Calendar, today: Date) -> Int {
        var cursor = today
        if !days.contains(cursor) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today), days.contains(yesterday) else {
                return 0
            }
            cursor = yesterday
        }
        var streak = 0
        while days.contains(cursor) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return streak
    }

    /// Longest run of consecutive calendar days with a session, anywhere in
    /// history.
    private static func longestStreak(days: Set<Date>, calendar: Calendar) -> Int {
        guard !days.isEmpty else { return 0 }
        let sorted = days.sorted()
        var longest = 1
        var current = 1
        for i in 1..<sorted.count {
            if let expected = calendar.date(byAdding: .day, value: 1, to: sorted[i - 1]), expected == sorted[i] {
                current += 1
            } else {
                current = 1
            }
            longest = max(longest, current)
        }
        return longest
    }
}
