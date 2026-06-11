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

@MainActor @Test func sessionSummaryFormatsTokensProjectCost() {
    let now = ISO8601.date("2026-06-10T12:00:00Z")!
    let store = UsageStore()
    func ev(minutesAgo: Double, project: String?, output: Int) -> (TokenEvent, String?) {
        (TokenEvent(service: .claude, timestamp: now.addingTimeInterval(-minutesAgo * 60),
                    model: "claude-opus-4-8", inputTokens: 0, outputTokens: output,
                    cacheReadTokens: 0, cacheCreationTokens: 0, project: project), nil)
    }
    // opus output 25.0/MTok. 2M output → $50.00. 주로 ai-glass.
    store.addEvents([
        ev(minutesAgo: 30, project: "ai-glass", output: 1_500_000),
        ev(minutesAgo: 60, project: "ai-glass", output: 500_000),
        ev(minutesAgo: 90, project: "other", output: 200_000),
    ])
    let from = now.addingTimeInterval(-5 * 3600)
    let s = try! #require(store.sessionSummary(service: .claude, from: from, to: now))
    #expect(s.contains("2.2M tokens"))
    #expect(s.contains("주로 ai-glass"))
    #expect(s.contains("~$"))
    #expect(s.hasPrefix("지난 세션:"))
}

@MainActor @Test func projectServiceBreakdownGroupsAndSorts() {
    let now = ISO8601.date("2026-06-10T12:00:00Z")!
    let store = UsageStore()
    func ev(_ project: String, _ service: ServiceID, _ total: Int) -> (TokenEvent, String?) {
        (TokenEvent(service: service, timestamp: now.addingTimeInterval(-3600),
                    model: "claude-opus", inputTokens: total, outputTokens: 0,
                    cacheReadTokens: 0, cacheCreationTokens: 0, project: project), nil)
    }
    store.addEvents([
        ev("alpha", .claude, 100),
        ev("alpha", .codex, 50),
        ev("beta", .claude, 300),
        (TokenEvent(service: .claude, timestamp: now.addingTimeInterval(-3600),
                    model: "claude-opus", inputTokens: 999, outputTokens: 0,
                    cacheReadTokens: 0, cacheCreationTokens: 0, project: nil), nil),
    ])
    let result = store.projectServiceBreakdown(days: 7, now: now)
    #expect(result.count == 2) // project nil 제외
    #expect(result[0].project == "beta")   // total 내림차순
    #expect(result[0].total == 300)
    #expect(result[1].project == "alpha")
    #expect(result[1].total == 150)
    #expect(result[1].byService[.claude] == 100)
    #expect(result[1].byService[.codex] == 50)
}

@MainActor @Test func sessionSummaryNilWhenNoEvents() {
    let now = ISO8601.date("2026-06-10T12:00:00Z")!
    let store = UsageStore()
    #expect(store.sessionSummary(service: .claude, from: now.addingTimeInterval(-3600), to: now) == nil)
}

@MainActor @Test func sessionSummaryOmitsProjectAndTinyCost() {
    let now = ISO8601.date("2026-06-10T12:00:00Z")!
    let store = UsageStore()
    // 프로젝트 nil, 비용 극소(haiku 1000 input → $0.000001) → 두 절 모두 생략
    let e = TokenEvent(service: .claude, timestamp: now.addingTimeInterval(-600),
                       model: "claude-haiku", inputTokens: 1000, outputTokens: 0,
                       cacheReadTokens: 0, cacheCreationTokens: 0, project: nil)
    store.addEvents([(e, nil)])
    let s = try! #require(store.sessionSummary(service: .claude, from: now.addingTimeInterval(-3600), to: now))
    #expect(!s.contains("주로"))
    #expect(!s.contains("~$"))
    #expect(s.contains("tokens"))
}

// MARK: - 컴백 감지

@MainActor
private func makeEvent(at date: Date, service: ServiceID = .claude) -> (event: TokenEvent, dedupKey: String?) {
    let e = TokenEvent(service: service, timestamp: date,
                       model: "m", inputTokens: 1, outputTokens: 0,
                       cacheReadTokens: 0, cacheCreationTokens: 0)
    return (e, nil)
}

@MainActor @Test func comebackNotFiredOnFirstLoad() {
    // 첫 addEvents는 8일치 일괄 적재 — 공백 기록 없어야 함
    // 최근 날짜를 사용해 retention 컷오프를 통과
    let now = Date()
    let store = UsageStore()
    // 4h 전 이벤트를 넣어도 첫 로드이므로 pendingComebackGap 없음
    store.addEvents([makeEvent(at: now.addingTimeInterval(-4 * 3600))])
    #expect(store.consumeComebackGap() == nil)
}

@MainActor @Test func comebackDetectedAfterGap() {
    // 두 번째 addEvents에서 gap ≥ 3h 이면 감지
    let now = Date()
    let store = UsageStore()

    // 첫 로드: now-1h 이벤트
    store.addEvents([makeEvent(at: now.addingTimeInterval(-3600))])
    _ = store.consumeComebackGap() // 첫 로드 → nil (소비)

    // 두 번째 배치: now 이벤트 (gap from now-1h = 1h, but wait we need gap ≥ 3h)
    // gap = now - (now-1h) = 1h. Use a batch that is 4h after the first event.
    // First event: now-5h, Second event: now-1h → gap = 4h ≥ 3h
    let store2 = UsageStore()
    store2.addEvents([makeEvent(at: now.addingTimeInterval(-5 * 3600))])
    _ = store2.consumeComebackGap()

    store2.addEvents([makeEvent(at: now.addingTimeInterval(-1 * 3600))])
    let gap = store2.consumeComebackGap()
    #expect(gap != nil)
    #expect(gap! >= 4 * 3600 - 1)
}

@MainActor @Test func comebackNotFiredWhenGapBelowThreshold() {
    // gap < 3h → nil
    let now = Date()
    let store = UsageStore()

    // 첫 로드: now-3h
    store.addEvents([makeEvent(at: now.addingTimeInterval(-3 * 3600))])
    _ = store.consumeComebackGap()

    // 두 번째 배치: now-1h (gap = 2h < 3h)
    store.addEvents([makeEvent(at: now.addingTimeInterval(-1 * 3600))])
    #expect(store.consumeComebackGap() == nil)
}

@MainActor @Test func consumeReturnsNilAfterConsume() {
    // consume 후 재호출 → nil
    let now = Date()
    let store = UsageStore()

    // 첫 로드: now-5h
    store.addEvents([makeEvent(at: now.addingTimeInterval(-5 * 3600))])
    _ = store.consumeComebackGap()

    // 두 번째 배치: now-1h (gap = 4h ≥ 3h)
    store.addEvents([makeEvent(at: now.addingTimeInterval(-1 * 3600))])
    let first = store.consumeComebackGap()
    #expect(first != nil)
    // 두 번째 consume → nil
    #expect(store.consumeComebackGap() == nil)
}

@MainActor @Test func comebackGapUsesMaxTimestampAsBaseline() {
    // lastKnownMaxTimestamp는 배치 내 max로 갱신 — 오래된 이벤트 재추가 시 gap 오발화 없음
    let now = Date()
    let store = UsageStore()

    // 첫 로드: now-6h, now-5h, now-4h 이벤트 혼재 (max = now-4h)
    store.addEvents([
        makeEvent(at: now.addingTimeInterval(-6 * 3600)),
        makeEvent(at: now.addingTimeInterval(-5 * 3600)),
        makeEvent(at: now.addingTimeInterval(-4 * 3600)),
    ])
    _ = store.consumeComebackGap()

    // 두 번째 배치: now-3.5h (gap from max(now-4h) = 0.5h < 3h → nil)
    store.addEvents([makeEvent(at: now.addingTimeInterval(-3.5 * 3600))])
    #expect(store.consumeComebackGap() == nil)

    // 세 번째 배치: now (gap from max(now-3.5h) = 3.5h ≥ 3h → 감지)
    store.addEvents([makeEvent(at: now)])
    let gap = store.consumeComebackGap()
    #expect(gap != nil)
    #expect(gap! >= 3 * 3600)
}

@MainActor @Test func comebackDetectedDespiteDedupedOldEventsInBatch() {
    // rotation 재파싱: 배치에 이미 추가된(dedup) 옛 이벤트가 섞여도
    // gap은 **실제 추가된** 이벤트의 min timestamp로 계산되어야 한다.
    let now = Date()
    let store = UsageStore()

    func keyedEvent(at date: Date, key: String) -> (event: TokenEvent, dedupKey: String?) {
        let e = TokenEvent(service: .claude, timestamp: date,
                           model: "m", inputTokens: 1, outputTokens: 0,
                           cacheReadTokens: 0, cacheCreationTokens: 0)
        return (e, key)
    }

    // 첫 로드: now-5h (dedup 키 부여)
    store.addEvents([keyedEvent(at: now.addingTimeInterval(-5 * 3600), key: "old")])
    _ = store.consumeComebackGap()

    // 두 번째 배치: 같은 옛 이벤트(dedup으로 버려짐) + 새 이벤트 now-1h
    // 종전 구현은 batchMin = now-5h → gap = 0 → 미발화. 수정 후 addedMin = now-1h → gap = 4h.
    store.addEvents([
        keyedEvent(at: now.addingTimeInterval(-5 * 3600), key: "old"),
        keyedEvent(at: now.addingTimeInterval(-1 * 3600), key: "new"),
    ])
    let gap = store.consumeComebackGap()
    #expect(gap != nil)
    #expect(gap! >= 4 * 3600 - 1)
}
