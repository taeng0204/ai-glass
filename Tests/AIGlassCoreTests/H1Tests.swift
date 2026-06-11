import Foundation
import Testing
@testable import AIGlassCore

// ─── ① ClaudeLogParser cwd → project ───────────────────────────────────────

private let claudeLineWithCwd = """
{"parentUuid":"x","cwd":"/Users/alice/projects/my-app","sessionId":"s1","type":"assistant","requestId":"req_1","timestamp":"2026-06-10T10:52:36.739Z","uuid":"u1","message":{"id":"msg_1","type":"message","role":"assistant","model":"claude-opus-4-8","usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
"""

private let claudeLineNoCwd = """
{"parentUuid":"x","sessionId":"s1","type":"assistant","requestId":"req_2","timestamp":"2026-06-10T10:52:36.739Z","uuid":"u2","message":{"id":"msg_2","type":"message","role":"assistant","model":"claude-opus-4-8","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
"""

private let claudeLineEmptyCwd = """
{"parentUuid":"x","cwd":"","sessionId":"s1","type":"assistant","requestId":"req_3","timestamp":"2026-06-10T10:52:36.739Z","uuid":"u3","message":{"id":"msg_3","type":"message","role":"assistant","model":"claude-opus-4-8","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
"""

@Test func claudeParserExtractsProjectFromCwd() throws {
    let (event, _) = try #require(ClaudeLogParser.parse(line: claudeLineWithCwd))
    #expect(event.project == "my-app")
}

@Test func claudeParserNilProjectWhenNoCwd() throws {
    let (event, _) = try #require(ClaudeLogParser.parse(line: claudeLineNoCwd))
    #expect(event.project == nil)
}

@Test func claudeParserNilProjectWhenEmptyCwd() throws {
    let (event, _) = try #require(ClaudeLogParser.parse(line: claudeLineEmptyCwd))
    #expect(event.project == nil)
}

// ─── ② CodexLogParser parseSessionMeta ────────────────────────────────────

private let sessionMetaLine = """
{"timestamp":"2026-06-10T14:00:00.000Z","type":"session_meta","payload":{"id":"sess-abc","cwd":"/Users/bob/workspace/ai-glass","cli_version":"1.2.3"}}
"""

private let nonSessionMetaLine = """
{"timestamp":"2026-06-10T14:10:20.726Z","type":"event_msg","payload":{"type":"token_count","info":null}}
"""

@Test func parseSessionMetaReturnsLastPathComponent() throws {
    let project = try #require(CodexLogParser.parseSessionMeta(line: sessionMetaLine))
    #expect(project == "ai-glass")
}

@Test func parseSessionMetaReturnsNilForNonSessionMeta() {
    #expect(CodexLogParser.parseSessionMeta(line: nonSessionMetaLine) == nil)
    #expect(CodexLogParser.parseSessionMeta(line: "garbage") == nil)
    #expect(CodexLogParser.parseSessionMeta(line: "") == nil)
}

@Test func parseSessionMetaCwdEqualToHomeBecomesTilde() throws {
    let prev = CodexLogParser.homeDirectoryOverride
    defer { CodexLogParser.homeDirectoryOverride = prev }
    CodexLogParser.homeDirectoryOverride = "/Users/bob"
    let line = #"{"timestamp":"2026-06-10T14:00:00.000Z","type":"session_meta","payload":{"id":"s","cwd":"/Users/bob"}}"#
    #expect(CodexLogParser.parseSessionMeta(line: line) == "~")
    // 홈이 아니면 lastPathComponent
    #expect(CodexLogParser.parseSessionMeta(line: sessionMetaLine) == "ai-glass")
}

// ─── ③ recentShare 비중 ────────────────────────────────────────────────────

@MainActor @Test func recentShareReturnsProportions() {
    let now = ISO8601.date("2026-06-10T12:00:00Z")!
    let store = UsageStore()

    func ev(_ service: ServiceID, minutesAgo: Double, total: Int) -> (TokenEvent, String?) {
        let e = TokenEvent(service: service, timestamp: now.addingTimeInterval(-minutesAgo * 60),
                           model: "m", inputTokens: total, outputTokens: 0,
                           cacheReadTokens: 0, cacheCreationTokens: 0)
        return (e, nil)
    }

    // claude 3000 tokens (2분 전), codex 1000 tokens (1분 전) — 둘 다 최근 3분 내
    store.addEvents([
        ev(.claude, minutesAgo: 2, total: 3000),
        ev(.codex,  minutesAgo: 1, total: 1000),
    ])

    let share = store.recentShare(windowMinutes: 3, now: now)
    #expect(share.count == 2)
    #expect(abs((share[.claude] ?? 0) - 0.75) < 0.001)
    #expect(abs((share[.codex]  ?? 0) - 0.25) < 0.001)
}

@MainActor @Test func recentShareEmptyWhenNoActivity() {
    let now = ISO8601.date("2026-06-10T12:00:00Z")!
    let store = UsageStore()
    #expect(store.recentShare(windowMinutes: 3, now: now).isEmpty)
}

// ─── ④ projectBreakdown 집계/정렬/nil 제외 ────────────────────────────────

@MainActor @Test func projectBreakdownAggregatesAndExcludesNil() {
    let now = ISO8601.date("2026-06-10T12:00:00Z")!
    let store = UsageStore()

    func ev(_ project: String?, minutesAgo: Double, total: Int) -> (TokenEvent, String?) {
        let e = TokenEvent(service: .claude, timestamp: now.addingTimeInterval(-minutesAgo * 60),
                           model: "m", inputTokens: total, outputTokens: 0,
                           cacheReadTokens: 0, cacheCreationTokens: 0,
                           project: project)
        return (e, nil)
    }

    store.addEvents([
        ev("ai-glass",  minutesAgo: 5,   total: 2000),
        ev("ai-glass",  minutesAgo: 10,  total: 1000),   // 합산 3000
        ev("my-server", minutesAgo: 15,  total: 4000),
        ev(nil,         minutesAgo: 20,  total: 9999),   // nil 제외
    ])

    let breakdown = store.projectBreakdown(days: 7, now: now, calendar: .utc)
    #expect(breakdown.count == 2)
    #expect(breakdown[0].project == "my-server")
    #expect(breakdown[0].tokens == 4000)
    #expect(breakdown[1].project == "ai-glass")
    #expect(breakdown[1].tokens == 3000)
}

// ─── ⑤ dailyTotalsByService ───────────────────────────────────────────────

@MainActor @Test func dailyTotalsByServiceReturnsPerServiceRows() {
    let now = ISO8601.date("2026-06-10T12:00:00Z")!
    let store = UsageStore()

    func ev(_ service: ServiceID, hoursAgo: Double, total: Int) -> (TokenEvent, String?) {
        let e = TokenEvent(service: service, timestamp: now.addingTimeInterval(-hoursAgo * 3600),
                           model: "m", inputTokens: total, outputTokens: 0,
                           cacheReadTokens: 0, cacheCreationTokens: 0)
        return (e, nil)
    }

    // 오늘 (UTC 2026-06-10)
    store.addEvents([
        ev(.claude, hoursAgo: 1, total: 1000),
        ev(.claude, hoursAgo: 2, total: 500),   // claude today = 1500
        ev(.codex,  hoursAgo: 3, total: 800),   // codex today = 800
        // 어제 (UTC 2026-06-09)
        ev(.claude, hoursAgo: 25, total: 200),  // claude yesterday = 200
    ])

    let rows = store.dailyTotalsByService(days: 7, now: now, calendar: .utc)

    // 활동이 있는 (day, service) 조합만 직접 검증
    let claudeToday = rows.first { r in
        let cal = Calendar.utc
        let today = cal.startOfDay(for: now)
        return cal.isDate(r.day, inSameDayAs: today) && r.service == .claude
    }
    #expect(claudeToday?.tokens == 1500)

    let codexToday = rows.first { r in
        let cal = Calendar.utc
        let today = cal.startOfDay(for: now)
        return cal.isDate(r.day, inSameDayAs: today) && r.service == .codex
    }
    #expect(codexToday?.tokens == 800)

    let claudeYesterday = rows.first { r in
        let cal = Calendar.utc
        let yesterday = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now))!
        return cal.isDate(r.day, inSameDayAs: yesterday) && r.service == .claude
    }
    #expect(claudeYesterday?.tokens == 200)

    // gemini가 없으면 rows에 gemini 행 없음 (또는 0일 수 있음 — 최소한 양수 확인)
    #expect(rows.allSatisfy { $0.tokens > 0 })
}

// ─── ⑥ CodexCollector가 session_meta에서 project 부여 ───────────────────

@MainActor @Test func codexCollectorAssignsProjectFromSessionMeta() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("aiglass-h1-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    // session_meta 첫 라인 + token_count 두 번째 라인
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let ts = f.string(from: Date().addingTimeInterval(-60))

    let sessionMetaLine = """
    {"timestamp":"\(ts)","type":"session_meta","payload":{"id":"sess-1","cwd":"/Users/test/projects/my-proj","cli_version":"1.0.0"}}
    """
    let tokenLine = """
    {"timestamp":"\(ts)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":20}},"rate_limits":{"primary":{"used_percent":10.0,"window_minutes":299,"resets_in_seconds":1000},"secondary":{"used_percent":5.0,"window_minutes":10079,"resets_in_seconds":2000}}}}
    """

    let content = sessionMetaLine + "\n" + tokenLine + "\n"
    try Data(content.utf8).write(to: dir.appendingPathComponent("session.jsonl"))

    let store = UsageStore()
    let collector = CodexCollector(root: dir)
    collector.collect(into: store)

    #expect(store.events.count == 1)
    #expect(store.events.first?.project == "my-proj")
}
