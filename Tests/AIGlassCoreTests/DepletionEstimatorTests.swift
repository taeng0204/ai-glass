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

@MainActor @Test func depletionUsesSession5hAndReturnsOnlyWhenBeforeReset() {
    let store = UsageStore()
    let base = ISO8601.date("2026-06-10T12:00:00Z")!
    // session5h 선형 증가(1%/min), weekly는 평탄. 5h 전용 추정이어야 한다.
    // 리셋이 충분히 멀어(now+2h) 50분 후 소진이 리셋 전 → 반환됨.
    for i in 0..<11 {
        let t = base.addingTimeInterval(Double(i) * 60)
        store.setLimits([
            LimitWindow(kind: .session5h, usedPercent: 40 + Double(i), resetsAt: base.addingTimeInterval(2 * 3600)),
            LimitWindow(kind: .weekly, usedPercent: 90, resetsAt: t.addingTimeInterval(7200)),
        ], for: .claude, at: t)
    }
    let now = base.addingTimeInterval(10 * 60)
    let d = try! #require(store.depletion(for: .claude, now: now))
    #expect(d.kind == .session5h)
    // 최신 50%, slope 1%/min → 50분 후 100%
    #expect(abs(d.etaTo100.timeIntervalSince(now) - 50 * 60) < 90)
    #expect(d.willDepleteBeforeReset)
}

@MainActor @Test func depletionNilWhenSession5hResetsBeforeDepletion() {
    let store = UsageStore()
    let base = ISO8601.date("2026-06-10T12:00:00Z")!
    // 5h 50분 후 소진 예정이지만 리셋이 now+30min → 리셋 후 소진은 표시 안 함(nil).
    for i in 0..<11 {
        let t = base.addingTimeInterval(Double(i) * 60)
        store.setLimits([
            LimitWindow(kind: .session5h, usedPercent: 40 + Double(i), resetsAt: base.addingTimeInterval(40 * 60)),
        ], for: .claude, at: t)
    }
    let now = base.addingTimeInterval(10 * 60)
    #expect(store.depletion(for: .claude, now: now) == nil)
}

// MARK: - 주간 일단위 추정

@Test func weeklyDailyRateAveragesPositivePairsOnly() {
    let day0 = ISO8601.date("2026-06-08T00:00:00Z")!
    // 10 → 20 (+10) → 35 (+15) → 5 (리셋, -30, 제외) → 12 (+7)
    let snaps: [(day: Date, percent: Double)] = [
        (day0, 10), (day0.addingTimeInterval(86400), 20),
        (day0.addingTimeInterval(2 * 86400), 35),
        (day0.addingTimeInterval(3 * 86400), 5),
        (day0.addingTimeInterval(4 * 86400), 12),
    ]
    let rate = try! #require(DepletionEstimator.weeklyDailyRate(snapshots: snaps))
    // 양수 페어 (10, 15, 7) 평균 = 32/3
    #expect(abs(rate - 32.0 / 3.0) < 1e-9)
}

@Test func weeklyDailyRateNilWhenTooFewPairs() {
    let day0 = ISO8601.date("2026-06-08T00:00:00Z")!
    #expect(DepletionEstimator.weeklyDailyRate(snapshots: [(day0, 10)]) == nil)
    // 음수만 있는 경우(양수 페어 0)도 nil
    let dropping: [(day: Date, percent: Double)] = [(day0, 30), (day0.addingTimeInterval(86400), 5)]
    #expect(DepletionEstimator.weeklyDailyRate(snapshots: dropping) == nil)
}

@Test func weeklyDepletionComputesDaysAndBeforeReset() {
    let now = ISO8601.date("2026-06-10T12:00:00Z")!
    // current 60%, rate 10%/day → 40% 남음 → 4일 후 100%.
    let d = try! #require(DepletionEstimator.weeklyDepletion(
        current: 60, rate: 10, resetsAt: now.addingTimeInterval(7 * 86400), now: now))
    #expect(d.kind == .weekly)
    #expect(abs(d.etaTo100.timeIntervalSince(now) - 4 * 86400) < 60)
    #expect(d.willDepleteBeforeReset)
    // 리셋이 2일 후면 소진은 리셋 후 → false
    let d2 = try! #require(DepletionEstimator.weeklyDepletion(
        current: 60, rate: 10, resetsAt: now.addingTimeInterval(2 * 86400), now: now))
    #expect(d2.willDepleteBeforeReset == false)
}

@Test func weeklyDepletionNilForNegligibleRate() {
    let now = ISO8601.date("2026-06-10T12:00:00Z")!
    // rate 0.3%/day는 노이즈 → nil
    #expect(DepletionEstimator.weeklyDepletion(current: 60, rate: 0.3, resetsAt: nil, now: now) == nil)
}

@Test func weeklyDailyRateNormalizesGapPairs() {
    let day0 = ISO8601.date("2026-06-01T00:00:00Z")!
    // day0(0%) → day3(+15%) : 3일 간격 → 5%/day
    // day3(15%) → day4(-10%) : 리셋으로 음수 → 제외
    // day4(5%) → day5(+5%) : 1일 간격 → 5%/day
    // 양수 페어 평균 = 5%/day
    let snaps: [(day: Date, percent: Double)] = [
        (day0, 0),
        (day0.addingTimeInterval(3 * 86400), 15),
        (day0.addingTimeInterval(4 * 86400), 5),
        (day0.addingTimeInterval(5 * 86400), 10),
    ]
    let rate = try! #require(DepletionEstimator.weeklyDailyRate(snapshots: snaps))
    #expect(abs(rate - 5.0) < 1e-9)
}
