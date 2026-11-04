import Foundation
import Testing
@testable import AIGlassCore

/// 빠른 직접 파서는 기존 ISO8601DateFormatter와 같은 결과여야 한다 (밀리초 오차 이내).
private func reference(_ s: String) -> Date? {
    let a = ISO8601DateFormatter(); a.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let b = ISO8601DateFormatter(); b.formatOptions = [.withInternetDateTime]
    return a.date(from: s) ?? b.date(from: s)
}

@Test func fastParseMatchesFormatterOnTypicalLogTimestamps() throws {
    let samples = [
        "2026-06-10T10:52:36.739Z", "2026-11-04T06:44:28.000Z", "2026-11-04T06:44:28Z",
        "1970-01-01T00:00:00Z", "2000-02-29T23:59:59.999Z", "2024-02-29T12:00:00Z",
        "2026-12-31T23:59:59.123456Z", "2026-03-08T02:30:00+09:00", "2026-03-08T02:30:00.5-05:30",
        "1999-12-31T23:59:59Z", "2100-03-01T00:00:00Z",
    ]
    for s in samples {
        let fast = try #require(ISO8601.fastParse(s), "fast 파서가 \(s)를 못 읽음")
        let ref = try #require(reference(s))
        #expect(abs(fast.timeIntervalSince(ref)) < 0.001, "\(s): fast=\(fast.timeIntervalSince1970) ref=\(ref.timeIntervalSince1970)")
        // 공개 API도 같은 값
        #expect(ISO8601.date(s) == fast)
    }
}

@Test func fastParseMatchesFormatterAcrossManyDates() throws {
    // 2020~2030을 불규칙한 간격으로 훑어 달력 계산(윤년·월말)을 대조한다.
    var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var t = utc.date(from: DateComponents(year: 2020, month: 1, day: 1))!.timeIntervalSince1970
    let end = utc.date(from: DateComponents(year: 2030, month: 1, day: 1))!.timeIntervalSince1970
    var checked = 0
    while t < end {
        let d = Date(timeIntervalSince1970: t)
        let s = f.string(from: d)
        let fast = try #require(ISO8601.fastParse(s))
        #expect(abs(fast.timeIntervalSince(d)) < 0.002, "\(s)")
        checked += 1
        t += 86_399.37 * 1.7 // 하루보다 조금 큰 불규칙 보폭
    }
    #expect(checked > 2000)
}

@Test func fastParseRejectsMalformedAndFallsBackToFormatter() {
    let bad = ["", "2026-06-10", "2026-06-10 10:52:36Z", "2026-13-10T10:52:36Z", "2026-02-30T10:52:36Z",
               "2026-06-10T25:00:00Z", "2026-06-10T10:61:00Z", "2026-06-10T10:52:36", "2026-06-10T10:52:36.Z",
               "2026-06-10T10:52:36+0900", "garbage-garbage-garbage", "2026-06-10T10:52:36Zextra"]
    for s in bad { #expect(ISO8601.fastParse(s) == nil, "\(s)") }
    // 공개 API는 포매터 폴백이므로 ISO8601DateFormatter가 읽는 형식(+0900 없는 형태 등)은 여전히 처리한다
    #expect(ISO8601.date("2026-06-10T10:52:36Z") != nil)
}
