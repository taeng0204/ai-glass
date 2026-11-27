import Foundation

/// 잔디 히트맵 격자: 최근 `weekCount`주 × 7일(월~일). 열 = 주(왼쪽=과거, 오른쪽=이번 주), 행 = 요일(위=월).
/// 칸마다 날짜·토큰·농도 단계(0~4)를 **한 번에** 계산해 둔다.
///
/// 예전에는 뷰가 칸마다 기간 최댓값을 다시 구하면서 통계 DB를 매번 새로 읽었다. 그래서 한 번 그릴 때 ~106회 조회
/// (실측 ~950ms)가 일어났고, 잔디를 열 때와 칸에 마우스를 올릴 때마다 앱이 멈췄다.
public struct HeatmapGrid: Equatable, Sendable {
    public struct Day: Equatable, Identifiable, Sendable {
        public let day: Date
        public let tokens: Int
        /// 0 = 빈 셀, 1~4 = 기간 최댓값 대비 25% 단위 농도.
        public let level: Int
        public let isToday: Bool
        public var id: TimeInterval { day.timeIntervalSinceReferenceDate }
    }

    public struct Week: Equatable, Identifiable, Sendable {
        /// 0 = 가장 과거 주 (등장 애니메이션 stagger 순서).
        public let index: Int
        /// 7칸 (월~일). 미래 날짜는 nil.
        public let days: [Day?]
        public var id: Int { index }
    }

    public static let defaultWeeks = 15

    /// 통계 DB의 day가 UTC 날짜라서(30일 추이와 같은 기준) 격자도 UTC로 짠다. 주는 월요일 시작.
    public static let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        cal.firstWeekday = 2
        return cal
    }()

    public let weeks: [Week]

    /// - Parameter totals: UTC 자정 → 그날 토큰 합.
    public init(totals: [Date: Int], today: Date, weekCount: Int = HeatmapGrid.defaultWeeks) {
        let cal = Self.calendar
        let today = cal.startOfDay(for: today)
        let maxTokens = max(1, totals.values.max() ?? 0)
        // 오른쪽 끝 열이 이번 주가 되도록, 이번 주 월요일에서 (weekCount-1)주 전 월요일부터 시작한다.
        let weekday = cal.component(.weekday, from: today)   // 1=일 … 2=월
        let daysSinceMonday = (weekday + 5) % 7               // 월=0, 일=6
        guard let thisMonday = cal.date(byAdding: .day, value: -daysSinceMonday, to: today),
              let firstMonday = cal.date(byAdding: .day, value: -(weekCount - 1) * 7, to: thisMonday)
        else { weeks = []; return }

        var weeks: [Week] = []
        for w in 0..<weekCount {
            var days: [Day?] = []
            for d in 0..<7 {
                guard let day = cal.date(byAdding: .day, value: w * 7 + d, to: firstMonday), day <= today else {
                    days.append(nil)
                    continue
                }
                let tokens = totals[day] ?? 0
                days.append(Day(day: day, tokens: tokens,
                                level: Self.level(tokens: tokens, max: maxTokens),
                                isToday: day == today))
            }
            weeks.append(Week(index: w, days: days))
        }
        self.weeks = weeks
    }

    /// 통계 DB를 **한 번만** 읽어 격자를 만든다. `services`에 든 서비스의 토큰만 합친다.
    @MainActor
    public static func load(from store: DailyStatsStore, services: Set<ServiceID>, now: Date = Date(),
                            weekCount: Int = HeatmapGrid.defaultWeeks) -> HeatmapGrid {
        let rows = store.dailyTotals(days: weekCount * 7, now: now, calendar: calendar, services: services)
        var totals: [Date: Int] = [:]
        for row in rows { totals[calendar.startOfDay(for: row.day)] = row.tokens }
        return HeatmapGrid(totals: totals, today: now, weekCount: weekCount)
    }

    /// 5단계 양자화: 0 = 토큰 없음, 1~4 = 최댓값 대비 ≤25% / ≤50% / ≤75% / 그 이상.
    static func level(tokens: Int, max: Int) -> Int {
        guard tokens > 0 else { return 0 }
        let ratio = Double(tokens) / Double(max)
        if ratio <= 0.25 { return 1 }
        if ratio <= 0.50 { return 2 }
        if ratio <= 0.75 { return 3 }
        return 4
    }
}
