import Foundation
import Testing
@testable import AIGlassCore

@MainActor @Test func approxFullResetSession5hCalculatesCorrectly() {
    let now = ISO8601.date("2026-06-11T10:00:00Z")!
    let store = UsageStore()
    // 60분 전 이벤트 → 마지막 이벤트 + 300분 = 240분 후
    let e = TokenEvent(service: .codex, timestamp: now.addingTimeInterval(-60 * 60),
                       model: "codex", inputTokens: 1, outputTokens: 0,
                       cacheReadTokens: 0, cacheCreationTokens: 0)
    store.addEvents([(e, nil)])

    let result = try! #require(store.approxFullReset(service: .codex, kind: .session5h, now: now))
    let expected = e.timestamp.addingTimeInterval(300 * 60)
    #expect(abs(result.timeIntervalSince(expected)) < 1)
    // now보다 미래여야 함
    #expect(result > now)
}

@MainActor @Test func approxFullResetWeeklyCalculatesCorrectly() {
    let now = ISO8601.date("2026-06-11T10:00:00Z")!
    let store = UsageStore()
    // 1일 전 이벤트 → 마지막 이벤트 + 7일 = 6일 후
    let e = TokenEvent(service: .claude, timestamp: now.addingTimeInterval(-24 * 3600),
                       model: "claude", inputTokens: 1, outputTokens: 0,
                       cacheReadTokens: 0, cacheCreationTokens: 0)
    store.addEvents([(e, nil)])

    let result = try! #require(store.approxFullReset(service: .claude, kind: .weekly, now: now))
    let expected = e.timestamp.addingTimeInterval(7 * 24 * 3600)
    #expect(abs(result.timeIntervalSince(expected)) < 1)
    #expect(result > now)
}

@MainActor @Test func approxFullResetReturnsNilWhenPast() {
    let now = ISO8601.date("2026-06-11T10:00:00Z")!
    let store = UsageStore()
    // 6시간 전 이벤트 + 300분(5h) = 1시간 전 → 과거 → nil
    let e = TokenEvent(service: .codex, timestamp: now.addingTimeInterval(-6 * 3600),
                       model: "codex", inputTokens: 1, outputTokens: 0,
                       cacheReadTokens: 0, cacheCreationTokens: 0)
    store.addEvents([(e, nil)])

    #expect(store.approxFullReset(service: .codex, kind: .session5h, now: now) == nil)
}

@MainActor @Test func approxFullResetReturnsNilForDaily() {
    let now = ISO8601.date("2026-06-11T10:00:00Z")!
    let store = UsageStore()
    let e = TokenEvent(service: .claude, timestamp: now.addingTimeInterval(-60),
                       model: "claude", inputTokens: 1, outputTokens: 0,
                       cacheReadTokens: 0, cacheCreationTokens: 0)
    store.addEvents([(e, nil)])

    #expect(store.approxFullReset(service: .claude, kind: .daily, now: now) == nil)
}

@MainActor @Test func approxFullResetReturnsNilWhenNoEvents() {
    let now = ISO8601.date("2026-06-11T10:00:00Z")!
    let store = UsageStore()

    #expect(store.approxFullReset(service: .claude, kind: .session5h, now: now) == nil)
    #expect(store.approxFullReset(service: .codex, kind: .weekly, now: now) == nil)
}
