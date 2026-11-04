import Foundation
import SQLite3

/// 기록 탭 알림의 영구 저장 — `HUDEvent.Kind` ↔ 문자열 키, 그리고 과거 일별 합계에서 마일스톤·신기록 복원.
extension HUDEvent.Kind {
    /// 저장용 키. 복원 가능한 형태만 만든다(서비스·임계 포함).
    public var persistKey: String {
        switch self {
        case .limitThreshold(let s, let p): return "limit:\(s.rawValue):\(p)"
        case .depletionRisk(let s): return "depletion:\(s.rawValue)"
        case .windowReset(let s): return "reset:\(s.rawValue)"
        case .burnSpike: return "spike"
        case .briefing(let p): return "briefing:\(p.rawValue)"
        case .comeback: return "comeback"
        case .milestone: return "milestone"
        case .record: return "record"
        case .update: return "update"
        }
    }

    public init?(persistKey: String) {
        let p = persistKey.split(separator: ":").map(String.init)
        switch (p.first, p.count) {
        case ("limit", 3):
            guard let s = ServiceID(rawValue: p[1]), let pct = Int(p[2]) else { return nil }
            self = .limitThreshold(s, pct)
        case ("depletion", 2):
            guard let s = ServiceID(rawValue: p[1]) else { return nil }
            self = .depletionRisk(s)
        case ("reset", 2):
            guard let s = ServiceID(rawValue: p[1]) else { return nil }
            self = .windowReset(s)
        case ("briefing", 2):
            guard let period = BriefingEngine.Period(rawValue: p[1]) else { return nil }
            self = .briefing(period)
        case ("spike", 1): self = .burnSpike
        case ("comeback", 1): self = .comeback
        case ("milestone", 1): self = .milestone
        case ("record", 1): self = .record
        case ("update", 1): self = .update
        default: return nil
        }
    }
}

/// 저장된 알림 한 건.
public struct StoredEvent {
    public let key: String
    public let event: HUDEvent
    public let date: Date
}

@MainActor
public enum EventReconstruction {
    /// 과거 일별 합계(오름차순, UTC 날짜 `yyyy-MM-dd`)에서 마일스톤·신기록을 다시 만든다.
    /// - 한도/소진/리셋/브리핑은 당시 퍼센트 기록이 없어 복원할 수 없다.
    /// - 시각은 해당 UTC 날짜의 정오(정확한 시각은 알 수 없음). `today`(UTC 날짜 문자열) 이후는 라이브가 만들므로 제외.
    /// - 키가 날짜 기반이라 여러 번 실행해도 중복되지 않는다.
    public static func milestonesAndRecords(dailyTotals: [(day: String, tokens: Int)], today: String,
                                            format: (Int) -> String) -> [StoredEvent] {
        var out: [StoredEvent] = []
        var prevMax = 0
        for (day, tokens) in dailyTotals where day < today {
            guard let date = noon(of: day) else { continue }
            if let crossed = MilestoneTracker.thresholds.last(where: { $0 <= tokens }) {
                out.append(StoredEvent(
                    key: "restored:milestone:\(day)",
                    event: HUDEvent(kind: .milestone, title: "\(format(crossed)) 돌파! 🎉",
                                    subtitle: "그날 누적 \(format(tokens)) tokens · 기록에서 복원", percent: nil),
                    date: date))
            }
            if prevMax > 0, tokens > prevMax {
                out.append(StoredEvent(
                    key: "restored:record:\(day)",
                    event: HUDEvent(kind: .record, title: "신기록! 🏆",
                                    subtitle: "\(format(tokens)) · 종전 \(format(prevMax)) · 기록에서 복원", percent: nil),
                    date: date))
            }
            prevMax = max(prevMax, tokens)
        }
        return out
    }

    private static func noon(of day: String) -> Date? {
        ISO8601.date("\(day)T12:00:00Z")
    }
}

extension DailyStatsStore {
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    func ensureEventTable() {
        sqlite3_exec(rawDB, """
        CREATE TABLE IF NOT EXISTS event_log(
            key TEXT PRIMARY KEY, ts REAL, kind TEXT, title TEXT, subtitle TEXT, percent REAL
        )
        """, nil, nil, nil)
    }

    /// 알림 저장 (같은 key면 무시). 오래된 것은 `keep`개만 남기고 정리.
    public func saveEvent(key: String, event: HUDEvent, date: Date, keep: Int = 200) {
        ensureEventTable()
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(rawDB, "INSERT OR IGNORE INTO event_log VALUES(?,?,?,?,?,?)", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, Self.transient)
        sqlite3_bind_double(stmt, 2, date.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 3, event.kind.persistKey, -1, Self.transient)
        sqlite3_bind_text(stmt, 4, event.title, -1, Self.transient)
        sqlite3_bind_text(stmt, 5, event.subtitle, -1, Self.transient)
        if let p = event.percent { sqlite3_bind_double(stmt, 6, p) } else { sqlite3_bind_null(stmt, 6) }
        sqlite3_step(stmt)
        sqlite3_exec(rawDB, "DELETE FROM event_log WHERE key NOT IN (SELECT key FROM event_log ORDER BY ts DESC LIMIT \(keep))", nil, nil, nil)
    }

    /// 최신 순으로 최대 `limit`개.
    public func recentEvents(limit: Int) -> [StoredEvent] {
        ensureEventTable()
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(rawDB, "SELECT key, ts, kind, title, subtitle, percent FROM event_log ORDER BY ts DESC LIMIT ?", -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        var out: [StoredEvent] = []
        func text(_ i: Int32) -> String { sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "" }
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let kind = HUDEvent.Kind(persistKey: text(2)) else { continue }
            let percent = sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 5)
            out.append(StoredEvent(key: text(0),
                                   event: HUDEvent(kind: kind, title: text(3), subtitle: text(4), percent: percent),
                                   date: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))))
        }
        return out
    }

    /// 일별 토큰 합계 전체 (UTC 날짜 오름차순).
    public func allDailyTokenSums() -> [(day: String, tokens: Int)] {
        var stmt: OpaquePointer?
        let sql = "SELECT day, SUM(input+output+cache_read+cache_create) FROM daily_stats GROUP BY day ORDER BY day"
        guard sqlite3_prepare_v2(rawDB, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [(String, Int)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append((String(cString: sqlite3_column_text(stmt, 0)), Int(sqlite3_column_int64(stmt, 1))))
        }
        return out
    }
}
