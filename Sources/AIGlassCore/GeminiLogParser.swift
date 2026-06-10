import Foundation

public enum GeminiLogParser {
    /// logs.json(배열) → user 메시지 타임스탬프 목록
    public static func userMessageDates(jsonData: Data) -> [Date] {
        guard let arr = (try? JSONSerialization.jsonObject(with: jsonData)) as? [[String: Any]] else {
            return []
        }
        return arr.compactMap { entry in
            guard entry["type"] as? String == "user",
                  let ts = entry["timestamp"] as? String else { return nil }
            return ISO8601.date(ts)
        }
    }

    /// 일일 요청 수 → 쿼터 % 추정 윈도우. 리셋은 다음 자정.
    public static func dailyWindow(requestDates: [Date], quota: Int, now: Date,
                                   calendar: Calendar = .current) -> LimitWindow {
        let start = calendar.startOfDay(for: now)
        let todayCount = requestDates.filter { $0 >= start && $0 <= now }.count
        let percent = quota > 0 ? Double(todayCount) / Double(quota) * 100.0 : 0
        return LimitWindow(kind: .daily, usedPercent: min(100, percent),
                           resetsAt: calendar.date(byAdding: .day, value: 1, to: start))
    }
}
