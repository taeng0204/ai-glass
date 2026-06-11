import Foundation

/// 시간대별 1회 HUD 확장 브리핑을 생성한다. 발화 상태(lastFired)는 호출자가 보관/저장한다.
@MainActor
public final class BriefingEngine {
    /// 브리핑 시간대. 시각(로컬 캘린더 hour) 구간으로 판정.
    public enum Period: String, CaseIterable, Sendable {
        case morning, lunch, evening

        /// 이 Period의 hour 구간 (반열림 [lower, upper)).
        var hourRange: Range<Int> {
            switch self {
            case .morning: return 8..<11
            case .lunch: return 12..<14
            case .evening: return 18..<22
            }
        }

        /// 주어진 hour가 속한 Period (없으면 nil).
        static func forHour(_ hour: Int) -> Period? {
            allCases.first { $0.hourRange.contains(hour) }
        }
    }

    /// 브리핑 본문에 필요한 집계 데이터. 호출자가 store/statsStore에서 구성한다.
    public struct BriefingData {
        public var yesterdayTokens: Int
        public var yesterdayCost: Double
        public var yesterdayTopProject: String?
        public var todayTokens: Int
        public var todayCost: Double
        public var todayTopService: (service: ServiceID, share: Double)?
        public init(yesterdayTokens: Int = 0, yesterdayCost: Double = 0,
                    yesterdayTopProject: String? = nil,
                    todayTokens: Int = 0, todayCost: Double = 0,
                    todayTopService: (service: ServiceID, share: Double)? = nil) {
            self.yesterdayTokens = yesterdayTokens
            self.yesterdayCost = yesterdayCost
            self.yesterdayTopProject = yesterdayTopProject
            self.todayTokens = todayTokens
            self.todayCost = todayCost
            self.todayTopService = todayTopService
        }
    }

    /// Period별 마지막 발화 시각. 외부 주입/저장(UserDefaults 등)은 호출자 책임.
    public var lastFired: [Period: Date] = [:]
    /// Period 구간 판정에 쓰는 캘린더. 테스트는 UTC 주입.
    public var calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    /// 현재 시각이 어느 Period 구간이고 그 Period가 오늘 미발화면 HUDEvent를 만들고 lastFired를 갱신한다.
    /// - 시간대 밖, 데이터 0(tokens/cost), 오늘 이미 발화, lunch 외삽 불가(경과<4h) 시 nil.
    public func evaluate(now: Date, data: BriefingData) -> HUDEvent? {
        let hour = calendar.component(.hour, from: now)
        guard let period = Period.forHour(hour) else { return nil }

        // 오늘 이미 발화했는지: lastFired가 같은 날이면 스킵.
        if let last = lastFired[period], calendar.isDate(last, inSameDayAs: now) {
            return nil
        }

        guard let event = makeEvent(period: period, now: now, data: data) else { return nil }
        lastFired[period] = now
        return event
    }

    private func makeEvent(period: Period, now: Date, data: BriefingData) -> HUDEvent? {
        switch period {
        case .morning:
            guard data.yesterdayTokens > 0 || data.yesterdayCost > 0 else { return nil }
            var subtitle = "어제: \(Self.formatTokens(data.yesterdayTokens)) tokens · ~\(Self.formatCost(data.yesterdayCost))"
            if let project = data.yesterdayTopProject {
                subtitle += " · 주로 \(project)"
            }
            return HUDEvent(kind: .briefing(.morning), title: "어제 사용 브리핑",
                            subtitle: subtitle, percent: nil)

        case .lunch:
            guard data.todayTokens > 0 || data.todayCost > 0 else { return nil }
            // 자정~now 경과 비율로 외삽. 경과 < 4h면 발화 안 함.
            let midnight = calendar.startOfDay(for: now)
            let elapsed = now.timeIntervalSince(midnight)
            guard elapsed >= 4 * 3600 else { return nil }
            let dayFraction = elapsed / (24 * 3600)
            let projectedTokens = Int(Double(data.todayTokens) / dayFraction)
            let projectedCost = data.todayCost / dayFraction
            let subtitle = "이 페이스면 자정까지 ~\(Self.formatTokens(projectedTokens)) (~\(Self.formatCost(projectedCost)))"
            return HUDEvent(kind: .briefing(.lunch), title: "오늘 페이스",
                            subtitle: subtitle, percent: nil)

        case .evening:
            guard data.todayTokens > 0 || data.todayCost > 0 else { return nil }
            var subtitle = "오늘: \(Self.formatTokens(data.todayTokens)) tokens · ~\(Self.formatCost(data.todayCost))"
            if let top = data.todayTopService {
                subtitle += " · \(top.service.displayName) \(Int((top.share * 100).rounded()))% 비중"
            }
            return HUDEvent(kind: .briefing(.evening), title: "오늘 사용 요약",
                            subtitle: subtitle, percent: nil)
        }
    }

    static func formatTokens(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...: return String(format: "%.1fK", Double(n) / 1_000)
        default: return "\(n)"
        }
    }

    static func formatCost(_ cost: Double) -> String {
        String(format: "$%.2f", cost)
    }
}
