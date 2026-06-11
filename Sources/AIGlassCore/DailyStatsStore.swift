import Foundation
import SQLite3

/// SQLite 기반 일별 토큰 통계 영구 저장소.
///
/// (day, service, model, project) 단위로 집계해 `INSERT OR REPLACE`로 저장한다.
/// **주의: REPLACE는 누적이 아니라 대체**이므로, 호출자는 해당 일자의 전체 이벤트를
/// 넘겨야 멱등성이 유지된다 (`UsageStore.events`가 8일 보존이므로 매번 최근 8일 전체를
/// 넘기는 것이 안전).
@MainActor
public final class DailyStatsStore {
    private var db: OpaquePointer?

    // SQLite가 바인딩 문자열을 자체 복사하도록 강제하는 transient destructor.
    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    // day 컬럼용 UTC "yyyy-MM-dd" 포맷터.
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC")!
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// DB 파일을 열고(없으면 생성) 스키마를 보장한다. 실패 시 nil.
    public init?(path: String) {
        let dir = (path as NSString).deletingLastPathComponent
        if !dir.isEmpty {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        let create = """
        CREATE TABLE IF NOT EXISTS daily_stats(
            day TEXT, service TEXT, model TEXT, project TEXT,
            input INTEGER, output INTEGER, cache_read INTEGER, cache_create INTEGER,
            PRIMARY KEY(day, service, model, project)
        )
        """
        guard sqlite3_exec(db, create, nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
    }

    deinit {
        sqlite3_close(db)
    }

    private struct Key: Hashable {
        let day: String
        let service: String
        let model: String
        let project: String
    }

    private struct Agg {
        var input = 0, output = 0, cacheRead = 0, cacheCreate = 0
    }

    /// 이벤트를 (day, service, model, project)로 집계해 `INSERT OR REPLACE`한다.
    /// project가 nil이면 빈 문자열로 저장한다.
    public func upsert(events: [TokenEvent], calendar: Calendar = .current) {
        guard !events.isEmpty else { return }
        var grouped: [Key: Agg] = [:]
        for e in events {
            let key = Key(day: Self.dayFormatter.string(from: e.timestamp),
                          service: e.service.rawValue,
                          model: e.model,
                          project: e.project ?? "")
            var agg = grouped[key] ?? Agg()
            agg.input += e.inputTokens
            agg.output += e.outputTokens
            agg.cacheRead += e.cacheReadTokens
            agg.cacheCreate += e.cacheCreationTokens
            grouped[key] = agg
        }

        let sql = """
        INSERT OR REPLACE INTO daily_stats
        (day, service, model, project, input, output, cache_read, cache_create)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        for (key, agg) in grouped {
            sqlite3_bind_text(stmt, 1, key.day, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, key.service, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, key.model, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, key.project, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 5, Int64(agg.input))
            sqlite3_bind_int64(stmt, 6, Int64(agg.output))
            sqlite3_bind_int64(stmt, 7, Int64(agg.cacheRead))
            sqlite3_bind_int64(stmt, 8, Int64(agg.cacheCreate))
            sqlite3_step(stmt)
            sqlite3_reset(stmt)
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    // 지정 days 범위의 시작일(UTC 문자열) 계산.
    private func cutoffDayString(days: Int, now: Date, calendar: Calendar) -> String {
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: now)) ?? now
        return Self.dayFormatter.string(from: start)
    }

    /// 일별×서비스별 토큰 합계 (tokens = 4컬럼 합). 최근 `days`일.
    public func dailyTotalsByService(days: Int, now: Date, calendar: Calendar = .current) -> [(day: Date, service: ServiceID, tokens: Int)] {
        let cutoff = cutoffDayString(days: days, now: now, calendar: calendar)
        let sql = """
        SELECT day, service, SUM(input + output + cache_read + cache_create)
        FROM daily_stats WHERE day >= ?
        GROUP BY day, service ORDER BY day
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, cutoff, -1, Self.SQLITE_TRANSIENT)

        var result: [(day: Date, service: ServiceID, tokens: Int)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let dayC = sqlite3_column_text(stmt, 0),
                  let svcC = sqlite3_column_text(stmt, 1) else { continue }
            let dayStr = String(cString: dayC)
            let svcStr = String(cString: svcC)
            guard let day = Self.dayFormatter.date(from: dayStr),
                  let service = ServiceID(rawValue: svcStr) else { continue }
            let tokens = Int(sqlite3_column_int64(stmt, 2))
            result.append((day: day, service: service, tokens: tokens))
        }
        return result
    }

    /// project별 토큰 합계 (내림차순). 빈 프로젝트 문자열은 제외. 최근 `days`일.
    public func projectBreakdown(days: Int, now: Date, calendar: Calendar = .current) -> [(project: String, tokens: Int)] {
        let cutoff = cutoffDayString(days: days, now: now, calendar: calendar)
        let sql = """
        SELECT project, SUM(input + output + cache_read + cache_create)
        FROM daily_stats WHERE day >= ? AND project <> ''
        GROUP BY project
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, cutoff, -1, Self.SQLITE_TRANSIENT)

        var result: [(project: String, tokens: Int)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let projC = sqlite3_column_text(stmt, 0) else { continue }
            let project = String(cString: projC)
            let tokens = Int(sqlite3_column_int64(stmt, 1))
            result.append((project: project, tokens: tokens))
        }
        return result.sorted { $0.tokens > $1.tokens }
    }

    /// 최근 `days`일의 추정 비용 합계(USD). model 컬럼 기준으로 CostEstimator 단가를 적용한다.
    public func totalCost(days: Int, now: Date, calendar: Calendar = .current) -> Double {
        let cutoff = cutoffDayString(days: days, now: now, calendar: calendar)
        let sql = """
        SELECT model, SUM(input), SUM(output), SUM(cache_read), SUM(cache_create)
        FROM daily_stats WHERE day >= ?
        GROUP BY model
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, cutoff, -1, Self.SQLITE_TRANSIENT)

        var total = 0.0
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let modelC = sqlite3_column_text(stmt, 0) else { continue }
            let model = String(cString: modelC)
            // 임시 이벤트로 단가 계산 위임 (service/timestamp/project는 비용에 무관).
            let synth = TokenEvent(service: .claude, timestamp: now, model: model,
                                   inputTokens: Int(sqlite3_column_int64(stmt, 1)),
                                   outputTokens: Int(sqlite3_column_int64(stmt, 2)),
                                   cacheReadTokens: Int(sqlite3_column_int64(stmt, 3)),
                                   cacheCreationTokens: Int(sqlite3_column_int64(stmt, 4)))
            total += CostEstimator.cost(of: synth)
        }
        return total
    }
}
