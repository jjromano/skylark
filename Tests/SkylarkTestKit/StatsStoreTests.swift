import Testing
import Foundation
@testable import SkylarkCore

@Suite("StatsStore summary")
struct StatsStoreTests {
    private func makeDB() throws -> SkylarkDatabase {
        try SkylarkDatabase.inMemory()
    }

    @discardableResult
    private func insert(
        _ store: HistoryStore,
        daysAgo: Int,
        words: Int,
        durationMs: Int,
        appName: String? = nil
    ) async throws -> HistoryRecord {
        let timestamp = try #require(Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()))
        return try await store.append(HistoryRecord(
            timestamp: timestamp,
            rawText: Array(repeating: "word", count: words).joined(separator: " "),
            engine: "parakeet",
            durationMs: durationMs,
            latencyMs: 10,
            wordCount: words,
            appName: appName
        ))
    }

    @Test("Totals, average WPM, and estimated-minutes-saved math")
    func totalsMath() async throws {
        let db = try makeDB()
        let store = HistoryStore(db: db)
        // 100 words spoken over 60 seconds -> 100 WPM.
        try await insert(store, daysAgo: 0, words: 100, durationMs: 60_000)

        let summary = try await StatsStore(db: db).summary(typingWPM: 40)

        #expect(summary.totalWords == 100)
        #expect(summary.totalSessions == 1)
        #expect(summary.totalSpeakingSeconds == 60)
        #expect(summary.averageWPM == 100)
        // Typing 100 words at 40 WPM = 2.5 min; speaking took 1 min -> saved 1.5 min.
        #expect(summary.estimatedMinutesSaved == 1.5)
        #expect(summary.wordsToday == 100)
        #expect(summary.sessionsToday == 1)
    }

    @Test("averageWPM and estimatedMinutesSaved are 0-safe with no sessions")
    func zeroSafeWithNoSessions() async throws {
        let db = try makeDB()
        let summary = try await StatsStore(db: db).summary()
        #expect(summary.totalWords == 0)
        #expect(summary.totalSessions == 0)
        #expect(summary.averageWPM == 0)
        #expect(summary.estimatedMinutesSaved == 0)
        #expect(summary.currentStreakDays == 0)
        #expect(summary.longestStreakDays == 0)
        #expect(summary.topApps.isEmpty)
        #expect(summary.dailyWords.isEmpty)
    }

    @Test("topApps ranks by summed word_count descending, excludes rows without an app name")
    func topAppsOrdering() async throws {
        let db = try makeDB()
        let store = HistoryStore(db: db)
        try await insert(store, daysAgo: 0, words: 10, durationMs: 1000, appName: "Mail")
        try await insert(store, daysAgo: 0, words: 5, durationMs: 1000, appName: "Mail")
        try await insert(store, daysAgo: 0, words: 30, durationMs: 1000, appName: "Xcode")
        try await insert(store, daysAgo: 0, words: 100, durationMs: 1000, appName: nil)

        let summary = try await StatsStore(db: db).summary()
        #expect(summary.topApps.count == 2)
        #expect(summary.topApps.first?.name == "Xcode")
        #expect(summary.topApps.first?.words == 30)
        #expect(summary.topApps.last?.name == "Mail")
        #expect(summary.topApps.last?.words == 15)
    }

    @Test("currentStreakDays/longestStreakDays count consecutive days ending today, broken by a gap")
    func currentStreakEndingTodayWithEarlierGap() async throws {
        let db = try makeDB()
        let store = HistoryStore(db: db)
        try await insert(store, daysAgo: 0, words: 1, durationMs: 100)
        try await insert(store, daysAgo: 1, words: 1, durationMs: 100)
        try await insert(store, daysAgo: 2, words: 1, durationMs: 100)
        // Gap at day 3 breaks the streak from an older, separate session.
        try await insert(store, daysAgo: 4, words: 1, durationMs: 100)

        let summary = try await StatsStore(db: db).summary()
        #expect(summary.currentStreakDays == 3)
        #expect(summary.longestStreakDays == 3)
    }

    @Test("currentStreakDays counts a streak ending yesterday when today has no sessions yet")
    func currentStreakEndingYesterday() async throws {
        let db = try makeDB()
        let store = HistoryStore(db: db)
        try await insert(store, daysAgo: 1, words: 1, durationMs: 100)
        try await insert(store, daysAgo: 2, words: 1, durationMs: 100)

        let summary = try await StatsStore(db: db).summary()
        #expect(summary.currentStreakDays == 2)
    }

    @Test("currentStreakDays is 0 when neither today nor yesterday has a session")
    func currentStreakZeroOnStaleGap() async throws {
        let db = try makeDB()
        let store = HistoryStore(db: db)
        try await insert(store, daysAgo: 3, words: 1, durationMs: 100)

        let summary = try await StatsStore(db: db).summary()
        #expect(summary.currentStreakDays == 0)
        #expect(summary.longestStreakDays == 1)
    }

    @Test("dailyWords sums word_count per calendar day within the last 84 days, omitting older/zero days")
    func dailyWordsBucketing() async throws {
        let db = try makeDB()
        let store = HistoryStore(db: db)
        try await insert(store, daysAgo: 0, words: 10, durationMs: 100)
        try await insert(store, daysAgo: 0, words: 5, durationMs: 100)
        try await insert(store, daysAgo: 10, words: 7, durationMs: 100)
        try await insert(store, daysAgo: 90, words: 999, durationMs: 100) // outside the 84-day window

        let summary = try await StatsStore(db: db).summary()
        #expect(summary.dailyWords.count == 2)
        #expect(summary.dailyWords.last?.words == 15) // today's two sessions, sorted ascending by day
        #expect(!summary.dailyWords.contains { $0.words == 999 })
    }
}
