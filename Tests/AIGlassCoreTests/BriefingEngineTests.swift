import Foundation
import Testing
@testable import AIGlassCore

private var utc: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}

/// UTC 기준 특정 시각 Date 생성.
private func at(_ iso: String) -> Date { ISO8601.date(iso)! }

@MainActor @Test func periodDetectionByHour() {
    #expect(BriefingEngine.Period.forHour(9) == .morning)
    #expect(BriefingEngine.Period.forHour(13) == .lunch)
    #expect(BriefingEngine.Period.forHour(20) == .evening)
    #expect(BriefingEngine.Period.forHour(11) == nil)  // 경계 밖
    #expect(BriefingEngine.Period.forHour(3) == nil)
}

@MainActor @Test func morningBriefingFiresOncePerDay() {
    let engine = BriefingEngine(calendar: utc)
    let data = BriefingEngine.BriefingData(
        yesterdayTokens: 1_200_000, yesterdayCost: 4.5, yesterdayTopProject: "ai-glass")
    let event = try! #require(engine.evaluate(now: at("2026-06-10T09:00:00Z"), data: data))
    if case .briefing(.morning) = event.kind {} else { Issue.record("morning kind 아님") }
    #expect(event.title == "어제 사용 브리핑")
    #expect(event.subtitle.contains("1.2M tokens"))
    #expect(event.subtitle.contains("$4.50"))
    #expect(event.subtitle.contains("주로 ai-glass"))
    // 같은 날 두번째 호출은 nil
    #expect(engine.evaluate(now: at("2026-06-10T09:30:00Z"), data: data) == nil)
    // 다음 날 morning은 다시 발화
    #expect(engine.evaluate(now: at("2026-06-11T09:00:00Z"), data: data) != nil)
}

@MainActor @Test func eveningBriefingIncludesServiceShare() {
    let engine = BriefingEngine(calendar: utc)
    let data = BriefingEngine.BriefingData(
        todayTokens: 50_000, todayCost: 1.2,
        todayTopService: (service: .claude, share: 0.73))
    let event = try! #require(engine.evaluate(now: at("2026-06-10T20:00:00Z"), data: data))
    if case .briefing(.evening) = event.kind {} else { Issue.record("evening kind 아님") }
    #expect(event.title == "오늘 사용 요약")
    #expect(event.subtitle.contains("50.0K tokens"))
    #expect(event.subtitle.contains("Claude 73% 비중"))
}

@MainActor @Test func lunchBriefingExtrapolatesPace() {
    let engine = BriefingEngine(calendar: utc)
    // now = 12:00 UTC → 자정부터 12h 경과 (dayFraction 0.5) → 외삽 x2
    let data = BriefingEngine.BriefingData(todayTokens: 100_000, todayCost: 2.0)
    let event = try! #require(engine.evaluate(now: at("2026-06-10T12:00:00Z"), data: data))
    if case .briefing(.lunch) = event.kind {} else { Issue.record("lunch kind 아님") }
    #expect(event.title == "오늘 페이스")
    #expect(event.subtitle.contains("200.0K"))  // 100k / 0.5
    #expect(event.subtitle.contains("$4.00"))   // 2.0 / 0.5
}

@MainActor @Test func skipsWhenDataEmpty() {
    let engine = BriefingEngine(calendar: utc)
    let empty = BriefingEngine.BriefingData()
    #expect(engine.evaluate(now: at("2026-06-10T09:00:00Z"), data: empty) == nil)  // morning
    #expect(engine.evaluate(now: at("2026-06-10T12:00:00Z"), data: empty) == nil)  // lunch
    #expect(engine.evaluate(now: at("2026-06-10T20:00:00Z"), data: empty) == nil)  // evening
}
