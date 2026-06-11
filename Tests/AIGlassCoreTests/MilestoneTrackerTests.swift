import Foundation
import Testing
@testable import AIGlassCore

private func at(_ iso: String) -> Date { ISO8601.date(iso)! }

@MainActor @Test func milestoneFiresOnceThenDeduped() {
    let tracker = MilestoneTracker()
    let day = at("2026-06-10T12:00:00Z")
    // 처음 100M 통과 → 100M 반환
    #expect(tracker.check(todayTokens: 120_000_000, day: day, calendar: .utc) == 100_000_000)
    // 같은 날 더 늘었지만 다음 임계(250M)는 안 넘음 → nil
    #expect(tracker.check(todayTokens: 200_000_000, day: day, calendar: .utc) == nil)
    // 250M 통과 → 250M 반환
    #expect(tracker.check(todayTokens: 260_000_000, day: day, calendar: .utc) == 250_000_000)
}

@MainActor @Test func milestoneSkipReturnsHighestOnly() {
    let tracker = MilestoneTracker()
    let day = at("2026-06-10T12:00:00Z")
    // 한 번에 100M/250M/500M 건너뜀 → 최고(500M) 하나만
    #expect(tracker.check(todayTokens: 600_000_000, day: day, calendar: .utc) == 500_000_000)
    // 그 다음은 1B 넘기 전엔 nil
    #expect(tracker.check(todayTokens: 900_000_000, day: day, calendar: .utc) == nil)
    #expect(tracker.check(todayTokens: 1_100_000_000, day: day, calendar: .utc) == 1_000_000_000)
}

@MainActor @Test func milestoneResetsOnDayChange() {
    let tracker = MilestoneTracker()
    let d1 = at("2026-06-10T12:00:00Z")
    let d2 = at("2026-06-11T09:00:00Z")
    #expect(tracker.check(todayTokens: 120_000_000, day: d1, calendar: .utc) == 100_000_000)
    #expect(tracker.check(todayTokens: 120_000_000, day: d1, calendar: .utc) == nil)
    // 다음 날 → 리셋되어 다시 100M 보고
    #expect(tracker.check(todayTokens: 120_000_000, day: d2, calendar: .utc) == 100_000_000)
}

@MainActor @Test func milestoneBelowFirstThresholdIsNil() {
    let tracker = MilestoneTracker()
    let day = at("2026-06-10T12:00:00Z")
    #expect(tracker.check(todayTokens: 99_999_999, day: day, calendar: .utc) == nil)
}

@MainActor @Test func milestoneTopThreshold() {
    let tracker = MilestoneTracker()
    let day = at("2026-06-10T12:00:00Z")
    #expect(tracker.check(todayTokens: 6_000_000_000, day: day, calendar: .utc) == 5_000_000_000)
    // 최고 임계 이후는 nil
    #expect(tracker.check(todayTokens: 9_000_000_000, day: day, calendar: .utc) == nil)
}
