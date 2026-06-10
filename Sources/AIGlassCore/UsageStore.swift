import Foundation
import Observation

@MainActor
@Observable
public final class UsageStore {
    public private(set) var limits: [ServiceID: [LimitWindow]] = [:]
    public private(set) var events: [TokenEvent] = []
    public private(set) var geminiRequestDates: [Date] = []
    public private(set) var lastActivityAt: Date?
    private var dedupKeys: Set<String> = []
    /// 분 단위 토큰 합계 캐시 (key = epoch초 / 60). burn rate 계산용.
    private var minuteBuckets: [Int: Int] = [:]

    /// 이벤트 보존 기간 (일). 이보다 오래된 이벤트는 ingest 시 무시.
    public static let retentionDays = 8

    public init() {}

    public func setLimits(_ windows: [LimitWindow], for service: ServiceID) {
        limits[service] = windows
    }

    public func addEvents(_ batch: [(event: TokenEvent, dedupKey: String?)]) {
        // 수집기는 최근 8일 파일만 읽지만, 파일 내 오래된 라인 방어용 컷오프
        let cutoff = Date().addingTimeInterval(-Double(Self.retentionDays) * 24 * 3600)
        var added = false
        for (event, key) in batch {
            guard event.timestamp >= cutoff else { continue }
            if let key {
                if dedupKeys.contains(key) { continue }
                dedupKeys.insert(key)
            }
            events.append(event)
            minuteBuckets[Int(event.timestamp.timeIntervalSince1970) / 60, default: 0] += event.totalTokens
            added = true
        }
        if added {
            lastActivityAt = Date()
            // 48h 이전 분 버킷 제거 (장기 실행 메모리 hygiene; baseline은 24h만 사용)
            // 컷오프 기준: 배치 내 가장 최신 이벤트 timestamp → 테스트 주입성 보장
            if let newest = batch.map(\.event.timestamp).max() {
                let cutoffMinute = Int(newest.timeIntervalSince1970) / 60 - 48 * 60
                minuteBuckets = minuteBuckets.filter { $0.key > cutoffMinute }
            }
        }
    }

    public func setGeminiRequests(_ dates: [Date]) {
        geminiRequestDates = dates
    }

    public var maxUsedPercent: Double {
        limits.values.flatMap { $0 }.map(\.usedPercent).max() ?? 0
    }

    public func dailyTotals(days: Int, now: Date, calendar: Calendar = .current) -> [(day: Date, tokens: Int)] {
        let today = calendar.startOfDay(for: now)
        var buckets: [Date: Int] = [:]
        for e in events {
            buckets[calendar.startOfDay(for: e.timestamp), default: 0] += e.totalTokens
        }
        return (0..<days).reversed().map { offset in
            let day = calendar.date(byAdding: .day, value: -offset, to: today)!
            return (day, buckets[day] ?? 0)
        }
    }

    public func modelBreakdown(days: Int, now: Date, calendar: Calendar = .current) -> [(model: String, tokens: Int)] {
        let cutoff = calendar.date(byAdding: .day, value: -days, to: now)!
        var byModel: [String: Int] = [:]
        for e in events where e.timestamp >= cutoff {
            byModel[e.model, default: 0] += e.totalTokens
        }
        return byModel.map { (model: $0.key, tokens: $0.value) }.sorted { $0.tokens > $1.tokens }
    }

    public func todayTokens(now: Date, calendar: Calendar = .current) -> Int {
        let start = calendar.startOfDay(for: now)
        return events.filter { $0.timestamp >= start }.reduce(0) { $0 + $1.totalTokens }
    }

    public func todayRequests(now: Date, calendar: Calendar = .current) -> Int {
        let start = calendar.startOfDay(for: now)
        let tokenReqs = events.filter { $0.timestamp >= start }.count
        let geminiReqs = geminiRequestDates.filter { $0 >= start }.count
        return tokenReqs + geminiReqs
    }

    public func tokensPerMinute(windowMinutes: Int, now: Date) -> Double {
        guard windowMinutes > 0 else { return 0 }
        let nowMinute = Int(now.timeIntervalSince1970) / 60
        var total = 0
        for minute in (nowMinute - windowMinutes + 1)...nowMinute {
            total += minuteBuckets[minute] ?? 0
        }
        return Double(total) / Double(windowMinutes)
    }

    /// 최근 24h 중 활동이 있던 분 단위 버킷들의 평균 tokens/min (burn spike 기저선)
    public func activeBaselineRate(now: Date) -> Double {
        let nowMinute = Int(now.timeIntervalSince1970) / 60
        let cutoffMinute = nowMinute - 24 * 60
        let active = minuteBuckets.filter { $0.key > cutoffMinute && $0.key <= nowMinute }
        guard !active.isEmpty else { return 0 }
        return Double(active.values.reduce(0, +)) / Double(active.count)
    }

    /// 펄스 웨이브 진폭 (0...1). 100k tokens/min에서 최대.
    /// 3분 창: 30fps 파형의 jitter와 반응성 균형
    public func activityLevel(now: Date) -> Double {
        min(1.0, tokensPerMinute(windowMinutes: 3, now: now) / 100_000.0)
    }
}
