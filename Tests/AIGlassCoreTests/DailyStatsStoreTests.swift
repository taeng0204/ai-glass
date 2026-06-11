import Foundation
import Testing
@testable import AIGlassCore

@MainActor
private func tempDBPath() -> String {
    let dir = NSTemporaryDirectory() + "aiglass-test-\(UUID().uuidString)"
    return dir + "/stats.db"
}

@MainActor @Test func upsertAndQueryRoundTrip() {
    let now = ISO8601.date("2026-06-10T12:00:00Z")!
    let store = try! #require(DailyStatsStore(path: tempDBPath()))
    let events = [
        TokenEvent(service: .claude, timestamp: now, model: "claude-opus-4-8",
                   inputTokens: 100, outputTokens: 200, cacheReadTokens: 0, cacheCreationTokens: 0, project: "ai-glass"),
        TokenEvent(service: .codex, timestamp: now, model: "gpt-codex",
                   inputTokens: 50, outputTokens: 50, cacheReadTokens: 0, cacheCreationTokens: 0, project: "other"),
    ]
    store.upsert(events: events, calendar: .utc)
    let totals = store.dailyTotalsByService(days: 7, now: now, calendar: .utc)
    let claude = try! #require(totals.first { $0.service == .claude })
    #expect(claude.tokens == 300)
    let codex = try! #require(totals.first { $0.service == .codex })
    #expect(codex.tokens == 100)

    let projects = store.projectBreakdown(days: 7, now: now, calendar: .utc)
    #expect(projects.first { $0.project == "ai-glass" }?.tokens == 300)
}

@MainActor @Test func replaceIsIdempotent() {
    let now = ISO8601.date("2026-06-10T12:00:00Z")!
    let path = tempDBPath()
    let store = try! #require(DailyStatsStore(path: path))
    let events = [
        TokenEvent(service: .claude, timestamp: now, model: "claude-opus-4-8",
                   inputTokens: 100, outputTokens: 200, cacheReadTokens: 0, cacheCreationTokens: 0, project: "ai-glass"),
    ]
    store.upsert(events: events, calendar: .utc)
    store.upsert(events: events, calendar: .utc)  // 두 번째 upsert
    let totals = store.dailyTotalsByService(days: 7, now: now, calendar: .utc)
    let total = totals.filter { $0.service == .claude }.reduce(0) { $0 + $1.tokens }
    #expect(total == 300)  // 누적되지 않고 대체됨
}

@MainActor @Test func dayRangeFilters() {
    let now = ISO8601.date("2026-06-10T12:00:00Z")!
    let store = try! #require(DailyStatsStore(path: tempDBPath()))
    let recent = TokenEvent(service: .claude, timestamp: now, model: "m",
                            inputTokens: 100, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0)
    let old = TokenEvent(service: .claude, timestamp: now.addingTimeInterval(-40 * 24 * 3600), model: "m",
                         inputTokens: 999, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0)
    store.upsert(events: [recent, old], calendar: .utc)
    let totals30 = store.dailyTotalsByService(days: 30, now: now, calendar: .utc)
    let sum = totals30.reduce(0) { $0 + $1.tokens }
    #expect(sum == 100)  // 40일 전은 30일 범위 밖
}

@MainActor @Test func statsStoreDailyTotalsByServiceIsDeterministicallySorted() {
    let now = ISO8601.date("2026-06-10T12:00:00Z")!
    let store = try! #require(DailyStatsStore(path: tempDBPath()))
    let yesterday = now.addingTimeInterval(-24 * 3600)
    // 삽입 순서를 일부러 allCases 역순/혼합으로.
    let events = [
        TokenEvent(service: .gemini, timestamp: now, model: "m",
                   inputTokens: 30, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0),
        TokenEvent(service: .claude, timestamp: now, model: "m",
                   inputTokens: 10, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0),
        TokenEvent(service: .codex, timestamp: now, model: "m",
                   inputTokens: 20, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0),
        TokenEvent(service: .gemini, timestamp: yesterday, model: "m",
                   inputTokens: 100, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0),
        TokenEvent(service: .claude, timestamp: yesterday, model: "m",
                   inputTokens: 300, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0),
    ]
    store.upsert(events: events, calendar: .utc)
    let rows = store.dailyTotalsByService(days: 7, now: now, calendar: .utc)

    // day 오름차순
    for i in 1..<rows.count { #expect(rows[i - 1].day <= rows[i].day) }
    // 같은 day 안에서 allCases 순서(claude < codex < gemini)
    let order = Dictionary(uniqueKeysWithValues: ServiceID.allCases.enumerated().map { ($1, $0) })
    for i in 1..<rows.count where Calendar.utc.isDate(rows[i - 1].day, inSameDayAs: rows[i].day) {
        #expect(order[rows[i - 1].service]! < order[rows[i].service]!)
    }
    // 어제 행 순서가 정확히 [claude, gemini] (codex는 어제 활동 없음)
    let cal = Calendar.utc
    let yStart = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now))!
    let yRows = rows.filter { cal.isDate($0.day, inSameDayAs: yStart) }
    #expect(yRows.map(\.service) == [.claude, .gemini])
}

@MainActor @Test func totalCostUsesModelRates() {
    let now = ISO8601.date("2026-06-10T12:00:00Z")!
    let store = try! #require(DailyStatsStore(path: tempDBPath()))
    // opus 1M input + 1M output → 5.0 + 25.0 = $30.00
    let e = TokenEvent(service: .claude, timestamp: now, model: "claude-opus-4-8",
                       inputTokens: 1_000_000, outputTokens: 1_000_000,
                       cacheReadTokens: 0, cacheCreationTokens: 0, project: "p")
    store.upsert(events: [e], calendar: .utc)
    let cost = store.totalCost(days: 7, now: now, calendar: .utc)
    #expect(abs(cost - 30.0) < 1e-6)
}

// MARK: - percent_snapshots

@MainActor @Test func percentSnapshotRoundTripAndReplace() {
    let store = try! #require(DailyStatsStore(path: tempDBPath()))
    let day0 = ISO8601.date("2026-06-08T03:00:00Z")!
    let day1 = day0.addingTimeInterval(86400)
    let day2 = day0.addingTimeInterval(2 * 86400)
    store.recordPercentSnapshot(service: .claude, kind: .weekly, percent: 10, day: day0)
    store.recordPercentSnapshot(service: .claude, kind: .weekly, percent: 25, day: day1)
    // 같은 날 재기록 → REPLACE로 마지막 값만 남음
    store.recordPercentSnapshot(service: .claude, kind: .weekly, percent: 40, day: day2)
    store.recordPercentSnapshot(service: .claude, kind: .weekly, percent: 55, day: day2)
    // 다른 kind/service는 섞이지 않음
    store.recordPercentSnapshot(service: .claude, kind: .session5h, percent: 99, day: day2)
    store.recordPercentSnapshot(service: .codex, kind: .weekly, percent: 99, day: day2)

    let snaps = store.percentSnapshots(service: .claude, kind: .weekly, days: 8, now: day2)
    #expect(snaps.map(\.percent) == [10, 25, 55])
    // day 오름차순
    for i in 1..<snaps.count { #expect(snaps[i - 1].day < snaps[i].day) }
}

@MainActor @Test func percentSnapshotDayRangeFilters() {
    let store = try! #require(DailyStatsStore(path: tempDBPath()))
    let now = ISO8601.date("2026-06-10T12:00:00Z")!
    store.recordPercentSnapshot(service: .claude, kind: .weekly, percent: 5,
                                day: now.addingTimeInterval(-40 * 86400))
    store.recordPercentSnapshot(service: .claude, kind: .weekly, percent: 50, day: now)
    let snaps = store.percentSnapshots(service: .claude, kind: .weekly, days: 8, now: now)
    #expect(snaps.map(\.percent) == [50])  // 40일 전은 범위 밖
}