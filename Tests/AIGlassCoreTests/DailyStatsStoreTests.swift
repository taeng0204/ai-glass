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