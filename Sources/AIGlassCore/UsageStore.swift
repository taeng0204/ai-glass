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

    public init() {}

    public func setLimits(_ windows: [LimitWindow], for service: ServiceID) {
        limits[service] = windows
    }

    public func addEvents(_ batch: [(event: TokenEvent, dedupKey: String?)]) {
        var added = false
        for (event, key) in batch {
            if let key {
                if dedupKeys.contains(key) { continue }
                dedupKeys.insert(key)
            }
            events.append(event)
            added = true
        }
        if added { lastActivityAt = Date() }
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
        return byModel.map { ($0.key, $0.value) }.sorted { $0.1 > $1.1 }
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
        let cutoff = now.addingTimeInterval(-Double(windowMinutes) * 60)
        let total = events.filter { $0.timestamp >= cutoff && $0.timestamp <= now }
            .reduce(0) { $0 + $1.totalTokens }
        return Double(total) / Double(windowMinutes)
    }

    /// 최근 24h 중 활동이 있던 분 단위 버킷들의 평균 tokens/min (burn spike 기저선)
    public func activeBaselineRate(now: Date) -> Double {
        let cutoff = now.addingTimeInterval(-24 * 3600)
        var buckets: [Int: Int] = [:]
        for e in events where e.timestamp >= cutoff {
            buckets[Int(e.timestamp.timeIntervalSince1970) / 60, default: 0] += e.totalTokens
        }
        guard !buckets.isEmpty else { return 0 }
        return Double(buckets.values.reduce(0, +)) / Double(buckets.count)
    }

    /// 펄스 웨이브 진폭 (0...1). 100k tokens/min(3분 창 기준)에서 최대.
    public func activityLevel(now: Date) -> Double {
        min(1.0, tokensPerMinute(windowMinutes: 3, now: now) / 100_000.0)
    }
}
