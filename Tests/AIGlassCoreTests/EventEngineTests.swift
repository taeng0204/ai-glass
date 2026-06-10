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
