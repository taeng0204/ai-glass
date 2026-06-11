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
    #expect(log.records[0].event.subtitle == "30")
    // 가장 오래된(i=0)이 제거됨 — 마지막은 i=1
    #expect(log.records.last?.event.subtitle == "1")
}
