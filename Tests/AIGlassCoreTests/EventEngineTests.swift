import Foundation
import Testing
@testable import AIGlassCore

@MainActor @Test func firesOnThresholdCrossing() {
    let engine = EventEngine()
    let now = Date()
    let below: [ServiceID: [LimitWindow]] = [.codex: [LimitWindow(kind: .session5h, usedPercent: 65, resetsAt: nil)]]
    let above: [ServiceID: [LimitWindow]] = [.codex: [LimitWindow(kind: .session5h, usedPercent: 73, resetsAt: nil)]]

    #expect(engine.evaluate(limits: below, burnRate: 0, baseline: 0, now: now).isEmpty)
    let events = engine.evaluate(limits: above, burnRate: 0, baseline: 0, now: now)
    #expect(events.count == 1)
    guard case .limitThreshold(.codex, 70) = events[0].kind else {
        Issue.record("expected limitThreshold(.codex, 70), got \(events[0].kind)")
        return
    }
    // 같은 상태 재평가 → 재발화 없음
    #expect(engine.evaluate(limits: above, burnRate: 0, baseline: 0, now: now).isEmpty)
}

@MainActor @Test func firesOnWindowReset() {
    let engine = EventEngine()
    let now = Date()
    let high: [ServiceID: [LimitWindow]] = [.claude: [LimitWindow(kind: .session5h, usedPercent: 80, resetsAt: nil)]]
    let reset: [ServiceID: [LimitWindow]] = [.claude: [LimitWindow(kind: .session5h, usedPercent: 2, resetsAt: nil)]]
    _ = engine.evaluate(limits: high, burnRate: 0, baseline: 0, now: now)
    let events = engine.evaluate(limits: reset, burnRate: 0, baseline: 0, now: now)
    #expect(events.count == 1)
    guard case .windowReset(.claude) = events[0].kind else {
        Issue.record("expected windowReset(.claude), got \(events[0].kind)")
        return
    }
}

@MainActor @Test func firesBurnSpikeWithCooldown() {
    let engine = EventEngine()
    let now = Date()
    let spike = engine.evaluate(limits: [:], burnRate: 9000, baseline: 1000, now: now)
    #expect(spike.count == 1)
    guard case .burnSpike = spike[0].kind else {
        Issue.record("expected burnSpike, got \(spike[0].kind)")
        return
    }
    // 쿨다운(30분) 내 재발화 없음
    #expect(engine.evaluate(limits: [:], burnRate: 9000, baseline: 1000, now: now.addingTimeInterval(60)).isEmpty)
    // 쿨다운 지나면 재발화
    #expect(engine.evaluate(limits: [:], burnRate: 9000, baseline: 1000, now: now.addingTimeInterval(31 * 60)).count == 1)
}

@MainActor @Test func priorityOrdersThresholdFirst() {
    let engine = EventEngine()
    let now = Date()
    let limits: [ServiceID: [LimitWindow]] = [.codex: [LimitWindow(kind: .session5h, usedPercent: 95, resetsAt: nil)]]
    let events = engine.evaluate(limits: limits, burnRate: 9000, baseline: 1000, now: now)
    #expect(events.count == 2)
    guard case .limitThreshold = events[0].kind else {
        Issue.record("threshold should come first")
        return
    }
}

@MainActor @Test func thresholdSubtitleIncludesCountdown() {
    let engine = EventEngine()
    let now = Date()
    let limits: [ServiceID: [LimitWindow]] = [.claude: [LimitWindow(kind: .session5h, usedPercent: 75, resetsAt: now.addingTimeInterval(2 * 3600 + 14 * 60))]]
    let events = engine.evaluate(limits: limits, burnRate: 0, baseline: 0, now: now)
    #expect(events.first?.subtitle.contains("2h 14m") == true)
}

@MainActor @Test func firesDepletionRiskWithCooldown() {
    let engine = EventEngine()
    let now = Date()
    let limits: [ServiceID: [LimitWindow]] = [.claude: [LimitWindow(kind: .session5h, usedPercent: 60, resetsAt: now.addingTimeInterval(3600))]]
    let dep: [ServiceID: [Depletion]] = [.claude: [Depletion(kind: .session5h, etaTo100: now.addingTimeInterval(20 * 60), willDepleteBeforeReset: true)]]
    let events = engine.evaluate(limits: limits, burnRate: 0, baseline: 0, now: now, depletions: dep)
    #expect(events.count == 1)
    guard case .depletionRisk(.claude) = events[0].kind else {
        Issue.record("expected depletionRisk(.claude), got \(events[0].kind)")
        return
    }
    #expect(events[0].title.contains("소진 임박"))
    #expect(events[0].subtitle.contains("5h 한도 소진"))
    // 30분 쿨다운 내 재발화 없음
    #expect(engine.evaluate(limits: limits, burnRate: 0, baseline: 0, now: now.addingTimeInterval(60), depletions: dep).isEmpty)
    // 쿨다운 경과 후 재발화
    #expect(engine.evaluate(limits: limits, burnRate: 0, baseline: 0, now: now.addingTimeInterval(31 * 60), depletions: dep).count == 1)
}

@MainActor @Test func firesWeeklyDepletionMessage() {
    let engine = EventEngine()
    let now = Date()
    let limits: [ServiceID: [LimitWindow]] = [.claude: [LimitWindow(kind: .weekly, usedPercent: 60, resetsAt: now.addingTimeInterval(7 * 86400))]]
    // 리셋 7일, 소진 4일 → 4 ≤ 7×0.6(4.2) → 발화.
    let dep: [ServiceID: [Depletion]] = [.claude: [Depletion(kind: .weekly, etaTo100: now.addingTimeInterval(4 * 86400), willDepleteBeforeReset: true, resetsAt: now.addingTimeInterval(7 * 86400))]]
    let events = engine.evaluate(limits: limits, burnRate: 0, baseline: 0, now: now, depletions: dep)
    #expect(events.count == 1)
    #expect(events[0].subtitle == "이 추세면 약 4일 후 주간 한도 소진")
}

@MainActor @Test func weeklyDepletionSuppressedWhenNearReset() {
    // 사용자 시나리오: 리셋 4일 남았는데 소진도 4일 후 — 리셋과 사실상 동시라 무의미.
    // 4 ≤ 4×0.6(2.4)? No → 발화 안 함.
    let engine = EventEngine()
    let now = Date()
    let reset = now.addingTimeInterval(4 * 86400)
    let dep: [ServiceID: [Depletion]] = [.claude: [Depletion(kind: .weekly, etaTo100: now.addingTimeInterval(4 * 86400), willDepleteBeforeReset: true, resetsAt: reset)]]
    #expect(engine.evaluate(limits: [:], burnRate: 0, baseline: 0, now: now, depletions: dep).isEmpty)
}

@MainActor @Test func weeklyDepletionTodayMessageWhenWithin24h() {
    // 리셋 2일, 소진 0.5일 → 0.5 ≤ 2×0.6(1.2) → 발화. 24h 이내라 "오늘".
    let engine = EventEngine()
    let now = Date()
    let dep: [ServiceID: [Depletion]] = [.claude: [Depletion(kind: .weekly, etaTo100: now.addingTimeInterval(12 * 3600), willDepleteBeforeReset: true, resetsAt: now.addingTimeInterval(2 * 86400))]]
    let events = engine.evaluate(limits: [:], burnRate: 0, baseline: 0, now: now, depletions: dep)
    #expect(events.count == 1)
    #expect(events[0].subtitle == "이 추세면 오늘 안에 주간 한도 소진")
}

@MainActor @Test func weeklyDepletionSuppressedOnResetDay() {
    // 리셋까지 0.5일(당일) → minLead(1일) 미만이라 발화 안 함.
    let engine = EventEngine()
    let now = Date()
    let dep: [ServiceID: [Depletion]] = [.claude: [Depletion(kind: .weekly, etaTo100: now.addingTimeInterval(3 * 3600), willDepleteBeforeReset: true, resetsAt: now.addingTimeInterval(12 * 3600))]]
    #expect(engine.evaluate(limits: [:], burnRate: 0, baseline: 0, now: now, depletions: dep).isEmpty)
}

@MainActor @Test func fiveHourDepletionNotAffectedByWeeklyRule() {
    let engine = EventEngine()
    let now = Date()
    // 5h 소진 예상이 5일 뒤(비현실적이지만)라도 시간 윈도우는 비율 제한 미적용 → 발화.
    let dep: [ServiceID: [Depletion]] = [.claude: [Depletion(kind: .session5h, etaTo100: now.addingTimeInterval(5 * 86400), willDepleteBeforeReset: true)]]
    #expect(engine.evaluate(limits: [:], burnRate: 0, baseline: 0, now: now, depletions: dep).count == 1)
}

@MainActor @Test func weeklyDepletionUsesLongCooldown() {
    let engine = EventEngine()  // weeklyDepletionCooldown 기본 12시간
    let now = Date()
    // 리셋 6일, 소진 3일 → 3 ≤ 3.6 발화.
    let dep: [ServiceID: [Depletion]] = [.claude: [Depletion(kind: .weekly, etaTo100: now.addingTimeInterval(3 * 86400), willDepleteBeforeReset: true, resetsAt: now.addingTimeInterval(6 * 86400))]]
    #expect(engine.evaluate(limits: [:], burnRate: 0, baseline: 0, now: now, depletions: dep).count == 1)
    // 30분 뒤 — 5h라면 발화하지만 주간은 12h 쿨다운이라 아직 침묵.
    #expect(engine.evaluate(limits: [:], burnRate: 0, baseline: 0, now: now.addingTimeInterval(31 * 60), depletions: dep).isEmpty)
    // 12시간 경과 후 재발화.
    #expect(engine.evaluate(limits: [:], burnRate: 0, baseline: 0, now: now.addingTimeInterval(12 * 3600 + 60), depletions: dep).count == 1)
}

@MainActor @Test func fivesAndWeeklyHaveSeparateCooldowns() {
    let engine = EventEngine()
    let now = Date()
    let dep: [ServiceID: [Depletion]] = [.claude: [
        Depletion(kind: .session5h, etaTo100: now.addingTimeInterval(20 * 60), willDepleteBeforeReset: true),
        Depletion(kind: .weekly, etaTo100: now.addingTimeInterval(3 * 86400), willDepleteBeforeReset: true, resetsAt: now.addingTimeInterval(6 * 86400)),
    ]]
    // 둘 다 첫 발화 — 5h가 주간보다 먼저.
    let events = engine.evaluate(limits: [:], burnRate: 0, baseline: 0, now: now, depletions: dep)
    #expect(events.count == 2)
    #expect(events[0].subtitle.contains("5h 한도"))
    #expect(events[1].subtitle.contains("주간 한도"))
}

@MainActor @Test func depletionNotFiredWhenNotBeforeReset() {
    let engine = EventEngine()
    let now = Date()
    let dep: [ServiceID: [Depletion]] = [.claude: [Depletion(kind: .session5h, etaTo100: now.addingTimeInterval(20 * 60), willDepleteBeforeReset: false)]]
    #expect(engine.evaluate(limits: [:], burnRate: 0, baseline: 0, now: now, depletions: dep).isEmpty)
}

@MainActor @Test func priorityThresholdBeforeDepletionBeforeResetBeforeSpike() {
    let engine = EventEngine()
    let now = Date()
    // threshold 교차(95) + depletion + spike 동시
    let limits: [ServiceID: [LimitWindow]] = [.codex: [LimitWindow(kind: .session5h, usedPercent: 95, resetsAt: now.addingTimeInterval(3600))]]
    let dep: [ServiceID: [Depletion]] = [.codex: [Depletion(kind: .session5h, etaTo100: now.addingTimeInterval(20 * 60), willDepleteBeforeReset: true)]]
    let events = engine.evaluate(limits: limits, burnRate: 9000, baseline: 1000, now: now, depletions: dep)
    guard case .limitThreshold = events[0].kind else { Issue.record("threshold first"); return }
    guard case .depletionRisk = events[1].kind else { Issue.record("depletion second"); return }
    guard case .burnSpike = events[2].kind else { Issue.record("spike last"); return }
}

@MainActor @Test func reportProviderReplacesResetSubtitle() {
    let engine = EventEngine()
    let now = Date()
    let high: [ServiceID: [LimitWindow]] = [.claude: [LimitWindow(kind: .session5h, usedPercent: 80, resetsAt: nil)]]
    let reset: [ServiceID: [LimitWindow]] = [.claude: [LimitWindow(kind: .session5h, usedPercent: 2, resetsAt: nil)]]
    _ = engine.evaluate(limits: high, burnRate: 0, baseline: 0, now: now)
    let events = engine.evaluate(limits: reset, burnRate: 0, baseline: 0, now: now,
                                 reportProvider: { svc in "지난 세션: 1.0M tokens (\(svc.rawValue))" })
    #expect(events.count == 1)
    guard case .windowReset(.claude) = events[0].kind else { Issue.record("reset"); return }
    #expect(events[0].subtitle == "지난 세션: 1.0M tokens (claude)")
}

// MARK: - countdown d-포맷

@MainActor @Test func countdownUnder24hReturnsHhMm() {
    let now = Date(timeIntervalSinceReferenceDate: 0)
    // 2h 14m
    let target = now.addingTimeInterval(2 * 3600 + 14 * 60)
    #expect(EventEngine.countdown(to: target, from: now) == "2h 14m")
}

@MainActor @Test func countdownUnder1hReturnsMmOnly() {
    let now = Date(timeIntervalSinceReferenceDate: 0)
    let target = now.addingTimeInterval(45 * 60)
    #expect(EventEngine.countdown(to: target, from: now) == "45m")
}

@MainActor @Test func countdownExact24hReturnsDFormat() {
    let now = Date(timeIntervalSinceReferenceDate: 0)
    // 정확히 24h → 1d 0h 0m
    let target = now.addingTimeInterval(24 * 3600)
    #expect(EventEngine.countdown(to: target, from: now) == "1d 0h 0m")
}

@MainActor @Test func countdown25hReturnsDFormat() {
    let now = Date(timeIntervalSinceReferenceDate: 0)
    // 25h = 1d 1h 0m
    let target = now.addingTimeInterval(25 * 3600)
    #expect(EventEngine.countdown(to: target, from: now) == "1d 1h 0m")
}

@MainActor @Test func countdownPreservesMinutesInDFormat() {
    let now = Date(timeIntervalSinceReferenceDate: 0)
    // 25h 30m = 1d 1h 30m
    let target = now.addingTimeInterval(25 * 3600 + 30 * 60)
    #expect(EventEngine.countdown(to: target, from: now) == "1d 1h 30m")
}
