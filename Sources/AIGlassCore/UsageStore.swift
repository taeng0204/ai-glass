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
    /// 분 단위 토큰 합계 캐시 (key = epoch초 / 60). burn rate 계산용. 서비스별로 분리.
    private var minuteBuckets: [ServiceID: [Int: Int]] = [:]

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
            let minute = Int(event.timestamp.timeIntervalSince1970) / 60
            minuteBuckets[event.service, default: [:]][minute, default: 0] += event.totalTokens
            added = true
        }
        if added {
            lastActivityAt = Date()
            // 48h 이전 분 버킷 제거 (장기 실행 메모리 hygiene; baseline은 24h만 사용)
            // 컷오프 기준: 배치 내 가장 최신 이벤트 timestamp → 테스트 주입성 보장
            if let newest = batch.map(\.event.timestamp).max() {
                let cutoffMinute = Int(newest.timeIntervalSince1970) / 60 - 48 * 60
                for svc in minuteBuckets.keys {
                    minuteBuckets[svc] = minuteBuckets[svc]!.filter { $0.key > cutoffMinute }
                }
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

    /// 전 서비스 합산 tokens/min (기존 시그니처 유지).
    public func tokensPerMinute(windowMinutes: Int, now: Date) -> Double {
        guard windowMinutes > 0 else { return 0 }
        let nowMinute = Int(now.timeIntervalSince1970) / 60
        var total = 0
        for svcBuckets in minuteBuckets.values {
            for minute in (nowMinute - windowMinutes + 1)...nowMinute {
                total += svcBuckets[minute] ?? 0
            }
        }
        return Double(total) / Double(windowMinutes)
    }

    /// 특정 서비스의 tokens/min.
    public func tokensPerMinute(service: ServiceID, windowMinutes: Int, now: Date) -> Double {
        guard windowMinutes > 0 else { return 0 }
        let nowMinute = Int(now.timeIntervalSince1970) / 60
        guard let svcBuckets = minuteBuckets[service] else { return 0 }
        var total = 0
        for minute in (nowMinute - windowMinutes + 1)...nowMinute {
            total += svcBuckets[minute] ?? 0
        }
        return Double(total) / Double(windowMinutes)
    }

    /// 최근 windowMinutes 내 서비스별 토큰 비중 (합 1.0). 활동 없으면 빈 dict.
    public func recentShare(windowMinutes: Int = 3, now: Date) -> [ServiceID: Double] {
        guard windowMinutes > 0 else { return [:] }
        let nowMinute = Int(now.timeIntervalSince1970) / 60
        var totals: [ServiceID: Int] = [:]
        for (svc, svcBuckets) in minuteBuckets {
            var sum = 0
            for minute in (nowMinute - windowMinutes + 1)...nowMinute {
                sum += svcBuckets[minute] ?? 0
            }
            if sum > 0 { totals[svc] = sum }
        }
        let grand = totals.values.reduce(0, +)
        guard grand > 0 else { return [:] }
        return totals.mapValues { Double($0) / Double(grand) }
    }

    /// project별 토큰 합계 (내림차순). project == nil 이벤트는 제외.
    public func projectBreakdown(days: Int, now: Date, calendar: Calendar = .current) -> [(project: String, tokens: Int)] {
        let cutoff = calendar.date(byAdding: .day, value: -days, to: now)!
        var byProject: [String: Int] = [:]
        for e in events where e.timestamp >= cutoff {
            guard let proj = e.project else { continue }
            byProject[proj, default: 0] += e.totalTokens
        }
        return byProject.map { (project: $0.key, tokens: $0.value) }.sorted { $0.tokens > $1.tokens }
    }

    /// 일별×서비스별 토큰 합계. 활동이 있는 조합만 반환 (tokens > 0).
    public func dailyTotalsByService(days: Int, now: Date, calendar: Calendar = .current) -> [(day: Date, service: ServiceID, tokens: Int)] {
        let today = calendar.startOfDay(for: now)
        var buckets: [Date: [ServiceID: Int]] = [:]
        for e in events {
            let day = calendar.startOfDay(for: e.timestamp)
            buckets[day, default: [:]][e.service, default: 0] += e.totalTokens
        }
        var result: [(day: Date, service: ServiceID, tokens: Int)] = []
        for offset in (0..<days).reversed() {
            let day = calendar.date(byAdding: .day, value: -offset, to: today)!
            if let svcMap = buckets[day] {
                for (svc, tokens) in svcMap where tokens > 0 {
                    result.append((day: day, service: svc, tokens: tokens))
                }
            }
        }
        return result
    }

    /// 최근 24h 중 활동이 있던 분 단위 버킷들의 평균 tokens/min (burn spike 기저선)
    public func activeBaselineRate(now: Date) -> Double {
        let nowMinute = Int(now.timeIntervalSince1970) / 60
        let cutoffMinute = nowMinute - 24 * 60
        var active: [Int: Int] = [:]
        for svcBuckets in minuteBuckets.values {
            for (minute, tokens) in svcBuckets where minute > cutoffMinute && minute <= nowMinute {
                active[minute, default: 0] += tokens
            }
        }
        guard !active.isEmpty else { return 0 }
        return Double(active.values.reduce(0, +)) / Double(active.count)
    }

    /// 펄스 웨이브 진폭 (0...1). 100k tokens/min에서 최대.
    /// 3분 창: 30fps 파형의 jitter와 반응성 균형
    public func activityLevel(now: Date) -> Double {
        min(1.0, tokensPerMinute(windowMinutes: 3, now: now) / 100_000.0)
    }
}
