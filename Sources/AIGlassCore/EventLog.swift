import Foundation
import Observation

@MainActor
@Observable
public final class EventLog {
    public struct Record: Identifiable {
        public let id: UUID
        public let event: HUDEvent
        public let date: Date

        public init(id: UUID = UUID(), event: HUDEvent, date: Date) {
            self.id = id
            self.event = event
            self.date = date
        }
    }

    public static let cap = 100

    public private(set) var records: [Record] = []

    private let store: DailyStatsStore?

    /// `store`가 있으면 알림을 DB에 저장하고, 시작 때 저장분을 불러온다.
    public init(store: DailyStatsStore? = nil) {
        self.store = store
        if let store {
            records = store.recentEvents(limit: Self.cap).map {
                Record(event: $0.event, date: $0.date)
            }
        }
    }

    /// 과거 일별 합계에서 복원한 마일스톤·신기록을 합친다 (이미 있으면 무시 — 멱등).
    public func restoreFromHistory(today: String, format: (Int) -> String) {
        guard let store else { return }
        let restored = EventReconstruction.milestonesAndRecords(
            dailyTotals: store.allDailyTokenSums(), today: today, format: format)
        for r in restored { store.saveEvent(key: r.key, event: r.event, date: r.date, keep: 400) }
        records = store.recentEvents(limit: Self.cap).map { Record(event: $0.event, date: $0.date) }
    }

    /// 이벤트를 기록 앞에 추가한다. cap(30) 초과 시 오래된 것을 제거한다.
    public func append(_ event: HUDEvent, at date: Date = Date()) {
        records.insert(Record(event: event, date: date), at: 0)
        store?.saveEvent(key: UUID().uuidString, event: event, date: date)
        if records.count > Self.cap {
            records.removeSubrange(Self.cap...)
        }
    }
}
