import Foundation

public enum ISO8601 {
    private static let withFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    public static func date(_ s: String) -> Date? {
        if let fast = fastParse(s) { return fast }
        return withFrac.date(from: s) ?? plain.date(from: s)
    }

    /// 로그의 고정 형식(`YYYY-MM-DDTHH:MM:SS[.fff]Z` 또는 `±HH:MM`)을 직접 파싱한다.
    /// `ISO8601DateFormatter`는 ICU 기반이라 호출당 비용·임시 객체가 커서, 시작 때 수만 줄을 읽을 때
    /// 메인 스레드 시간의 대부분과 메모리 급증을 만들었다. 형식이 조금이라도 다르면 nil → 기존 포매터로 폴백한다.
    static func fastParse(_ s: String) -> Date? {
        s.utf8.withContiguousStorageIfAvailable { b -> Date? in
            let n = b.count
            guard n >= 20 else { return nil }
            @inline(__always) func digit(_ i: Int) -> Int? {
                let c = Int(b[i]) - 48
                return (0...9).contains(c) ? c : nil
            }
            @inline(__always) func num(_ from: Int, _ count: Int) -> Int? {
                var v = 0
                for i in from..<(from + count) {
                    guard let d = digit(i) else { return nil }
                    v = v * 10 + d
                }
                return v
            }
            guard b[4] == 45, b[7] == 45, b[10] == 84, b[13] == 58, b[16] == 58,   // - - T : :
                  let year = num(0, 4), let month = num(5, 2), let day = num(8, 2),
                  let hour = num(11, 2), let minute = num(14, 2), let second = num(17, 2),
                  (1...12).contains(month), hour < 24, minute < 60, second < 60 else { return nil }
            let daysInMonth = [31, (year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)) ? 29 : 28,
                               31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
            guard (1...daysInMonth[month - 1]).contains(day) else { return nil }

            var i = 19
            var frac = 0.0
            if b[i] == 46 { // .
                i += 1
                var scale = 0.1
                var digits = 0
                while i < n, let d = digit(i) {
                    frac += Double(d) * scale
                    scale /= 10
                    digits += 1
                    i += 1
                }
                guard digits > 0 else { return nil }
            }
            var offset = 0
            guard i < n else { return nil }
            if b[i] == 90, i == n - 1 { // Z
                offset = 0
            } else if (b[i] == 43 || b[i] == 45), n - i == 6, b[i + 3] == 58,
                      let oh = num(i + 1, 2), let om = num(i + 4, 2), oh < 24, om < 60 {
                offset = (oh * 3600 + om * 60) * (b[i] == 45 ? -1 : 1)
            } else {
                return nil
            }

            // 민간 달력 → 1970-01-01 기준 일수 (Howard Hinnant의 days_from_civil)
            let y = month <= 2 ? year - 1 : year
            let era = (y >= 0 ? y : y - 399) / 400
            let yoe = y - era * 400
            let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
            let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
            let days = era * 146097 + doe - 719468
            let seconds = days * 86400 + hour * 3600 + minute * 60 + second - offset
            return Date(timeIntervalSince1970: Double(seconds) + frac)
        } ?? nil
    }
}

public extension Calendar {
    /// UTC calendar — 타임존에 독립적인 테스트/집계에 사용
    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
}
