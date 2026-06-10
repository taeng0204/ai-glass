import Foundation
import Testing
@testable import AIGlassCore

@MainActor
private func makeStore(now: Date) -> UsageStore {
    let store = UsageStore()
    func ev(minutesAgo: Double, model: String, total: Int, service: ServiceID = .claude) -> (TokenEvent, String?) {
        let e = TokenEvent(service: service, timestamp: now.addingTimeInterval(-minutesAgo * 60),
                           model: model, inputTokens: total, outputTokens: 0,
                           cacheReadTokens: 0, cacheCreationTokens: 0)
        return (e, nil)
    }
    store.addEvents([
        ev(minutesAgo: 5, model: "claude-opus-4-8", total: 1000),
        ev(minutesAgo: 8, model: "claude-fable-5", total: 2000),
        ev(minutesAgo: 60 * 26, model: "claude-opus-4-8", total: 500), // 어제
    ])
    return store
}

@MainActor @Test func dedupSkipsSameKey() {
    let store = UsageStore()
    let e = TokenEvent(service: .claude, timestamp: Date(), model: "m",
                       inputTokens: 1, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0)
    store.addEvents([(e, "k1"), (e, "k1"), (e, nil), (e, nil)])
    #expect(store.events.count == 3) // 키 중복 1개만 제거, nil 키는 중복 허용
}

@MainActor @Test func dailyTotalsAndModelBreakdown() {
    let now = ISO8601.date("2026-06-10T12:00:00Z")!
    let store = makeStore(now: now)
    let days = store.dailyTotals(days: 7, now: now, calendar: .utc)
    #expect(days.count == 7)
    #expect(days.last!.tokens == 3000)         // 오늘
    #expect(days[5].tokens == 500)             // 어제
    let models = store.modelBreakdown(days: 7, now: now, calendar: .utc)
    // opus 합계 1000+500=1500, fable 2000 → fable이 1위
    #expect(models.first!.model == "claude-fable-5")
    #expect(models.first!.tokens == 2000)
}

@MainActor @Test func burnRateUsesRecentWindow() {
    let now = ISO8601.date("2026-06-10T12:00:00Z")!
    let store = makeStore(now: now)
    // 최근 10분: 5분 전 1000 + 8분 전 2000 = 3000 → 300 tokens/min
    #expect(abs(store.tokensPerMinute(windowMinutes: 10, now: now) - 300.0) < 0.01)
}

@MainActor @Test func activityLevelReactsToRecentActivity() {
    let now = ISO8601.date("2026-06-10T12:00:00Z")!
    let store = UsageStore()
    let recent = TokenEvent(service: .claude, timestamp: now.addingTimeInterval(-60), model: "m",
                            inputTokens: 30_000, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0)
    store.addEvents([(recent, nil)])
    #expect(store.activityLevel(now: now) > 0)   // 1분 전 활동 → 반응
    #expect(store.activityLevel(now: now) <= 1)
    // 30_000 tokens 1분 전, 3분 창 → 10_000 t/min → level = 0.1
    #expect(abs(store.activityLevel(now: now) - 0.1) < 0.01)
    #expect(store.activityLevel(now: now.addingTimeInterval(10 * 60)) == 0) // 10분 뒤엔 잠잠
}

@MainActor @Test func maxUsedPercentAcrossServices() {
    let store = UsageStore()
    store.setLimits([LimitWindow(kind: .session5h, usedPercent: 38, resetsAt: nil)], for: .claude)
    store.setLimits([LimitWindow(kind: .session5h, usedPercent: 72, resetsAt: nil),
                     LimitWindow(kind: .weekly, usedPercent: 54, resetsAt: nil)], for: .codex)
    #expect(store.maxUsedPercent == 72)
}

@MainActor @Test func todayTokensCountsOnlyTodayEvents() {
    let now = ISO8601.date("2026-06-10T12:00:00Z")!
    let store = makeStore(now: now)
    // makeStore: 5분 전 1000 + 8분 전 2000 (오늘 UTC 6/10) + 26h 전 500 (어제)
    #expect(store.todayTokens(now: now, calendar: .utc) == 3000)
}

@MainActor @Test func todayRequestsCountsTokenEventsAndGemini() {
    let now = ISO8601.date("2026-06-10T12:00:00Z")!
    let store = makeStore(now: now)
    // gemini: 오늘 1건 + 어제 1건
    store.setGeminiRequests([
        now.addingTimeInterval(-30 * 60),           // 오늘 (30분 전)
        now.addingTimeInterval(-25 * 3600),          // 어제
    ])
    // 오늘 토큰 이벤트 2건 + gemini 오늘 1건 = 3
    #expect(store.todayRequests(now: now, calendar: .utc) == 3)
}
