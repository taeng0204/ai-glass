import Foundation
import Testing
@testable import AIGlassCore

private let codexLine = """
{"timestamp":"2026-06-10T14:10:20.726Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10693227,"cached_input_tokens":10102400,"output_tokens":89540,"reasoning_output_tokens":40000,"total_tokens":10782767},"last_token_usage":{"input_tokens":93100,"cached_input_tokens":1920,"output_tokens":541,"reasoning_output_tokens":256,"total_tokens":93641},"model_context_window":272000},"rate_limits":{"primary":{"used_percent":34.5,"window_minutes":299,"resets_in_seconds":17940},"secondary":{"used_percent":12.0,"window_minutes":10079,"resets_in_seconds":561809}}}}
"""

private let codexLineNullInfo = """
{"timestamp":"2026-06-10T14:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"primary":{"used_percent":10.0,"window_minutes":299,"resets_in_seconds":1000},"secondary":{"used_percent":5.0,"window_minutes":10079,"resets_in_seconds":2000}}}}
"""

@Test func parsesTokenCountWithInfo() throws {
    let p = try #require(CodexLogParser.parse(line: codexLine))
    let event = try #require(p.event)
    // input은 캐시 제외분: 93100 - 1920 = 91180
    #expect(event.inputTokens == 91180)
    #expect(event.cacheReadTokens == 1920)
    #expect(event.outputTokens == 541)
    #expect(event.service == .codex)
    #expect(p.limits.count == 2)
    let session = try #require(p.limits.first { $0.kind == .session5h })
    #expect(session.usedPercent == 34.5)
    #expect(session.resetsAt == p.timestamp.addingTimeInterval(17940))
    #expect(p.limits.contains { $0.kind == .weekly && $0.usedPercent == 12.0 })
}

/// 최신 Codex CLI 스키마: resets_in_seconds 대신 절대 epoch 초 `resets_at`.
private let codexLineResetsAtEpoch = """
{"timestamp":"2026-06-11T12:02:33.568Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"limit_id":"codex","limit_name":null,"primary":{"used_percent":1.0,"window_minutes":300,"resets_at":1781196928},"secondary":{"used_percent":1.0,"window_minutes":10080,"resets_at":1781765689},"credits":{"has_credits":false,"unlimited":false,"balance":"0"},"plan_type":"pro"}}}
"""

@Test func parsesResetsAtEpochSchema() throws {
    let parsed = try #require(CodexLogParser.parse(line: codexLineResetsAtEpoch))
    #expect(parsed.limits.count == 2)
    let session = try #require(parsed.limits.first { $0.kind == .session5h })
    #expect(session.resetsAt == Date(timeIntervalSince1970: 1_781_196_928))
    let weekly = try #require(parsed.limits.first { $0.kind == .weekly })
    #expect(weekly.resetsAt == Date(timeIntervalSince1970: 1_781_765_689))
}

@Test func parsesTokenCountWithNullInfo() throws {
    let parsed = try #require(CodexLogParser.parse(line: codexLineNullInfo))
    #expect(parsed.event == nil)
    #expect(parsed.limits.count == 2)
}

@Test func parsesTokenCountWithMissingRateLimits() throws {
    let line = #"{"timestamp":"2026-06-10T14:00:00Z","type":"event_msg","payload":{"type":"token_count","info":null}}"#
    let parsed = try #require(CodexLogParser.parse(line: line))
    #expect(parsed.limits.isEmpty)
    #expect(parsed.event == nil)
}

@Test func skipsNonTokenCountLines() {
    #expect(CodexLogParser.parse(line: #"{"timestamp":"2026-06-10T14:00:00Z","type":"event_msg","payload":{"type":"agent_message"}}"#) == nil)
    #expect(CodexLogParser.parse(line: "garbage") == nil)
}
