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
    let dep: [ServiceID: Depletion] = [.claude: Depletion(etaTo100: now.addingTimeInterval(20 * 60), willDepleteBeforeReset: true)]
    let events = engine.evaluate(limits: limits, burnRate: 0, baseline: 0, now: now, depletions: dep)
    #expect(events.count == 1)
    guard case .depletionRisk(.claude) = events[0].kind else {
        Issue.record("expected depletionRisk(.claude), got \(events[0].kind)")
        return
    }
    #expect(events[0].title.contains("소진 임박"))
    // 30분 쿨다운 내 재발화 없음
    #expect(engine.evaluate(limits: limits, burnRate: 0, baseline: 0, now: now.addingTimeInterval(60), depletions: dep).isEmpty)
    // 쿨다운 경과 후 재발화
    #expect(engine.evaluate(limits: limits, burnRate: 0, baseline: 0, now: now.addingTimeInterval(31 * 60), depletions: dep).count == 1)
}

@MainActor @Test func depletionNotFiredWhenNotBeforeReset() {
    let engine = EventEngine()
    let now = Date()
    let dep: [ServiceID: Depletion] = [.claude: Depletion(etaTo100: now.addingTimeInterval(20 * 60), willDepleteBeforeReset: false)]
    #expect(engine.evaluate(limits: [:], burnRate: 0, baseline: 0, now: now, depletions: dep).isEmpty)
}

@MainActor @Test func priorityThresholdBeforeDepletionBeforeResetBeforeSpike() {
    let engine = EventEngine()
    let now = Date()
    // threshold 교차(95) + depletion + spike 동시
    let limits: [ServiceID: [LimitWindow]] = [.codex: [LimitWindow(kind: .session5h, usedPercent: 95, resetsAt: now.addingTimeInterval(3600))]]
    let dep: [ServiceID: Depletion] = [.codex: Depletion(etaTo100: now.addingTimeInterval(20 * 60), willDepleteBeforeReset: true)]
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
