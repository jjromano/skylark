import SkylarkCore
import SwiftUI

/// Settings → Insights: aggregate usage stats (words, WPM, time saved, streaks,
/// per-app usage, 12-week activity). Pure display — all math in `StatsStore`.
struct InsightsView: View {
    @Bindable var controller: AppController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let stats = controller.stats, stats.totalSessions > 0 {
                    grid(stats)
                    if !stats.topApps.isEmpty { topApps(stats) }
                    activity(stats)
                } else {
                    emptyState
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(20)
        }
        .onAppear { controller.refreshStats() }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("Dictate something and your stats will show up here.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private func grid(_ stats: StatsSummary) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            StatCard(
                value: Format.count(stats.totalWords),
                label: "words dictated",
                detail: "\(Format.count(stats.wordsToday)) today",
                icon: "text.word.spacing", tint: .blue
            )
            StatCard(
                value: stats.averageWPM > 0 ? "\(Int(stats.averageWPM.rounded()))" : "—",
                label: "words per minute",
                detail: "speaking pace",
                icon: "gauge.with.needle", tint: .purple
            )
            StatCard(
                value: Format.duration(minutes: stats.estimatedMinutesSaved),
                label: "time saved",
                detail: "vs. typing at 40 wpm",
                icon: "clock.arrow.circlepath", tint: .green
            )
            StatCard(
                value: Format.count(stats.totalSessions),
                label: "dictations",
                detail: "\(Format.count(stats.sessionsToday)) today",
                icon: "mic.fill", tint: .orange
            )
            StatCard(
                value: "\(stats.currentStreakDays)d",
                label: "current streak",
                detail: "longest \(stats.longestStreakDays)d",
                icon: "flame.fill", tint: .red
            )
            StatCard(
                value: Format.duration(minutes: stats.totalSpeakingSeconds / 60),
                label: "time speaking",
                detail: "all time",
                icon: "waveform", tint: .teal
            )
        }
    }

    private func topApps(_ stats: StatsSummary) -> some View {
        Card(title: "Top apps", icon: "square.grid.2x2") {
            let maxWords = stats.topApps.map(\.words).max() ?? 1
            VStack(spacing: 8) {
                ForEach(stats.topApps, id: \.name) { app in
                    HStack(spacing: 10) {
                        Text(app.name)
                            .font(.system(size: 12))
                            .frame(width: 120, alignment: .leading)
                            .lineLimit(1)
                        GeometryReader { geo in
                            Capsule()
                                .fill(.blue.opacity(0.7))
                                .frame(width: max(4, geo.size.width * CGFloat(app.words) / CGFloat(maxWords)))
                        }
                        .frame(height: 8)
                        Text(Format.count(app.words))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 56, alignment: .trailing)
                    }
                }
            }
        }
    }

    /// GitHub-style 12-week activity heatmap from `dailyWords` (last 84 days).
    private func activity(_ stats: StatsSummary) -> some View {
        Card(title: "Last 12 weeks", icon: "calendar") {
            let byDay = Dictionary(uniqueKeysWithValues: stats.dailyWords.map {
                (Calendar.current.startOfDay(for: $0.day), $0.words)
            })
            let maxWords = max(1, byDay.values.max() ?? 1)
            let today = Calendar.current.startOfDay(for: Date())
            HStack(spacing: 3) {
                ForEach(0..<12, id: \.self) { week in
                    VStack(spacing: 3) {
                        ForEach(0..<7, id: \.self) { day in
                            let offset = (11 - week) * 7 + (6 - day)
                            let date = Calendar.current.date(byAdding: .day, value: -offset, to: today)!
                            let words = byDay[date] ?? 0
                            RoundedRectangle(cornerRadius: 2)
                                .fill(cellColor(words: words, max: maxWords))
                                .frame(width: 13, height: 13)
                                .help(words > 0 ? "\(Format.count(words)) words" : "No dictation")
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func cellColor(words: Int, max maxWords: Int) -> Color {
        guard words > 0 else { return Color.primary.opacity(0.06) }
        let intensity = 0.25 + 0.75 * min(1, Double(words) / Double(maxWords))
        return Color.blue.opacity(intensity)
    }
}

private struct StatCard: View {
    let value: String
    let label: String
    let detail: String
    let icon: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                Spacer()
            }
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
    }
}

private struct Card<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
    }
}

private enum Format {
    static func count(_ n: Int) -> String {
        n.formatted(.number.grouping(.automatic))
    }

    static func duration(minutes: Double) -> String {
        let total = Int(minutes.rounded())
        if total < 1 { return "0m" }
        if total < 60 { return "\(total)m" }
        return "\(total / 60)h \(total % 60)m"
    }
}
