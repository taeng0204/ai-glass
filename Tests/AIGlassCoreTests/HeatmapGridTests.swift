import Foundation
import Testing
@testable import AIGlassCore

private func utcDay(_ s: String) -> Date { ISO8601.date(s + "T00:00:00Z")! }

// 2026-11-27은 금요일 → 마지막 열(이번 주)의 토·일은 미래라 빈 칸.
private let today = utcDay("2026-11-27")

@Test func heatmapGridIsFifteenWeeksEndingThisWeek() throws {
    let grid = HeatmapGrid(totals: [:], today: today)
    #expect(grid.weeks.count == 15)
    #expect(grid.weeks.allSatisfy { $0.days.count == 7 })
    let last = try #require(grid.weeks.last)
    #expect(last.days[0]?.day == utcDay("2026-11-23"))   // 월
    #expect(last.days[4]?.day == today)                  // 금
    #expect(last.days[4]?.isToday == true)
    #expect(last.days[5] == nil && last.days[6] == nil)  // 미래
    #expect(grid.weeks.first?.days[0]?.day == utcDay("2026-08-17"))  // 14주 전 월요일
}

@Test func heatmapGridQuantizesAgainstPeriodMax() throws {
    let grid = HeatmapGrid(totals: [
        utcDay("2026-11-23"): 1000,   // 최댓값 → 4
        utcDay("2026-11-24"): 250,    // 25% → 1
        utcDay("2026-11-25"): 500,    // 50% → 2
        utcDay("2026-11-26"): 750,    // 75% → 3
    ], today: today)
    let days = try #require(grid.weeks.last).days
    #expect(days.map { $0?.level } == [4, 1, 2, 3, 0, nil, nil])
    #expect(days[1]?.tokens == 250)
    #expect(days[0]?.isToday == false)
}

@MainActor @Test func heatmapGridLoadsEnabledServicesOnly() throws {
    let path = NSTemporaryDirectory() + "aiglass-test-\(UUID().uuidString)/stats.db"
    let store = try #require(DailyStatsStore(path: path))
    let noon = ISO8601.date("2026-11-27T12:00:00Z")!
    store.upsert(events: [
        TokenEvent(service: .claude, timestamp: noon, model: "claude-opus-5-5",
                   inputTokens: 300, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0),
        TokenEvent(service: .glm, timestamp: noon, model: "glm-5.4",
                   inputTokens: 700, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0),
    ], calendar: .utc)

    let claudeOnly = HeatmapGrid.load(from: store, services: [.claude], now: noon)
    #expect(claudeOnly.weeks.last?.days[4]?.tokens == 300)
    let both = HeatmapGrid.load(from: store, services: [.claude, .glm], now: noon)
    #expect(both.weeks.last?.days[4]?.tokens == 1000)
    #expect(both.weeks.last?.days[4]?.level == 4)
}
