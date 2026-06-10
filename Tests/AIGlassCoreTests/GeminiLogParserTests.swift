import Foundation
import Testing
@testable import AIGlassCore

private let geminiJSON = """
[
 {"sessionId":"s1","messageId":0,"type":"user","message":"hello","timestamp":"2026-06-10T05:41:43.169Z"},
 {"sessionId":"s1","messageId":1,"type":"user","message":"/exit","timestamp":"2026-06-10T05:42:00.000Z"},
 {"sessionId":"s1","messageId":2,"type":"assistant","message":"bye","timestamp":"2026-06-10T05:42:01.000Z"}
]
"""

@Test func countsUserMessages() {
    let dates = GeminiLogParser.userMessageDates(jsonData: Data(geminiJSON.utf8))
    #expect(dates.count == 2)
    #expect(dates[0] == ISO8601.date("2026-06-10T05:41:43.169Z"))
}

@Test func toleratesMalformedJSON() {
    #expect(GeminiLogParser.userMessageDates(jsonData: Data("nope".utf8)).isEmpty)
    #expect(GeminiLogParser.userMessageDates(jsonData: Data("{}".utf8)).isEmpty)
}

@Test func dailyLimitFromRequestCount() {
    let now = ISO8601.date("2026-06-10T12:00:00Z")!
    let cal = Calendar.utc
    let today = [now.addingTimeInterval(-3600), now.addingTimeInterval(-60)]
    let yesterday = [now.addingTimeInterval(-26 * 3600)]
    let window = GeminiLogParser.dailyWindow(requestDates: today + yesterday, quota: 100, now: now, calendar: cal)
    #expect(window.kind == .daily)
    #expect(window.usedPercent == 2.0) // 오늘 2건 / 100
    #expect(window.resetsAt == cal.startOfDay(for: now).addingTimeInterval(24 * 3600))
}
