import Foundation
import Testing
@testable import AIGlassCore

@Test func antigravityParsesNormalEntries() {
    let json = """
    {"display":"first prompt","timestamp":1780910341188,"workspace":"/Users/taeng02/Desktop/dev/hack-nas","conversationId":"c1"}
    {"display":"second","timestamp":1780910400000,"workspace":"/Users/taeng02/Desktop/dev/ai-glass","conversationId":"c2"}
    """
    let entries = AntigravityLogParser.entries(jsonData: Data(json.utf8))
    #expect(entries.count == 2)
    #expect(entries[0].project == "hack-nas")
    #expect(entries[1].project == "ai-glass")
}

@Test func antigravityConvertsMillisecondsToDate() {
    let json = #"{"display":"x","timestamp":1780910341188,"workspace":"/a/b"}"#
    let entries = AntigravityLogParser.entries(jsonData: Data(json.utf8))
    #expect(entries.count == 1)
    // 1780910341188 ms == 1780910341.188 s
    #expect(abs(entries[0].date.timeIntervalSince1970 - 1780910341.188) < 0.001)
}

@Test func antigravityHandlesMissingWorkspace() {
    let json = #"{"display":"x","timestamp":1780910341188}"#
    let entries = AntigravityLogParser.entries(jsonData: Data(json.utf8))
    #expect(entries.count == 1)
    #expect(entries[0].project == nil)
}

@Test func antigravityWorkspaceMatchingHomeReturnsTilde() {
    let prev = AntigravityLogParser.homeDirectoryOverride
    defer { AntigravityLogParser.homeDirectoryOverride = prev }
    AntigravityLogParser.homeDirectoryOverride = "/Users/me"
    let json = #"{"display":"x","timestamp":1780910341188,"workspace":"/Users/me"}"#
    let entries = AntigravityLogParser.entries(jsonData: Data(json.utf8))
    #expect(entries.count == 1)
    #expect(entries[0].project == "~")
}

@Test func antigravityIgnoresGarbageLines() {
    let json = """
    {"display":"ok","timestamp":1780910341188,"workspace":"/a/proj"}
    this is not json
    {"display":"no timestamp","workspace":"/a/x"}
    {invalid
    """
    let entries = AntigravityLogParser.entries(jsonData: Data(json.utf8))
    #expect(entries.count == 1)
    #expect(entries[0].project == "proj")
}

@Test func antigravityConversationWorkspacesJoinsByConversationId() {
    let json = """
    {"display":"a","timestamp":1780910341188,"workspace":"/Users/me/Desktop/dev/hack-nas","conversationId":"c1"}
    {"display":"b","timestamp":1780910400000,"workspace":"/Users/me/Desktop/dev/ai-glass","conversationId":"c2"}
    {"display":"c","timestamp":1780910500000,"workspace":"/Users/me/Desktop/dev/ai-glass","conversationId":"c2"}
    """
    let map = AntigravityLogParser.conversationWorkspaces(jsonData: Data(json.utf8))
    #expect(map.count == 2)
    #expect(map["c1"] == "hack-nas")
    #expect(map["c2"] == "ai-glass")
}

@Test func antigravityConversationWorkspacesHandlesHomeAndMissing() {
    let prev = AntigravityLogParser.homeDirectoryOverride
    defer { AntigravityLogParser.homeDirectoryOverride = prev }
    AntigravityLogParser.homeDirectoryOverride = "/Users/me"
    let json = """
    {"display":"a","timestamp":1780910341188,"workspace":"/Users/me","conversationId":"home"}
    {"display":"b","timestamp":1780910400000,"conversationId":"noworkspace"}
    {"display":"c","timestamp":1780910500000,"workspace":"/x/y"}
    """
    let map = AntigravityLogParser.conversationWorkspaces(jsonData: Data(json.utf8))
    #expect(map["home"] == "~")
    #expect(map["noworkspace"] == nil) // workspace 없음 → 엔트리 없음
    #expect(map.count == 1)
}

@Test func antigravityParsesModelRequestLogLines() {
    let log = """
    I0611 23:20:50.123456 19134 http_helpers.go:183] URL: https://daily-cloudcode-pa.googleapis.com/v1internal:streamGenerateContent?alt=sse Trace: 0x1
    I0611 23:20:51.123456 19134 http_helpers.go:183] URL: https://example.invalid/noop
    I0611 23:21:00.000000 19134 http_helpers.go:183] URL: https://daily-cloudcode-pa.googleapis.com/v1internal:streamGenerateContent?alt=sse Trace: 0x2
    """
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let dates = AntigravityLogParser.modelRequestDates(logData: Data(log.utf8),
                                                       year: 2026,
                                                       calendar: calendar)
    #expect(dates.count == 2)
    let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: dates[0])
    #expect(comps.year == 2026)
    #expect(comps.month == 6)
    #expect(comps.day == 11)
    #expect(comps.hour == 23)
    #expect(comps.minute == 20)
    #expect(comps.second == 50)
}

@Test func antigravityRollsYearWhenLogCrossesYearBoundary() {
    // 12월에 생성된 파일이 해를 넘겨 1월 로그를 기록하면 연도를 +1 보정한다.
    let log = """
    I1231 23:59:50.000000 1 http_helpers.go:183] URL: https://daily-cloudcode-pa.googleapis.com/v1internal:streamGenerateContent?alt=sse Trace: 0x1
    I0101 00:00:05.000000 1 http_helpers.go:183] URL: https://daily-cloudcode-pa.googleapis.com/v1internal:streamGenerateContent?alt=sse Trace: 0x2
    """
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let dates = AntigravityLogParser.modelRequestDates(logData: Data(log.utf8),
                                                       year: 2025, fileStartMonth: 12,
                                                       calendar: calendar)
    #expect(dates.count == 2)
    #expect(calendar.component(.year, from: dates[0]) == 2025) // 12-31
    #expect(calendar.component(.year, from: dates[1]) == 2026) // 01-01 → 다음 해
}
