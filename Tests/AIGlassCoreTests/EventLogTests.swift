import Foundation
import Testing
@testable import AIGlassCore

@MainActor @Test func eventLogAppendsNewestFirst() {
    let log = EventLog()
    let now = ISO8601.date("2026-06-11T10:00:00Z")!
    let e1 = HUDEvent(kind: .burnSpike, title: "급증", subtitle: "1", percent: nil)
    let e2 = HUDEvent(kind: .burnSpike, title: "급증", subtitle: "2", percent: nil)

    log.append(e1, at: now)
    log.append(e2, at: now.addingTimeInterval(10))

    #expect(log.records.count == 2)
    // 최신(e2)이 앞에 있어야 함
    #expect(log.records[0].event.subtitle == "2")
    #expect(log.records[1].event.subtitle == "1")
}

@MainActor @Test func eventLogCapRemovesOldest() {
    let log = EventLog()
    let base = ISO8601.date("2026-06-11T10:00:00Z")!

    // cap+1개(31개) 삽입 — 각 이벤트를 시간 순서대로 추가
    for i in 0..<(EventLog.cap + 1) {
        let e = HUDEvent(kind: .burnSpike, title: "t\(i)", subtitle: "\(i)", percent: nil)
        log.append(e, at: base.addingTimeInterval(Double(i)))
    }

    // cap(30)개만 남아야 함
    #expect(log.records.count == EventLog.cap)
    // 가장 최신(i=30)이 첫 번째
    #expect(log.records[0].event.subtitle == "\(EventLog.cap)")
    // 가장 오래된(i=0)이 제거됨 — 마지막은 i=1
    #expect(log.records.last?.event.subtitle == "1")
}

@MainActor @Test func eventLogPersistsAcrossInstances() {
    let path = NSTemporaryDirectory() + "evlog-\(UUID().uuidString).db"
    defer { try? FileManager.default.removeItem(atPath: path) }
    let a = EventLog(store: DailyStatsStore(path: path))
    a.append(HUDEvent(kind: .limitThreshold(.claude, 90), title: "90%", subtitle: "s", percent: 90),
             at: Date(timeIntervalSince1970: 1_000))
    a.append(HUDEvent(kind: .briefing(.evening), title: "저녁", subtitle: "x", percent: nil),
             at: Date(timeIntervalSince1970: 2_000))
    let b = EventLog(store: DailyStatsStore(path: path))
    #expect(b.records.count == 2)
    #expect(b.records[0].event.kind == .briefing(.evening))   // 최신 앞
    #expect(b.records[1].event.kind == .limitThreshold(.claude, 90))
    #expect(b.records[1].event.percent == 90)
}

@Test func eventKindPersistKeyRoundTrips() {
    let kinds: [HUDEvent.Kind] = [.limitThreshold(.kimi, 70), .depletionRisk(.codex), .windowReset(.gemini),
                                  .burnSpike, .briefing(.lunch), .comeback, .milestone, .record, .update]
    for k in kinds { #expect(HUDEvent.Kind(persistKey: k.persistKey) == k) }
    #expect(HUDEvent.Kind(persistKey: "garbage") == nil)
}

@MainActor @Test func reconstructsMilestonesAndRecordsFromDailyTotals() {
    let days: [(day: String, tokens: Int)] = [
        ("2026-10-01", 50_000_000), ("2026-10-02", 120_000_000),   // 100M 돌파 + 신기록
        ("2026-10-03", 80_000_000),                                // 해당 없음
        ("2026-10-04", 300_000_000),                               // 250M 돌파 + 신기록
        ("2026-10-05", 999_000_000),                               // 오늘 — 제외
    ]
    let r = EventReconstruction.milestonesAndRecords(dailyTotals: days, today: "2026-10-05") { "\($0 / 1_000_000)M" }
    let keys = Set(r.map(\.key))
    #expect(keys == ["restored:milestone:2026-10-02", "restored:record:2026-10-02",
                     "restored:milestone:2026-10-04", "restored:record:2026-10-04"])
    // 첫날(비교 대상 없음)은 신기록 아님
    #expect(!keys.contains("restored:record:2026-10-01"))
}

@MainActor @Test func restoreFromHistoryIsIdempotent() {
    let path = NSTemporaryDirectory() + "evlog-\(UUID().uuidString).db"
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = DailyStatsStore(path: path)!
    let t = ISO8601.date("2026-10-01T05:00:00Z")!
    let t2 = ISO8601.date("2026-10-02T05:00:00Z")!
    store.upsert(events: [TokenEvent(service: .claude, timestamp: t, model: "m", inputTokens: 60_000_000, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0, project: nil),
                          TokenEvent(service: .claude, timestamp: t2, model: "m", inputTokens: 150_000_000, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0, project: nil)],
                 calendar: .utc)
    let log = EventLog(store: store)
    log.restoreFromHistory(today: "2026-10-10") { "\($0)" }
    let first = log.records.count
    log.restoreFromHistory(today: "2026-10-10") { "\($0)" }
    #expect(first == 2)              // milestone + record (10/2)
    #expect(log.records.count == first)
}
