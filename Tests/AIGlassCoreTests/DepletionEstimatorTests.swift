import Foundation
import Testing
@testable import AIGlassCore

@Test func linearIncreaseGivesAccurateETA() {
    let now = ISO8601.date("2026-06-10T12:00:00Z")!
    // 1%/min 증가: 10분 전 40% → now 50%
    var samples: [(Date, Double)] = []
    for m in stride(from: 10, through: 0, by: -1) {
        samples.append((now.addingTimeInterval(-Double(m) * 60), 50 - Double(m)))
    }
    let d = DepletionEstimator.estimate(samples: samples, resetsAt: nil, now: now)
    let est = try! #require(d)
    // 50% → 100%, slope 1%/min → 50분 후
    #expect(abs(est.etaTo100.timeIntervalSince(now) - 50 * 60) < 60)
}

@Test func flatSamplesGiveNil() {
    let now = ISO8601.date("2026-06-10T12:00:00Z")!
    let samples: [(Date, Double)] = (0...10).reversed().map {
        (now.addingTimeInterval(-Double($0) * 60), 42.0)
    }
    #expect(DepletionEstimator.estimate(samples: samples, resetsAt: nil, now: now) == nil)
}

@Test func depleteBeforeResetDetected() {
    let now = ISO8601.date("2026-06-10T12:00:00Z")!
    var samples: [(Date, Double)] = []
    for m in stride(from: 10, through: 0, by: -1) {
        samples.append((now.addingTimeInterval(-Double(m) * 60), 50 - Double(m)))
    }
    // ETA ~ now+50min. 리셋이 now+30min이면 리셋 전엔 소진 안 됨.
    let before = DepletionEstimator.estimate(samples: samples, resetsAt: now.addingTimeInterval(30 * 60), now: now)
    #expect(before?.willDepleteBeforeReset == false)
    // 리셋이 now+90min이면 소진이 먼저.
    let after = DepletionEstimator.estimate(samples: samples, resetsAt: now.addingTimeInterval(90 * 60), now: now)
    #expect(after?.willDepleteBeforeReset == true)
}

@Test func tooFewSamplesGivesNil() {
    let now = ISO8601.date("2026-06-10T12:00:00Z")!
    let samples: [(Date, Double)] = [
        (now.addingTimeInterval(-120), 40),
        (now, 50),
    ]
    #expect(DepletionEstimator.estimate(samples: samples, resetsAt: nil, now: now) == nil)
}

@Test func tooShortRangeGivesNil() {
    let now = ISO8601.date("2026-06-10T12:00:00Z")!
    // 3 샘플이지만 시간 범위 2분 < 5분
    let samples: [(Date, Double)] = [
        (now.addingTimeInterval(-120), 40),
        (now.addingTimeInterval(-60), 45),
        (now, 50),
    ]
    #expect(DepletionEstimator.estimate(samples: samples, resetsAt: nil, now: now) == nil)
}

@MainActor @Test func percentHistoryAppendsAndTrims() {
    let store = UsageStore()
    let base = ISO8601.date("2026-06-10T12:00:00Z")!
    // 70분 전 첫 샘플 → now 시점 호출 시 60분 초과분 제거
    store.setLimits([LimitWindow(kind: .session5h, usedPercent: 10, resetsAt: nil)],
                    for: .claude, at: base.addingTimeInterval(-70 * 60))
    store.setLimits([LimitWindow(kind: .session5h, usedPercent: 30, resetsAt: nil)],
                    for: .claude, at: base.addingTimeInterval(-30 * 60))
    store.setLimits([LimitWindow(kind: .session5h, usedPercent: 40, resetsAt: nil)],
                    for: .claude, at: base)
    let hist = store.percentHistory[.claude]?[.session5h]
    // 70분 전 샘플은 마지막 호출(base) 기준 60분 초과 → 제거. 남은 2개.
    #expect(hist?.count == 2)
    #expect(hist?.last?.percent == 40)
}

@MainActor @Test func depletionConvenienceUsesHighestWindow() {
    let store = UsageStore()
    let base = ISO8601.date("2026-06-10T12:00:00Z")!
    // 두 윈도우: weekly 더 높은 %(선형 증가), session5h 평탄. depletion은 weekly 선택.
    for i in 0..<11 {
        let t = base.addingTimeInterval(Double(i) * 60)
        store.setLimits([
            LimitWindow(kind: .session5h, usedPercent: 10, resetsAt: t.addingTimeInterval(3600)),
            LimitWindow(kind: .weekly, usedPercent: 50 + Double(i), resetsAt: t.addingTimeInterval(7200)),
        ], for: .claude, at: t)
    }
    let now = base.addingTimeInterval(10 * 60)
    let d = try! #require(store.depletion(for: .claude, now: now))
    // weekly slope 1%/min, 최신 60% → 40분 후 100%
    #expect(abs(d.etaTo100.timeIntervalSince(now) - 40 * 60) < 90)
}
