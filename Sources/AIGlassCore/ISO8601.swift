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
        withFrac.date(from: s) ?? plain.date(from: s)
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
