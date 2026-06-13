import Testing
import Foundation
@testable import AIGlassCore

@MainActor @Test func realModePoolNeverEmptyForEveryKind() {
    let kinds: [HUDEvent.Kind] = [
        .limitThreshold(.claude, 90), .depletionRisk(.codex), .windowReset(.gemini),
        .burnSpike, .comeback, .milestone, .record, .update,
        .briefing(.morning), .briefing(.lunch), .briefing(.evening),
    ]
    for kind in kinds {
        #expect(!RealModeMessages.pool(for: kind).isEmpty, "빈 풀: \(kind)")
    }
}

@MainActor @Test func realModeOffReturnsFallbackTitle() {
    let title = RealModeMessages.title(for: .milestone, default: "기본 제목", realMode: false)
    #expect(title == "기본 제목")
}

@MainActor @Test func realModeOnReturnsTitleFromPool() {
    let pool = RealModeMessages.pool(for: .depletionRisk(.claude))
    let title = RealModeMessages.title(for: .depletionRisk(.claude), default: "기본", realMode: true)
    #expect(pool.contains(title))
    #expect(title != "기본")
}

@MainActor @Test func resolveCustomMessagesRotateOnly() {
    // 커스텀이 있으면 그 안에서만 로테이션 (기본/REAL과 섞지 않음).
    let cfg = CustomMessageConfig(messages: ["BAAAM!", "또 너야?"])
    var seen = Set<String>()
    for _ in 0..<60 {
        seen.insert(RealModeMessages.resolve(kind: .milestone, defaultTitle: "기본",
                                             realMode: true, custom: cfg, context: .empty))
    }
    #expect(seen == ["BAAAM!", "또 너야?"])
}

@MainActor @Test func resolveEmptyCustomFallsBackToDefault() {
    // 공백뿐이면 기본 풀로 안전 폴백 (빈 제목 금지).
    let cfg = CustomMessageConfig(messages: ["  ", ""])
    let title = RealModeMessages.resolve(kind: .burnSpike, defaultTitle: "토큰 사용량 급증",
                                         realMode: false, custom: cfg, context: .empty)
    #expect(title == "토큰 사용량 급증")
}

@MainActor @Test func substituteFillsPlaceholders() {
    let ctx = MessageContext(agent: "Claude", usage: 63.4, tokens: 263_000_000, reset: "2h 15m")
    let out = RealModeMessages.substitute("{AGENT} {USAGE} {TOKENS} {RESET}", context: ctx)
    #expect(out == "Claude 63% 263M 2h 15m")
}

@MainActor @Test func substituteMissingVariablesCleanedToSingleSpace() {
    // agent 없음 → "{AGENT} 또 너야?" 앞의 빈 변수와 공백이 정리되어야.
    let ctx = MessageContext()
    let raw = RealModeMessages.substitute("{AGENT} 또 너야?", context: ctx)
    #expect(RealModeMessages.clean(raw) == "또 너야?")
}

@MainActor @Test func customKeyMatchesCustomizableEventRawValue() {
    // UI(CustomizableEvent.rawValue)와 발화(kind.customKey) 키가 일치해야 저장이 연결됨.
    #expect(HUDEvent.Kind.limitThreshold(.claude, 90).customKey == CustomizableEvent.limitThreshold.rawValue)
    #expect(HUDEvent.Kind.briefing(.morning).customKey == CustomizableEvent.briefingMorning.rawValue)
    #expect(HUDEvent.Kind.briefing(.evening).customKey == CustomizableEvent.briefingEvening.rawValue)
    #expect(HUDEvent.Kind.update.customKey == CustomizableEvent.update.rawValue)
}

@MainActor @Test func eventEngineRealModeReplacesTitleKeepsSubtitle() {
    let engine = EventEngine()
    engine.realMode = true
    let now = Date()
    // resetsAt nil → {RESET} 미사용 멘트라 시간 흐름과 무관하게 안정적으로 비교 가능.
    let limits: [ServiceID: [LimitWindow]] = [.claude: [LimitWindow(kind: .session5h, usedPercent: 95, resetsAt: nil)]]
    let events = engine.evaluate(limits: limits, burnRate: 0, baseline: 0, now: now)
    #expect(events.count == 1)
    // 제목은 감성 멘트 풀을 {AGENT}=Claude·{USAGE}=95%로 치환한 결과 중 하나, 부제는 정보 유지.
    let ctx = MessageContext(agent: "Claude", usage: 95)
    let expected = Set(RealModeMessages.pool(for: .limitThreshold(.claude, 90))
        .map { RealModeMessages.clean(RealModeMessages.substitute($0, context: ctx)) })
    #expect(expected.contains(events[0].title))
    #expect(events[0].title.contains("Claude") || events[0].title.contains("95%"))
    #expect(events[0].subtitle.contains("95%"))
}
