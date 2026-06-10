import Foundation
import Testing
@testable import AIGlassCore

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("aiglass-col-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private let claudeLine = """
{"type":"assistant","requestId":"req_1","timestamp":"TIMESTAMP","message":{"id":"msg_1","model":"claude-opus-4-8","usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
"""

private let codexLine = """
{"timestamp":"TIMESTAMP","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":200,"cached_input_tokens":0,"output_tokens":30}},"rate_limits":{"primary":{"used_percent":34.5,"window_minutes":299,"resets_in_seconds":17940},"secondary":{"used_percent":12.0,"window_minutes":10079,"resets_in_seconds":561809}}}}
"""

/// UsageStore의 retentionDays(8일) 컷오프에 걸리지 않도록 현재 시각 기반 타임스탬프 사용
private func stamped(_ template: String, secondsAgo: TimeInterval = 60) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return template.replacingOccurrences(of: "TIMESTAMP",
                                         with: f.string(from: Date().addingTimeInterval(-secondsAgo)))
}

@MainActor @Test func claudeCollectorFeedsStore() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data((stamped(claudeLine) + "\n").utf8).write(to: dir.appendingPathComponent("a.jsonl"))

    let store = UsageStore()
    let collector = ClaudeCollector(root: dir)
    collector.collect(into: store)
    #expect(store.events.count == 1)
    #expect(store.events.first?.model == "claude-opus-4-8")

    collector.collect(into: store) // 증분 — 중복 누적 없음
    #expect(store.events.count == 1)
}

@MainActor @Test func codexCollectorFeedsStoreAndLimits() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data((stamped(codexLine) + "\n").utf8).write(to: dir.appendingPathComponent("rollout.jsonl"))

    let store = UsageStore()
    let collector = CodexCollector(root: dir)
    collector.collect(into: store)
    #expect(store.events.count == 1)
    #expect(store.limits[.codex]?.count == 2)
    #expect(store.limits[.codex]?.first { $0.kind == .session5h }?.usedPercent == 34.5)
}

@MainActor @Test func geminiCollectorEstimatesDailyQuota() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let hashDir = dir.appendingPathComponent("abc123")
    try FileManager.default.createDirectory(at: hashDir, withIntermediateDirectories: true)
    let now = Date()
    let iso = ISO8601DateFormatter()
    let json = """
    [{"type":"user","timestamp":"\(iso.string(from: now))","message":"hi","messageId":0,"sessionId":"s"}]
    """
    try Data(json.utf8).write(to: hashDir.appendingPathComponent("logs.json"))

    let store = UsageStore()
    let collector = GeminiCollector(root: dir, dailyQuota: 100)
    collector.collect(into: store)
    #expect(store.geminiRequestDates.count == 1)
    #expect(store.limits[.gemini]?.first?.usedPercent == 1.0)
}
